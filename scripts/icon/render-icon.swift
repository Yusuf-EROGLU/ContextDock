// Renders the ContextDock app icon: a purple gradient rounded square with a glowing white
// outline glyph (a bar of cards with a handle above), in the same visual language as the
// user's other apps. Usage: swift render-icon.swift <output-dir>
import AppKit
import CoreGraphics

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func render(size: Int) -> CGImage {
    let canvas = CGFloat(size)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

    // Apple's macOS icon grid: the tile occupies ~80.5 % of the canvas.
    let tile = canvas * 0.805
    let inset = (canvas - tile) / 2
    let tileRect = CGRect(x: inset, y: inset, width: tile, height: tile)
    let radius = tile * 0.225
    let tilePath = CGPath(roundedRect: tileRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -canvas * 0.012), blur: canvas * 0.03, color: CGColor(gray: 0, alpha: 0.35))
    context.setFillColor(CGColor(red: 0.45, green: 0.32, blue: 0.80, alpha: 1))
    context.addPath(tilePath)
    context.fillPath()
    context.restoreGState()

    // Purple gradient, lighter at the top.
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let gradient = CGGradient(colorsSpace: colorSpace, colors: [
        CGColor(red: 0.72, green: 0.60, blue: 0.97, alpha: 1),
        CGColor(red: 0.53, green: 0.38, blue: 0.86, alpha: 1),
        CGColor(red: 0.45, green: 0.30, blue: 0.78, alpha: 1),
    ] as CFArray, locations: [0, 0.6, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: canvas / 2, y: tileRect.maxY), end: CGPoint(x: canvas / 2, y: tileRect.minY), options: [])
    // Soft top highlight.
    let highlight = CGGradient(colorsSpace: colorSpace, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(highlight, start: CGPoint(x: canvas / 2, y: tileRect.maxY), end: CGPoint(x: canvas / 2, y: tileRect.midY), options: [])
    context.restoreGState()

    // Inner edge light.
    context.saveGState()
    context.addPath(tilePath)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
    context.setLineWidth(canvas * 0.006)
    context.strokePath()
    context.restoreGState()

    // Glyph: a bar with three cards and a handle capsule above, white outline with glow.
    let glyph = CGMutablePath()
    let barWidth = tile * 0.66
    let barHeight = tile * 0.30
    let barRect = CGRect(x: tileRect.midX - barWidth / 2, y: tileRect.midY - barHeight * 0.78, width: barWidth, height: barHeight)
    glyph.addPath(CGPath(roundedRect: barRect, cornerWidth: barHeight * 0.28, cornerHeight: barHeight * 0.28, transform: nil))

    let cardGap = barWidth * 0.045
    let cardInset = barHeight * 0.22
    let cardWidth = (barWidth - 2 * cardInset - 2 * cardGap) / 3
    let cardHeight = barHeight - 2 * cardInset
    for index in 0..<3 {
        let x = barRect.minX + cardInset + CGFloat(index) * (cardWidth + cardGap)
        let cardRect = CGRect(x: x, y: barRect.minY + cardInset, width: cardWidth, height: cardHeight)
        glyph.addPath(CGPath(roundedRect: cardRect, cornerWidth: cardHeight * 0.22, cornerHeight: cardHeight * 0.22, transform: nil))
    }

    let handleWidth = barWidth * 0.30
    let handleHeight = barHeight * 0.26
    let handleRect = CGRect(x: tileRect.midX - handleWidth / 2, y: barRect.maxY + barHeight * 0.30, width: handleWidth, height: handleHeight)
    glyph.addPath(CGPath(roundedRect: handleRect, cornerWidth: handleHeight / 2, cornerHeight: handleHeight / 2, transform: nil))

    let stroke = tile * 0.036
    context.saveGState()
    context.setLineWidth(stroke)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    // Glow pass.
    context.setShadow(offset: .zero, blur: tile * 0.045, color: CGColor(red: 1, green: 0.95, blue: 1, alpha: 0.75))
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    context.addPath(glyph)
    context.strokePath()
    context.restoreGState()
    // Crisp pass.
    context.saveGState()
    context.setLineWidth(stroke)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.addPath(glyph)
    context.strokePath()
    context.restoreGState()

    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: url)
}

let entries: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for entry in entries {
    write(render(size: entry.size), to: outputDirectory.appendingPathComponent(entry.name))
}
print("rendered \(entries.count) icon files into \(outputDirectory.path)")
