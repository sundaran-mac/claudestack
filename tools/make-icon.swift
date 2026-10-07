// Draws AppIcon.icns: the orange stack symbol on a dark rounded square.
// Usage, from the repo root: swift tools/make-icon.swift   (commit AppIcon.icns; build.sh copies it into the app)
import AppKit

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icons leave a margin around the rounded square.
    let box = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let path = NSBezierPath(roundedRect: box, xRadius: s * 0.18, yRadius: s * 0.18)
    NSColor(red: 0x1C / 255, green: 0x2B / 255, blue: 0x3A / 255, alpha: 1).setFill()
    path.fill()
    NSColor(red: 0x2E / 255, green: 0x3F / 255, blue: 0x50 / 255, alpha: 1).setStroke()
    path.lineWidth = max(1, s * 0.006)
    path.stroke()
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(red: 1, green: 0x9A / 255, blue: 0, alpha: 1)]))
    if let sym = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let sz = sym.size
        sym.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ClaudeStack.iconset")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", dir.path, "-o", "AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote AppIcon.icns" : "iconutil failed")
