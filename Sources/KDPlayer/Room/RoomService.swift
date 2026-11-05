import Foundation
import Observation

/// Birlikte izleme odası: video paylaşılmaz, herkes kendi dosyasını oynatır; odada yalnızca oynatma
/// durumu, altyazı ve sohbet dolaşır. Çakışmada son yazan kazanır (`seq` + sunucu zamanı).
@Observable
final class RoomService {
    enum Phase: Equatable {
        case idle, connecting, active
        case failed(String)
    }

    struct Preview {
        let code: String
        let meta: RoomMeta
        let media: RoomMedia?
        let members: [RoomMember]
        let playback: RoomPlayback?
        let hasSubtitle: Bool
        let serverNow: Double
    }

    enum JoinError: LocalizedError {
        case notFound, full, invalidCode
        var errorDescription: String? {
            switch self {
            case .notFound: "Bu kodla açık bir oda yok"
            case .full: "Oda dolu (en fazla 8 kişi)"
            case .invalidCode: "Oda kodu 6 karakter olmalı"
            }
        }
    }

    static let maxMembers = 8
    static let staleAfter: Double = 10_000
    static let codeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    // MARK: Durum

    private(set) var phase: Phase = .idle
    private(set) var code: String?
    private(set) var meta: RoomMeta?
    private(set) var media: RoomMedia?
    private(set) var playback: RoomPlayback?
    private(set) var subtitle: RoomSubtitle?
    private(set) var members: [RoomMember] = []
    private(set) var messages: [RoomMessage] = []
    /// serverNow = localNow + serverOffset (ms)
    private(set) var serverOffset: Double = 0
    private(set) var rttMs: Double = 0
    private(set) var connectionLabel = ""
    /// Bu istemcinin raporladığı durum ve sapma.
    var localStatus: RoomMember.Status = .loading
    /// Odada görünen adımız (ilk anlık görüntü gelmeden yazılan mesajlar için).
    private(set) var displayName = ""
    var localDriftMs: Double = 0
    var usingRoomSubtitle = false

    @ObservationIgnored private var backend: RoomBackend?
    @ObservationIgnored private var tree = JSONTree()
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var subtitleTimingTask: Task<Void, Never>?
    @ObservationIgnored private var lastSeq = 0
    @ObservationIgnored private var seenMessageIDs: Set<String> = []
    @ObservationIgnored private var knownMemberIDs: Set<String> = []
    @ObservationIgnored private var initialSnapshot = true
    @ObservationIgnored private var bestRTT = Double.infinity

    // Oturuma giden olaylar
    @ObservationIgnored var onRemotePlayback: ((RoomPlayback, RoomMember?, _ initial: Bool) -> Void)?
    @ObservationIgnored var onSubtitleShared: ((RoomSubtitle, RoomMember?) -> Void)?
    @ObservationIgnored var onSubtitleTiming: ((SubtitleTiming) -> Void)?
    @ObservationIgnored var onReaction: ((String, RoomMember?) -> Void)?
    @ObservationIgnored var onMessage: ((RoomMessage) -> Void)?
    @ObservationIgnored var onMemberJoined: ((RoomMember) -> Void)?
    @ObservationIgnored var onMemberLeft: ((String) -> Void)?
    @ObservationIgnored var onStartAt: ((Double) -> Void)?
    @ObservationIgnored var onClosed: ((String) -> Void)?

    var isActive: Bool { phase == .active }
    var uid: String { backend?.uid ?? "" }
    var serverNow: Double { Date.now.timeIntervalSince1970 * 1000 + serverOffset }
    var me: RoomMember? { members.first { $0.id == uid } }
    var isHost: Bool { meta?.createdBy == uid }
    var inviteLink: String { "kdplayer://join/\(code ?? "")" }
    var webLink: String { "https://kdplayer.app/j/\(code ?? "")" }

    static var isConfigured: Bool { RoomServerConfig.current != nil }

    /// Bağlantısı canlı üyeler (son 10 sn içinde ses vermiş).
    var activeMembers: [RoomMember] { members.filter { !isStale($0) } }

    func isStale(_ member: RoomMember) -> Bool {
        member.id != uid && serverNow - member.lastSeen > Self.staleAfter
    }

    /// Kontrol kimde: herkes modunda herkes; "host" modunda kurucu, kurucu yoksa en eski üye.
    var controllerID: String? {
        guard let meta else { return nil }
        if let host = members.first(where: { $0.id == meta.createdBy }), !isStale(host) { return host.id }
        return activeMembers.min { $0.joinedAt < $1.joinedAt }?.id
    }

    var canControl: Bool {
        guard let meta else { return true }
        return meta.controlMode == .everyone || controllerID == uid
    }

    /// Dosya süresi odadakinden 1 sn'den fazla farklı mı.
    func isMismatch(_ member: RoomMember) -> Bool {
        guard let media, media.durationMs > 0, member.durationMs > 0 else { return false }
        return abs(member.durationMs - media.durationMs) > 1000 && !member.acceptedMismatch
    }

    /// Bağlantısı ya da dosyası takılan üyeler: biri buffering ise herkes bekler.
    var bufferingMembers: [RoomMember] {
        activeMembers.filter { $0.id != uid && $0.status == .buffering }
    }

    var reconnectingMembers: [RoomMember] { members.filter { isStale($0) } }

    var waitingForApproval: [RoomMember] { members.filter { $0.status == .waiting && $0.id != uid } }

    /// "Herkes senkron · 38 ms": en kötü üyenin sapması.
    var worstDriftMs: Double {
        activeMembers.map { abs($0.id == uid ? localDriftMs : $0.driftMs) }.max() ?? 0
    }

    var readyCount: Int { activeMembers.filter { $0.status == .ready }.count }

    func member(_ id: String) -> RoomMember? { members.first { $0.id == id } }

    // MARK: Kur / katıl / ayrıl

    private func makeBackend() throws -> RoomBackend {
        guard let config = RoomServerConfig.current else { throw RoomBackendError.notConfigured }
        return FirebaseRESTBackend(config: config)
    }

    @MainActor
    func create(name: String, controlMode: ControlMode, readyCheck: Bool, locked: Bool, media: RoomMedia,
                position: Double, displayName: String, sharedSubtitle: RoomSubtitle?, preferredCode: String? = nil) async throws -> String {
        phase = .connecting
        self.displayName = displayName
        do {
            let backend = try makeBackend()
            try await backend.signIn()
            self.backend = backend
            connectionLabel = backend.label

            var code = preferredCode ?? Self.generateCode()
            for _ in 0..<5 {
                guard let existing = try await backend.get("rooms/\(code)/meta"), RoomMeta(existing) != nil else { break }
                code = Self.generateCode()
            }
            let meta = RoomMeta(name: name, createdBy: backend.uid, controlMode: controlMode, locked: locked, readyCheck: readyCheck)
            var room: [String: Any] = [
                "meta": meta.json,
                "media": media.json,
                "playback": RoomPlayback(playing: !readyCheck, positionMs: position * 1000, rate: 1, updatedAt: 0, by: backend.uid, seq: 1, action: "open").json(),
                "members": [backend.uid: memberJSON(name: displayName, color: 0, durationMs: media.durationMs, fileHash: media.fileHash, status: readyCheck ? .loading : .ready)],
            ]
            if var subtitle = sharedSubtitle {
                subtitle.by = backend.uid
                subtitle.version = 1
                room["subtitle"] = subtitle.json
                usingRoomSubtitle = true
            }
            try await backend.set("rooms/\(code)", room)
            lastSeq = 1
            self.code = code
            localStatus = readyCheck ? .loading : .ready
            startSession(code: code)
            if let subtitle = sharedSubtitle {
                try? await postSystem("\(displayName) altyazıyı paylaştı · \(Language.name(for: subtitle.lang) ?? "Altyazı") · \(Format.milliseconds(subtitle.offsetMs))")
            }
            return code
        } catch {
            phase = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Katılmadan önce oda bilgisi (ekran 12).
    @MainActor
    func preview(code rawCode: String) async throws -> Preview {
        let code = Self.normalize(rawCode)
        guard code.count == 6 else { throw JoinError.invalidCode }
        let backend = try self.backend ?? makeBackend()
        try await backend.signIn()
        self.backend = backend
        connectionLabel = backend.label
        await measureClock(backend: backend, code: nil)
        guard let json = try await backend.get("rooms/\(code)") as? [String: Any], let meta = RoomMeta(json["meta"]) else {
            throw JoinError.notFound
        }
        let members = ((json["members"] as? [String: Any]) ?? [:]).compactMap { RoomMember(id: $0.key, $0.value) }
        let now = serverNow
        let fresh = members.filter { now - $0.lastSeen < 30 * 60_000 }
        guard !fresh.isEmpty else {
            // Herkes 30 dk'dan uzun süredir yok: terk edilmiş odayı temizle.
            try? await backend.remove("rooms/\(code)")
            throw JoinError.notFound
        }
        if fresh.filter({ now - $0.lastSeen < Self.staleAfter }).count >= Self.maxMembers { throw JoinError.full }
        return Preview(code: code, meta: meta, media: RoomMedia(json["media"]), members: fresh.sorted { $0.joinedAt < $1.joinedAt },
                       playback: RoomPlayback(json["playback"]), hasSubtitle: json["subtitle"] != nil, serverNow: now)
    }

    @MainActor
    func join(code rawCode: String, displayName: String, durationMs: Double, fileHash: String?) async throws {
        let code = Self.normalize(rawCode)
        phase = .connecting
        self.displayName = displayName
        do {
            let preview = try await preview(code: code)
            guard let backend else { throw RoomBackendError.notConfigured }
            let usedColors = Set(preview.members.map(\.color))
            let color = (0..<RoomPalette.colors.count).first { !usedColors.contains($0) } ?? preview.members.count
            let status: RoomMember.Status = preview.meta.locked && preview.meta.createdBy != backend.uid ? .waiting : (preview.meta.readyCheck ? .loading : .ready)
            try await backend.set("rooms/\(code)/members/\(backend.uid)",
                                  memberJSON(name: displayName, color: color, durationMs: durationMs, fileHash: fileHash, status: status))
            localStatus = status
            self.code = code
            startSession(code: code)
            var text = "\(displayName) katıldı"
            if let media = preview.media, media.durationMs > 0, durationMs > 0, abs(media.durationMs - durationMs) > 1000 {
                let diff = Int((abs(media.durationMs - durationMs) / 60_000).rounded())
                text += " · dosyası \(max(diff, 1)) dk \(durationMs < media.durationMs ? "kısa" : "uzun"), farklı sürüm olabilir"
            }
            try? await postSystem(text)
        } catch {
            phase = .failed(error.localizedDescription)
            throw error
        }
    }

    @MainActor
    func leave() async {
        guard let backend, let code else { reset(); return }
        let name = me?.name ?? displayName
        let others = activeMembers.filter { $0.id != uid }
        listenTask?.cancel()
        heartbeatTask?.cancel()
        if others.isEmpty {
            // Son üye: oda silinir.
            try? await backend.remove("rooms/\(code)")
        } else {
            try? await postSystem("\(name) odadan ayrıldı")
            try? await backend.remove("rooms/\(code)/members/\(backend.uid)")
        }
        reset()
    }

    private func reset() {
        listenTask?.cancel()
        heartbeatTask?.cancel()
        seekTask?.cancel()
        phase = .idle
        code = nil
        meta = nil
        media = nil
        playback = nil
        subtitle = nil
        members = []
        messages = []
        tree = JSONTree()
        seenMessageIDs = []
        knownMemberIDs = []
        initialSnapshot = true
        usingRoomSubtitle = false
        localDriftMs = 0
    }

    private func memberJSON(name: String, color: Int, durationMs: Double, fileHash: String?, status: RoomMember.Status) -> [String: Any] {
        var value: [String: Any] = ["name": name, "color": color, "status": status.rawValue, "durationMs": durationMs.rounded(),
                                    "lastSeen": ServerValue.timestamp, "joinedAt": ServerValue.timestamp, "rttMs": 0, "driftMs": 0]
        if let fileHash { value["fileHash"] = fileHash }
        return value
    }

    // MARK: Akış

    private func startSession(code: String) {
        guard let backend else { return }
        initialSnapshot = true
        listenTask?.cancel()
        listenTask = Task { @MainActor [weak self] in
            do {
                for try await event in backend.listen("rooms/\(code)") {
                    guard let self else { return }
                    self.tree.apply(event)
                    self.rebuild()
                }
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.measureClock(backend: backend, code: code)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Sunucu saati farkı ve gecikme: sunucu zaman damgası yazılıp dönen değerle karşılaştırılır.
    @MainActor
    private func measureClock(backend: RoomBackend, code: String?) async {
        let path = code.map { "rooms/\($0)/members/\(backend.uid)/lastSeen" } ?? "clock/\(backend.uid)"
        let start = Date.now.timeIntervalSince1970 * 1000
        guard let written = try? await backend.set(path, ServerValue.timestamp) else { return }
        var end = Date.now.timeIntervalSince1970 * 1000
        // Yanıt çözülmüş zamanı içermiyorsa değeri ayrıca oku.
        var resolved = written as? NSNumber
        if resolved == nil {
            resolved = try? await backend.get(path) as? NSNumber
            end = Date.now.timeIntervalSince1970 * 1000
        }
        guard let value = resolved else { return }
        let rtt = end - start
        rttMs = rtt
        // En düşük gecikmeli ölçüm en güvenilir saat farkını verir.
        if rtt <= bestRTT * 1.5 || bestRTT == .infinity {
            bestRTT = min(bestRTT, rtt)
            serverOffset = value.doubleValue - (start + end) / 2
        }
        if code == nil { try? await backend.remove(path); return }
        guard let code, phase == .active || phase == .connecting else { return }
        try? await backend.update("rooms/\(code)/members/\(backend.uid)", [
            "rttMs": rtt.rounded(), "driftMs": localDriftMs.rounded(), "status": localStatus.rawValue,
            "usingRoomSubtitle": usingRoomSubtitle,
        ])
    }

    @MainActor
    private func rebuild() {
        let root = tree.root
        guard let newMeta = RoomMeta(root["meta"]) else {
            if !initialSnapshot || phase == .active {
                let wasActive = phase == .active
                reset()
                if wasActive { onClosed?("Oda kapandı") }
            }
            return
        }
        let firstSnapshot = initialSnapshot
        initialSnapshot = false
        if phase != .active { phase = .active }

        let previousStartAt = meta?.startAt
        meta = newMeta
        media = RoomMedia(root["media"])

        let newMembers = ((root["members"] as? [String: Any]) ?? [:]).compactMap { RoomMember(id: $0.key, $0.value) }
            .sorted { $0.joinedAt < $1.joinedAt }
        let newIDs = Set(newMembers.map(\.id))
        if !firstSnapshot {
            for member in newMembers where !knownMemberIDs.contains(member.id) && member.id != uid { onMemberJoined?(member) }
            for id in knownMemberIDs.subtracting(newIDs) where id != uid { onMemberLeft?(id) }
        }
        knownMemberIDs = newIDs
        members = newMembers
        if let mine = members.first(where: { $0.id == uid }), localStatus == .waiting, mine.status != .waiting {
            // Kilitli odada kurucu onayladı.
            localStatus = mine.status
        }

        if let newPlayback = RoomPlayback(root["playback"]) {
            let changed = newPlayback != playback
            playback = newPlayback
            lastSeq = max(lastSeq, newPlayback.seq)
            if changed && (newPlayback.by != uid || firstSnapshot) {
                onRemotePlayback?(newPlayback, member(newPlayback.by), firstSnapshot)
            }
        }

        let newSubtitle = RoomSubtitle(root["subtitle"])
        if let newSubtitle, newSubtitle.by != uid {
            if newSubtitle.version != subtitle?.version || newSubtitle.contentGz != subtitle?.contentGz {
                subtitle = newSubtitle
                onSubtitleShared?(newSubtitle, member(newSubtitle.by))
            } else if newSubtitle.offsetMs != subtitle?.offsetMs || newSubtitle.scale != subtitle?.scale {
                subtitle = newSubtitle
                if usingRoomSubtitle { onSubtitleTiming?(newSubtitle.timing) }
            }
        } else {
            subtitle = newSubtitle
        }

        if let startAt = newMeta.startAt, startAt != previousStartAt, startAt > serverNow - 2000 {
            onStartAt?(startAt)
        }

        let entries = ((root["messages"] as? [String: Any]) ?? [:]).compactMap { RoomMessage(id: $0.key, $0.value) }
            .sorted { $0.ts == $1.ts ? $0.id < $1.id : $0.ts < $1.ts }
        for message in entries where !seenMessageIDs.contains(message.id) {
            seenMessageIDs.insert(message.id)
            guard !firstSnapshot else { continue }
            if message.kind == .reaction {
                onReaction?(message.text, member(message.uid))
            } else if message.uid != uid {
                onMessage?(message)
            }
        }
        messages = entries.filter { $0.kind != .reaction }.suffix(200).map { $0 }
    }

    // MARK: Oynatma

    /// Yerel kullanıcı eylemini odaya yazar. Aynı kullanıcının 300 ms içindeki ardışık sarmaları tek olay.
    func broadcast(playing: Bool, position: Double, rate: Float, action: String) {
        guard let backend, let code, isActive, canControl else { return }
        seekTask?.cancel()
        let send = { [weak self] in
            guard let self else { return }
            self.lastSeq += 1
            let value = RoomPlayback(playing: playing, positionMs: position * 1000, rate: Double(rate), updatedAt: 0,
                                     by: backend.uid, seq: self.lastSeq, action: action)
            // Yerel kopyayı hemen güncelle (sapma düzeltmesi beklemeden yeni duruma göre hesaplasın).
            self.playback = RoomPlayback(playing: playing, positionMs: position * 1000, rate: Double(rate), updatedAt: self.serverNow,
                                         by: backend.uid, seq: self.lastSeq, action: action)
            Task { _ = try? await backend.set("rooms/\(code)/playback", value.json()) }
        }
        if action == "seek" {
            seekTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                send()
            }
        } else {
            send()
        }
    }

    /// Hazır kontrolü bitince (ya da "beklemeden başlat") 3 sn sonra herkes için başlat.
    func startCountdown(position: Double) {
        guard let backend, let code else { return }
        let startAt = serverNow + 3000
        lastSeq += 1
        let value = RoomPlayback(playing: true, positionMs: position * 1000, rate: 1, updatedAt: startAt, by: backend.uid, seq: lastSeq, action: "start")
        Task {
            try? await backend.update("rooms/\(code)/meta", ["startAt": startAt, "readyCheck": false])
            _ = try? await backend.set("rooms/\(code)/playback", value.json(serverTimestamp: false))
        }
    }

    func setReady(_ ready: Bool) {
        localStatus = ready ? .ready : .loading
        guard let backend, let code else { return }
        Task { try? await backend.update("rooms/\(code)/members/\(backend.uid)", ["status": localStatus.rawValue]) }
    }

    func setStatus(_ status: RoomMember.Status) {
        guard localStatus != status, localStatus != .waiting else { return }
        localStatus = status
        guard let backend, let code else { return }
        Task { try? await backend.update("rooms/\(code)/members/\(backend.uid)", ["status": status.rawValue]) }
    }

    /// "Yine de izlesin": kurucu farklı sürümü onaylar.
    func acceptMismatch(_ member: RoomMember) {
        guard let backend, let code else { return }
        Task { try? await backend.update("rooms/\(code)/members/\(member.id)", ["acceptedMismatch": true]) }
    }

    /// Kilitli oda: bekleyen üyeyi içeri al.
    func approve(_ member: RoomMember) {
        guard let backend, let code else { return }
        Task { try? await backend.update("rooms/\(code)/members/\(member.id)", ["status": (meta?.readyCheck == true ? RoomMember.Status.loading : .ready).rawValue]) }
    }

    // MARK: Altyazı

    func shareSubtitle(text: String, name: String, language: String?, source: String, timing: SubtitleTiming) -> Bool {
        guard let backend, let code, let packed = RoomSubtitle.pack(text), packed.count <= 270_000 else { return false }
        let shared = RoomSubtitle(lang: language, source: source, name: name, contentGz: packed, offsetMs: timing.offsetMilliseconds,
                                  scale: timing.scale, by: backend.uid, version: (subtitle?.version ?? 0) + 1)
        subtitle = shared
        usingRoomSubtitle = true
        Task {
            _ = try? await backend.set("rooms/\(code)/subtitle", shared.json)
            try? await postSystem("\(me?.name ?? displayName) altyazıyı paylaştı · \(Language.name(for: language) ?? "Altyazı") · \(Format.milliseconds(timing.offsetMilliseconds))")
        }
        return true
    }

    /// Odanın altyazısını kullanan biri senkronu değiştirince herkese yaz (debounce 400 ms).
    func updateSharedTiming(_ timing: SubtitleTiming) {
        guard let backend, let code, usingRoomSubtitle, subtitle != nil else { return }
        guard subtitle?.offsetMs != timing.offsetMilliseconds || subtitle?.scale != timing.scale else { return }
        subtitle?.offsetMs = timing.offsetMilliseconds
        subtitle?.scale = timing.scale
        subtitleTimingTask?.cancel()
        subtitleTimingTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? await backend.update("rooms/\(code)/subtitle", ["offsetMs": timing.offsetMilliseconds, "scale": timing.scale])
        }
    }

    func markUsingRoomSubtitle(_ using: Bool) {
        usingRoomSubtitle = using
    }

    // MARK: Sohbet

    func send(text: String, positionMs: Double? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { try? await post(text: String(trimmed.prefix(500)), kind: .text, atMs: RoomMessage.timestamp(in: trimmed)) }
    }

    func react(_ emoji: String) {
        Task { try? await post(text: emoji, kind: .reaction, atMs: nil) }
    }

    func postSystem(_ text: String) async throws {
        try await post(text: text, kind: .system, atMs: nil)
    }

    private func post(text: String, kind: RoomMessage.Kind, atMs: Double?) async throws {
        guard let backend, let code else { return }
        var value: [String: Any] = ["uid": backend.uid, "name": me?.name ?? displayName, "text": text, "type": kind.rawValue, "ts": ServerValue.timestamp]
        if let atMs { value["atMs"] = atMs }
        try await backend.push("rooms/\(code)/messages", value)
    }

    // MARK: Yardımcılar

    static func generateCode() -> String {
        String((0..<6).map { _ in codeAlphabet.randomElement()! })
    }

    /// "k7x2qm", "kdplayer://join/K7X2QM", "kdplayer.app/j/K7X2QM" → "K7X2QM"
    static func normalize(_ raw: String) -> String {
        let last = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").last.map(String.init) ?? raw
        return String(last.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(6))
    }
}
