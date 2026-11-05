import Foundation

/// Türkçe biçimlendirme yardımcıları (süre, hız, gecikme).
enum Format {
    /// NumberFormatter oluşturmak pahalı; kontrol çubuğu saniyede birkaç kez çağırır.
    private static let decimal2: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()
    private static let decimal1: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    /// 1:04:12 ya da 4:12.
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Kalan süre: −57:21.
    static func remaining(_ seconds: Double) -> String { "−" + time(max(0, seconds)) }

    /// "48 dk kaldı" · "1 dk'dan az kaldı"
    static func remainingText(_ seconds: Double) -> String {
        seconds < 60 ? "1 dk'dan az kaldı" : "\(duration(seconds)) kaldı"
    }

    /// 2 sa 1 dk · 48 dk.
    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) dk" }
        return m == 0 ? "\(h) sa" : "\(h) sa \(m) dk"
    }

    /// 1× · 1,25× · 0,5×.
    static func rate(_ rate: Float) -> String {
        (decimal2.string(from: NSNumber(value: rate)) ?? "\(rate)") + "×"
    }

    /// +300 ms · −1,2 sn · 0 ms.
    static func milliseconds(_ ms: Int) -> String {
        if ms == 0 { return "0 ms" }
        let sign = ms > 0 ? "+" : "−"
        let value = abs(ms)
        if value >= 10_000 {
            return sign + (decimal1.string(from: NSNumber(value: Double(value) / 1000)) ?? "") + " sn"
        }
        return "\(sign)\(value) ms"
    }

    /// 12,4 B (bin) indirme.
    static func count(_ value: Int) -> String {
        if value < 1000 { return "\(value)" }
        let formatter = decimal1
        if value < 1_000_000 { return (formatter.string(from: NSNumber(value: Double(value) / 1000)) ?? "") + " B" }
        return (formatter.string(from: NSNumber(value: Double(value) / 1_000_000)) ?? "") + " Mn"
    }

    /// "dün akşam", "3 gün önce".
    static func relative(_ date: Date) -> String {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let part = switch hour {
        case 5..<12: "sabah"
        case 12..<17: "öğleden sonra"
        case 17..<22: "akşam"
        default: "gece"
        }
        if calendar.isDateInToday(date) { return "bugün \(part)" }
        if calendar.isDateInYesterday(date) { return "dün \(part)" }
        let days = calendar.dateComponents([.day], from: date, to: .now).day ?? 0
        if days < 7 { return "\(days) gün önce" }
        if days < 30 { return "\(days / 7) hafta önce" }
        return date.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "tr_TR")))
    }

    static let turkish = Locale(identifier: "tr_TR")
}

/// Dil kodlarını Türkçe adlara çevirir (ISO 639-1/2).
enum Language {
    /// "und" (belirsiz), "zxx", "mul" gibi gerçek dil olmayan kodlar.
    static let undefined: Set<String> = ["und", "zxx", "mul", "mis", "qaa"]

    static func name(for code: String?) -> String? {
        guard let code = code?.lowercased(), !code.isEmpty, !undefined.contains(code) else { return nil }
        let map: [String: String] = [
            "tr": "Türkçe", "tur": "Türkçe", "en": "English", "eng": "English",
            "de": "Deutsch", "ger": "Deutsch", "deu": "Deutsch", "fr": "Français", "fre": "Français", "fra": "Français",
            "es": "Español", "spa": "Español", "it": "Italiano", "ita": "Italiano", "ru": "Русский", "rus": "Русский",
            "ja": "日本語", "jpn": "日本語", "ko": "한국어", "kor": "한국어", "ar": "العربية", "ara": "العربية",
            "pt": "Português", "por": "Português", "nl": "Nederlands", "dut": "Nederlands", "nld": "Nederlands",
        ]
        return map[code] ?? Locale(identifier: "tr_TR").localizedString(forLanguageCode: code)?.capitalized(with: Format.turkish)
    }

    /// VLC bazen kodu değil adı verir ("English"): ISO koduna çevirir; kod zaten geçerliyse aynen döner.
    static func code(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 3 else { return trimmed }
        if let guessed = guess(from: trimmed) { return guessed }
        let english = Locale(identifier: "en")
        let lower = trimmed.lowercased()
        for code in Locale.LanguageCode.isoLanguageCodes.map(\.identifier) where code.count == 2 {
            if english.localizedString(forLanguageCode: code)?.lowercased() == lower { return code }
        }
        return trimmed
    }

    /// Kısa gösterim: "EN", "TR".
    static func short(for code: String?) -> String? {
        guard let code = code?.lowercased(), !code.isEmpty, !undefined.contains(code) else { return nil }
        let map = ["tur": "tr", "eng": "en", "ger": "de", "deu": "de", "fre": "fr", "fra": "fr", "spa": "es", "ita": "it", "rus": "ru", "jpn": "ja", "kor": "ko", "ara": "ar", "por": "pt", "dut": "nl", "nld": "nl"]
        return (map[code] ?? String(code.prefix(2))).uppercased()
    }

    /// Serbest metinden (parça adı) dil kodu yakalar: "Türkçe", "Turkish", "[tr]".
    static func guess(from text: String) -> String? {
        let lower = text.lowercased(with: Format.turkish)
        let pairs: [(String, [String])] = [
            ("tr", ["türkçe", "turkish", "turkce", "[tr]", "(tr)", " tr ", "tur"]),
            ("en", ["english", "ingilizce", "[en]", "(en)", " en ", "eng"]),
            ("de", ["deutsch", "german", "almanca"]), ("fr", ["français", "french", "fransızca"]),
            ("es", ["español", "spanish", "ispanyolca"]), ("it", ["italiano", "italian"]),
            ("ru", ["русский", "russian", "rusça"]), ("ja", ["japanese", "日本語", "japonca"]),
        ]
        let padded = " " + lower + " "
        for (code, keys) in pairs where keys.contains(where: { padded.contains($0) }) { return code }
        return nil
    }
}
