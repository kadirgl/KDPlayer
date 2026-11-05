import SwiftUI

// rooms/{code} veri modeli (spesifikasyon › Oda ve senkron protokolü › Veri modeli).

enum ControlMode: String, CaseIterable, Identifiable {
    case everyone, host
    var id: Self { self }
    var title: String { self == .everyone ? "Herkes" : "Sadece ben" }
    var caption: String { self == .everyone ? "Herkes durdurur, sarar" : "Diğerleri sadece izler" }
    var badge: String { self == .everyone ? "Herkes kontrol edebilir" : "Sadece oda sahibi kontrol eder" }
}

struct RoomMeta: Equatable {
    var name: String
    var createdBy: String
    var createdAt: Double
    var controlMode: ControlMode
    var locked: Bool
    var readyCheck: Bool
    /// Hazır kontrolü sonrası geri sayımın bittiği sunucu zamanı (ms).
    var startAt: Double?

    init(name: String, createdBy: String, createdAt: Double = 0, controlMode: ControlMode, locked: Bool, readyCheck: Bool, startAt: Double? = nil) {
        self.name = name
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.controlMode = controlMode
        self.locked = locked
        self.readyCheck = readyCheck
        self.startAt = startAt
    }

    init?(_ json: Any?) {
        guard let json = json as? [String: Any], let name = json["name"] as? String, let createdBy = json["createdBy"] as? String else { return nil }
        self.name = name
        self.createdBy = createdBy
        createdAt = json.double("createdAt") ?? 0
        controlMode = ControlMode(rawValue: json["controlMode"] as? String ?? "") ?? .everyone
        locked = json["locked"] as? Bool ?? false
        readyCheck = json["readyCheck"] as? Bool ?? false
        startAt = json.double("startAt")
    }

    var json: [String: Any] {
        var value: [String: Any] = ["name": name, "createdBy": createdBy, "createdAt": ServerValue.timestamp,
                                    "controlMode": controlMode.rawValue, "locked": locked, "readyCheck": readyCheck]
        if let startAt { value["startAt"] = startAt }
        return value
    }
}

struct RoomMedia: Equatable {
    var title: String
    var durationMs: Double
    var fileHash: String?
    var release: String?
    var fps: Double?
    var detail: String

    init(title: String, durationMs: Double, fileHash: String?, release: String?, fps: Double?, detail: String) {
        self.title = title
        self.durationMs = durationMs
        self.fileHash = fileHash
        self.release = release
        self.fps = fps
        self.detail = detail
    }

    init?(_ json: Any?) {
        guard let json = json as? [String: Any], let title = json["title"] as? String else { return nil }
        self.title = title
        durationMs = json.double("durationMs") ?? 0
        fileHash = json["fileHash"] as? String
        release = json["release"] as? String
        fps = json.double("fps")
        detail = json["detail"] as? String ?? ""
    }

    var json: [String: Any] {
        var value: [String: Any] = ["title": title, "durationMs": durationMs, "detail": detail]
        if let fileHash { value["fileHash"] = fileHash }
        if let release { value["release"] = release }
        if let fps { value["fps"] = fps }
        return value
    }
}

struct RoomPlayback: Equatable {
    var playing: Bool
    var positionMs: Double
    var rate: Double
    /// Sunucu zamanı (ms).
    var updatedAt: Double
    var by: String
    var seq: Int
    /// Son eylem: "play" | "pause" | "seek" | "rate".
    var action: String

    init(playing: Bool, positionMs: Double, rate: Double, updatedAt: Double, by: String, seq: Int, action: String) {
        self.playing = playing
        self.positionMs = positionMs
        self.rate = rate
        self.updatedAt = updatedAt
        self.by = by
        self.seq = seq
        self.action = action
    }

    init?(_ json: Any?) {
        guard let json = json as? [String: Any], let state = json["state"] as? String else { return nil }
        playing = state == "playing"
        positionMs = json.double("positionMs") ?? 0
        rate = json.double("rate") ?? 1
        updatedAt = json.double("updatedAt") ?? 0
        by = json["by"] as? String ?? ""
        seq = Int(json.double("seq") ?? 0)
        action = json["action"] as? String ?? ""
    }

    func json(serverTimestamp: Bool = true) -> [String: Any] {
        ["state": playing ? "playing" : "paused", "positionMs": positionMs.rounded(), "rate": rate,
         "updatedAt": serverTimestamp ? ServerValue.timestamp as Any : updatedAt, "by": by, "seq": seq, "action": action]
    }

    /// Sunucu zamanı `serverNow` anında beklenen konum (sn).
    func expectedPosition(serverNow: Double) -> Double {
        let elapsed = playing ? max(0, serverNow - updatedAt) * rate : 0
        return (positionMs + elapsed) / 1000
    }
}

struct RoomSubtitle: Equatable {
    var lang: String?
    var source: String
    var name: String
    /// DEFLATE ile sıkıştırılmış UTF-8 altyazı metni, base64 (≤ 200 KB).
    var contentGz: String
    var offsetMs: Int
    var scale: Double
    var by: String
    var version: Int

    init(lang: String?, source: String, name: String, contentGz: String, offsetMs: Int, scale: Double, by: String, version: Int) {
        self.lang = lang
        self.source = source
        self.name = name
        self.contentGz = contentGz
        self.offsetMs = offsetMs
        self.scale = scale
        self.by = by
        self.version = version
    }

    init?(_ json: Any?) {
        guard let json = json as? [String: Any], let content = json["contentGz"] as? String, let by = json["by"] as? String else { return nil }
        lang = json["lang"] as? String
        source = json["source"] as? String ?? ""
        name = json["name"] as? String ?? "Altyazı"
        contentGz = content
        offsetMs = Int(json.double("offsetMs") ?? 0)
        scale = json.double("scale") ?? 1
        self.by = by
        version = Int(json.double("version") ?? 0)
    }

    var json: [String: Any] {
        var value: [String: Any] = ["source": source, "name": name, "contentGz": contentGz, "offsetMs": offsetMs,
                                    "scale": scale, "by": by, "version": version]
        if let lang { value["lang"] = lang }
        return value
    }

    var timing: SubtitleTiming { SubtitleTiming(scale: scale, offset: Double(offsetMs) / 1000) }

    static func pack(_ text: String) -> String? {
        guard let compressed = try? (Data(text.utf8) as NSData).compressed(using: .zlib) as Data else { return nil }
        return compressed.base64EncodedString()
    }

    func unpackedText() -> String? {
        guard let data = Data(base64Encoded: contentGz),
              let raw = try? (data as NSData).decompressed(using: .zlib) as Data else { return nil }
        return String(data: raw, encoding: .utf8)
    }
}

struct RoomMember: Identifiable, Equatable {
    enum Status: String { case ready, loading, buffering, mismatch, waiting }

    let id: String
    var name: String
    var color: Int
    var status: Status
    var durationMs: Double
    var fileHash: String?
    var lastSeen: Double
    var joinedAt: Double
    var rttMs: Double
    var driftMs: Double
    var acceptedMismatch: Bool
    var usingRoomSubtitle: Bool

    init?(id: String, _ json: Any?) {
        guard let json = json as? [String: Any] else { return nil }
        self.id = id
        name = json["name"] as? String ?? "Misafir"
        color = Int(json.double("color") ?? 0)
        status = Status(rawValue: json["status"] as? String ?? "") ?? .loading
        durationMs = json.double("durationMs") ?? 0
        fileHash = json["fileHash"] as? String
        lastSeen = json.double("lastSeen") ?? 0
        joinedAt = json.double("joinedAt") ?? 0
        rttMs = json.double("rttMs") ?? 0
        driftMs = json.double("driftMs") ?? 0
        acceptedMismatch = json["acceptedMismatch"] as? Bool ?? false
        usingRoomSubtitle = json["usingRoomSubtitle"] as? Bool ?? false
    }

    var initial: String { String(name.prefix(1)).uppercased(with: Format.turkish) }
}

struct RoomMessage: Identifiable, Equatable {
    enum Kind: String { case text, system, reaction }

    let id: String
    var uid: String
    var name: String
    var text: String
    var kind: Kind
    /// Mesajdaki zaman damgası (ms): "12:34 yazınca zaman damgası olur".
    var atMs: Double?
    var ts: Double

    init?(id: String, _ json: Any?) {
        guard let json = json as? [String: Any], let text = json["text"] as? String else { return nil }
        self.id = id
        uid = json["uid"] as? String ?? ""
        name = json["name"] as? String ?? ""
        self.text = text
        kind = Kind(rawValue: json["type"] as? String ?? "") ?? .text
        atMs = json.double("atMs")
        ts = json.double("ts") ?? 0
    }

    /// Metindeki ilk "12:34" ya da "1:02:03" zaman damgası.
    static func timestamp(in text: String) -> Double? {
        guard let match = text.firstMatch(of: #/\b(\d{1,2}):(\d{2})(?::(\d{2}))?\b/#) else { return nil }
        let a = Double(match.1) ?? 0, b = Double(match.2) ?? 0
        if let c = match.3.flatMap({ Double($0) }) { return (a * 3600 + b * 60 + c) * 1000 }
        return (a * 60 + b) * 1000
    }
}

/// Odada kişiye sabit avatar gradyanları.
enum RoomPalette {
    static let colors: [(UInt32, UInt32)] = [
        (0xFFB067, 0xF08A2E), (0xB48CF0, 0x8150D6), (0x5AA2F8, 0x2C6FE0),
        (0x5FD4C4, 0x1C9A8E), (0xFF8FB5, 0xE0306A), (0xFFD27A, 0xD9952A),
    ]

    static func gradient(_ index: Int) -> LinearGradient {
        let pair = colors[((index % colors.count) + colors.count) % colors.count]
        return LinearGradient(colors: [Color(hex: pair.0), Color(hex: pair.1)], startPoint: .top, endPoint: .bottom)
    }

    /// Açık gradyanlarda (turuncu, sarı) koyu yazı.
    static func text(_ index: Int) -> Color {
        let i = ((index % colors.count) + colors.count) % colors.count
        return i == 0 || i == 5 ? Color(hex: 0x1D1D1F) : .white
    }
}

/// `KDAvatar`: baş harf + kişiye sabit gradyan; isteğe bağlı durum noktası.
struct KDAvatar: View {
    let initial: String
    let color: Int
    var size: CGFloat = 32
    var status: Color?

    var body: some View {
        Text(initial)
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(RoomPalette.text(color))
            .frame(width: size, height: size)
            .background(Circle().fill(RoomPalette.gradient(color)))
            .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
            .overlay(alignment: .bottomTrailing) {
                if let status {
                    Circle().fill(status)
                        .frame(width: size * 0.32, height: size * 0.32)
                        .overlay(Circle().strokeBorder(Color(hex: 0x2A2730), lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            }
            .accessibilityHidden(true)
    }
}

extension Dictionary where Key == String, Value == Any {
    func double(_ key: String) -> Double? {
        if let number = self[key] as? NSNumber { return number.doubleValue }
        return self[key] as? Double
    }
}
