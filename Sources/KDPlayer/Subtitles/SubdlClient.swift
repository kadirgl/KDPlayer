import Foundation

/// Subdl resmi API'si (api.subdl.com/api/v1, belgeler: subdl.com/api-doc). OpenSubtitles bulamazsa ikinci kaynak.
/// Arama ücretsiz anahtarla günde 2.000 istek; indirme anahtarsız (IP başına günde 300), zip olarak gelir.
struct SubdlClient {
    struct Result: Sendable, Equatable {
        /// İndirme yolu: "/subtitle/3197651-3213944.zip" (dl.subdl.com'a eklenir).
        let path: String
        let releaseName: String
        let language: String
        let hearingImpaired: Bool
        let fps: Double?
        let season: Int?
        let episode: Int?
        let fullSeason: Bool
    }

    enum ClientError: LocalizedError {
        case api(String)
        case http(Int)
        case decoding

        var errorDescription: String? {
            switch self {
            case .api(let message): "Subdl: \(message)"
            case .http(let code): "Subdl hatası (\(code))"
            case .decoding: "Subdl yanıtı okunamadı"
            }
        }
    }

    static let base = URL(string: "https://api.subdl.com/api/v1/subtitles")!
    static let downloadBase = URL(string: "https://dl.subdl.com")!
    let apiKey: String
    var timeout: TimeInterval = 10

    /// Kullanıcı anahtarı (Ayarlar) → pakete gömülü (Config/subdl.key) → KD_SUBDL_KEY.
    static var configuredKey: String? {
        guard UserDefaults.standard.bool(forKey: SettingsKey.subdlEnabled) else { return nil }
        let stored = UserDefaults.standard.string(forKey: SettingsKey.subdlAPIKey)?.trimmingCharacters(in: .whitespaces)
        if let stored, !stored.isEmpty { return stored }
        if let bundled = Bundle.main.object(forInfoDictionaryKey: "SubdlAPIKey") as? String, !bundled.isEmpty { return bundled }
        return ProcessInfo.processInfo.environment["KD_SUBDL_KEY"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static var hasBundledKey: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "SubdlAPIKey") as? String).map { !$0.isEmpty } ?? false
    }

    /// Diller ISO 639-1 ("tr") verilir; Subdl büyük harf bekler ("TR").
    func search(title: String, year: Int?, season: Int?, episode: Int?, languages: [String]) async throws -> [Result] {
        var components = URLComponents(url: Self.base, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "film_name", value: title),
            URLQueryItem(name: "languages", value: languages.map { $0.uppercased() }.joined(separator: ",")),
            URLQueryItem(name: "subs_per_page", value: "30"),
            URLQueryItem(name: "client", value: "custom_integration"),
        ]
        if let season {
            items.append(URLQueryItem(name: "type", value: "tv"))
            items.append(URLQueryItem(name: "season_number", value: String(season)))
            if let episode { items.append(URLQueryItem(name: "episode_number", value: String(episode))) }
        } else {
            items.append(URLQueryItem(name: "type", value: "movie"))
            if let year { items.append(URLQueryItem(name: "year", value: String(year))) }
        }
        components.queryItems = items
        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("KDPlayer v\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Hata gövdesi de JSON olabilir ({"status":false,"error":"..."}).
            if let message = Self.errorMessage(data) { throw ClientError.api(message) }
            throw ClientError.http(http.statusCode)
        }
        return try Self.parse(data, season: season, episode: episode)
    }

    static func parse(_ data: Data, season: Int?, episode: Int?) throws -> [Result] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClientError.decoding }
        if (object["status"] as? Bool) == false {
            let message = (object["error"] as? String) ?? "bilinmeyen hata"
            // "Bulunamadı" bir hata değil, boş sonuçtur.
            if message.lowercased().contains("not found") || message.lowercased().contains("can't find") { return [] }
            throw ClientError.api(message)
        }
        let entries = (object["subtitles"] as? [[String: Any]]) ?? []
        return entries.compactMap { entry in
            guard let raw = entry["url"] as? String, !raw.isEmpty else { return nil }
            // Subdl indirme adresine anahtarı ekliyor; anahtarlı indirme günde 50 ile sınırlı ve tüm kullanıcılar
            // paylaşırdı. Anahtarsız (IP başına günde 300) indirilir; anahtar kayda ya da ekrana da düşmez.
            let path = Self.strippingKey(raw)
            // RAR açılamıyor (zip ve düz altyazı açılır).
            if (URL(string: path, relativeTo: downloadBase)?.pathExtension.lowercased() ?? "") == "rar" { return nil }
            let entrySeason = Self.int(entry["season"])
            let entryEpisode = Self.int(entry["episode"])
            let fullSeason = (entry["full_season"] as? Bool) ?? false
            // Dizide başka bölümün altyazısı (paket değilse) elenir.
            if let episode, let entryEpisode, entryEpisode != 0, !fullSeason, entryEpisode != episode { return nil }
            if let season, let entrySeason, entrySeason != 0, entrySeason != season { return nil }
            let language = ((entry["language"] as? String) ?? (entry["lang"] as? String) ?? "").lowercased()
            return Result(
                path: path,
                releaseName: (entry["release_name"] as? String) ?? (entry["name"] as? String) ?? "",
                language: Self.code(for: language),
                hearingImpaired: (entry["hi"] as? Bool) ?? false,
                fps: (entry["fps"] as? String).flatMap(Double.init) ?? (entry["fps"] as? Double),
                season: entrySeason,
                episode: entryEpisode,
                fullSeason: fullSeason
            )
        }
    }

    /// İndirilen zip'ten altyazı baytları (dizide bölüm koduna uyan dosya seçilir).
    func download(_ result: Result, episodeCode: String?) async throws -> (data: Data, name: String?) {
        guard let url = URL(string: result.path, relativeTo: Self.downloadBase) else { throw ClientError.decoding }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("KDPlayer v\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw ClientError.http(http.statusCode) }
        return try SubtitleArchive.subtitleData(from: data, episode: episodeCode)
    }

    static func strippingKey(_ path: String) -> String {
        guard var components = URLComponents(string: path) else { return path }
        components.queryItems = components.queryItems?.filter { $0.name.lowercased() != "api_key" }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.string ?? path
    }

    private static func errorMessage(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        return nil
    }

    /// "TR" / "turkish" → "tr".
    static func code(for value: String) -> String {
        let lower = value.lowercased()
        if lower.count == 2 { return lower }
        return Language.code(for: value.capitalized).lowercased()
    }
}
