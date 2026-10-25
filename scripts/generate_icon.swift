import AppKit

// The app's sidebar mark, redrawn at each macOS icon resolution.
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets"
let destination = URL(fileURLWithPath: output, isDirectory: true)
let iconset = destination.appendingPathComponent("Murmur.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ size: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let ink = NSColor(srgbRed: 0.16, green: 0.23, blue: 0.21, alpha: 1)
    let paper = NSColor(srgbRed: 0.97, green: 0.96, blue: 0.93, alpha: 1)
    let tile = NSBezierPath(roundedRect: NSRect(x: 58, y: 58, width: 908, height: 908), xRadius: 202, yRadius: 202)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
    shadow.shadowBlurRadius = 22; shadow.shadowOffset = NSSize(width: 0, height: -8); shadow.set()
    paper.setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    ink.withAlphaComponent(0.08).setStroke(); tile.lineWidth = 2; tile.stroke()
    ink.setFill()
    NSBezierPath(ovalIn: NSRect(x: 252, y: 346, width: 520, height: 520)).fill()
    paper.setFill()
    let heights: [CGFloat] = [74, 156, 250, 182, 108, 210, 136]
    for (index, height) in heights.enumerated() {
        NSBezierPath(roundedRect: NSRect(x: 364 + CGFloat(index) * 44, y: 606 - height / 2, width: 28, height: height), xRadius: 14, yRadius: 14).fill()
    }
    let title = "murmur" as NSString
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Georgia-Bold", size: 146) ?? NSFont.boldSystemFont(ofSize: 146), .foregroundColor: ink]
    let bounds = title.size(withAttributes: attributes)
    title.draw(at: NSPoint(x: (1024 - bounds.width) / 2, y: 170), withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(points * scale).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
try render(1024).write(to: destination.appendingPathComponent("Murmur.png"))
