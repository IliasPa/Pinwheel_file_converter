import CoreGraphics
import Foundation
import ImageIO

/// The pictures on a PDF page, for documents made from it: where the page
/// draws images (its drawing is followed, forms within forms too), cut out
/// of the page as it looks there, whatever the image's own coding.
enum PDFPictures {
    struct Found {
        /// On the page, y up (as the page's text is placed).
        var frame: CGRect
        var picture: Document.Picture
    }

    /// The page's pictures, top to bottom. Tiny ones (bullets, rules) and
    /// one covering the whole page (a background, or a scan) are left out;
    /// pieces that touch become one picture.
    static func find(on page: CGPDFPage, dpi: CGFloat = 150) -> [Found] {
        let box = page.getBoxRect(.cropBox)
        var frames = frames(on: page).compactMap { frame -> CGRect? in
            let visible = frame.standardized.intersection(box)
            return visible.isNull || visible.isEmpty ? nil : visible
        }
        // Pieces that touch or overlap become one.
        var merged: [CGRect] = []
        while let first = frames.first {
            frames.removeFirst()
            var area = first
            var grew = true
            while grew {
                grew = false
                for (index, other) in frames.enumerated().reversed() where area.insetBy(dx: -2, dy: -2).intersects(other) {
                    area = area.union(other)
                    frames.remove(at: index)
                    grew = true
                }
            }
            merged.append(area)
        }
        let pageArea = box.width * box.height
        return merged
            .filter { $0.width >= 24 && $0.height >= 24 && $0.width * $0.height < pageArea * 0.85 }
            .sorted { $0.maxY > $1.maxY }
            .compactMap { frame in picture(of: page, in: frame, dpi: dpi).map { Found(frame: frame, picture: $0) } }
    }

    // MARK: - Following the drawing

    /// Where the page draws images (unit squares through the transforms in force).
    static func frames(on page: CGPDFPage) -> [CGRect] {
        guard let table = CGPDFOperatorTableCreate() else { return [] }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let state = scan(info)
            state.transforms.append(state.current)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let state = scan(info)
            if state.transforms.count > 1 { state.transforms.removeLast() }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            var values = [CGPDFReal](repeating: 0, count: 6)
            for index in (0..<6).reversed() {
                guard CGPDFScannerPopNumber(scanner, &values[index]) else { return }
            }
            let state = scan(info)
            let matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            state.transforms[state.transforms.count - 1] = matrix.concatenating(state.current)
        }
        CGPDFOperatorTableSetCallback(table, "EI") { _, info in scan(info).addImage() }  // an image in the drawing itself
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            let stream = CGPDFScannerGetContentStream(scanner)
            var xobject: CGPDFStreamRef?
            guard let object = CGPDFContentStreamGetResource(stream, "XObject", name),
                  CGPDFObjectGetValue(object, .stream, &xobject), let xobject,
                  let dictionary = CGPDFStreamGetDictionary(xobject) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
            let state = scan(info)
            switch String(cString: subtype) {
            case "Image":
                state.addImage()
            case "Form" where state.depth < 6:
                // A drawing of its own, placed by its matrix: followed too.
                var matrix = CGAffineTransform.identity
                var array: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
                    var values = [CGPDFReal](repeating: 0, count: 6)
                    for index in 0..<6 { _ = CGPDFArrayGetNumber(array, index, &values[index]) }
                    matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
                }
                // Without resources of its own it can't name an image to draw.
                var resources: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return }
                let form = CGPDFContentStreamCreateWithStream(xobject, resources, stream)
                state.transforms.append(matrix.concatenating(state.current))
                state.depth += 1
                let inner = CGPDFScannerCreate(form, state.table, info)
                CGPDFScannerScan(inner)
                CGPDFScannerRelease(inner)
                CGPDFContentStreamRelease(form)
                state.depth -= 1
                state.transforms.removeLast()
            default:
                break
            }
        }
        let state = PDFPictureScan(table: table)
        let info = Unmanaged.passUnretained(state).toOpaque()
        let content = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(content, table, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(content)
        CGPDFOperatorTableRelease(table)
        return withExtendedLifetime(state) { state.frames }
    }

    // MARK: - Cutting out

    /// The page as it looks in `rect`, as a JPEG, upright, sized as on the
    /// page (at most a text column wide).
    static func picture(of page: CGPDFPage, in rect: CGRect, dpi: CGFloat) -> Document.Picture? {
        let scale = dpi / 72
        let width = Int((rect.width * scale).rounded()), height = Int((rect.height * scale).rounded())
        guard width >= 8, height >= 8, width * height < 40_000_000,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        ctx.drawPDFPage(page)
        guard var image = ctx.makeImage() else { return nil }
        let turn = ((Int(page.rotationAngle) % 360) + 360) % 360
        if turn != 0, let turned = rotated(image, by: turn) { image = turned }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let size = turn % 180 == 0 ? rect.size : CGSize(width: rect.height, height: rect.width)
        let shown = min(size.width, 451)
        return Document.Picture(data: data as Data, isJPEG: true, width: shown, height: size.height * shown / size.width)
    }

    /// Turned clockwise by 90, 180 or 270 degrees, as the page is shown.
    private static func rotated(_ image: CGImage, by degrees: Int) -> CGImage? {
        let sideways = degrees % 180 != 0
        let width = sideways ? image.height : image.width, height = sideways ? image.width : image.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        ctx.rotate(by: -CGFloat(degrees) * .pi / 180)
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage()
    }
}

/// Following a page's drawing: the transforms in force, and where images went.
private final class PDFPictureScan {
    var transforms: [CGAffineTransform] = [.identity]
    var frames: [CGRect] = []
    var depth = 0
    let table: CGPDFOperatorTableRef

    init(table: CGPDFOperatorTableRef) {
        self.table = table
    }

    var current: CGAffineTransform { transforms.last ?? .identity }

    /// An image fills the unit square of where it's drawn.
    func addImage() {
        frames.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(current))
    }
}

/// The scan in progress, from what the scanner passes each callback.
private func scan(_ info: UnsafeMutableRawPointer?) -> PDFPictureScan {
    Unmanaged<PDFPictureScan>.fromOpaque(info!).takeUnretainedValue()
}
