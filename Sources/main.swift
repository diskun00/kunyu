// Kunyu (坤语): tap right Option to record, tap again to transcribe via OpenRouter,
// then paste at the cursor (result also stays on the clipboard).
// Menu bar: history, usage/cost, last 3 recordings for retry, model and language.
import AVFoundation
import ApplicationServices
import Cocoa
import ServiceManagement

let appName = "Kunyu"
let keychainService = "kunyu-openrouter"
let endpoint = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
var model: String { UserDefaults.standard.string(forKey: "model") ?? "elevenlabs/scribe-v2" }
var language: String? { UserDefaults.standard.string(forKey: "language") }  // nil = auto-detect

let dataDir: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(appName, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir.appendingPathComponent("recordings"),
                                             withIntermediateDirectories: true)
    return dir
}()

// MARK: - Transcription

struct KunyuError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Transcript {
    let text: String
    let seconds: Double?  // billed audio length
    let cost: Double?     // USD, as reported by OpenRouter
}

func apiKey() throws -> String {
    if let env = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !env.isEmpty { return env }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", keychainService, "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try p.run()
    p.waitUntilExit()
    let key = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard p.terminationStatus == 0, !key.isEmpty else {
        throw KunyuError(message: "No API key in Keychain (service \"\(keychainService)\")")
    }
    return key
}

func transcribe(_ file: URL) async throws -> Transcript {
    let audio = try Data(contentsOf: file)
    let boundary = "Boundary-\(UUID().uuidString)"
    var body = Data()
    func field(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }
    field("model", model)
    if let language, !language.isEmpty { field("language", language) }
    body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
    body.append(audio)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

    var req = URLRequest(url: endpoint, timeoutInterval: 60)
    req.httpMethod = "POST"
    req.setValue("Bearer \(try apiKey())", forHTTPHeaderField: "Authorization")
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    req.setValue(appName, forHTTPHeaderField: "X-Title")
    req.httpBody = body

    let (data, resp) = try await URLSession.shared.data(for: req)
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard (200...299).contains(status) else {
        let msg = (json?["error"] as? [String: Any])?["message"] as? String
            ?? String(data: data, encoding: .utf8)?.prefix(200).description ?? ""
        throw KunyuError(message: "HTTP \(status): \(msg)")
    }
    guard let text = json?["text"] as? String else {
        throw KunyuError(message: "Unexpected response: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
    }
    let usage = json?["usage"] as? [String: Any]
    return Transcript(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                      seconds: (usage?["seconds"] as? NSNumber)?.doubleValue,
                      cost: (usage?["cost"] as? NSNumber)?.doubleValue)
}

// MARK: - Persistence

func loadJSON<T: Decodable>(_ type: T.Type, _ file: URL) -> T? {
    guard let data = try? Data(contentsOf: file) else { return nil }
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    return try? dec.decode(type, from: data)
}

func saveJSON<T: Encodable>(_ value: T, _ file: URL) {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    try? enc.encode(value).write(to: file, options: .atomic)
}

struct Entry: Codable {
    let date: Date
    let text: String
    var model: String?
    var seconds: Double?
    var cost: Double?
}

/// Every successful transcription, newest first. Usage totals are computed from it,
/// so history is capped generously (a year of heavy use is a few MB).
final class History {
    static let maxEntries = 20_000
    let file = dataDir.appendingPathComponent("history.json")
    private(set) var entries: [Entry] = []

    init() { entries = loadJSON([Entry].self, file) ?? [] }

    func add(_ e: Entry) {
        entries.insert(e, at: 0)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        saveJSON(entries, file)
    }

    /// (cost, seconds, count) for entries on or after `since`.
    func usage(since: Date = .distantPast) -> (cost: Double, seconds: Double, count: Int) {
        entries.filter { $0.date >= since }.reduce((0, 0, 0)) {
            ($0.0 + ($1.cost ?? 0), $0.1 + ($1.seconds ?? 0), $0.2 + 1)
        }
    }
}

struct Recording: Codable {
    let file: String  // name inside recordings/
    let date: Date
    let duration: Double
    var error: String?  // nil = transcribed fine (or not yet)
}

/// The last few recordings, kept on disk so they can be re-transcribed.
final class Recordings {
    static let keep = 3
    let dir = dataDir.appendingPathComponent("recordings")
    let index = dataDir.appendingPathComponent("recordings/index.json")
    private(set) var items: [Recording] = []  // newest first

    init() {
        items = (loadJSON([Recording].self, index) ?? []).filter {
            FileManager.default.fileExists(atPath: url($0).path)
        }
    }

    func url(_ r: Recording) -> URL { dir.appendingPathComponent(r.file) }
    func newURL() -> URL { dir.appendingPathComponent("\(UUID().uuidString).m4a") }

    func add(_ r: Recording) {
        items.insert(r, at: 0)
        while items.count > Self.keep { try? FileManager.default.removeItem(at: url(items.removeLast())) }
        saveJSON(items, index)
    }

    func setError(_ file: String, _ error: String?) {
        guard let i = items.firstIndex(where: { $0.file == file }) else { return }
        items[i].error = error
        saveJSON(items, index)
    }
}

// MARK: - Formatting

func money(_ v: Double) -> String {
    v == 0 ? "$0" : v < 0.01 ? String(format: "$%.4f", v) : String(format: "$%.2f", v)
}

func minutes(_ s: Double) -> String { s < 60 ? String(format: "%.0f s", s) : String(format: "%.1f min", s / 60) }

/// The 坤 mark (six broken lines) from the Diskun design system, on its 64×64 grid.
/// `solid` closes the gaps (乾), used while transcribing.
func markImage(size: CGFloat, solid: Bool) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
        let s = size / 64
        NSColor.black.setFill()
        for i in 0..<6 {
            let y = CGFloat(4 + i * 10) * s
            let bars = solid ? [(4.0, 56.0)] : [(4.0, 24.0), (36.0, 24.0)]
            for (x, w) in bars {
                NSBezierPath(roundedRect: NSRect(x: x * s, y: y, width: w * s, height: 6 * s),
                             xRadius: 3 * s, yRadius: 3 * s).fill()
            }
        }
        return true
    }
    img.isTemplate = true
    return img
}

// MARK: - App

enum State { case idle, recording, transcribing }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let history = History()
    let recordings = Recordings()
    var recorder: AVAudioRecorder?
    var state = State.idle { didSet { updateIcon() } }
    var lastError: String?
    var monitorsInstalled = false
    var monitorsInstalledAtLaunch = false

    // Right-Option tap detection: fire on release if nothing else was pressed in between.
    var rightOptionDownAt: Date?
    var tapSpoiled = false
    static let rightOptionKeyCode: UInt16 = 61
    static let rightOptionMask: UInt = 0x40  // NX_DEVICERALTKEYMASK

    func applicationDidFinishLaunching(_ note: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.updateIcon() } }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) { installMonitors(); monitorsInstalledAtLaunch = true }
        // Keep the menu bar "!" in sync with permissions granted or revoked in System Settings.
        // Key monitors are only installed once Accessibility is granted (useless before).
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if AXIsProcessTrusted() { self.installMonitors() }
            self.updateIcon()
        }
    }

    // MARK: Permissions

    var hasAccessibility: Bool { AXIsProcessTrusted() }
    var micStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    var permissionsMissing: Bool { !hasAccessibility || micStatus != .authorized }

    func openPrivacyPane(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    @objc func grantAccessibility() {
        // Adds Kunyu to the list (switched off) and shows the system prompt, then opens the pane.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        openPrivacyPane("Privacy_Accessibility")
    }

    @objc func grantMicrophone() {
        if micStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.updateIcon() } }
        } else {
            openPrivacyPane("Privacy_Microphone")
        }
    }

    @objc func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }

    func installMonitors() {
        guard !monitorsInstalled else { return }
        monitorsInstalled = true
        NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in self?.handle(e) }
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in self?.handle(e); return e }
        updateIcon()
    }

    func handle(_ e: NSEvent) {
        if e.type == .keyDown {
            if rightOptionDownAt != nil { tapSpoiled = true }
            if e.keyCode == 53, state == .recording { cancelRecording() }  // Esc
            return
        }
        guard e.keyCode == Self.rightOptionKeyCode else {
            if rightOptionDownAt != nil { tapSpoiled = true }  // another modifier joined in
            return
        }
        let isDown = e.modifierFlags.rawValue & Self.rightOptionMask != 0
        if isDown {
            let others = e.modifierFlags.intersection([.command, .control, .shift, .function])
            rightOptionDownAt = Date()
            tapSpoiled = !others.isEmpty
        } else if let downAt = rightOptionDownAt {
            rightOptionDownAt = nil
            if !tapSpoiled, Date().timeIntervalSince(downAt) < 0.4 { toggle() }
        }
    }

    func toggle() {
        switch state {
        case .idle: startRecording()
        case .recording: stopAndTranscribe()
        case .transcribing: NSSound.beep()
        }
    }

    func startRecording() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            fail("Microphone access denied (System Settings > Privacy & Security > Microphone)")
            return
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
        ]
        do {
            let r = try AVAudioRecorder(url: recordings.newURL(), settings: settings)
            guard r.record() else { throw KunyuError(message: "Recorder failed to start") }
            recorder = r
            state = .recording
            NSSound(named: "Tink")?.play()
        } catch {
            fail("Could not record: \(error.localizedDescription)")
        }
    }

    func cancelRecording() {
        guard let r = recorder else { return }
        r.stop()
        try? FileManager.default.removeItem(at: r.url)
        recorder = nil
        state = .idle
        NSSound(named: "Funk")?.play()
    }

    func stopAndTranscribe() {
        guard let r = recorder else { return }
        let duration = r.currentTime
        r.stop()
        recorder = nil
        if duration < 0.4 {  // stray double-tap: not worth an API call
            try? FileManager.default.removeItem(at: r.url)
            state = .idle
            return
        }
        NSSound(named: "Pop")?.play()
        let rec = Recording(file: r.url.lastPathComponent, date: Date(), duration: duration)
        recordings.add(rec)
        run(rec)
    }

    func run(_ rec: Recording) {
        state = .transcribing
        let audio = recordings.url(rec)
        Task.detached {
            do {
                let t = try await transcribe(audio)
                await MainActor.run { self.finish(t, rec: rec) }
            } catch {
                await MainActor.run {
                    self.recordings.setError(rec.file, error.localizedDescription)
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    func finish(_ t: Transcript, rec: Recording) {
        state = .idle
        lastError = nil
        recordings.setError(rec.file, nil)
        guard !t.text.isEmpty else { NSSound.beep(); return }
        history.add(Entry(date: Date(), text: t.text, model: model, seconds: t.seconds ?? rec.duration, cost: t.cost))
        copy(t.text)
        // Small delay so the just-released Option key can't leak into the paste.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.pasteIntoFrontApp() }
    }

    func fail(_ message: String) {
        state = .idle
        lastError = message
        NSSound(named: "Basso")?.play()
        NSLog("Kunyu error: %@", message)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func pasteIntoFrontApp() {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)  // 'V'
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Menu bar

    func updateIcon() {
        guard let button = statusItem.button else { return }
        button.image = markImage(size: 16, solid: state == .transcribing)
        button.image?.accessibilityDescription = appName
        button.contentTintColor = state == .recording ? .systemRed : nil
        let missing = permissionsMissing
        button.alphaValue = missing ? 0.5 : 1
        button.title = missing ? "!" : ""
        button.imagePosition = .imageLeading
        button.toolTip = missing ? "\(appName) needs permissions: click to grant" : appName
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String
        if !monitorsInstalled {
            status = "Grant Accessibility access to enable right ⌥"
        } else {
            switch state {
            case .idle: status = "Tap right ⌥ to dictate"
            case .recording: status = "Recording… tap right ⌥ to finish, Esc to cancel"
            case .transcribing: status = "Transcribing…"
            }
        }
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        if permissionsMissing {
            if !hasAccessibility {
                let it = item("⚠︎ Grant Accessibility…  (hotkey and paste)", #selector(grantAccessibility))
                it.toolTip = "Opens System Settings. Switch Kunyu on in the list."
                menu.addItem(it)
            }
            if micStatus != .authorized {
                let it = item("⚠︎ Grant Microphone…", #selector(grantMicrophone))
                it.toolTip = micStatus == .notDetermined ? "Shows the microphone prompt"
                    : "Opens System Settings. Switch Kunyu on in the list."
                menu.addItem(it)
            }
        }
        if hasAccessibility {
            // Escape hatch: if the hotkey stays dead after granting, a fresh process fixes it.
            if !monitorsInstalledAtLaunch {
                menu.addItem(item("Relaunch Kunyu (if right ⌥ doesn't respond)", #selector(relaunch)))
            }
        }
        if let lastError {
            let item = menu.addItem(withTitle: "⚠︎ \(lastError.prefix(80))", action: nil, keyEquivalent: "")
            item.toolTip = lastError
        }
        if let latest = recordings.items.first, latest.error != nil, state == .idle {
            menu.addItem(retryItem("Retry Failed Recording", latest))
        }

        menu.addItem(.separator())
        let header = menu.addItem(withTitle: history.entries.isEmpty ? "No history yet" : "History (click to copy)",
                                  action: nil, keyEquivalent: "")
        header.isEnabled = false
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        for (i, entry) in history.entries.prefix(15).enumerated() {
            let oneLine = entry.text.replacingOccurrences(of: "\n", with: " ")
            let title = "\(fmt.string(from: entry.date))  " + (oneLine.count > 60 ? oneLine.prefix(60) + "…" : oneLine)
            let it = item(title, #selector(copyHistory(_:)))
            it.tag = i
            it.toolTip = entry.text
            menu.addItem(it)
        }
        if !history.entries.isEmpty { menu.addItem(item("Open Full History…", #selector(openHistory))) }

        if !recordings.items.isEmpty {
            let sub = NSMenu()
            let rfmt = DateFormatter()
            rfmt.dateFormat = "MMM d, HH:mm"
            for r in recordings.items {
                let mark = r.error == nil ? "" : "  ⚠︎ failed"
                let it = retryItem("\(rfmt.string(from: r.date)) · \(minutes(r.duration))\(mark)", r)
                it.toolTip = r.error ?? "Transcribe again and paste"
                sub.addItem(it)
            }
            let parent = NSMenuItem(title: "Recent Recordings (click to retry)", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }

        menu.addItem(.separator())
        menu.addItem(usageMenu())
        menu.addItem(choiceMenu("Model", Self.models, current: model, action: #selector(pickModel(_:))))
        menu.addItem(choiceMenu("Language", Self.languages, current: language ?? "", action: #selector(pickLanguage(_:))))
        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    func usageMenu() -> NSMenuItem {
        let cal = Calendar.current
        let now = Date()
        let rows: [(String, Date)] = [
            ("Today", cal.startOfDay(for: now)),
            ("Last 7 days", cal.date(byAdding: .day, value: -7, to: now)!),
            ("This month", cal.dateInterval(of: .month, for: now)!.start),
            ("All time", .distantPast),
        ]
        let sub = NSMenu()
        for (label, since) in rows {
            let u = history.usage(since: since)
            let it = sub.addItem(withTitle: "\(label): \(money(u.cost)) · \(minutes(u.seconds)) · \(u.count)×",
                                 action: nil, keyEquivalent: "")
            it.isEnabled = false
        }
        let today = history.usage(since: cal.startOfDay(for: now))
        let parent = NSMenuItem(title: "Usage today: \(money(today.cost))", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        return it
    }

    func retryItem(_ title: String, _ r: Recording) -> NSMenuItem {
        let it = item(title, #selector(retry(_:)))
        it.representedObject = r.file
        it.isEnabled = state == .idle
        return it
    }

    // Models verified to pass this account's Zero Data Retention policy (2026-11-01).
    static let models: [(id: String, label: String)] = [
        ("elevenlabs/scribe-v2", "ElevenLabs Scribe v2"),
        ("openai/whisper-large-v3-turbo", "Whisper Large v3 Turbo (cheapest)"),
        ("deepgram/nova-3", "Deepgram Nova 3"),
        ("mistralai/voxtral-small-transcribe-3-0", "Voxtral Small"),
        ("assemblyai/universal-3-6-pro", "AssemblyAI Universal 3.6 Pro"),
    ]
    static let languages: [(id: String, label: String)] = [
        ("", "Auto-detect"), ("en", "English"), ("de", "German"), ("zh", "Chinese"),
    ]

    /// Submenu titled "Title: Current" with a checkmark on the active choice.
    /// A value set via `defaults write` that isn't in the list is shown as an extra checked item.
    func choiceMenu(_ title: String, _ choices: [(id: String, label: String)], current: String,
                    action: Selector) -> NSMenuItem {
        var all = choices
        if !all.contains(where: { $0.id == current }) { all.append((current, current)) }
        let sub = NSMenu()
        for c in all {
            let it = item(c.label, action)
            it.representedObject = c.id
            it.state = c.id == current ? .on : .off
            sub.addItem(it)
        }
        let label = all.first { $0.id == current }?.label ?? current
        let parent = NSMenuItem(title: "\(title): \(label)", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    @objc func pickModel(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String, forKey: "model")
    }

    @objc func pickLanguage(_ sender: NSMenuItem) {
        let id = sender.representedObject as? String ?? ""
        if id.isEmpty { UserDefaults.standard.removeObject(forKey: "language") }
        else { UserDefaults.standard.set(id, forKey: "language") }
    }

    @objc func copyHistory(_ sender: NSMenuItem) {
        guard history.entries.indices.contains(sender.tag) else { return }
        copy(history.entries[sender.tag].text)
    }

    @objc func openHistory() { NSWorkspace.shared.open(history.file) }

    @objc func retry(_ sender: NSMenuItem) {
        guard state == .idle, let file = sender.representedObject as? String,
              let rec = recordings.items.first(where: { $0.file == file }) else { return }
        lastError = nil
        run(rec)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            fail("Launch at Login: \(error.localizedDescription)")
        }
    }
}

// MARK: - Entry point

let args = CommandLine.arguments
if args.count == 3, args[1] == "--transcribe" {
    // CLI test path: Kunyu --transcribe file.m4a
    Task.detached {
        do {
            let t = try await transcribe(URL(fileURLWithPath: args[2]))
            print(t.text)
            FileHandle.standardError.write("[\(model)] \(t.seconds.map { minutes($0) } ?? "?") · \(t.cost.map { money($0) } ?? "?")\n".data(using: .utf8)!)
            exit(0)
        } catch {
            FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
