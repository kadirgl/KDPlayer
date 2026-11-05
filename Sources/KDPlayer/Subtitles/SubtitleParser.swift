import Foundation

/// SRT, WebVTT ve ASS/SSA ayrıştırıcı. Biçim içerikten anlaşılır.
enum SubtitleParser {
    enum ParseError: Error { case empty, unknownFormat }

    static func parse(_ text: String) throws -> SubtitleDocument {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        let head = normalized.prefix(2000).lowercased()
        let document: SubtitleDocument
        if head.contains("[script info]") || head.contains("[events]") {
            document = SubtitleDocument(cues: parseASS(normalized), format: .ass)
        } else if head.hasPrefix("webvtt") {
            document = SubtitleDocument(cues: parseTimed(normalized), format: .vtt)
        } else if normalized.contains("-->") {
            document = SubtitleDocument(cues: parseTimed(normalized), format: .srt)
        } else {
            throw ParseError.unknownFormat
        }
        guard !document.cues.isEmpty else { throw ParseError.empty }
        return document
    }

    // MARK: SRT / WebVTT

    private static let timeLine = try! NSRegularExpression(
        pattern: #"((?:\d+:)?\d{1,2}:\d{1,2}[,.]\d{1,3})\s*-->\s*((?:\d+:)?\d{1,2}:\d{1,2}[,.]\d{1,3})(.*)"#
    )

    private static func parseTimed(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = text.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let line = lines[timeIndex]
            let range = NSRange(line.startIndex..., in: line)
            guard let match = timeLine.firstMatch(in: line, range: range),
                  let startRange = Range(match.range(at: 1), in: line),
                  let endRange = Range(match.range(at: 2), in: line),
                  let start = seconds(String(line[startRange])),
                  let end = seconds(String(line[endRange])) else { continue }
            let settings = Range(match.range(at: 3), in: line).map { String(line[$0]) } ?? ""
            let body = lines[(timeIndex + 1)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = cleanMarkup(body)
            guard !cleaned.isEmpty, end > start else { continue }
            let top = body.contains("{\\an8}") || settings.contains("line:0") || settings.contains("line:10%")
            cues.append(SubtitleCue(id: cues.count, start: start, end: end, text: cleaned, top: top))
        }
        return sortAndNumber(cues)
    }

    /// "01:04:12,345" / "04:12.3" → saniye.
    static func seconds(_ value: String) -> Double? {
        let parts = value.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count >= 2 else { return nil }
        var total = 0.0
        for part in parts {
            guard let number = Double(part) else { return nil }
            total = total * 60 + number
        }
        return total
    }

    // MARK: ASS / SSA

    private static func parseASS(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var format: [String] = []
        var inEvents = false
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased() == "[events]"
                continue
            }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                format = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:") else { continue }
            if format.isEmpty {
                format = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
            }
            // Metin alanı virgül içerebilir: yalnızca ilk (n-1) virgülden böl.
            let fields = line.dropFirst(9).split(separator: ",", maxSplits: format.count - 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == format.count,
                  let startIndex = format.firstIndex(of: "start"), let endIndex = format.firstIndex(of: "end"),
                  let textIndex = format.firstIndex(of: "text"),
                  let start = seconds(fields[startIndex]), let end = seconds(fields[endIndex]) else { continue }
            let raw = fields[textIndex]
            // Çizim komutlarını ({\p1}) ve boş satırları atla.
            if raw.contains("\\p1") { continue }
            let top = raw.contains("\\an8") || raw.contains("\\an7") || raw.contains("\\an9")
            let cleaned = cleanMarkup(
                raw.replacingOccurrences(of: "\\N", with: "\n")
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\h", with: " ")
            )
            guard !cleaned.isEmpty, end > start else { continue }
            cues.append(SubtitleCue(id: 0, start: start, end: end, text: cleaned, top: top))
        }
        return sortAndNumber(cues)
    }

    // MARK: Yardımcılar

    private static let tagPattern = try! NSRegularExpression(pattern: #"\{[^}]*\}|<[^>]+>"#)

    /// {\i1}, <i>, <font> gibi işaretleri temizler.
    static func cleanMarkup(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let stripped = tagPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return stripped
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func sortAndNumber(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.sorted { $0.start < $1.start }.enumerated().map { index, cue in
            var cue = cue
            cue = SubtitleCue(id: index, start: cue.start, end: cue.end, text: cue.text, top: cue.top)
            return cue
        }
    }
}
