import AVFoundation
import Foundation
import ImageIO
import PDFKit

/// Saves the Info window's changes in a copy of the file. The picture,
/// sound or pages themselves are copied as they are, never re-encoded.
enum MetadataWriter {
    static func write(
        _ file: SourceFile, edit: MetadataEdit, destination: URL,
        options: ConversionOptions, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard !edit.isEmpty else { throw NothingToDo(reason: "Nothing was changed, so nothing was saved.") }
        switch file.kind {
        case .image: try writeImage(file.url, edit: edit, destination: destination)
        case .pdf: try writePDF(file.url, edit: edit, destination: destination)
        case .video, .audio: try await writeMedia(file, edit: edit, destination: destination, options: options, progress: progress)
        case .archive, nil: throw ConversionError.unsupported(file.url.lastPathComponent)
        }
    }

    // MARK: - Images

    /// Where each detail lives in a photo. Descriptions, authors and
    /// copyrights also have an older TIFF twin; both are kept in step.
    static func imageProperties(_ field: MetadataField) -> [(dictionary: CFString, key: CFString)] {
        switch field {
        case .title: [(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCObjectName)]
        case .description: [(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription), (kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract)]
        case .author: [(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist), (kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCByline)]
        case .copyright: [(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFCopyright), (kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCopyrightNotice)]
        case .keywords: [(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCKeywords)]
        default: []
        }
    }

    static func writeImage(_ url: URL, edit: MetadataEdit, destination: URL) throws {
        let src = try ImageConverter.open(url)
        let index = CGImageSourceGetPrimaryImageIndex(src)
        guard let type = CGImageSourceGetType(src), FileInspector.editableImageTypes.contains(type as String) else {
            throw ConversionError.failed("Pinwheel can save details only in JPEG, HEIC, PNG and TIFF files.")
        }
        let metadata = CGImageSourceCopyMetadataAtIndex(src, index, nil).flatMap(CGImageMetadataCreateMutableCopy)
            ?? CGImageMetadataCreateMutable()
        for (field, value) in edit.changes {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            for (dictionary, key) in imageProperties(field) {
                // Remove first, so a shorter list doesn't keep old entries.
                if let tag = CGImageMetadataCopyTagMatchingImageProperty(metadata, dictionary, key),
                   let prefix = CGImageMetadataTagCopyPrefix(tag), let name = CGImageMetadataTagCopyName(tag) {
                    CGImageMetadataRemoveTagWithPath(metadata, nil, "\(prefix):\(name)" as CFString)
                }
                guard !text.isEmpty else { continue }
                let isList = key == kCGImagePropertyIPTCKeywords || key == kCGImagePropertyIPTCByline
                let stored: CFTypeRef = isList ? MetadataField.list(text) as CFArray : text as CFString
                CGImageMetadataSetValueMatchingImageProperty(metadata, dictionary, key, stored)
            }
        }
        var options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false,
        ]
        if edit.removeLocation {
            // The option alone is ignored for PNGs, so the tags go too.
            options[kCGImageMetadataShouldExcludeGPS] = true
            removeGPS(from: metadata)
        }

        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else {
            throw ConversionError.cannotWrite(destination.lastPathComponent)
        }
        if CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, nil) { return }

        // Some files can't be copied as they are; save the picture again instead.
        try? FileManager.default.removeItem(at: destination)
        guard let again = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil),
              let image = CGImageSourceCreateImageAtIndex(src, index, nil) else {
            throw ConversionError.cannotWrite(destination.lastPathComponent)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        options.removeValue(forKey: kCGImageDestinationMergeMetadata)
        options.removeValue(forKey: kCGImageDestinationMetadata)
        options[kCGImagePropertyOrientation] = properties[kCGImagePropertyOrientation] ?? 1
        options[kCGImageDestinationLossyCompressionQuality] = 0.95
        CGImageDestinationAddImageAndMetadata(again, image, metadata, options as CFDictionary)
        try ImageConverter.finalize(again, destination)
    }

    /// Removes every GPS tag (they're the exif:GPS… ones).
    static func removeGPS(from metadata: CGMutableImageMetadata) {
        var paths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
            if let name = CGImageMetadataTagCopyName(tag) as String?, name.hasPrefix("GPS") {
                paths.append(path as String)
            }
            return true
        }
        for path in paths {
            CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
        }
    }

    // MARK: - PDFs

    static func pdfKey(_ field: MetadataField) -> PDFDocumentAttribute? {
        switch field {
        case .title: .titleAttribute
        case .author: .authorAttribute
        case .subject: .subjectAttribute
        case .keywords: .keywordsAttribute
        default: nil
        }
    }

    static func writePDF(_ url: URL, edit: MetadataEdit, destination: URL) throws {
        let document = try PDFConverter.open(url)
        var attributes = document.documentAttributes ?? [:]
        for (field, value) in edit.changes {
            guard let key = pdfKey(field) else { continue }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                attributes.removeValue(forKey: key)
            } else {
                attributes[key] = field == .keywords ? MetadataField.list(text) as Any : text as Any
            }
        }
        document.documentAttributes = attributes
        guard document.write(to: destination) else { throw ConversionError.cannotWrite(destination.lastPathComponent) }
    }

    // MARK: - Video and audio

    /// Containers macOS can save new tags into without converting.
    static let avFileTypes: [String: AVFileType] = [
        "mov": .mov, "mp4": .mp4, "m4v": .m4v, "3gp": .mobile3GPP, "m4a": .m4a, "m4b": .m4a,
    ]

    /// The common key a detail goes by in every format, if it has one.
    static func commonKey(_ field: MetadataField) -> AVMetadataKey? {
        switch field {
        case .title: .commonKeyTitle
        case .artist: .commonKeyArtist
        case .album: .commonKeyAlbumName
        case .description: .commonKeyDescription
        case .author: .commonKeyAuthor
        case .copyright: .commonKeyCopyrights
        default: nil
        }
    }

    /// Format-specific names for details without a common key.
    static func identifiers(_ field: MetadataField) -> [AVMetadataIdentifier] {
        switch field {
        case .genre: [.iTunesMetadataUserGenre, .iTunesMetadataPredefinedGenre, .quickTimeMetadataGenre, .id3MetadataContentType]
        case .comment: [.iTunesMetadataUserComment, .quickTimeMetadataComment, .quickTimeUserDataComment, .id3MetadataComments]
        case .year: [.iTunesMetadataReleaseDate, .quickTimeMetadataYear, .id3MetadataYear, .id3MetadataRecordingTime]
        default: []
        }
    }

    static func matches(_ item: AVMetadataItem, _ field: MetadataField) -> Bool {
        if let key = commonKey(field), item.commonKey == key { return true }
        return item.identifier.map(identifiers(field).contains) ?? false
    }

    static func isLocation(_ item: AVMetadataItem) -> Bool {
        if item.commonKey == .commonKeyLocation { return true }
        let id = item.identifier?.rawValue.lowercased() ?? ""
        return id.contains("location") || id.contains("%a9xyz") || id.contains("©xyz")
    }

    static func value(of field: MetadataField, in items: [AVMetadataItem]) async -> String? {
        for item in items where matches(item, field) {
            if let text = try? await item.load(.stringValue), !text.isEmpty { return text }
        }
        return nil
    }

    /// How a new detail is stored: QuickTime keys in .mov, iTunes keys in
    /// MPEG-4 files (common keys are translated by macOS).
    static func newIdentifier(_ field: MetadataField, quickTime: Bool) -> AVMetadataIdentifier? {
        switch field {
        case .title: .commonIdentifierTitle
        case .artist: .commonIdentifierArtist
        case .album: .commonIdentifierAlbumName
        case .description: .commonIdentifierDescription
        case .author: .commonIdentifierAuthor
        case .copyright: .commonIdentifierCopyrights
        case .genre: quickTime ? .quickTimeMetadataGenre : .iTunesMetadataUserGenre
        case .comment: quickTime ? .quickTimeMetadataComment : .iTunesMetadataUserComment
        case .year: quickTime ? .quickTimeMetadataYear : .iTunesMetadataReleaseDate
        case .subject, .keywords: nil
        }
    }

    /// ffmpeg's name for a detail.
    static func ffmpegKey(_ field: MetadataField) -> String {
        switch field {
        case .year: "date"
        default: field.rawValue
        }
    }

    static func writeMedia(
        _ file: SourceFile, edit: MetadataEdit, destination: URL,
        options: ConversionOptions, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let ext = file.url.pathExtension.lowercased()
        if let fileType = avFileTypes[ext], !file.needsFFmpegToRead {
            let asset = AVURLAsset(url: file.url)
            var items = try await asset.load(.metadata)
            for (field, value) in edit.changes {
                items.removeAll { matches($0, field) }
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, let identifier = newIdentifier(field, quickTime: fileType == .mov) else { continue }
                let item = AVMutableMetadataItem()
                item.identifier = identifier
                item.value = text as NSString
                item.extendedLanguageTag = "und"
                items.append(item)
            }
            if edit.removeLocation { items.removeAll(where: isLocation) }
            try await MediaConverter.export(
                asset, preset: AVAssetExportPresetPassthrough, fileType: fileType, to: destination,
                metadata: items, progress: progress
            )
            return
        }
        guard let ffmpeg = options.ffmpegURL else { throw ConversionError.needsFFmpeg }
        var arguments = ["-map", "0", "-c", "copy", "-map_metadata", "0"]
        for (field, value) in edit.changes.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            arguments += ["-metadata", "\(ffmpegKey(field))=\(value.trimmingCharacters(in: .whitespacesAndNewlines))"]
        }
        if edit.removeLocation {
            arguments += ["-metadata", "location=", "-metadata", "location-eng=", "-metadata", "com.apple.quicktime.location.ISO6709="]
        }
        if ext == "mp3" { arguments += ["-id3v2_version", "3", "-write_id3v1", "1"] }
        let duration = await FFmpeg.duration(of: file, ffmpeg: ffmpeg)
        try await FFmpeg.convert(ffmpeg: ffmpeg, input: file.url, output: destination, arguments: arguments, duration: duration, progress: progress)
    }
}
