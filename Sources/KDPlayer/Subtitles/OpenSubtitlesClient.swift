import Foundation

/// OpenSubtitles REST API (api.opensubtitles.com/api/v1). Anahtar: Ayarlar › Altyazı ya da
/// Info.plist'teki `OpenSubtitlesAPIKey`. Kota modeli açık konu (spesifikasyon › Açık konular).
struct OpenSubtitlesClient {
    struct Result: Sendable {
        let fileID: Int
        let fileName: String
        let language: String
        let release: String
        let downloads: Int
        let rating: Double
        let fps: Double?
        let hashMatch: Bool
        let fromTrusted: Bool
    }

    enum ClientError: LocalizedError {
        case missingKey
        case rateLimited
        case http(Int)
        case decoding

        var errorDescription: String? {
            switch self {
            case .missingKey: "OpenSubtitles API anahtarı ayarlanmadı"
            case .rateLimited: "OpenSubtitles günlük indirme sınırına ulaşıldı"
            case .http(let code): "OpenSubtitles hatası (\(code))"
            case .decoding: "OpenSubtitles yanıtı okunamadı"
            }
        }
    }

    static let base = URL(string: "https://api.opensubtitles.com/api/v1/")!
    let apiKey: String
    var timeout: TimeInterval = 3

    static var configuredKey: String? {
        let stored = UserDefaults.standard.string(forKey: SettingsKey.openSubtitlesAPIKey)?.trimmingCharacters(in: .whitespaces)
        if let stored, !stored.isEmpty { return stored }
        if let bundled = Bundle.main.object(forInfoDictionaryKey: "OpenSubtitlesAPIKey") as? String, !bundled.isEmpty { return bundled }
        return ProcessInfo.processInfo.environment["KD_OPENSUBTITLES_KEY"]
    }

    private func request(_ url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("KDPlayer v\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Hash ve/veya sorguyla arama. Diller: "tr,en".
    func search(hash: String?, query: String?, season: Int?, episode: Int?, languages: [String]) async throws -> [Result] {
        var components = URLComponents(url: Self.base.appendingPathComponent("subtitles"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "languages", value: languages.sorted().joined(separator: ","))]
        if let hash { items.append(URLQueryItem(name: "moviehash", value: hash)) }
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "query", value: query.lowercased())) }
        if let season { items.append(URLQueryItem(name: "season_number", value: String(season))) }
        if let episode { items.append(URLQueryItem(name: "episode_number", value: String(episode))) }
        // API, parametrelerin alfabetik sırada olmasını öneriyor (önbellek isabeti).
        components.queryItems = items.sorted { $0.name < $1.name }

        let (data, response) = try await URLSession.shared.data(for: request(components.url!))
        try check(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]] else { throw ClientError.decoding }

        return entries.compactMap { entry in
            guard let attributes = entry["attributes"] as? [String: Any],
                  let files = attributes["files"] as? [[String: Any]],
                  let file = files.first,
                  let fileID = file["file_id"] as? Int else { return nil }
            return Result(
                fileID: fileID,
                fileName: (file["file_name"] as? String) ?? (attributes["release"] as? String) ?? "",
                language: (attributes["language"] as? String) ?? "",
                release: (attributes["release"] as? String) ?? "",
                downloads: (attributes["download_count"] as? Int) ?? 0,
                rating: (attributes["ratings"] as? Double) ?? 0,
                fps: (attributes["fps"] as? Double).flatMap { $0 > 0 ? $0 : nil },
                hashMatch: (attributes["moviehash_match"] as? Bool) ?? false,
                fromTrusted: (attributes["from_trusted"] as? Bool) ?? false
            )
        }
    }

    /// İndirme bağlantısı alıp dosyayı getirir. `remaining`: günlük kalan indirme.
    func download(fileID: Int) async throws -> (data: Data, remaining: Int?) {
        let body = try JSONSerialization.data(withJSONObject: ["file_id": fileID])
        let (data, response) = try await URLSession.shared.data(for: request(Self.base.appendingPathComponent("download"), method: "POST", body: body))
        try check(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let link = (object["link"] as? String).flatMap(URL.init(string:)) else { throw ClientError.decoding }
        var fileRequest = URLRequest(url: link, timeoutInterval: 10)
        fileRequest.setValue("KDPlayer v\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (file, fileResponse) = try await URLSession.shared.data(for: fileRequest)
        try check(fileResponse)
        return (file, object["remaining"] as? Int)
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 429, 406: throw ClientError.rateLimited
        default: throw ClientError.http(http.statusCode)
        }
    }
}
