// Renders Claude Whisper's app icon into Resources/AppIcon.icns:
//   tools/make-icon.sh (also compiles Resources/Assets.car for macOS 26)
// A dark square (macOS rounds it) with the same voice bars as the on-screen capsule.
import AppKit

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024

    // Full-bleed square: macOS 26 rounds the corners itself, and puts icons with their own
    // transparent margin into a smaller grey tile instead.
    let tile = NSRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
    NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.20, blue: 0.25, alpha: 1),
               ending: NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1))!.draw(in: tile, angle: -90)

    // Voice bars, tallest in the middle, with a soft white-to-grey fade.
    let heights: [CGFloat] = [250, 430, 600, 430, 250]
    let barWidth = 96 * s, gap = 76 * s
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = tile.midX - total / 2
    let bars = NSGradient(starting: .white, ending: NSColor(white: 0.78, alpha: 1))!
    for h in heights {
        let bar = NSRect(x: x, y: tile.midY - h * s / 2, width: barWidth, height: h * s)
        bars.draw(in: NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2), angle: -90)
        x += barWidth + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let output = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try! iconutil.run()
iconutil.waitUntilExit()
print("wrote \(output)")
