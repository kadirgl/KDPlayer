import SwiftUI
import AppKit

/// Oda olaylarını oynatıcıya uygular, yerel eylemleri odaya yazar (spesifikasyon › Olaylar, Sapma düzeltme).
extension PlayerSession {
    struct RoomEvent: Identifiable, Equatable {
        let id = UUID()
        let memberID: String?
        let initial: String
        let color: Int
        let name: String
        let text: String
    }

    struct FlyingReaction: Identifiable, Equatable {
        let id = UUID()
        let emoji: String
        let name: String
        let color: Int
        let x: CGFloat
    }

    struct PendingSharedSubtitle: Equatable {
        let subtitle: RoomSubtitle
        let from: String
        let color: Int
    }

    static let reactions = ["❤️", "😂", "😮", "👏"]
    /// Ölçülen sarma uygulama gecikmesi (sn).
    static let seekLatency = 0.13

    // MARK: Kurulum

    func configureRoom() {
        room.onRemotePlayback = { [weak self] playback, member, initial in self?.applyRemote(playback, from: member, initial: initial) }
        room.onSubtitleShared = { [weak self] subtitle, member in self?.receiveSharedSubtitle(subtitle, from: member) }
        room.onSubtitleTiming = { [weak self] timing in
            guard let self, self.room.usingRoomSubtitle else { return }
            self.subtitles.timing = timing
        }
        room.onReaction = { [weak self] emoji, member in self?.showReaction(emoji, from: member) }
        room.onMessage = { [weak self] message in
            guard let self, message.kind == .text, !self.showsRoomPanel || self.panel != nil else { return }
            let member = self.room.member(message.uid)
            self.showRoomEvent(member: member, text: message.text, prefixName: true)
        }
        room.onMemberJoined = { [weak self] member in
            guard let self else { return }
            if member.status == .waiting {
                self.showRoomEvent(member: member, text: "odaya girmek için onay bekliyor", prefixName: true)
            } else {
                self.showRoomEvent(member: member, text: "odaya katıldı", prefixName: true)
            }
            // Altyazımızı paylaştıysak yeni gelen de görür (oda düğümünde zaten var).
        }
        room.onMemberLeft = { [weak self] _ in self?.updateRoomWaiting() }
        room.onStartAt = { [weak self] startAt in self?.beginCountdown(until: startAt) }
        room.onClosed = { [weak self] reason in
            guard let self else { return }
            self.stopRoomLoops()
            self.showsRoomPanel = false
            self.readyCheckVisible = false
            self.toasts.show(reason, subtitle: "Film kesilmeden devam ediyor")
        }
        subtitles.onTimingChanged = { [weak self] timing in self?.room.updateSharedTiming(timing) }
        subtitles.onSubtitleReplaced = { [weak self] source in
            guard let self, self.room.isActive else { return }
            self.room.markUsingRoomSubtitle(source == .room)
        }
    }

    var inRoom: Bool { room.isActive }

    // MARK: Oda kur / katıl / ayrıl

    func presentRoomSetup() {
        guard url != nil else { return }
        if inRoom {
            withAnimation(Theme.spring) { showsRoomPanel = true; panel = nil }
            return
        }
        guard RoomService.isConfigured else {
            toasts.show(Toast(kind: .warning, title: "Birlikte izleme şu an kullanılamıyor", subtitle: "Bu sürümde oda sunucusu yok; güncel sürümü indir"))
            return
        }
        guard NetworkMonitor.shared.isOnline else {
            toasts.show(Toast(kind: .warning, title: "İnternet bağlantısı yok", subtitle: "Oda kurmak için bağlantı gerekli"))
            return
        }
        player.pause()
        withAnimation(Theme.spring) { roomSetupVisible = true; tracksOpen = false }
    }

    var currentRoomMedia: RoomMedia {
        RoomMedia(
            title: title, durationMs: (player.duration * 1000).rounded(), fileHash: record?.fileHash,
            release: parsed.release, fps: player.videoTrack?.frameRate, detail: detailLine
        )
    }

    /// Paylaşılabilir altyazı: yalnızca harici (metni elimizde olan) altyazılar.
    var shareableSubtitle: RoomSubtitle? {
        guard let loaded = subtitles.loaded, subtitles.enabled, !loaded.rawText.isEmpty,
              let packed = RoomSubtitle.pack(loaded.rawText) else { return nil }
        return RoomSubtitle(lang: loaded.language, source: loaded.source.rawValue, name: loaded.name, contentGz: packed,
                            offsetMs: subtitles.timing.offsetMilliseconds, scale: subtitles.timing.scale, by: "", version: 1)
    }

    @MainActor
    func createRoom(name: String, controlMode: ControlMode, shareSubtitle: Bool, readyCheck: Bool, locked: Bool, code: String) async -> Bool {
        if resumePrompt != nil {
            countdownTask?.cancel()
            resumePrompt = nil
        }
        do {
            let code = try await room.create(
                name: name, controlMode: controlMode, readyCheck: readyCheck, locked: locked, media: currentRoomMedia,
                position: player.time, displayName: displayName, sharedSubtitle: shareSubtitle ? shareableSubtitle : nil, preferredCode: code
            )
            withAnimation(Theme.spring) {
                roomSetupVisible = false
                showsRoomPanel = true
                panel = nil
                readyCheckVisible = readyCheck
            }
            startRoomLoops()
            copyInviteLink(code: code, announce: false)
            toasts.show(Toast(kind: .success, title: "Oda açıldı · \(code)", subtitle: "Davet linki panoya kopyalandı"))
            if !readyCheck { player.play() }
            return true
        } catch {
            toasts.show(Toast(kind: .warning, title: "Oda açılamadı", subtitle: error.localizedDescription))
            return false
        }
    }

    /// Dosya açıldıktan sonra odaya katıl (ekran 12'den).
    @MainActor
    func joinRoom(code: String) async -> Bool {
        // Süre bilgisi gelene kadar bekle (dosya doğrulaması için).
        for _ in 0..<50 where player.duration <= 0 { try? await Task.sleep(for: .milliseconds(100)) }
        if resumePrompt != nil {
            countdownTask?.cancel()
            resumePrompt = nil
        }
        do {
            try await room.join(code: code, displayName: displayName, durationMs: (player.duration * 1000).rounded(), fileHash: record?.fileHash)
            withAnimation(Theme.spring) {
                showsRoomPanel = true
                panel = nil
                readyCheckVisible = room.meta?.readyCheck == true
            }
            startRoomLoops()
            return true
        } catch {
            toasts.show(Toast(kind: .warning, title: "Odaya katılınamadı", subtitle: error.localizedDescription))
            return false
        }
    }

    func leaveRoom() {
        stopRoomLoops()
        withAnimation(Theme.spring) {
            showsRoomPanel = false
            readyCheckVisible = false
            pendingSharedSubtitle = nil
        }
        Task { @MainActor in await room.leave() }
    }

    var displayName: String {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["KD_DISPLAY_NAME"] { return name }
        #endif
        let stored = UserDefaults.standard.string(forKey: SettingsKey.displayName)?.trimmingCharacters(in: .whitespaces) ?? ""
        if !stored.isEmpty { return stored }
        return NSFullUserName().split(separator: " ").first.map(String.init) ?? "Misafir"
    }

    func copyInviteLink(code: String? = nil, announce: Bool = true) {
        guard let code = code ?? room.code else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("kdplayer://join/\(code)", forType: .string)
        if announce { toasts.show(Toast(kind: .success, title: "Davet linki kopyalandı", subtitle: "kdplayer://join/\(code)")) }
    }

    // MARK: Yerel eylem → oda

    /// Oda "sadece oda sahibi" modundaysa ve kontrol bizde değilse eylemi engeller.
    func roomAllowsControl() -> Bool {
        guard inRoom, !room.canControl else { return true }
        let host = room.controllerID.flatMap { room.member($0)?.name } ?? "Oda sahibi"
        toasts.show("Kontrol \(host)'de", subtitle: "Bu odada yalnızca oda sahibi oynatır ve sarar")
        return false
    }

    func broadcastPlayback(_ action: String, playing: Bool? = nil) {
        guard inRoom else { return }
        room.broadcast(playing: playing ?? (player.isPlaying || player.state == .opening), position: player.preciseTime, rate: player.rate, action: action)
    }

    // MARK: Oda → oynatıcı

    private func applyRemote(_ playback: RoomPlayback, from member: RoomMember?, initial: Bool) {
        let now = room.serverNow
        // Geri sayımla başlatma: başlangıç anı gelecekte.
        if playback.updatedAt > now + 50 {
            player.pause()
            player.seek(to: playback.positionMs / 1000)
            beginCountdown(until: playback.updatedAt)
            return
        }
        let expected = playback.expectedPosition(serverNow: now)
        // VLC sarmayı ~130 ms'de uygular; oynarken hedefi o kadar ileri al.
        if abs(player.preciseTime - expected) > 0.5 { player.seek(to: expected + (playback.playing ? Self.seekLatency : 0)) }
        if abs(player.rate - Float(playback.rate)) > 0.01 {
            player.setRate(Float(playback.rate))
            if !initial { hud.show(.rate(player.rate)) }
        }
        if playback.playing {
            if !player.isPlaying && !pausedForBuffering { player.play() }
        } else if player.isPlaying || player.state == .opening {
            player.pause()
        }
        if initial || member == nil { return }
        let text: String = switch playback.action {
        case "pause", "wait": playback.action == "wait" ? "herkesi bekletiyor" : "durdurdu"
        case "play", "resume": "devam ettirdi"
        case "seek": "\(Format.time(expected))'a sardı"
        case "rate": "hızı \(Format.rate(Float(playback.rate))) yaptı"
        default: ""
        }
        if !text.isEmpty {
            showRoomEvent(member: member, text: text, prefixName: true)
            if playback.action == "seek" {
                let marker = (memberID: member?.id ?? "", seconds: expected)
                withAnimation(Theme.spring) { lastSeekMarker = marker }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard let self, self.lastSeekMarker?.seconds == marker.seconds else { return }
                    withAnimation(.easeOut(duration: 0.3)) { self.lastSeekMarker = nil }
                }
            }
        }
    }

    // MARK: Sapma düzeltme ve buffering

    func startRoomLoops() {
        stopRoomLoops()
        roomLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.correctDrift()
                self?.updateRoomWaiting()
            }
        }
    }

    func stopRoomLoops() {
        roomLoopTask?.cancel()
        roomLoopTask = nil
        player.setRateNudge(1)
        pausedForBuffering = false
    }

    /// Her 2 sn: < 150 ms dokunma; 150 ms – 2 sn hızı geçici ×0,97 / ×1,03; > 2 sn doğrudan sar.
    private func correctDrift() {
        guard inRoom, let playback = room.playback, countdown == nil, !pausedForBuffering else { return }
        let expected = playback.expectedPosition(serverNow: room.serverNow)
        // Film sonu: oda saati süreyi geçtiyse herkes bitirmiştir, sapma yok.
        if player.duration > 0, expected >= player.duration - 0.5 || player.state == .ended {
            room.localDriftMs = 0
            player.setRateNudge(1)
            return
        }
        let drift = player.preciseTime - expected
        room.localDriftMs = (drift * 1000).rounded()
        guard playback.playing else {
            // Oda duraklatılmışken yerel oynatma da durur ve aynı karede bekler.
            if player.isPlaying { player.pause() }
            if abs(drift) > 0.5 { player.seek(to: expected) }
            room.localDriftMs = 0
            player.setRateNudge(1)
            return
        }
        if !player.isPlaying, player.state == .paused {
            player.play()
        }
        switch abs(drift) {
        case ..<0.15: player.setRateNudge(1)
        case ..<2: player.setRateNudge(drift > 0 ? 0.97 : 1.03)
        default:
            player.setRateNudge(1)
            player.seek(to: expected + Self.seekLatency)
        }
    }

    /// Yerel durumu raporla; biri buffering ise kontrol sahibi herkesi bekletir, düzelince 1 sn sonra devam.
    func updateRoomWaiting() {
        guard inRoom else { return }
        let localBuffering = player.state == .buffering || player.state == .opening
        if room.localStatus != .waiting, !(room.meta?.readyCheck == true && room.localStatus == .loading) {
            room.setStatus(localBuffering ? .buffering : .ready)
        }
        guard room.controllerID == room.uid, let playback = room.playback else { return }
        let waiting = !room.bufferingMembers.isEmpty
        if waiting, playback.playing {
            pausedForBuffering = true
            player.pause()
            room.broadcast(playing: false, position: player.preciseTime, rate: player.rate, action: "wait")
        } else if !waiting, pausedForBuffering, !playback.playing {
            pausedForBuffering = false
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.room.bufferingMembers.isEmpty else { return }
                self.player.play()
                self.room.broadcast(playing: true, position: self.player.time, rate: self.player.rate, action: "resume")
            }
        }
    }

    // MARK: Hazır kontrolü

    func toggleReady() {
        room.setReady(room.localStatus != .ready)
        maybeStartWhenAllReady()
    }

    func maybeStartWhenAllReady() {
        guard room.isHost, room.meta?.readyCheck == true else { return }
        let active = room.activeMembers.filter { $0.status != .waiting }
        let ready = active.filter { $0.id == room.uid ? room.localStatus == .ready : $0.status == .ready }
        if !active.isEmpty, ready.count == active.count { startRoomNow() }
    }

    func startRoomNow() {
        room.startCountdown(position: player.time)
    }

    private func beginCountdown(until startAt: Double) {
        withAnimation(Theme.spring) { readyCheckVisible = false }
        if room.localStatus == .loading { room.setReady(true) }
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while true {
                let remaining = (startAt - self.room.serverNow) / 1000
                if remaining <= 0 { break }
                self.countdown = Int(remaining.rounded(.up))
                try? await Task.sleep(for: .milliseconds(min(250, max(10, remaining * 1000))))
                if Task.isCancelled { return }
            }
            self.countdown = nil
            self.player.play()
        }
    }

    // MARK: Altyazı paylaşımı (ekran 15)

    func shareSubtitleToRoom() {
        guard inRoom else {
            toasts.show("Önce bir oda kur", subtitle: "Birlikte izleme odası açıkken altyazı herkese gönderilir")
            return
        }
        guard let loaded = subtitles.loaded, !loaded.rawText.isEmpty else {
            toasts.show("Bu altyazı paylaşılamıyor", subtitle: "Dosyanın içindeki altyazıyı herkes kendi dosyasından seçebilir")
            return
        }
        if room.shareSubtitle(text: loaded.rawText, name: loaded.name, language: loaded.language, source: loaded.source.rawValue, timing: subtitles.timing) {
            toasts.show(Toast(kind: .success, title: "Altyazı odaya gönderildi", subtitle: "\(Language.name(for: loaded.language) ?? "Altyazı") · \(Format.milliseconds(subtitles.timing.offsetMilliseconds))"))
        } else {
            toasts.show("Altyazı çok büyük", subtitle: "Oda en fazla 200 KB sıkıştırılmış altyazı taşır")
        }
    }

    private func receiveSharedSubtitle(_ subtitle: RoomSubtitle, from member: RoomMember?) {
        // Aynı altyazı zaten açıksa sormadan odanınkine bağlan, yalnızca senkron ayarını al.
        if let mine = subtitles.loaded?.rawText, !mine.isEmpty, subtitle.unpackedText() == mine {
            room.markUsingRoomSubtitle(true)
            subtitles.timing = subtitle.timing
            return
        }
        let auto = UserDefaults.standard.bool(forKey: SettingsKey.roomAutoAcceptSubtitle)
        if auto || !subtitles.hasSubtitle {
            acceptSharedSubtitle(subtitle, announce: true, from: member)
        } else {
            withAnimation(Theme.spring) {
                pendingSharedSubtitle = PendingSharedSubtitle(subtitle: subtitle, from: member?.name ?? "Biri", color: member?.color ?? 0)
            }
        }
    }

    func acceptSharedSubtitle(_ subtitle: RoomSubtitle, announce: Bool, from member: RoomMember? = nil, remember: Bool = false) {
        if remember { UserDefaults.standard.set(true, forKey: SettingsKey.roomAutoAcceptSubtitle) }
        guard let text = subtitle.unpackedText(),
              subtitles.loadShared(text: text, name: subtitle.name, language: subtitle.lang, timing: subtitle.timing) else {
            toasts.show("Odanın altyazısı açılamadı")
            return
        }
        room.markUsingRoomSubtitle(true)
        withAnimation(Theme.spring) { pendingSharedSubtitle = nil }
        Task { try? await room.postSystem("\(displayName) odanın altyazısına geçti") }
        if announce {
            showRoomEvent(member: member, text: "altyazısını paylaştı · \(Language.name(for: subtitle.lang) ?? "") kullanılıyor", prefixName: true)
        }
    }

    func keepOwnSubtitle(remember: Bool) {
        withAnimation(Theme.spring) { pendingSharedSubtitle = nil }
    }

    // MARK: Geri bildirim

    func showRoomEvent(member: RoomMember?, text: String, prefixName: Bool) {
        let event = RoomEvent(memberID: member?.id, initial: member?.initial ?? "•", color: member?.color ?? 0,
                              name: member?.name ?? "", text: text)
        withAnimation(Theme.spring) { roomEvent = event }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard let self, self.roomEvent?.id == event.id else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.roomEvent = nil }
        }
    }

    func sendReaction(_ emoji: String) {
        room.react(emoji)
        showReaction(emoji, from: room.me)
    }

    private func showReaction(_ emoji: String, from member: RoomMember?) {
        let reaction = FlyingReaction(emoji: emoji, name: member?.name ?? "", color: member?.color ?? 0, x: .random(in: 0.55...0.9))
        reactions.append(reaction)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.reactions.removeAll { $0.id == reaction.id }
        }
    }

    /// Sohbetteki zaman damgasına git ("Şu sahneyi bir daha izleyelim 41:52").
    func jump(toMilliseconds ms: Double) {
        guard roomAllowsControl() else { return }
        player.seek(to: ms / 1000)
        broadcastPlayback("seek")
    }
}

// MARK: - Ağ durumu

import Network

/// İnternet yoksa Oda kur / katıl pasif ve açıklamalı.
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()
    private(set) var isOnline = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.isOnline = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "KDPlayer.network"))
    }
}
