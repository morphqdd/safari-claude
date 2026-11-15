// Generates the extension and app icons: a white cursor arrow with a small spark on a warm orange circle.
// Usage: swift scripts/gen-icons.swift   (from the repo root)
import AppKit

let orange = CGColor(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1)
let white = CGColor(gray: 1, alpha: 1)
let shadow = CGColor(red: 0.35, green: 0.15, blue: 0.08, alpha: 0.35)

/// Draws the icon into a unit square (0...1, y up).
func draw(_ c: CGContext) {
    c.setFillColor(orange)
    c.fillEllipse(in: CGRect(x: 0.02, y: 0.02, width: 0.96, height: 0.96))

    // Cursor arrow, tip at the upper left.
    let arrow: [CGPoint] = [
        (0.27, 0.80), (0.27, 0.27), (0.40, 0.39), (0.50, 0.18), (0.59, 0.22), (0.49, 0.43), (0.67, 0.44),
    ].map { CGPoint(x: $0.0, y: $0.1) }
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -0.015), blur: 0.03, color: shadow)
    c.setFillColor(white)
    c.addLines(between: arrow)
    c.closePath()
    c.fillPath()
    c.restoreGState()

    // Four-pointed spark at the upper right.
    let center = CGPoint(x: 0.70, y: 0.70), long = 0.15, short = 0.04
    var spark: [CGPoint] = []
    for k in 0..<8 {
        let angle = Double(k) * .pi / 4 + .pi / 2
        let r = k % 2 == 0 ? long : short
        spark.append(CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle)))
    }
    c.setFillColor(white)
    c.addLines(between: spark)
    c.closePath()
    c.fillPath()
}

func png(_ n: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    let c = ctx.cgContext
    c.setShouldAntialias(true)
    c.scaleBy(x: CGFloat(n), y: CGFloat(n))
    draw(c)
    ctx.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
func write(_ n: Int, _ path: String) { try! png(n).write(to: URL(fileURLWithPath: path)) }

for n in [16, 32, 48, 128] { write(n, "extension/icons/\(n).png") }
let appIcons = "app/Safari Agent/Safari Agent/Assets.xcassets/AppIcon.appiconset"
for s in [16, 32, 128, 256, 512] {
    write(s, "\(appIcons)/mac-icon-\(s)@1x.png")
    write(s * 2, "\(appIcons)/mac-icon-\(s)@2x.png")
}
print("icons written")
