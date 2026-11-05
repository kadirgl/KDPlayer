// Uygulama simgesini (turuncu gradyan kare + oynat üçgeni) iconset olarak çizer.
//   swift scripts/render-icon.swift <çıktı.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = size * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(colors: [NSColor(srgbRed: 1, green: 0.69, blue: 0.40, alpha: 1), NSColor(srgbRed: 0.88, green: 0.44, blue: 0.11, alpha: 1)])!
        .draw(in: path, angle: -90)
    // Üst kenar parlaması
    NSColor.white.withAlphaComponent(0.35).setStroke()
    let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.004, dy: size * 0.004), xRadius: rect.width * 0.22, yRadius: rect.width * 0.22)
    highlight.lineWidth = size * 0.006
    highlight.stroke()
    // Oynat üçgeni (yuvarlatılmış)
    let tri = NSBezierPath()
    let cx = size * 0.53, cy = size * 0.5, r = size * 0.2
    tri.move(to: NSPoint(x: cx - r * 0.75, y: cy + r))
    tri.line(to: NSPoint(x: cx + r, y: cy))
    tri.line(to: NSPoint(x: cx - r * 0.75, y: cy - r))
    tri.close()
    tri.lineJoinStyle = .round
    tri.lineWidth = size * 0.05
    NSColor.white.setFill()
    NSColor.white.setStroke()
    tri.fill()
    tri.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
