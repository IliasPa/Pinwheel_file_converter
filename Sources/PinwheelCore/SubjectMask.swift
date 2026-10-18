import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Finds the main subjects of a picture (people, pets, objects) with the same
/// on-device model as "Lift subject from background" in Photos.
public enum SubjectMask {
    /// A gray picture the size of `image`: white on the subjects, black
    /// elsewhere, soft at the edges. nil when there's no clear subject.
    public static func make(for image: CGImage) throws -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        let buffer: CVPixelBuffer? = try VisionTurns.take {
            do {
                try handler.perform([request])
            } catch {
                throw ConversionError.failed("Couldn't look for the subject: \(error.localizedDescription)")
            }
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            return try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        }
        guard let buffer else { return nil }
        let mask = CIImage(cvPixelBuffer: buffer)
        guard let gray = CGColorSpace(name: CGColorSpace.linearGray),
              let picture = StudioRenderer.context.createCGImage(mask, from: mask.extent, format: .L8, colorSpace: gray) else {
            throw ConversionError.failed("Not enough memory to cut out the subject.")
        }
        return picture
    }
}

/// Vision can deadlock when several of its requests run at once in one
/// process (each waits for room the others are holding), so Pinwheel's
/// requests take turns. Jobs each have their own worker process anyway;
/// this matters for the editor's preview and for the tests.
enum VisionTurns {
    private static let lock = NSLock()

    static func take<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }
}
