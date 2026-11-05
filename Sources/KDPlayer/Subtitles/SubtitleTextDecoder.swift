import Foundation

/// Altyazı dosyalarının karakter kodlamasını bulur. Türkçe altyazılar sıklıkla Windows-1254 ya da
/// ISO-8859-9'dur. Sıra: BOM → UTF-8 doğrulaması → 1254 → 8859-9. UTF-8 olarak okunup bozulmuş
/// ("ÅŸ", "Ä±", "Ã¼") metin de onarılır.
enum SubtitleTextDecoder {
    struct Result: Equatable {
        let text: String
        /// Kullanılan kodlamanın görünen adı.
        let encodingName: String
        /// Bozuk karakterler düzeltildiyse "Windows-1254 → UTF-8" gibi açıklama.
        let repairNote: String?
    }

    enum Preference: String, CaseIterable, Identifiable {
        case auto, utf8, windows1254, iso8859_9
        var id: Self { self }
        var title: String {
            switch self {
            case .auto: "Otomatik"
            case .utf8: "UTF-8"
            case .windows1254: "Windows-1254"
            case .iso8859_9: "ISO-8859-9"
            }
        }
    }

    static let windows1254 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsLatin5.rawValue)))
    static let iso8859_9 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.isoLatin5.rawValue)))

    static func decode(_ data: Data, preference: Preference = .auto) -> Result? {
        switch preference {
        case .utf8: return String(data: data, encoding: .utf8).map { Result(text: $0, encodingName: "UTF-8", repairNote: nil) }
        case .windows1254: return String(data: data, encoding: windows1254).map { Result(text: $0, encodingName: "Windows-1254", repairNote: nil) }
        case .iso8859_9: return String(data: data, encoding: iso8859_9).map { Result(text: $0, encodingName: "ISO-8859-9", repairNote: nil) }
        case .auto: break
        }

        // 1. BOM
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return repairIfNeeded(text, name: "UTF-8")
        }
        if data.starts(with: [0xFF, 0xFE]), let text = String(data: data, encoding: .utf16LittleEndian) {
            return Result(text: text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")), encodingName: "UTF-16", repairNote: nil)
        }
        if data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16BigEndian) {
            return Result(text: text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")), encodingName: "UTF-16", repairNote: nil)
        }
        // 2. Geçerli UTF-8
        if let text = String(data: data, encoding: .utf8) {
            return repairIfNeeded(text, name: "UTF-8")
        }
        // 3. Windows-1254 (Türkçe Windows); 0x80–0x9F aralığında tanımsız bayt yoksa başarılı olur.
        if let text = String(data: data, encoding: windows1254) {
            return Result(text: text, encodingName: "Windows-1254", repairNote: turkishCharacters(in: text) ? "Windows-1254 → UTF-8" : nil)
        }
        // 4. ISO-8859-9
        if let text = String(data: data, encoding: iso8859_9) {
            return Result(text: text, encodingName: "ISO-8859-9", repairNote: turkishCharacters(in: text) ? "ISO-8859-9 → UTF-8" : nil)
        }
        return String(data: data, encoding: .isoLatin1).map { Result(text: $0, encodingName: "Latin-1", repairNote: nil) }
    }

    /// UTF-8 baytları Latin-1/1252/1254 sanılıp yeniden UTF-8'e çevrilmiş metin ("ÅŸ" → "ş").
    static let mojibakeMarkers = ["Ã¼", "Ã¶", "Ã§", "Ä±", "Ä°", "ÅŸ", "Åž", "ÄŸ", "Äž", "Ã‡", "Ã–", "Ãœ"]

    static func looksBroken(_ text: String) -> Bool {
        let sample = String(text.prefix(20_000))
        return mojibakeMarkers.contains { sample.contains($0) }
    }

    private static func repairIfNeeded(_ text: String, name: String) -> Result {
        guard looksBroken(text) else { return Result(text: text, encodingName: name, repairNote: nil) }
        for encoding in [String.Encoding.windowsCP1252, windows1254, .isoLatin1] {
            if let bytes = text.data(using: encoding), let repaired = String(data: bytes, encoding: .utf8), !looksBroken(repaired) {
                return Result(text: repaired, encodingName: "UTF-8", repairNote: "Bozuk UTF-8 → UTF-8")
            }
        }
        return Result(text: text, encodingName: name, repairNote: nil)
    }

    private static func turkishCharacters(in text: String) -> Bool {
        text.prefix(20_000).contains { "şŞğĞıİçÇöÖüÜ".contains($0) }
    }
}
