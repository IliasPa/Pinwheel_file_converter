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
            try VisionTurns.perform(requests, on: image)
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

    /// The same, from async code: Vision blocks its thread until it's done
    /// (and needs the system's shared threads meanwhile), so it gets one of
    /// its own instead of one of those.
    public static func find(in image: CGImage, faces: Bool = true, text: Bool = true) async throws -> [RelativeRect] {
        let picture = SendablePicture(image: image)
        return try await Blocking.run { _ in try regions(in: picture.image, faces: faces, text: text) }
    }

    private struct SendablePicture: @unchecked Sendable {
        let image: CGImage
    }

    /// What the editor can look for and blur by itself.
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case faces, emails, numbers
        /// Every line of text, whatever it says.
        case text

        /// Its switch in the editor.
        public var title: String {
            switch self {
            case .faces: "Faces"
            case .emails: "E-mail addresses"
            case .numbers: "Numbers"
            case .text: "All text"
            }
        }

        /// Plural, for a sentence.
        public var noun: String {
            switch self {
            case .faces: "faces"
            case .emails: "e-mail addresses"
            case .numbers: "numbers"
            case .text: "lines of text"
            }
        }

        public var singular: String {
            switch self {
            case .faces: "face"
            case .emails: "e-mail address"
            case .numbers: "number"
            case .text: "line of text"
            }
        }
    }

    /// A box and what it covers.
    public struct Found: Codable, Sendable, Equatable {
        public var kind: Kind
        public var rect: RelativeRect
        public init(kind: Kind, rect: RelativeRect) {
            self.kind = kind
            self.rect = rect
        }
    }

    /// Where the wanted kinds are: faces, e-mail addresses, numbers (four
    /// digits or more, with the spaces, dashes and brackets of phone and card
    /// numbers) and all text. A box covers just the address or number, not the
    /// whole line; for all text, a box covers each line.
    public static func find(kinds: Set<Kind>, in image: CGImage) throws -> [Found] {
        guard !kinds.isEmpty else { return [] }
        let faceRequest = VNDetectFaceRectanglesRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = false
        var requests: [VNRequest] = []
        if kinds.contains(.faces) { requests.append(faceRequest) }
        if !kinds.isDisjoint(with: [.emails, .numbers, .text]) { requests.append(textRequest) }
        do {
            try VisionTurns.perform(requests, on: image)
        } catch {
            throw ConversionError.failed("Couldn't look for faces and text: \(error.localizedDescription)")
        }
        var found: [Found] = []
        func add(_ kind: Kind, _ box: CGRect, grow: CGFloat) {
            let grown = box.insetBy(dx: -grow, dy: -grow)
            let clamped = grown.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return }
            found.append(Found(kind: kind, rect: RelativeRect(x: clamped.minX, y: 1 - clamped.maxY, width: clamped.width, height: clamped.height)))
        }
        if kinds.contains(.faces) {
            for face in faceRequest.results ?? [] {
                let box = face.boundingBox
                add(.faces, box.insetBy(dx: -box.width * 0.2, dy: -box.height * 0.25), grow: 0)
            }
        }
        for line in textRequest.results ?? [] {
            if kinds.contains(.text) {
                add(.text, line.boundingBox, grow: line.boundingBox.height * 0.3)
            }
            guard let candidate = line.topCandidates(1).first else { continue }
            let text = candidate.string
            for (kind, range) in matches(in: text, kinds: kinds) {
                guard let box = try? candidate.boundingBox(for: range)?.boundingBox else { continue }
                add(kind, box, grow: box.height * 0.2)
            }
        }
        return found
    }

    /// The e-mail addresses and numbers in a line of text.
    public static func matches(in text: String, kinds: Set<Kind>) -> [(Kind, Range<String.Index>)] {
        var result: [(Kind, Range<String.Index>)] = []
        if kinds.contains(.emails) {
            for match in text.matches(of: /[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/) {
                result.append((.emails, match.range))
            }
        }
        if kinds.contains(.numbers) {
            for match in text.matches(of: /\+?\d(?:[\d ().\-]{2,}\d)?/) {
                let digits = text[match.range].filter(\.isNumber).count
                // A number inside an address is part of the address.
                if digits >= 4, !result.contains(where: { $0.1.overlaps(match.range) }) {
                    result.append((.numbers, match.range))
                }
            }
        }
        return result
    }

    public static func find(kinds: Set<Kind>, inAsync image: CGImage) async throws -> [Found] {
        let picture = SendablePicture(image: image)
        return try await Blocking.run { _ in try find(kinds: kinds, in: picture.image) }
    }

    /// Blur markup for what was found, tagged so its switch can take it away:
    /// in blocks (`.redact`) or smooth (`.blur`).
    public static func annotations(for found: [Found], style: Annotation.Kind = .redact) -> [Annotation] {
        found.map { item in
            Annotation(
                kind: style == .blur ? .blur : .redact,
                points: [RelativePoint(x: item.rect.x, y: item.rect.y), RelativePoint(x: item.rect.x + item.rect.width, y: item.rect.y + item.rect.height)],
                color: .black, size: 0.01, auto: item.kind.rawValue
            )
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
