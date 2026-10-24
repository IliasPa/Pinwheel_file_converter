// Makes the bench's hard pictures: color spaces, depths, orientations,
// transparency, sizes, animation, damaged and misnamed files.
// Usage: swift scripts/bench/make-pictures.swift <folder>
import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("images")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!

func context(_ width: Int, _ height: Int, space: CGColorSpace = sRGB, alpha: Bool = true, bits: Int = 8) -> CGContext {
    var info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
    if bits == 32 { info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue }
    return CGContext(data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0, space: space, bitmapInfo: info)!
}

/// A photo-like scene: a sky gradient, a sun, hills and a few sharp edges,
/// with a red square top left and a blue one bottom right (to tell which way is up).
func scene(_ ctx: CGContext, _ width: Int, _ height: Int) {
    let w = CGFloat(width), h = CGFloat(height)
    let sky = CGGradient(colorsSpace: ctx.colorSpace, colors: [
        CGColor(srgbRed: 0.1, green: 0.3, blue: 0.8, alpha: 1), CGColor(srgbRed: 0.95, green: 0.7, blue: 0.4, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0.9, blue: 0.2, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: w * 0.6, y: h * 0.55, width: w * 0.18, height: w * 0.18))
    ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.55, blue: 0.2, alpha: 1))
    ctx.move(to: CGPoint(x: 0, y: h * 0.35))
    for i in 0...20 {
        let x = w * CGFloat(i) / 20
        ctx.addLine(to: CGPoint(x: x, y: h * (0.3 + 0.08 * sin(CGFloat(i) * 0.9))))
    }
    ctx.addLine(to: CGPoint(x: w, y: 0))
    ctx.addLine(to: CGPoint(x: 0, y: 0))
    ctx.fillPath()
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: h * 0.85, width: w * 0.15, height: h * 0.15))
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: w * 0.85, y: 0, width: w * 0.15, height: h * 0.15))
    // Fine lines, which show blur and banding.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.8))
    ctx.setLineWidth(max(1, w / 1000))
    for i in 0..<30 {
        let y = h * 0.05 + CGFloat(i) * h * 0.006
        ctx.move(to: CGPoint(x: w * 0.3, y: y))
        ctx.addLine(to: CGPoint(x: w * 0.55, y: y))
    }
    ctx.strokePath()
}

func write(_ image: CGImage, _ name: String, _ type: UTType, _ properties: [CFString: Any] = [:]) {
    let url = out.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        print("can't write \(name)"); return
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    if !CGImageDestinationFinalize(destination) { print("failed \(name)") }
}

func frames(_ images: [CGImage], _ name: String, _ type: UTType, delays: [Double], fileProperties: [CFString: Any], frameKey: CFString, delayKey: CFString) {
    let url = out.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil)!
    CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
    for (image, delay) in zip(images, delays) {
        CGImageDestinationAddImage(destination, image, [frameKey: [delayKey: delay]] as CFDictionary)
    }
    if !CGImageDestinationFinalize(destination) { print("failed \(name)") }
}

func png(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

let exif: [CFString: Any] = [
    kCGImagePropertyTIFFDictionary: [
        kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17 Pro", kCGImagePropertyTIFFSoftware: "Bench",
        kCGImagePropertyTIFFDateTime: "2026:08:15 18:30:00",
    ],
    kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifDateTimeOriginal: "2026:08:15 18:30:00", kCGImagePropertyExifLensModel: "Main Camera",
        kCGImagePropertyExifUserComment: "Σχόλιο",
    ],
    kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 36.4618, kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 25.3753, kCGImagePropertyGPSLongitudeRef: "E",
    ],
]

// 1. A wide-color photo with camera info and a location.
do {
    let ctx = context(3000, 2000, space: p3, alpha: false)
    scene(ctx, 3000, 2000)
    // Greens and reds outside sRGB.
    ctx.setFillColor(CGColor(colorSpace: p3, components: [0, 1, 0, 1])!)
    ctx.fill(CGRect(x: 1200, y: 1500, width: 300, height: 300))
    ctx.setFillColor(CGColor(colorSpace: p3, components: [1, 0, 0, 1])!)
    ctx.fill(CGRect(x: 1600, y: 1500, width: 300, height: 300))
    write(ctx.makeImage()!, "photo p3 gps.jpg", .jpeg, exif.merging([kCGImageDestinationLossyCompressionQuality: 0.92]) { $1 })
}

// 2. A phone photo stored sideways with orientation 6 (shown upright as 3024×4032).
do {
    let upright = context(3024, 4032, alpha: false)
    scene(upright, 3024, 4032)
    let shown = upright.makeImage()!
    // Stored = the upright picture turned a quarter to the left.
    let stored = context(4032, 3024, alpha: false)
    stored.translateBy(x: 0, y: 3024)
    stored.rotate(by: -.pi / 2)
    stored.draw(shown, in: CGRect(x: 0, y: 0, width: 3024, height: 4032))
    write(stored.makeImage()!, "phone rotated exif6.jpg", .jpeg, exif.merging([kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 0.9]) { $1 })
    // The same as HEIC, the way iPhones save them.
    write(stored.makeImage()!, "iphone rotated.heic", .heic, exif.merging([kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 0.8]) { $1 })
}

// 3. CMYK, for print; 4. progressive JPEG.
do {
    let cmyk = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.genericCMYK)!, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    scene(cmyk, 1200, 800)
    write(cmyk.makeImage()!, "print cmyk.jpg", .jpeg, [kCGImageDestinationLossyCompressionQuality: 0.9])
    write(cmyk.makeImage()!, "print cmyk.tiff", .tiff, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]])
    let ctx = context(1600, 1000, alpha: false)
    scene(ctx, 1600, 1000)
    write(ctx.makeImage()!, "progressive.jpg", .jpeg, [kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true], kCGImageDestinationLossyCompressionQuality: 0.85])
}

// 5. 16-bit gray; 6. soft see-through edges and shadow; 7. one pixel; 8. a thin banner.
do {
    let gray = CGContext(data: nil, width: 1024, height: 256, bitsPerComponent: 16, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.linearGray)!, bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
    let ramp = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.linearGray)!, colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1)] as CFArray, locations: [0, 1])!
    gray.drawLinearGradient(ramp, start: .zero, end: CGPoint(x: 1024, y: 0), options: [])
    write(gray.makeImage()!, "gray 16bit.png", .png)

    let soft = context(800, 800)
    soft.clear(CGRect(x: 0, y: 0, width: 800, height: 800))
    soft.setShadow(offset: CGSize(width: 20, height: -20), blur: 40, color: CGColor(gray: 0, alpha: 0.6))
    soft.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.5, alpha: 1))
    soft.fillEllipse(in: CGRect(x: 150, y: 150, width: 500, height: 500))
    soft.setShadow(offset: .zero, blur: 0, color: nil)
    soft.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 1, alpha: 0.5))
    soft.fill(CGRect(x: 0, y: 650, width: 800, height: 150))
    let softImage = soft.makeImage()!
    write(softImage, "soft shadow alpha.png", .png)
    write(softImage, "alpha.heic", .heic, [kCGImageDestinationLossyCompressionQuality: 0.8])
    write(softImage, "alpha 32bit.bmp", .bmp)
    write(softImage, "alpha.tiff", .tiff)
    try png(softImage).write(to: out.appendingPathComponent("soft-for-webp.png.tmp"))

    let one = context(1, 1)
    one.setFillColor(CGColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1))
    one.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    write(one.makeImage()!, "tiny 1x1.png", .png)

    let banner = context(8000, 40, alpha: false)
    scene(banner, 8000, 40)
    write(banner.makeImage()!, "banner 8000x40.png", .png)
}

// 9. A very big photo (96 megapixels).
do {
    let ctx = context(12000, 8000, alpha: false)
    scene(ctx, 12000, 8000)
    write(ctx.makeImage()!, "huge 12000x8000.jpg", .jpeg, [kCGImageDestinationLossyCompressionQuality: 0.85])
}

// 10. A TIFF with three pages of different sizes; 16-bit color TIFF; HDR EXR;
// Photoshop, Targa, JPEG 2000 and PBM; AVIF; a retina screenshot.
do {
    let url = out.appendingPathComponent("three pages.tiff")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 3, nil)!
    for (index, size) in [(800, 600), (600, 800), (300, 300)].enumerated() {
        let ctx = context(size.0, size.1, alpha: false)
        scene(ctx, size.0, size.1)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 10, y: 10, width: 40 * (index + 1), height: 20))
        CGImageDestinationAddImage(destination, ctx.makeImage()!, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] as CFDictionary)
    }
    CGImageDestinationFinalize(destination)

    let deep = context(1200, 800, alpha: false, bits: 16)
    scene(deep, 1200, 800)
    write(deep.makeImage()!, "deep color 16bit.tiff", .tiff)

    let hdr = context(800, 400, space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, bits: 32)
    scene(hdr, 800, 400)
    hdr.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, components: [4, 4, 3, 1])!)
    hdr.fillEllipse(in: CGRect(x: 480, y: 220, width: 140, height: 140))
    write(hdr.makeImage()!, "hdr bright.exr", UTType("com.ilm.openexr-image")!)

    let ctx = context(1000, 700, alpha: false)
    scene(ctx, 1000, 700)
    let picture = ctx.makeImage()!
    write(picture, "photoshop.psd", UTType("com.adobe.photoshop-image")!)
    write(picture, "old targa.tga", UTType("com.truevision.tga-image")!)
    write(picture, "jpeg 2000.jp2", UTType("public.jpeg-2000")!)
    write(picture, "photo.avif", UTType("public.avif")!, [kCGImageDestinationLossyCompressionQuality: 0.7])
    write(picture, "netpbm.pbm", UTType("public.pbm")!)

    // A retina screenshot: flat colors, text, 144 dpi.
    let shot = context(2880, 1800, alpha: false)
    shot.setFillColor(CGColor(gray: 0.96, alpha: 1))
    shot.fill(CGRect(x: 0, y: 0, width: 2880, height: 1800))
    shot.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
    shot.fill(CGRect(x: 0, y: 1700, width: 2880, height: 100))
    for row in 0..<12 {
        shot.setFillColor(CGColor(gray: row % 2 == 0 ? 1 : 0.92, alpha: 1))
        shot.fill(CGRect(x: 200, y: 1500 - row * 110, width: 2400, height: 100))
    }
    let attributed = NSAttributedString(string: "Screenshot · Στιγμιότυπο οθόνης · 12:45", attributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
    shot.textPosition = CGPoint(x: 220, y: 1530)
    CTLineDraw(CTLineCreateWithAttributedString(attributed), shot)
    write(shot.makeImage()!, "screenshot retina.png", .png, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
}

// 11. Text to read (English and Greek); a QR code.
do {
    let ctx = context(1600, 700, alpha: false)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 700))
    let lines = ["Invoice number 2026-117", "Total due: 1.234,56 EUR", "Καλημέρα, αυτό είναι ελληνικό κείμενο.", "The quick brown fox jumps over the lazy dog."]
    for (index, line) in lines.enumerated() {
        let attributed = NSAttributedString(string: line, attributes: [.font: NSFont(name: "Helvetica", size: 56)!, .foregroundColor: NSColor.black])
        ctx.textPosition = CGPoint(x: 60, y: 580 - index * 150)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
    }
    write(ctx.makeImage()!, "text to read.png", .png)

    let filter = CIFilter(name: "CIQRCodeGenerator")!
    filter.setValue(Data("https://github.com/IliasPa/Pinwheel_file_converter".utf8), forKey: "inputMessage")
    let qr = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
    let rendered = CIContext().createCGImage(qr, from: qr.extent)!
    let framed = context(rendered.width + 120, rendered.height + 120, alpha: false)
    framed.setFillColor(CGColor(gray: 1, alpha: 1))
    framed.fill(CGRect(x: 0, y: 0, width: framed.width, height: framed.height))
    framed.draw(rendered, in: CGRect(x: 60, y: 60, width: rendered.width, height: rendered.height))
    write(framed.makeImage()!, "qr code.png", .png)
}

// 12. Animation: a GIF with uneven delays and see-through parts, an APNG,
// a HEIC sequence, and frames for an animated WebP (made by img2webp).
do {
    var images: [CGImage] = []
    for frame in 0..<12 {
        let ctx = context(320, 240)
        ctx.clear(CGRect(x: 0, y: 0, width: 320, height: 240))
        let x = CGFloat(frame) * 22
        let gradient = CGGradient(colorsSpace: sRGB, colors: [CGColor(srgbRed: 1, green: 0.3, blue: 0.1, alpha: 1), CGColor(srgbRed: 0.1, green: 0.3, blue: 1, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: x, y: 60, width: 100, height: 100))
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: CGPoint(x: x, y: 60), end: CGPoint(x: x + 100, y: 160), options: [])
        ctx.restoreGState()
        ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 20))
        images.append(ctx.makeImage()!)
    }
    let delays = (0..<12).map { $0 == 0 ? 0.5 : ($0 % 3 == 0 ? 0.2 : 0.05) }
    frames(images, "animated uneven.gif", .gif, delays: delays,
           fileProperties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]],
           frameKey: kCGImagePropertyGIFDictionary, delayKey: kCGImagePropertyGIFDelayTime)
    frames(images, "animated.png", .png, delays: delays,
           fileProperties: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]],
           frameKey: kCGImagePropertyPNGDictionary, delayKey: kCGImagePropertyAPNGDelayTime)
    frames(images, "sequence.heics", UTType("public.heics")!, delays: delays,
           fileProperties: [kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSLoopCount: 0]],
           frameKey: kCGImagePropertyHEICSDictionary, delayKey: kCGImagePropertyHEICSDelayTime)
    let folder = out.appendingPathComponent("webp-frames.tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (index, image) in images.enumerated() {
        try png(image).write(to: folder.appendingPathComponent(String(format: "%02d.png", index)))
    }
    // A still GIF with a see-through background.
    write(images[3], "still transparent.gif", .gif)
}

// 13. Icons: an ICO with several sizes, an ICNS.
do {
    let ico = CGImageDestinationCreateWithURL(out.appendingPathComponent("windows icon.ico") as CFURL, UTType.ico.identifier as CFString, 4, nil)!
    let icns = CGImageDestinationCreateWithURL(out.appendingPathComponent("mac icon.icns") as CFURL, UTType.icns.identifier as CFString, 4, nil)!
    for size in [16, 32, 128, 256] {
        let ctx = context(size, size)
        ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.7, blue: 0.8, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: size / 3, y: size / 3, width: size / 3, height: size / 3))
        CGImageDestinationAddImage(ico, ctx.makeImage()!, nil)
        CGImageDestinationAddImage(icns, ctx.makeImage()!, nil)
    }
    CGImageDestinationFinalize(ico)
    CGImageDestinationFinalize(icns)
}

// 14. A Greek name with an emoji; damaged, misnamed and empty files.
do {
    let ctx = context(900, 600, alpha: false)
    scene(ctx, 900, 600)
    write(ctx.makeImage()!, "Ελληνικό όνομα 😀.png", .png)
    write(ctx.makeImage()!, "really a jpeg.png", .jpeg)
    let whole = out.appendingPathComponent("progressive.jpg")
    let data = try Data(contentsOf: whole)
    try data.prefix(data.count * 4 / 10).write(to: out.appendingPathComponent("damaged cut short.jpg"))
    try Data().write(to: out.appendingPathComponent("empty.jpg"))
}

// 15. SVGs: gradients, CSS, reused shapes, Greek text, only a viewBox;
// sizes in millimeters; a picture inside; one with no size at all.
do {
    let picture = png({
        let ctx = context(64, 64, alpha: false)
        scene(ctx, 64, 64)
        return ctx.makeImage()!
    }()).base64EncodedString()
    let svgs = [
        "gradients css text.svg": """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 400 300">
          <style>.title { font: bold 28px Helvetica, sans-serif; fill: #223; } .dash { stroke-dasharray: 6 4; }</style>
          <defs>
            <linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ff6a00"/><stop offset="1" stop-color="#ee0979"/></linearGradient>
            <radialGradient id="r"><stop offset="0" stop-color="#fff" stop-opacity="1"/><stop offset="1" stop-color="#09f" stop-opacity="0"/></radialGradient>
            <circle id="dot" r="12" fill="url(#r)"/>
          </defs>
          <rect width="400" height="300" fill="url(#g)"/>
          <g transform="translate(200 150) rotate(-15)">
            <rect x="-120" y="-50" width="240" height="100" rx="18" fill="#fff" opacity="0.85" stroke="#223" stroke-width="3" class="dash"/>
            <text class="title" text-anchor="middle" y="10">Γεια σου SVG</text>
          </g>
          <use xlink:href="#dot" x="40" y="40"/><use href="#dot" x="360" y="260"/>
          <path d="M20 280 Q 200 180 380 280" fill="none" stroke="#fff" stroke-width="4"/>
        </svg>
        """,
        "millimeters.svg": """
        <svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="50mm" viewBox="0 0 100 50">
          <rect x="5" y="5" width="90" height="40" fill="#0a7" stroke="#000" stroke-width="0.5"/>
          <circle cx="50" cy="25" r="15" fill="#fd0"/>
        </svg>
        """,
        "picture inside.svg": """
        <svg xmlns="http://www.w3.org/2000/svg" width="300" height="200">
          <rect width="300" height="200" fill="#eee"/>
          <image x="20" y="20" width="160" height="160" href="data:image/png;base64,\(picture)"/>
          <text x="200" y="100" font-size="20">PNG</text>
        </svg>
        """,
        "no size.svg": """
        <svg xmlns="http://www.w3.org/2000/svg"><circle cx="50" cy="50" r="40" fill="red"/></svg>
        """,
    ]
    for (name, text) in svgs {
        try Data(text.utf8).write(to: out.appendingPathComponent(name))
    }
}
print("pictures done")
