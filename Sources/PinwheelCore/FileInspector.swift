import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Reads what the Info window shows: size, dates, camera, codecs, pages…,
/// plus the details that can be edited.
public enum FileInspector {
    public static func details(of file: SourceFile, ffmpegURL: URL?) async -> FileDetails {
        var details = FileDetails()
        details.fields = MetadataField.fields(for: file.kind)
        switch file.kind {
        case .image:
            imageDetails(file, into: &details)
        case .video, .audio:
            await mediaDetails(file, ffmpegURL: ffmpegURL, into: &details)
        case .pdf:
            pdfDetails(file, into: &details)
        case nil:
            details.readOnlyReason = "Pinwheel can't read this kind of file."
        }
        details.sections.append(fileSection(file.url))
        return details
    }

    // MARK: - Images

    /// ImageIO can save new details into these without touching the picture.
    static let editableImageTypes: Set<String> = [UTType.jpeg, .png, .heic, .tiff].map(\.identifier).reduce(into: []) { $0.insert($1) }

    static func imageDetails(_ file: SourceFile, into details: inout FileDetails) {
        guard let src = CGImageSourceCreateWithURL(file.url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil) as? [CFString: Any]
        else {
            details.readOnlyReason = "\(file.url.lastPathComponent) couldn't be opened."
            return
        }
        let type = CGImageSourceGetType(src) as String?
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]

        var picture: [FileDetails.Row] = []
        if let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int {
            let turned = (props[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
            let (w, h) = turned ? (height, width) : (width, height)
            let megapixels = Double(w * h) / 1_000_000
            picture.append(row("Dimensions", "\(w) × \(h) pixels (\(String(format: megapixels < 10 ? "%.1f" : "%.0f", megapixels)) MP)"))
        }
        if let type, let name = UTType(type)?.localizedDescription { picture.append(row("Format", name)) }
        if CGImageSourceGetCount(src) > 1 { picture.append(row("Frames", "\(CGImageSourceGetCount(src))")) }
        let color = [props[kCGImagePropertyColorModel] as? String, props[kCGImagePropertyProfileName] as? String].compactMap { $0 }
        if !color.isEmpty { picture.append(row("Color", color.joined(separator: " · "))) }
        if let depth = props[kCGImagePropertyDepth] as? Int { picture.append(row("Depth", "\(depth) bits per channel")) }
        if let dpi = props[kCGImagePropertyDPIWidth] as? Double { picture.append(row("Resolution", "\(Int(dpi.rounded())) DPI")) }
        if props[kCGImagePropertyHasAlpha] as? Bool == true { picture.append(row("Transparency", "Yes")) }
        details.sections.append(.init(title: "Picture", rows: picture))

        var camera: [FileDetails.Row] = []
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        if let model {
            // "Apple" + "iPhone 15 Pro", but not "Canon" + "Canon EOS R6".
            let name = make.map { model.lowercased().hasPrefix($0.lowercased()) ? model : "\($0) \(model)" } ?? model
            camera.append(row("Camera", name))
        }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String { camera.append(row("Lens", lens)) }
        var exposure: [String] = []
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { exposure.append(String(format: "ƒ/%.1f", f)) }
        if let time = exif[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
            exposure.append(time >= 1 ? String(format: "%.1f s", time) : "1/\(Int((1 / time).rounded())) s")
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { exposure.append("ISO \(iso)") }
        if let focal = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int ?? (exif[kCGImagePropertyExifFocalLength] as? Double).map({ Int($0.rounded()) }) {
            exposure.append("\(focal) mm")
        }
        if !exposure.isEmpty { camera.append(row("Exposure", exposure.joined(separator: " · "))) }
        if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? tiff[kCGImagePropertyTIFFDateTime] as? String {
            camera.append(row("Taken", Formats.exifDate(taken)))
        }
        if let software = tiff[kCGImagePropertyTIFFSoftware] as? String { camera.append(row("Software", software)) }
        if !camera.isEmpty { details.sections.append(.init(title: "Camera", rows: camera)) }

        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
           let longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
            details.location = GeoLocation(
                latitude: (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -latitude : latitude,
                longitude: (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -longitude : longitude
            )
        }

        func text(_ value: Any?) -> String? {
            if let list = value as? [String] { return list.isEmpty ? nil : list.joined(separator: ", ") }
            return (value as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        details.values[.title] = text(iptc[kCGImagePropertyIPTCObjectName])
        details.values[.description] = text(iptc[kCGImagePropertyIPTCCaptionAbstract]) ?? text(tiff[kCGImagePropertyTIFFImageDescription])
        details.values[.author] = text(iptc[kCGImagePropertyIPTCByline]) ?? text(tiff[kCGImagePropertyTIFFArtist])
        details.values[.copyright] = text(iptc[kCGImagePropertyIPTCCopyrightNotice]) ?? text(tiff[kCGImagePropertyTIFFCopyright])
        details.values[.keywords] = text(iptc[kCGImagePropertyIPTCKeywords])

        if type.map({ !editableImageTypes.contains($0) }) ?? true {
            details.readOnlyReason = "Pinwheel can save these details only in JPEG, HEIC, PNG and TIFF files. Convert it first."
        }
    }

    // MARK: - Video and audio

    static func mediaDetails(_ file: SourceFile, ffmpegURL: URL?, into details: inout FileDetails) async {
        let ext = file.url.pathExtension.lowercased()
        let avWritable = MetadataWriter.avFileTypes[ext] != nil && !file.needsFFmpegToRead
        if !avWritable && ffmpegURL == nil {
            details.readOnlyReason = "Saving details in \(ext.uppercased()) files needs ffmpeg (brew install ffmpeg)."
        }
        // ffprobe reads tags the way ffmpeg will write them, and files macOS can't open.
        if !avWritable, let ffmpegURL, let probed = await probe(file.url, ffmpeg: ffmpegURL) {
            details.sections.append(contentsOf: probed.sections)
            details.values = probed.values
            details.location = probed.location
            return
        }
        guard !file.needsFFmpegToRead else {
            details.readOnlyReason = "macOS can't open this file. Install ffmpeg to see its details (brew install ffmpeg)."
            return
        }
        await avDetails(file.url, into: &details)
    }

    static func avDetails(_ url: URL, into details: inout FileDetails) async {
        let asset = AVURLAsset(url: url)
        var rows: [FileDetails.Row] = []
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        if duration > 0 { rows.append(row("Duration", Formats.duration(duration))) }

        if let video = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await video.load(.naturalSize), let transform = try? await video.load(.preferredTransform) {
                let shown = size.applying(transform)
                rows.append(row("Dimensions", "\(Int(abs(shown.width))) × \(Int(abs(shown.height))) pixels"))
            }
            if let fps = try? await video.load(.nominalFrameRate), fps > 0 {
                rows.append(row("Frame rate", String(format: fps.rounded() == fps ? "%.0f fps" : "%.2f fps", fps)))
            }
            if let code = try? await video.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType) {
                var text = Formats.codecName(code)
                if let rate = try? await video.load(.estimatedDataRate), rate > 0 { text += " · \(Formats.bitRate(Double(rate)))" }
                rows.append(row("Video", text))
            }
        }
        if let audio = try? await asset.loadTracks(withMediaType: .audio).first,
           let description = try? await audio.load(.formatDescriptions).first {
            var parts = [Formats.codecName(CMFormatDescriptionGetMediaSubType(description))]
            if let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                parts.append(stream.mChannelsPerFrame == 1 ? "mono" : stream.mChannelsPerFrame == 2 ? "stereo" : "\(stream.mChannelsPerFrame) channels")
                parts.append(String(format: "%g kHz", stream.mSampleRate / 1000))
            }
            if let rate = try? await audio.load(.estimatedDataRate), rate > 0 { parts.append(Formats.bitRate(Double(rate))) }
            rows.append(row("Audio", parts.joined(separator: " · ")))
        }

        let items = (try? await asset.load(.metadata)) ?? []
        var recorded: [FileDetails.Row] = []
        let make = await stringValue(items, [.quickTimeMetadataMake])
        let model = await stringValue(items, [.quickTimeMetadataModel])
        if let model { recorded.append(row("Recorded with", make.map { "\($0) \(model)" } ?? model)) }
        if let software = await stringValue(items, [.quickTimeMetadataSoftware, .commonIdentifierSoftware]) {
            recorded.append(row("Software", software))
        }
        if let created = await creationDate(items) { recorded.append(row("Recorded", created)) }

        details.sections.append(.init(title: "Media", rows: rows))
        if !recorded.isEmpty { details.sections.append(.init(title: "Recording", rows: recorded)) }
        for field in details.fields {
            details.values[field] = await MetadataWriter.value(of: field, in: items)
        }
        for item in items where MetadataWriter.isLocation(item) {
            if let text = try? await item.load(.stringValue), let location = GeoLocation(iso6709: text) {
                details.location = location
                break
            }
        }
    }

    static func stringValue(_ items: [AVMetadataItem], _ identifiers: [AVMetadataIdentifier]) async -> String? {
        for item in items where item.identifier.map(identifiers.contains) == true {
            if let value = try? await item.load(.stringValue), !value.isEmpty { return value }
        }
        return nil
    }

    static func creationDate(_ items: [AVMetadataItem]) async -> String? {
        for item in items where item.commonKey == .commonKeyCreationDate {
            if let date = try? await item.load(.dateValue) { return Formats.date(date) }
            if let text = try? await item.load(.stringValue), !text.isEmpty { return text }
        }
        return nil
    }

    /// Details from ffprobe, for files only ffmpeg can open or save.
    static func probe(_ url: URL, ffmpeg: URL) async -> (sections: [FileDetails.Section], values: [MetadataField: String], location: GeoLocation?)? {
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobe.path),
              let result = try? await ProcessRunner.run(ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path]),
              result.status == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        else { return nil }
        let format = json["format"] as? [String: Any] ?? [:]
        let streams = json["streams"] as? [[String: Any]] ?? []
        var rows: [FileDetails.Row] = []
        if let duration = (format["duration"] as? String).flatMap(Double.init) { rows.append(row("Duration", Formats.duration(duration))) }
        for stream in streams {
            let codec = (stream["codec_long_name"] ?? stream["codec_name"]) as? String ?? "Unknown"
            switch stream["codec_type"] as? String {
            case "video" where (stream["disposition"] as? [String: Any])?["attached_pic"] as? Int != 1:
                if let width = stream["width"] as? Int, let height = stream["height"] as? Int {
                    rows.append(row("Dimensions", "\(width) × \(height) pixels"))
                }
                rows.append(row("Video", codec))
            case "audio":
                var parts = [codec]
                if let channels = stream["channels"] as? Int { parts.append(channels == 1 ? "mono" : channels == 2 ? "stereo" : "\(channels) channels") }
                if let rate = (stream["sample_rate"] as? String).flatMap(Double.init) { parts.append(String(format: "%g kHz", rate / 1000)) }
                rows.append(row("Audio", parts.joined(separator: " · ")))
            default:
                break
            }
        }
        if let rate = (format["bit_rate"] as? String).flatMap(Double.init) { rows.append(row("Bit rate", Formats.bitRate(rate))) }

        // Tag names vary in case between formats ("title", "TITLE").
        var tags: [String: String] = [:]
        for (key, value) in format["tags"] as? [String: Any] ?? [:] {
            if let value = value as? String { tags[key.lowercased()] = value }
        }
        var values: [MetadataField: String] = [:]
        for field in MetadataField.allCases {
            if let value = tags[MetadataWriter.ffmpegKey(field)] ?? (field == .year ? tags["year"] : nil), !value.isEmpty {
                values[field] = value
            }
        }
        let location = (tags["location"] ?? tags["com.apple.quicktime.location.iso6709"]).flatMap(GeoLocation.init(iso6709:))
        return ([.init(title: "Media", rows: rows)], values, location)
    }

    // MARK: - PDFs

    static func pdfDetails(_ file: SourceFile, into details: inout FileDetails) {
        guard let document = PDFDocument(url: file.url) else {
            details.readOnlyReason = "\(file.url.lastPathComponent) couldn't be opened."
            return
        }
        var rows: [FileDetails.Row] = []
        if document.isLocked {
            rows.append(row("Password", "Needed to open it"))
            details.readOnlyReason = "It's password-protected."
        } else {
            rows.append(row("Pages", "\(document.pageCount)"))
            if let page = document.page(at: 0) { rows.append(row("Page size", Formats.pageSize(page.bounds(for: .mediaBox).size))) }
            let hasText = (0..<min(document.pageCount, 3)).contains {
                !(document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            rows.append(row("Text", hasText ? "Selectable" : "None found (scanned pages?)"))
        }
        rows.append(row("Version", "PDF \(document.majorVersion).\(document.minorVersion)"))
        if document.isEncrypted && !document.isLocked { rows.append(row("Restrictions", "Has an owner password")) }
        let attributes = document.documentAttributes ?? [:]
        if let creator = attributes[PDFDocumentAttribute.creatorAttribute] as? String, !creator.isEmpty { rows.append(row("Made with", creator)) }
        if let producer = attributes[PDFDocumentAttribute.producerAttribute] as? String, !producer.isEmpty { rows.append(row("Producer", producer)) }
        if let created = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date { rows.append(row("Created", Formats.date(created))) }
        if let modified = attributes[PDFDocumentAttribute.modificationDateAttribute] as? Date { rows.append(row("Modified", Formats.date(modified))) }
        details.sections.append(.init(title: "Document", rows: rows))

        for field in details.fields {
            guard let key = MetadataWriter.pdfKey(field) else { continue }
            if let list = attributes[key] as? [String] {
                if !list.isEmpty { details.values[field] = list.joined(separator: ", ") }
            } else if let text = attributes[key] as? String, !text.isEmpty {
                details.values[field] = text
            }
        }
    }

    // MARK: - Any file

    static func fileSection(_ url: URL) -> FileDetails.Section {
        var rows: [FileDetails.Row] = []
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .contentTypeKey])
        if let type = values?.contentType?.localizedDescription { rows.append(row("Kind", type)) }
        if let size = values?.fileSize { rows.append(row("Size", Formats.bytes(Int64(size)))) }
        if let created = values?.creationDate { rows.append(row("Created", Formats.date(created))) }
        if let modified = values?.contentModificationDate { rows.append(row("Modified", Formats.date(modified))) }
        rows.append(row("Where", (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath))
        return .init(title: "File", rows: rows)
    }

    static func row(_ label: String, _ value: String) -> FileDetails.Row {
        FileDetails.Row(label: label, value: value)
    }
}

/// Numbers and dates the way people read them.
enum Formats {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// "1:05" or "1:02:05"
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    static func bitRate(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000
            ? String(format: "%.1f Mbit/s", bitsPerSecond / 1_000_000)
            : String(format: "%.0f kbit/s", bitsPerSecond / 1000)
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// EXIF writes "2026:07:01 10:00:00".
    static func exifDate(_ text: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return parser.date(from: text).map(date) ?? text
    }

    /// "210 × 297 mm (A4)"
    static func pageSize(_ points: CGSize) -> String {
        let width = points.width * 25.4 / 72, height = points.height * 25.4 / 72
        let named: [(String, Double, Double)] = [("A4", 210, 297), ("A3", 297, 420), ("A5", 148, 210), ("Letter", 215.9, 279.4), ("Legal", 215.9, 355.6)]
        let match = named.first { abs($0.1 - min(width, height)) < 2 && abs($0.2 - max(width, height)) < 2 }
        let text = String(format: "%.0f × %.0f mm", width, height)
        return match.map { "\(text) (\($0.0)\(width > height ? ", landscape" : ""))" } ?? text
    }

    static func codecName(_ code: FourCharCode) -> String {
        switch code {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha: return "HEVC (H.265)"
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT,
             kCMVideoCodecType_AppleProRes422Proxy, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ:
            return "ProRes"
        case kCMVideoCodecType_MPEG4Video: return "MPEG-4"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD: return "AAC"
        case kAudioFormatAppleLossless: return "Apple Lossless"
        case kAudioFormatLinearPCM: return "PCM (uncompressed)"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatOpus: return "Opus"
        case kAudioFormatAC3: return "Dolby Digital"
        case kAudioFormatEnhancedAC3: return "Dolby Digital Plus"
        default:
            let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
    }
}
