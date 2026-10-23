import Foundation
import ImageIO
import Vision

/// A QR code or barcode found in a picture.
public struct ReadCode: Codable, Sendable, Equatable, Identifiable {
    public let text: String
    /// "QR code", "EAN-13 barcode"…
    public let kind: String

    public init(text: String, kind: String) {
        self.text = text
        self.kind = kind
    }

    public var id: String { "\(kind)\n\(text)" }

    /// The link, when the code holds one to open.
    public var link: URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "tel", "sms", "facetime", "maps"].contains(scheme) else { return nil }
        return url
    }
}

/// Reads QR codes and barcodes with Apple's Vision, on this Mac.
public enum CodeReader {
    /// From async code: Vision gets a thread of its own (see `PrivacyBlur.find`).
    public static func read(_ url: URL) async throws -> [ReadCode] {
        try await Blocking.run { _ in try codes(in: url) }
    }

    public static func codes(in url: URL) throws -> [ReadCode] {
        let src = try ImageConverter.open(url)
        let image = try ImageConverter.orientedImage(src, index: CGImageSourceGetPrimaryImageIndex(src), maxPixelSize: 4096)
        let request = VNDetectBarcodesRequest()
        try VisionTurns.perform([request], on: image)
        var codes: [ReadCode] = []
        for observation in request.results ?? [] {
            guard let text = observation.payloadStringValue, !text.isEmpty else { continue }
            let code = ReadCode(text: text, kind: names[observation.symbology] ?? "Barcode")
            if !codes.contains(code) { codes.append(code) }
        }
        return codes
    }

    static let names: [VNBarcodeSymbology: String] = [
        .qr: "QR code", .microQR: "QR code", .aztec: "Aztec code", .dataMatrix: "Data Matrix code",
        .pdf417: "PDF417 code", .microPDF417: "PDF417 code", .ean13: "EAN-13 barcode", .ean8: "EAN-8 barcode",
        .upce: "UPC-E barcode", .code128: "Code 128 barcode", .code39: "Code 39 barcode", .code93: "Code 93 barcode",
        .itf14: "ITF-14 barcode", .codabar: "Codabar barcode",
    ]
}
