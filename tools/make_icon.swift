// Draws the Kunyu app icon: the Diskun 坤 mark (six broken lines) in white on a
// primary (#7a4fb0) macOS rounded square, with the bottom line closed in Blossom
// (#f6b1d0), the design system's ChoiceMark: one line closed = a voice given.
// Usage: swift tools/make_icon.swift out.png   (1024×1024)
import AppKit

let out = CommandLine.arguments[1]
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)  // y down, matching the SVG grid

func hex(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

// macOS icon grid: 824×824 body, ~185 corner radius, centred.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
hex(0x7a4fb0).setFill()
NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).fill()

// Mark content spans 4…60 on the 64 grid; draw it 480 px wide.
let s: CGFloat = 480 / 56
let origin = CGPoint(x: 512 - 32 * s, y: 512 - 32 * s)
for i in 0..<6 {
    let y = origin.y + CGFloat(4 + i * 10) * s
    let closed = i == 5
    let bars: [(CGFloat, CGFloat)] = closed ? [(4, 56)] : [(4, 24), (36, 24)]
    (closed ? hex(0xf6b1d0) : NSColor.white).setFill()
    for (x, w) in bars {
        NSBezierPath(roundedRect: NSRect(x: origin.x + x * s, y: y, width: w * s, height: 6 * s),
                     xRadius: 3 * s, yRadius: 3 * s).fill()
    }
}

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
