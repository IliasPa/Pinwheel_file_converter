import AVFoundation
import Foundation

/// A song's title, artist, album, year, track and cover, carried from the
/// original to what's made of it. Each format keeps them its own way (ID3 in
/// MP3, iTunes atoms in M4A, Vorbis comments in FLAC and Ogg), and macOS
/// writes only some: without this, they were lost.
enum AudioTags {
    static let soundExtensions: Set<String> = ["mp3", "m4a", "m4b", "flac", "wav", "aif", "aiff", "ogg", "opus", "wma"]

    /// When the original has a title or cover the new file lacks.
    static func carryIfMissing(from source: URL, into output: URL, ffmpeg: URL?) async {
        let before = await summary(source, ffmpeg: ffmpeg), after = await summary(output, ffmpeg: ffmpeg)
        let coverFits = ["mp3", "m4a", "m4b", "flac"].contains(output.pathExtension.lowercased())
        guard (before.title && !after.title) || (before.cover && !after.cover && coverFits) else { return }
        await carry(from: source, into: output, ffmpeg: ffmpeg)
    }

    /// Whether a file has a title and a cover.
    private static func summary(_ url: URL, ffmpeg: URL?) async -> (title: Bool, cover: Bool) {
        if let ffmpeg {
            let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
            guard let result = try? await ProcessRunner.run(ffprobe, ["-v", "error", "-show_entries", "format_tags=title:stream_tags=title:stream_disposition=attached_pic",
                                                                       "-of", "json", url.path]) else { return (false, false) }
            let text = result.stdout.lowercased()
            return (text.contains("\"title\""), text.contains("\"attached_pic\": 1"))
        }
        let items = (try? await AVURLAsset(url: url).load(.commonMetadata)) ?? []
        return (items.contains { $0.commonKey == .commonKeyTitle }, items.contains { $0.commonKey == .commonKeyArtwork })
    }

    /// Into a file made without them: by ffmpeg when it's installed (any
    /// format, the cover too), else by macOS (M4A). Best effort: the file is
    /// left as it was when it can't be done.
    static func carry(from source: URL, into output: URL, ffmpeg: URL?) async {
        if let ffmpeg, let streams = await FFmpeg.streams(of: source, ffmpeg: ffmpeg) {
            let ext = output.pathExtension.lowercased()
            let temporary = output.deletingLastPathComponent().appendingPathComponent(".pinwheel-tags-\(UUID().uuidString).\(ext)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            var arguments = ["-map", "0:a", "-map_metadata", streams.tagsOnSound ? "1:s:a:0" : "1", "-c", "copy"]
            if let cover = streams.cover, ["mp3", "m4a", "m4b", "flac"].contains(ext) {
                arguments += ["-map", "1:\(cover)", "-disposition:v:0", "attached_pic"]
            }
            if ext == "mp3" { arguments += ["-id3v2_version", "3"] }
            if ext == "aif" || ext == "aiff" { arguments += ["-write_id3v2", "1"] }
            let result = try? await ProcessRunner.run(ffmpeg, ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-i", output.path, "-i", source.path]
                + arguments + [temporary.path])
            if result?.status == 0, (try? FileManager.default.replaceItemAt(output, withItemAt: temporary)) != nil { return }
        }
        guard ["m4a", "m4b"].contains(output.pathExtension.lowercased()) else { return }
        let items = await itunes(from: AVURLAsset(url: source))
        guard !items.isEmpty else { return }
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".pinwheel-tags-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try await MediaConverter.export(AVURLAsset(url: output), preset: AVAssetExportPresetPassthrough, fileType: .m4a, to: temporary, metadata: items) { _ in }
            _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
        } catch {
            return
        }
    }

    /// The tags as M4A (iTunes) keeps them, whatever the original's kind.
    static func itunes(from asset: AVAsset) async -> [AVMetadataItem] {
        guard let all = try? await asset.load(.metadata) else { return [] }
        var items: [AVMetadataItem] = []
        var done: Set<AVMetadataIdentifier> = []
        let common: [AVMetadataKey: AVMetadataIdentifier] = [
            .commonKeyTitle: .iTunesMetadataSongName, .commonKeyArtist: .iTunesMetadataArtist, .commonKeyAlbumName: .iTunesMetadataAlbum,
            .commonKeyArtwork: .iTunesMetadataCoverArt, .commonKeyType: .iTunesMetadataUserGenre, .commonKeyCreationDate: .iTunesMetadataReleaseDate,
            .commonKeyDescription: .iTunesMetadataDescription, .commonKeyCopyrights: .iTunesMetadataCopyright,
        ]
        for item in all {
            // Already iTunes's own: kept as it is.
            if item.keySpace == .iTunes, let identifier = item.identifier, !done.contains(identifier) {
                items.append(item)
                done.insert(identifier)
                continue
            }
            guard let key = item.commonKey, let identifier = common[key], !done.contains(identifier) else { continue }
            let copy = AVMutableMetadataItem()
            copy.identifier = identifier
            if key == .commonKeyArtwork {
                guard let data = try? await item.load(.dataValue) else { continue }
                copy.value = data as NSData
                copy.dataType = data.starts(with: [0x89, 0x50]) ? kCMMetadataBaseDataType_PNG as String : kCMMetadataBaseDataType_JPEG as String
            } else {
                guard let text = try? await item.load(.stringValue), !text.isEmpty else { continue }
                copy.value = text as NSString
            }
            items.append(copy)
            done.insert(identifier)
        }
        // Track numbers aren't a common key: ID3's "3" or "3/12".
        if !done.contains(.iTunesMetadataTrackNumber),
           let track = all.first(where: { $0.identifier == .id3MetadataTrackNumber }), let text = try? await track.load(.stringValue) {
            let parts = text.split(separator: "/").compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) }
            if let number = parts.first {
                let total = parts.count > 1 ? parts[1] : 0
                let copy = AVMutableMetadataItem()
                copy.identifier = .iTunesMetadataTrackNumber
                copy.value = Data([0, 0, UInt8(number >> 8), UInt8(number & 0xFF), UInt8(total >> 8), UInt8(total & 0xFF), 0, 0]) as NSData
                copy.dataType = kCMMetadataBaseDataType_RawData as String
                items.append(copy)
            }
        }
        return items
    }
}

/// What Apple's AAC encoder takes: a bit rate in a range that depends on
/// the sample rate and channels (8 kHz mono: 16–24 kbps; 44.1 kHz stereo:
/// 64–320). Outside it, writing failed ("couldn't save").
enum AACBitRate {
    static func allowed(_ wanted: Int, sampleRate: Double, channels: Int) -> Int {
        let channels = max(1, min(channels, 2))
        let perChannel = sampleRate < 11_000 ? 24_000 : sampleRate < 16_000 ? 32_000 : sampleRate < 22_000 ? 48_000
            : sampleRate < 32_000 ? 64_000 : sampleRate < 44_000 ? 96_000 : 160_000
        let least = channels * (sampleRate >= 44_000 ? 32_000 : sampleRate >= 32_000 ? 24_000 : 16_000)
        return min(max(wanted, least), perChannel * channels)
    }
}
