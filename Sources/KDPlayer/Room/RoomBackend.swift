import Foundation

/// Oda taşıma katmanı. MVP'de Firebase Realtime Database (REST + canlı akış); v2'de aynı olaylar WebRTC
/// data channel üzerinden gider ve bu protokolün başka bir uygulaması yazılır (spesifikasyon › Oda).
protocol RoomBackend: AnyObject, Sendable {
    var uid: String { get }
    var label: String { get }
    func signIn() async throws
    func get(_ path: String) async throws -> Any?
    /// PUT; sunucu değerleri (`ServerValue.timestamp`) çözülmüş haliyle döner.
    @discardableResult func set(_ path: String, _ value: Any) async throws -> Any?
    func update(_ path: String, _ values: [String: Any]) async throws
    @discardableResult func push(_ path: String, _ value: Any) async throws -> String
    func remove(_ path: String) async throws
    /// `path` altındaki değişiklikler: ilk olay tüm düğüm (`put` "/"), sonra farklar.
    func listen(_ path: String) -> AsyncThrowingStream<RoomStreamEvent, Error>
}

enum ServerValue {
    static let timestamp: [String: String] = [".sv": "timestamp"]
}

struct RoomStreamEvent: @unchecked Sendable {
    enum Kind { case put, patch }
    let kind: Kind
    /// Dinlenen düğüme göre yol ("/", "/members/abc").
    let path: String
    let data: Any?
}

enum RoomBackendError: LocalizedError {
    case notConfigured
    case auth(String)
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Birlikte izleme bu sürümde kullanılamıyor"
        case .auth(let message): "Oturum açılamadı: \(message)"
        case .http(let code, let message): "Oda sunucusu hatası (\(code)) \(message)"
        case .badResponse: "Oda sunucusunun yanıtı okunamadı"
        }
    }
}

/// Oda sunucusu uygulamanın içinde gelir: adres paketleme sırasında Info.plist'e yazılır
/// (`KDRoomDatabaseURL`, isteğe bağlı `KDRoomAPIKey`; kaynak: Config/room-server.json). Kullanıcı hiçbir şey
/// ayarlamaz. Geliştirme için `KD_ROOM_SERVER` ortam değişkeni yerel sunucuya yönlendirir.
struct RoomServerConfig: Equatable {
    var databaseURL: URL
    /// Varsa Firebase Anonymous Auth kullanılır; yoksa istemci kimliği cihazda üretilir.
    var apiKey: String?

    var usesAuth: Bool { apiKey != nil }
    var isLocal: Bool { ["127.0.0.1", "localhost"].contains(databaseURL.host ?? "") }

    static var current: RoomServerConfig? {
        let env = ProcessInfo.processInfo.environment
        if let server = env["KD_ROOM_SERVER"], let url = URL(string: server) {
            return RoomServerConfig(databaseURL: url, apiKey: nil)
        }
        guard let string = Bundle.main.object(forInfoDictionaryKey: "KDRoomDatabaseURL") as? String,
              !string.isEmpty, let url = URL(string: string) else { return nil }
        let key = (Bundle.main.object(forInfoDictionaryKey: "KDRoomAPIKey") as? String).flatMap { $0.isEmpty ? nil : $0 }
        return RoomServerConfig(databaseURL: url, apiKey: key)
    }
}

// MARK: - Firebase REST

/// Firebase Realtime Database REST API + Anonymous Auth (Identity Toolkit). Canlı akış için
/// `Accept: text/event-stream` ile Server-Sent Events kullanılır.
final class FirebaseRESTBackend: RoomBackend, @unchecked Sendable {
    let config: RoomServerConfig
    private(set) var uid: String = ""
    private var idToken: String?
    private var tokenExpiry = Date.distantPast
    private let lock = NSLock()
    private let session: URLSession

    var label: String { config.isLocal ? "Yerel sunucu" : "Bağlı" }

    /// Aynı Mac'te iki kopya denerken kimlikler karışmasın diye (yalnızca geliştirme).
    private static var profileSuffix: String {
        ProcessInfo.processInfo.environment["KD_PROFILE"].map { ".\($0)" } ?? ""
    }

    init(config: RoomServerConfig) {
        self.config = config
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = .infinity
        session = URLSession(configuration: configuration)
    }

    // MARK: Kimlik

    func signIn() async throws {
        if !config.usesAuth {
            // Kimlik doğrulamasız sunucu: cihaza özgü, kalıcı rastgele kimlik.
            let key = "roomClientID" + Self.profileSuffix
            let stored = UserDefaults.standard.string(forKey: key) ?? "c" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(15).lowercased()
            UserDefaults.standard.set(stored, forKey: key)
            uid = stored
            return
        }
        _ = try await token()
    }

    private func token() async throws -> String? {
        guard let apiKey = config.apiKey else { return nil }
        let cached: String? = lock.withLock {
            guard let idToken, tokenExpiry > Date.now.addingTimeInterval(60) else { return nil }
            return idToken
        }
        if let cached { return cached }

        let refreshKey = "roomRefreshToken" + Self.profileSuffix
        var json: [String: Any]
        if let refresh = UserDefaults.standard.string(forKey: refreshKey) {
            var request = URLRequest(url: URL(string: "https://securetoken.googleapis.com/v1/token?key=\(apiKey)")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = "grant_type=refresh_token&refresh_token=\(refresh)".data(using: .utf8)
            json = try await authCall(request)
            json["idToken"] = json["id_token"]
            json["localId"] = json["user_id"]
            json["expiresIn"] = json["expires_in"]
            json["refreshToken"] = json["refresh_token"]
        } else {
            var request = URLRequest(url: URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=\(apiKey)")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["returnSecureToken": true])
            json = try await authCall(request)
        }
        guard let token = json["idToken"] as? String, let localID = json["localId"] as? String else {
            UserDefaults.standard.removeObject(forKey: refreshKey)
            throw RoomBackendError.auth("yanıt eksik")
        }
        if let refresh = json["refreshToken"] as? String { UserDefaults.standard.set(refresh, forKey: refreshKey) }
        let expiresIn = Double(json["expiresIn"] as? String ?? "") ?? 3600
        lock.withLock {
            idToken = token
            uid = localID
            tokenExpiry = Date.now.addingTimeInterval(expiresIn)
        }
        return token
    }

    private func authCall(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(http.statusCode)"
            if message.contains("TOKEN") { UserDefaults.standard.removeObject(forKey: "roomRefreshToken" + Self.profileSuffix) }
            throw RoomBackendError.auth(message)
        }
        return json
    }

    // MARK: İstekler

    private func url(_ path: String) async throws -> URL {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents(url: config.databaseURL.appendingPathComponent(trimmed + ".json"), resolvingAgainstBaseURL: false)!
        if let token = try await token() {
            components.queryItems = [URLQueryItem(name: "auth", value: token)]
        }
        return components.url!
    }

    private func call(_ method: String, _ path: String, body: Any? = nil) async throws -> Any? {
        var request = URLRequest(url: try await url(path))
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String ?? ""
            throw RoomBackendError.http(http.statusCode, message)
        }
        guard !data.isEmpty else { return nil }
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return value is NSNull ? nil : value
    }

    func get(_ path: String) async throws -> Any? { try await call("GET", path) }
    func set(_ path: String, _ value: Any) async throws -> Any? { try await call("PUT", path, body: value) }
    func update(_ path: String, _ values: [String: Any]) async throws { _ = try await call("PATCH", path, body: values) }
    func remove(_ path: String) async throws { _ = try await call("DELETE", path) }

    func push(_ path: String, _ value: Any) async throws -> String {
        guard let response = try await call("POST", path, body: value) as? [String: Any], let name = response["name"] as? String else {
            throw RoomBackendError.badResponse
        }
        return name
    }

    // MARK: Canlı akış (SSE)

    func listen(_ path: String) -> AsyncThrowingStream<RoomStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var attempt = 0
                while !Task.isCancelled {
                    do {
                        var request = URLRequest(url: try await self.url(path))
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        request.timeoutInterval = .infinity
                        let (bytes, response) = try await self.session.bytes(for: request)
                        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                            throw RoomBackendError.http(http.statusCode, "akış")
                        }
                        attempt = 0
                        var event = ""
                        for try await line in bytes.lines {
                            if line.hasPrefix("event:") {
                                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                            } else if line.hasPrefix("data:") {
                                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                                switch event {
                                case "put", "patch":
                                    guard let data = payload.data(using: .utf8),
                                          let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
                                          let eventPath = object["path"] as? String else { continue }
                                    let value = object["data"].flatMap { $0 is NSNull ? nil : $0 }
                                    continuation.yield(RoomStreamEvent(kind: event == "put" ? .put : .patch, path: eventPath, data: value))
                                case "auth_revoked":
                                    self.lock.withLock { self.tokenExpiry = .distantPast }
                                    throw RoomBackendError.auth("oturum yenileniyor")
                                case "cancel":
                                    throw RoomBackendError.http(403, "erişim reddedildi")
                                default:
                                    break // keep-alive
                                }
                            }
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        if case RoomBackendError.http(403, _) = error {
                            continuation.finish(throwing: error)
                            return
                        }
                        // Bağlantı koptu: artan bekleme ile yeniden bağlan.
                        attempt += 1
                        try? await Task.sleep(for: .seconds(min(8, Double(attempt))))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - JSON ağacı

/// Akış olaylarını yerel kopyaya uygular (put: yolu değiştir, patch: çocukları birleştir).
struct JSONTree {
    private(set) var root: [String: Any] = [:]

    mutating func apply(_ event: RoomStreamEvent) {
        let keys = event.path.split(separator: "/").map(String.init)
        switch event.kind {
        case .put:
            if keys.isEmpty {
                root = event.data as? [String: Any] ?? [:]
            } else {
                root = Self.setting(root, keys: keys[...], value: event.data)
            }
        case .patch:
            guard let values = event.data as? [String: Any] else { return }
            for (key, value) in values {
                let childKeys = keys + key.split(separator: "/").map(String.init)
                root = Self.setting(root, keys: childKeys[...], value: value is NSNull ? nil : value)
            }
        }
    }

    private static func setting(_ node: [String: Any], keys: ArraySlice<String>, value: Any?) -> [String: Any] {
        var node = node
        guard let first = keys.first else { return node }
        if keys.count == 1 {
            node[first] = value
        } else {
            let child = node[first] as? [String: Any] ?? [:]
            let updated = setting(child, keys: keys.dropFirst(), value: value)
            node[first] = updated.isEmpty ? nil : updated
        }
        return node
    }
}
