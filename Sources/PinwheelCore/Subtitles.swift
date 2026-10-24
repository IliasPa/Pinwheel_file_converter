import Foundation

/// Subtitles: SRT and WebVTT, either into the other, or into plain text.
/// Bold, italics, underlines, colors and a subtitle's place on the screen
/// (top or bottom, left or right) go across; what one format can't hold
/// (VTT's exact positions and sizes) is simplified.
enum Subtitles {
    struct Cue: Equatable {
        /// Seconds from the start.
        var start: Double
        var end: Double
        var text: String
        /// Where it goes on the screen (bottom center when not set).
        var place = Place()
    }

    /// The screen in a 3 × 3 grid, as SRT's {\an1}…{\an9} has it.
    struct Place: Equatable {
        enum Row { case top, middle, bottom }
        enum Column { case left, center, right }
        var row = Row.bottom
        var column = Column.center

        /// SRT's number for it: 1–3 along the bottom, 4–6 the middle, 7–9 the top.
        var number: Int {
            (row == .bottom ? 1 : row == .middle ? 4 : 7) + (column == .left ? 0 : column == .center ? 1 : 2)
        }

        init(row: Row = .bottom, column: Column = .center) {
            self.row = row
            self.column = column
        }

        init?(number: Int) {
            guard (1...9).contains(number) else { return nil }
            row = number >= 7 ? .top : number >= 4 ? .middle : .bottom
            column = [.left, .center, .right][(number - 1) % 3]
        }

        /// From VTT's cue settings ("line:0 align:start", "line:10%").
        init(vttSettings settings: String) {
            for setting in settings.split(separator: " ") {
                let parts = setting.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let value = parts[1].components(separatedBy: ",")[0]
                switch parts[0] {
                case "line":
                    if value.hasSuffix("%"), let percent = Double(value.dropLast()) {
                        row = percent < 35 ? .top : percent < 65 ? .middle : .bottom
                    } else if let line = Int(value) {
                        row = line >= 0 ? .top : .bottom  // counted from the top, or (negative) from the bottom
                    }
                case "align":
                    if value == "start" || value == "left" { column = .left }
                    if value == "end" || value == "right" { column = .right }
                default:
                    break
                }
            }
        }

        /// As VTT cue settings ("" for the bottom center).
        var vttSettings: String {
            var settings: [String] = []
            switch row {
            case .top: settings.append("line:0")
            case .middle: settings.append("line:50%")
            case .bottom: break
            }
            switch column {
            case .left: settings.append("align:start")
            case .right: settings.append("align:end")
            case .center: break
            }
            return settings.joined(separator: " ")
        }
    }

    static func read(_ url: URL) throws -> [Cue] {
        let cues = parse(try TextFile.read(url))
        guard !cues.isEmpty else { throw ConversionError.failed("\(url.lastPathComponent) has no subtitles Pinwheel can read.") }
        return cues
    }

    /// SRT or WebVTT: blocks with a "start --> end" line, then the text.
    /// A VTT's colors (its STYLE blocks, and the standard color classes)
    /// become SRT's font colors; SRT's {\anN} becomes the cue's place.
    static func parse(_ text: String) -> [Cue] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")
        let colors = styleColors(blocks)
        var cues: [Cue] = []
        for block in blocks {
            var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }  // header, NOTE, STYLE…
            let parts = lines[timing].components(separatedBy: "-->")
            let after = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ") : []
            guard parts.count == 2, let start = seconds(parts[0]), let end = after.first.flatMap(seconds) else { continue }
            var body = lines[(timing + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            var place = Place(vttSettings: after.dropFirst().joined(separator: " "))
            // SRT's place: {\an8} (or the older {\a6}) at the start.
            if let match = body.firstMatch(of: /\{\\an?(\d)\}/), let number = Int(match.1) {
                place = Place(number: number) ?? place
                body.removeSubrange(match.range)
            }
            body = body.replacing(/\{\\[^}]*\}/, with: "")  // other SRT/ASS codes
            cues.append(Cue(start: start, end: end, text: colored(body, colors: colors), place: place))
        }
        return cues
    }

    /// WebVTT's standard color classes, and those its STYLE blocks give a
    /// color: `::cue(.name) { color: #ff0 }`.
    static func styleColors(_ blocks: [String]) -> [String: String] {
        var colors = [
            "white": "#FFFFFF", "lime": "#00FF00", "cyan": "#00FFFF", "red": "#FF0000",
            "yellow": "#FFFF00", "magenta": "#FF00FF", "blue": "#0000FF", "black": "#000000",
        ]
        for block in blocks where block.trimmingCharacters(in: .whitespaces).hasPrefix("STYLE") {
            for match in block.matches(of: /::cue\(\.([\w-]+)\)\s*\{([^}]*)\}/) {
                if let color = String(match.2).firstMatch(of: /(?:^|[;\s])color:\s*([^;\s]+)/) {
                    colors[String(match.1)] = String(color.1)
                }
            }
        }
        return colors
    }

    /// VTT's `<c.yellow>…</c>` as SRT's `<font color="#FFFF00">…</font>`.
    static func colored(_ text: String, colors: [String: String]) -> String {
        var result = text
        while let open = result.firstMatch(of: /<c((?:\.[\w-]+)+)>/) {
            let classes = open.1.split(separator: ".").map(String.init)
            let color = classes.lazy.compactMap { colors[$0] }.first
            let close = result[open.range.upperBound...].firstRange(of: "</c>")
            if let color, let close {
                result.replaceSubrange(close, with: "</font>")
                result.replaceSubrange(open.range, with: "<font color=\"\(color)\">")
            } else {
                if let close { result.replaceSubrange(close, with: "") }
                result.replaceSubrange(open.range, with: "")
            }
        }
        return result
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
            let place = cue.place.number == 2 ? "" : "{\\an\(cue.place.number)}"
            return "\(index + 1)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n\(place)\(srtText(cue.text))"
        }.joined(separator: "\n\n") + "\n"
    }

    static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            let settings = cue.place.vttSettings
            return "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\(settings.isEmpty ? "" : " " + settings)\n\(vttText(cue.text))"
        }.joined(separator: "\n\n") + "\n"
    }

    /// WebVTT's voices and classes aren't SRT; italics, bold, underlines
    /// and font colors are.
    static func srtText(_ text: String) -> String {
        text.replacing(/<v(?:\.[^ >]*)?\s+([^>]*)>/) { "\($0.1): " }
            .replacing(/<\/?(c|v|lang|ruby|rt)[^>]*>/, with: "")
            .replacing(/<\d[\d:.]*>/, with: "")
    }

    /// SRT's font colors aren't VTT (it colors with classes): the words stay.
    static func vttText(_ text: String) -> String {
        text.replacing(/<\/?font[^>]*>/, with: "")
    }

    /// Just the words, each line once (subtitles often repeat as they build
    /// up); with `times`, each subtitle's start before it ("[00:01:05]").
    static func plainText(_ cues: [Cue], times: Bool = false) -> String {
        var lines: [String] = []
        var last: String?
        for cue in cues {
            let clean = cue.text.replacing(/<v(?:\.[^ >]*)?\s+([^>]*)>/) { "\($0.1): " }.replacing(/<[^>]+>/, with: "")
            let words = clean.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if times {
                let joined = words.joined(separator: " ")
                guard !joined.isEmpty, joined != last else { continue }
                lines.append("[\(timestamp(cue.start, separator: ".").prefix(8))] \(joined)")
                last = joined
            } else {
                for line in words where line != lines.last { lines.append(line) }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func convert(_ source: URL, to format: OutputFormat, destination: URL, options: ConversionOptions = ConversionOptions()) throws {
        let cues = try read(source)
        let text: String
        switch format {
        case .srt: text = srt(cues)
        case .vtt: text = vtt(cues)
        case .txt: text = plainText(cues, times: options.subtitleTimes)
        default: throw ConversionError.unsupported("\(format.title) from subtitles")
        }
        do {
            try Data(text.utf8).write(to: destination)
        } catch {
            throw ConversionError.cannotWrite(destination.lastPathComponent)
        }
    }
}
