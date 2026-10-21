import Foundation

/// Subtitles: SRT and WebVTT, either into the other, or into plain text.
enum Subtitles {
    struct Cue: Equatable {
        /// Seconds from the start.
        var start: Double
        var end: Double
        var text: String
    }

    static func read(_ url: URL) throws -> [Cue] {
        let cues = parse(try TextFile.read(url))
        guard !cues.isEmpty else { throw ConversionError.failed("\(url.lastPathComponent) has no subtitles Pinwheel can read.") }
        return cues
    }

    /// SRT or WebVTT: blocks with a "start --> end" line, then the text.
    static func parse(_ text: String) -> [Cue] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")
        var cues: [Cue] = []
        for block in blocks {
            var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }  // header, NOTE, STYLE…
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2, let start = seconds(parts[0]),
                  let end = seconds(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0]) else { continue }
            let body = lines[(timing + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            cues.append(Cue(start: start, end: end, text: body))
        }
        return cues
    }

    /// "01:02:03,456", "01:02:03.456" or "02:03.456".
    static func seconds(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    static func timestamp(_ seconds: Double, separator: String) -> String {
        let milliseconds = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60, milliseconds / 1000 % 60, separator, milliseconds % 1000)
    }

    static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n\(srtText(cue.text))"
        }.joined(separator: "\n\n") + "\n"
    }

    static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n\(cue.text)"
        }.joined(separator: "\n\n") + "\n"
    }

    /// WebVTT's voices and classes aren't SRT; italics and bold are.
    static func srtText(_ text: String) -> String {
        text.replacing(/<v(?:\.[^ >]*)?\s+([^>]*)>/) { "\($0.1): " }
            .replacing(/<\/?(c|v|lang|ruby|rt)[^>]*>/, with: "")
            .replacing(/<\d[\d:.]*>/, with: "")
    }

    /// Just the words, each line once (subtitles often repeat as they build up).
    static func plainText(_ cues: [Cue]) -> String {
        var lines: [String] = []
        for cue in cues {
            let clean = cue.text.replacing(/<v(?:\.[^ >]*)?\s+([^>]*)>/) { "\($0.1): " }.replacing(/<[^>]+>/, with: "")
            for line in clean.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && trimmed != lines.last { lines.append(trimmed) }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func convert(_ source: URL, to format: OutputFormat, destination: URL) throws {
        let cues = try read(source)
        let text: String
        switch format {
        case .srt: text = srt(cues)
        case .vtt: text = vtt(cues)
        case .txt: text = plainText(cues)
        default: throw ConversionError.unsupported("\(format.title) from subtitles")
        }
        do {
            try Data(text.utf8).write(to: destination)
        } catch {
            throw ConversionError.cannotWrite(destination.lastPathComponent)
        }
    }
}
