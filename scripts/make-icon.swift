// Draws Pinwheel's app icon at every size macOS needs.
// Usage: swift scripts/make-icon.swift <output.iconset>   (then run iconutil)
// `make icon` does both steps.

import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Same rounded-wedge construction the app uses for its wheel (y up).
func wedge(center c: CGPoint, inner: CGFloat, outer: CGFloat, start: CGFloat, end: CGFloat, gap: CGFloat, corner: CGFloat) -> CGPath {
    let d = gap / 2 + corner
    let rIn = inner + corner, rOut = outer - corner
    let o0 = start + asin(d / rOut), o1 = end - asin(d / rOut)
    let i0 = start + asin(d / rIn), i1 = end - asin(d / rIn)
    func p(_ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: c.x + r * sin(a), y: c.y + r * cos(a)) }
    let core = CGMutablePath()
    core.move(to: p(rOut, o0))
    for i in 1...60 { core.addLine(to: p(rOut, o0 + (o1 - o0) * CGFloat(i) / 60)) }
    core.addLine(to: p(rIn, i1))
    for i in 1...60 { core.addLine(to: p(rIn, i1 - (i1 - i0) * CGFloat(i) / 60)) }
    core.closeSubpath()
    return core.union(core.copy(strokingWithWidth: corner * 2, lineCap: .round, lineJoin: .round, miterLimit: 10))
}

func drawIcon(in ctx: CGContext, size: CGFloat) {
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // macOS icon grid: an 824pt rounded square centered on a 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.30))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x3F37C9))
    ctx.fillPath()
    ctx.restoreGState()

    // Background: deep indigo to teal.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let background = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0x4338CA), color(0x2563EB), color(0x0D9488)] as CFArray,
        locations: [0, 0.5, 1]
    )!
    ctx.drawLinearGradient(background, start: CGPoint(x: 180, y: 924), end: CGPoint(x: 844, y: 100), options: [])
    // Soft light from the top.
    let glow = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 900), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 900), endRadius: 620, options: [])
    ctx.restoreGState()

    // The wheel: six frosted wedges, one picked and popped out.
    let center = CGPoint(x: 512, y: 512)
    let count = 6
    let step = 2 * CGFloat.pi / CGFloat(count)
    let picked = 1
    for i in 0..<count {
        let mid = CGFloat(i) * step
        var c = center
        if i == picked {
            c.x += sin(mid) * 30
            c.y += cos(mid) * 30
        }
        let path = wedge(center: c, inner: 118, outer: i == picked ? 318 : 296,
                         start: mid - step / 2, end: mid + step / 2, gap: 26, corner: 22)
        ctx.saveGState()
        if i == picked {
            ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.28))
            ctx.addPath(path)
            ctx.setFillColor(color(0xFFFFFF))
        } else {
            ctx.addPath(path)
            ctx.setFillColor(color(0xFFFFFF, 0.30))
        }
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Small mark on the picked wedge.
    let markAngle = CGFloat(picked) * step
    let markCenter = CGPoint(x: 512 + sin(markAngle) * 245, y: 512 + cos(markAngle) * 245)
    ctx.setFillColor(color(0x2563EB))
    ctx.fillEllipse(in: CGRect(x: markCenter.x - 30, y: markCenter.y - 30, width: 60, height: 60))

    // Hub.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: color(0x000000, 0.25))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(x: 512 - 84, y: 512 - 84, width: 168, height: 168))
    ctx.restoreGState()
    ctx.setFillColor(color(0x4338CA))
    ctx.fillEllipse(in: CGRect(x: 512 - 34, y: 512 - 34, width: 68, height: 68))
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let px = variant.pixels
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    drawIcon(in: ctx, size: CGFloat(px))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: outDir.appendingPathComponent("\(variant.name).png"))
}
print("Wrote \(variants.count) images to \(outDir.path)")
