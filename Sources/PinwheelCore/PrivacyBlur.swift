import CoreGraphics
import Foundation
import Vision

/// Finds faces and text in a picture, to blur them out (with the image
/// editor's Blur Out).
public enum PrivacyBlur {
    /// Where faces and text are, as shares of the picture (0...1, y down),
    /// with some room around them: a face's hair and chin, a word's tails.
    public static func regions(in image: CGImage, faces: Bool = true, text: Bool = true) throws -> [RelativeRect] {
        let faceRequest = VNDetectFaceRectanglesRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = false
        let requests: [VNRequest] = (faces ? [faceRequest] : []) + (text ? [textRequest] : [])
        guard !requests.isEmpty else { return [] }
        do {
            try VNImageRequestHandler(cgImage: image).perform(requests)
        } catch {
            throw ConversionError.failed("Couldn't look for faces and text: \(error.localizedDescription)")
        }
        // Vision's boxes are 0...1 with y up.
        var boxes: [CGRect] = []
        if faces {
            boxes += (faceRequest.results ?? []).map { $0.boundingBox.insetBy(dx: -$0.boundingBox.width * 0.2, dy: -$0.boundingBox.height * 0.25) }
        }
        if text {
            boxes += (textRequest.results ?? []).map { $0.boundingBox.insetBy(dx: -$0.boundingBox.height * 0.3, dy: -$0.boundingBox.height * 0.3) }
        }
        return boxes.compactMap { box in
            let clamped = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return nil }
            return RelativeRect(x: clamped.minX, y: 1 - clamped.maxY, width: clamped.width, height: clamped.height)
        }
    }

    /// Blur Out markup over each region.
    public static func annotations(for regions: [RelativeRect]) -> [Annotation] {
        regions.map { region in
            Annotation(
                kind: .redact,
                points: [RelativePoint(x: region.x, y: region.y), RelativePoint(x: region.x + region.width, y: region.y + region.height)],
                color: .black, size: 0.01
            )
        }
    }

    /// The tool: every face and all text blurred out, in a copy.
    static func export(_ url: URL, format: OutputFormat, destination: URL, options: ConversionOptions) throws {
        // Looking in a smaller copy is quicker, and finds the same.
        let look = try StudioSource.load(url, maxPixelSize: 2400)
        let found = try regions(in: look.image)
        guard !found.isEmpty else { throw NothingToDo(reason: "No faces or text were found, so nothing was changed.") }
        try Task.checkCancellation()
        var edit = ImageEdit()
        edit.markup = annotations(for: found)
        try StudioExporter.export(url, edit: edit, format: format, destination: destination, options: options)
    }
}
