import AppKit

// Renders the app icon: a dark squircle with a "sound dome" of arcs over a play button.
// usage: makeicon <out.iconset>

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let k = s / 1024
    let cs = CGColorSpaceCreateDeviceRGB()
    func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

    // Squircle body with drop shadow
    let body = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let path = CGPath(roundedRect: body, cornerWidth: 185 * k, cornerHeight: 185 * k, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 28 * k, color: c(0, 0, 0, 0.45))
    ctx.addPath(path); ctx.setFillColor(c(0.05, 0.07, 0.2)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [c(0.13, 0.19, 0.48), c(0.04, 0.05, 0.17)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 924 * k), end: CGPoint(x: 0, y: 100 * k), options: [])
    // glow behind the dome
    let glow = CGGradient(colorsSpace: cs, colors: [c(0.25, 0.6, 1, 0.55), c(0.25, 0.6, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512 * k, y: 430 * k), startRadius: 0,
                           endCenter: CGPoint(x: 512 * k, y: 430 * k), endRadius: 420 * k, options: [])
    // subtle top sheen
    let sheen = CGGradient(colorsSpace: cs, colors: [c(1, 1, 1, 0.10), c(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: 924 * k), end: CGPoint(x: 0, y: 600 * k), options: [])

    // Sound dome: three concentric arcs (height channels) with a cyan→magenta gradient stroke
    let center = CGPoint(x: 512 * k, y: 330 * k)
    let radii: [CGFloat] = [215, 300, 385]
    let widths: [CGFloat] = [34, 30, 26]
    let alphas: [CGFloat] = [1, 0.8, 0.55]
    for i in 0..<3 {
        ctx.saveGState()
        let arc = CGMutablePath()
        arc.addArc(center: center, radius: radii[i] * k, startAngle: .pi * 0.12, endAngle: .pi * 0.88, clockwise: false)
        ctx.addPath(arc)
        ctx.setLineWidth(widths[i] * k)
        ctx.setLineCap(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let g = CGGradient(colorsSpace: cs, colors: [c(0.2, 0.9, 1, alphas[i]), c(0.55, 0.45, 1, alphas[i]), c(1, 0.35, 0.8, alphas[i])] as CFArray,
                           locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 100 * k, y: 0), end: CGPoint(x: 924 * k, y: 0), options: [])
        ctx.restoreGState()
    }
    // floor speakers: small dots along the base
    for (i, x) in [262, 387, 512, 637, 762].enumerated() {
        let r: CGFloat = i == 2 ? 0 : 13
        if r > 0 {
            ctx.setFillColor(c(0.6, 0.8, 1, 0.55))
            ctx.fillEllipse(in: CGRect(x: CGFloat(x) * k - r * k, y: 205 * k - r * k, width: 2 * r * k, height: 2 * r * k))
        }
    }

    // Play button with rounded corners
    let tri = CGMutablePath()
    let a = CGPoint(x: 455 * k, y: 470 * k), b = CGPoint(x: 455 * k, y: 230 * k), cc = CGPoint(x: 660 * k, y: 350 * k)
    tri.move(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
    tri.addArc(tangent1End: b, tangent2End: cc, radius: 30 * k)
    tri.addArc(tangent1End: cc, tangent2End: a, radius: 30 * k)
    tri.addArc(tangent1End: a, tangent2End: b, radius: 30 * k)
    tri.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * k), blur: 18 * k, color: c(0, 0, 0, 0.5))
    ctx.addPath(tri); ctx.setFillColor(c(1, 1, 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.restoreGState()

    // thin inner border
    ctx.addPath(path); ctx.setStrokeColor(c(1, 1, 1, 0.12)); ctx.setLineWidth(3 * k); ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(size)x\(size)@2x.png"))
}
