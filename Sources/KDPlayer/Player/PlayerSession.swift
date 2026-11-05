import SwiftUI
import SwiftData
import Observation
import MediaPlayer

/// Bir dosyanın oynatma oturumu: oynatıcı, altyazı servisi, geçmiş kaydı ve ekran durumu
/// (panel, popover, HUD, toast, devam et, hata, sonraki bölüm) burada birleşir.
@Observable
final class PlayerSession {
    enum PanelTab: String, CaseIterable, Identifiable {
        case find, sync, appearance
        var id: Self { self }
        var title: String {
            switch self {
            case .find: "Bul"
            case .sync: "Senkron"
            case .appearance: "Görünüm"
            }
        }
    }

    struct ResumePrompt: Equatable {
        let position: Double
        let duration: Double
        let lastOpened: Date
    }

    struct BlockingError: Equatable {
        let title: String
        let message: String
        let technical: String
        let canCompleteDownload: Bool
    }

    struct NextEpisode: Equatable {
        let url: URL
        let code: String
        let title: String
    }

    let player = PlayerController()
    let subtitles = SubtitleService()
    let toasts = ToastCenter()
    let hud = HUDCenter()
    let room = RoomService()

    private(set) var url: URL?
    private(set) var title = ""
    private(set) var record: WatchRecord?
    private(set) var parsed = ParsedFilename(title: "")

    // Ekran durumu
    var controlsVisible = true
    var panel: PanelTab?
    var tracksOpen = false
    var resumePrompt: ResumePrompt?
    var blockingError: BlockingError?
    var nextEpisode: NextEpisode?
    /// Sonraki bölüm geri sayımı (sn); nil = kart kapalı.
    var nextEpisodeCountdown: Int?
    var hoveringControls = false
    /// "Duy ve bas" modu: Space konuşma anını işaretler.
    var listeningForSpeech = false
    private(set) var isMini = false

    // Oda
    var showsRoomPanel = false
    var roomSetupVisible = false
    var readyCheckVisible = false
    var pendingSharedSubtitle: PendingSharedSubtitle?
    var roomEvent: RoomEvent?
    var reactions: [FlyingReaction] = []
    /// Hazır kontrolü sonrası 3-2-1.
    var countdown: Int?
    var pausedForBuffering = false
    /// Son uzak sarmanın scrubber'daki avatar işareti (üye, saniye).
    var lastSeekMarker: (memberID: String, seconds: Double)?
    /// Return ile sohbet alanına odaklanma isteği.
    var chatFocusRequest = 0
    @ObservationIgnored var roomLoopTask: Task<Void, Never>?

    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var modelContext: ModelContext?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored var onOpenFilePanel: (() -> Void)?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var pauseOnStart = false
    @ObservationIgnored private var lastSavedTime: Double = 0
    @ObservationIgnored private var restoredTracks = false
    @ObservationIgnored private var miniRestoreFrame: NSRect?
    @ObservationIgnored private var nextEpisodeDismissed = false

    init() {
        subtitles.attach(player: player)
        player.onStateChanged = { [weak self] state in self?.handleState(state) }
        player.onTimeChanged = { [weak self] time in self?.handleTime(time) }
        player.onEnded = { [weak self] in self?.handleEnded() }
        subtitles.onAutoLoaded = { [weak self] candidate, loaded in self?.announceSubtitle(candidate: candidate, loaded: loaded) }
        subtitles.onEmbeddedSelected = { [weak self] track in
            self?.toasts.show(Toast(kind: .success, title: "Dosyadaki \(track.languageName) altyazı açıldı", subtitle: "Gömülü altyazı her zaman birebir senkrondur"))
        }
        subtitles.onNeedsAttention = { [weak self] in
            guard let self, self.panel == nil else { return }
            withAnimation(Theme.spring) { self.panel = .find }
        }
        subtitles.onPersist = { [weak self] in self?.persistSubtitle() }
        hud.onUndoSubtitleDelay = nil
        setupRemoteCommands()
        configureRoom()
    }

    // MARK: Açma / kapama

    func open(_ url: URL) {
        if inRoom, url != self.url { leaveRoom() }
        saveProgress(final: true)
        blockingError = nil
        resumePrompt = nil
        nextEpisode = nil
        nextEpisodeCountdown = nil
        nextEpisodeDismissed = false
        listeningForSpeech = false
        restoredTracks = false
        self.url = url
        parsed = ParsedFilename(filename: url.lastPathComponent)
        title = parsed.isEpisode ? "\(parsed.title) · \(parsed.episodeCode ?? "")" : parsed.title

        let hash = try? MovieHash.compute(for: url)
        let record = hash.flatMap { fetchOrCreateRecord(hash: $0, url: url) }
        self.record = record
        record?.lastOpened = .now
        record?.path = url.path

        subtitles.reset(for: url, hash: hash)

        var start: Double?
        if let record, record.isResumable {
            let mode = ResumeMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.resumeMode) ?? "") ?? .ask
            switch mode {
            case .always:
                start = record.position
            case .ask:
                start = record.position
                pauseOnStart = true
                resumePrompt = ResumePrompt(position: record.position, duration: record.duration, lastOpened: record.lastOpened)
                startResumeCountdown()
            case .never:
                break
            }
        }
        player.open(url, startAt: start)
        if let record { player.setAudioDelay(record.audioDelay) }
        subtitles.start(restoring: record)
        nextEpisode = findNextEpisode()
        controlsVisible = true
        scheduleHide()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        updateNowPlaying()
    }

    func close() {
        if inRoom { leaveRoom() }
        saveProgress(final: true)
        player.stop()
        countdownTask?.cancel()
        hideTask?.cancel()
        if isMini { toggleMini() }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        url = nil
        record = nil
        panel = nil
        tracksOpen = false
        NSCursor.unhide()
        onClose?()
    }

    private func fetchOrCreateRecord(hash: String, url: URL) -> WatchRecord? {
        guard let context = modelContext else { return nil }
        let descriptor = FetchDescriptor<WatchRecord>(predicate: #Predicate { $0.fileHash == hash })
        if let existing = try? context.fetch(descriptor).first { return existing }
        let record = WatchRecord(fileHash: hash, path: url.path, title: parsed.isEpisode ? "\(parsed.title) · \(parsed.episodeCode ?? "")" : parsed.title)
        context.insert(record)
        return record
    }

    // MARK: Olaylar

    private func handleState(_ state: PlayerController.State) {
        switch state {
        case .playing:
            if pauseOnStart {
                pauseOnStart = false
                player.pause()
            }
            restoreTracksIfNeeded()
            updateDetail()
            scheduleHide()
        case .paused:
            controlsVisible = true
            saveProgress(final: false)
        case .error(let message):
            blockingError = makeError(message: message)
        default:
            break
        }
        updateNowPlaying()
    }

    private func handleTime(_ time: Double) {
        if abs(time - lastSavedTime) > 5 { saveProgress(final: false) }
        // Sonraki bölüm kartı: son 20 sn.
        if let nextEpisode, !nextEpisodeDismissed, nextEpisodeCountdown == nil, player.duration > 300,
           player.remaining < 20, player.remaining > 0.5,
           UserDefaults.standard.bool(forKey: SettingsKey.autoplayNextEpisode) {
            startNextEpisodeCountdown(nextEpisode)
        }
    }

    private func handleEnded() {
        record?.position = 0
        record?.finished = true
        if let nextEpisode, UserDefaults.standard.bool(forKey: SettingsKey.autoplayNextEpisode), !nextEpisodeDismissed {
            open(nextEpisode.url)
        } else {
            controlsVisible = true
        }
    }

    private func restoreTracksIfNeeded() {
        guard !restoredTracks, !player.audioTracks.isEmpty else { return }
        restoredTracks = true
        if let id = record?.audioTrackID, player.audioTracks.contains(where: { $0.id == Int32(id) }) {
            player.selectAudio(Int32(id))
        } else if UserDefaults.standard.bool(forKey: SettingsKey.rememberTrackLanguages),
                  let language = UserDefaults.standard.string(forKey: SettingsKey.preferredAudioLanguage),
                  let track = player.audioTracks.first(where: { $0.languageCode == language && !$0.isCommentary }) {
            player.selectAudio(track.id)
        }
    }

    // MARK: Kayıt

    func saveProgress(final: Bool) {
        guard let record, player.duration > 0 else { return }
        lastSavedTime = player.time
        record.duration = player.duration
        if player.state != .ended {
            record.position = player.time
            record.finished = player.time > player.duration * 0.95
        }
        record.audioTrackID = player.currentAudioID >= 0 ? Int(player.currentAudioID) : nil
        record.audioDelay = player.audioDelay
        if final {
            player.saveSnapshot(to: record.thumbnailURL)
            try? modelContext?.save()
        }
    }

    private func persistSubtitle() {
        guard let record else { return }
        record.subtitleEnabled = subtitles.enabled
        record.subtitleTiming = subtitles.timing
        if let loaded = subtitles.loaded {
            record.subtitlePath = loaded.fileURL?.path
            record.subtitleName = loaded.name
            record.subtitleSource = loaded.source.rawValue
            record.subtitleLanguage = loaded.language
            record.embeddedSubtitleID = nil
        } else if let id = subtitles.embeddedTrackID {
            record.embeddedSubtitleID = Int(id)
            record.subtitlePath = nil
        }
    }

    private func updateDetail() {
        guard let record else { return }
        var parts: [String] = []
        if let year = parsed.year { parts.append(String(year)) }
        if parsed.isEpisode, let code = parsed.episodeCode { parts.append(code) }
        if player.duration > 0 { parts.append(Format.duration(player.duration)) }
        if let video = player.videoTrack, !video.meta.isEmpty { parts.append(video.meta) }
        record.detail = parts.joined(separator: " · ")
    }

    var detailLine: String {
        if let detail = record?.detail, !detail.isEmpty { return detail }
        var parts: [String] = []
        if let year = parsed.year { parts.append(String(year)) }
        if player.duration > 0 { parts.append(Format.duration(player.duration)) }
        if let video = player.videoTrack, !video.meta.isEmpty { parts.append(video.meta) }
        return parts.joined(separator: " · ")
    }

    // MARK: Altyazı bildirimleri

    private func announceSubtitle(candidate: SubtitleService.Candidate?, loaded: SubtitleService.Loaded) {
        let languageName = Language.name(for: loaded.language) ?? "Altyazı"
        let score = candidate?.score ?? 100
        var detail: [String] = []
        if candidate?.hashMatch == true { detail.append("Birebir eşleşme") } else if let score = candidate?.score { detail.append("%\(score) eşleşme") }
        detail.append(loaded.source.title)
        let change = Toast.Action(title: "Değiştir", emphasized: score < 90) { [weak self] in
            withAnimation(Theme.spring) { self?.panel = .find }
        }
        toasts.show(Toast(kind: .success, title: "\(languageName) altyazı yüklendi", subtitle: detail.joined(separator: " · "), actions: [change], duration: score < 90 ? 7 : 4))
    }

    // MARK: Kontrol katmanı

    /// Fare 2,5 sn hareketsiz kalınca kontrol katmanı 300 ms'de gizlenir; panel açıkken gizlenmez.
    func userActivity() {
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
        }
        scheduleHide()
    }

    func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !Task.isCancelled else { return }
            guard self.player.isPlaying, self.panel == nil, !self.tracksOpen, !self.hoveringControls,
                  self.resumePrompt == nil, self.blockingError == nil, !self.showsRoomPanel,
                  !self.roomSetupVisible, !self.readyCheckVisible else { return }
            withAnimation(.easeInOut(duration: 0.3)) { self.controlsVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    func togglePanel(_ tab: PanelTab = .find) {
        withAnimation(Theme.spring) {
            tracksOpen = false
            panel = panel == tab ? nil : tab
        }
        if panel == nil { listeningForSpeech = false }
        userActivity()
    }

    func toggleTracks() {
        withAnimation(Theme.spring) {
            tracksOpen.toggle()
        }
        userActivity()
    }

    // MARK: Eylemler

    func togglePlayPause() {
        if resumePrompt != nil {
            resume(fromStart: false)
            return
        }
        guard roomAllowsControl() else { return }
        let willPlay = !player.isPlaying
        pausedForBuffering = false
        player.togglePlayPause()
        broadcastPlayback(willPlay ? "play" : "pause", playing: willPlay)
        userActivity()
    }

    func seek(by seconds: Double) {
        guard roomAllowsControl() else { return }
        player.seek(by: seconds)
        hud.show(.seek(deltaSeconds: Int(seconds), position: Format.time(player.time)))
        broadcastPlayback("seek")
        userActivity()
    }

    func seek(to seconds: Double) {
        guard roomAllowsControl() else { return }
        player.seek(to: seconds)
        broadcastPlayback("seek")
        userActivity()
    }

    func changeVolume(by delta: Int) {
        player.setVolume(player.volume + delta)
        hud.show(.volume(level: player.volume, muted: player.muted))
    }

    func toggleMute() {
        player.toggleMute()
        hud.show(.volume(level: player.volume, muted: player.muted))
    }

    func changeRate(by delta: Float) {
        guard roomAllowsControl() else { return }
        player.setRate(((player.rate + delta) * 4).rounded() / 4)
        hud.show(.rate(player.rate))
        broadcastPlayback("rate")
    }

    func setRate(_ rate: Float) {
        guard roomAllowsControl() else { return }
        player.setRate(rate)
        hud.show(.rate(player.rate))
        broadcastPlayback("rate")
    }

    /// G / H: altyazı gecikmesi ±100 ms; HUD'da "Geri al".
    func nudgeSubtitle(by milliseconds: Int) {
        guard subtitles.hasSubtitle else {
            toasts.show("Açık altyazı yok", subtitle: "S ile altyazı seç ya da ⇧S ile paneli aç")
            return
        }
        let previous = subtitles.timing
        subtitles.nudge(by: milliseconds)
        hud.onUndoSubtitleDelay = { [weak self] in
            guard let self else { return }
            self.subtitles.timing = previous
            self.hud.show(.subtitleDelay(ms: previous.offsetMilliseconds))
        }
        hud.show(.subtitleDelay(ms: subtitles.timing.offsetMilliseconds))
    }

    func cycleAudio() {
        guard let track = player.cycleAudio() else { return }
        toasts.show("Ses: \(track.audioTitle)", subtitle: track.meta)
    }

    /// S: kapalı → gömülü metin parçaları → harici altyazı → kapalı.
    func cycleSubtitle() {
        enum Option: Equatable { case off, embedded(MediaTrack), external }
        var options: [Option] = [.off]
        options += player.embeddedSubtitles.map { .embedded($0) }
        if subtitles.loaded != nil { options.append(.external) }
        let current: Option = if !subtitles.enabled { .off } else if let id = subtitles.embeddedTrackID, let track = player.embeddedSubtitles.first(where: { $0.id == id }) { .embedded(track) } else if subtitles.loaded != nil { .external } else { .off }
        let index = options.firstIndex(of: current) ?? 0
        let next = options[(index + 1) % options.count]
        switch next {
        case .off:
            subtitles.turnOff()
            toasts.show("Altyazı kapalı")
        case .embedded(let track):
            subtitles.selectEmbedded(track)
            toasts.show("Altyazı: \(track.languageName)", subtitle: track.meta)
        case .external:
            subtitles.turnOn()
            if subtitles.embeddedTrackID != nil { player.selectEmbeddedSubtitle(-1) }
            toasts.show("Altyazı: \(Language.name(for: subtitles.loaded?.language) ?? "Harici")", subtitle: subtitles.loaded?.name)
        }
    }

    func resume(fromStart: Bool) {
        countdownTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { resumePrompt = nil }
        pauseOnStart = false
        if fromStart { player.seek(to: 0) }
        player.play()
        scheduleHide()
    }

    private func startResumeCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.resumePrompt != nil else { return }
            self.resume(fromStart: false)
        }
    }

    // MARK: Sonraki bölüm

    private func startNextEpisodeCountdown(_ episode: NextEpisode) {
        nextEpisodeCountdown = 10
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            while let self, let value = self.nextEpisodeCountdown, value > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                self.nextEpisodeCountdown = value - 1
            }
            guard let self, !Task.isCancelled, self.nextEpisodeCountdown == 0 else { return }
            self.open(episode.url)
        }
    }

    func playNextEpisodeNow() {
        guard let nextEpisode else { return }
        countdownTask?.cancel()
        open(nextEpisode.url)
    }

    func cancelNextEpisode() {
        countdownTask?.cancel()
        nextEpisodeCountdown = nil
        nextEpisodeDismissed = true
    }

    /// Klasördeki SxxEyy sırasından bir sonraki bölümü bulur.
    private func findNextEpisode() -> NextEpisode? {
        guard let url, let season = parsed.season, let episode = parsed.episode else { return nil }
        let folder = url.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let videos = files.filter { AppInfo.videoExtensions.contains($0.pathExtension.lowercased()) }
        let parsedFiles = videos.map { ($0, ParsedFilename(filename: $0.lastPathComponent)) }
        let sameShow = parsedFiles.filter { $0.1.title.lowercased() == parsed.title.lowercased() }
        let next = sameShow.first { $0.1.season == season && $0.1.episode == episode + 1 }
            ?? sameShow.first { $0.1.season == season + 1 && $0.1.episode == 1 }
        guard let (nextURL, info) = next else { return nil }
        return NextEpisode(url: nextURL, code: info.episodeCode ?? "", title: info.title)
    }

    // MARK: Hatalar

    private func makeError(message: String) -> BlockingError {
        let name = url?.lastPathComponent ?? "Dosya"
        let size = (try? url?.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
        let partial = url.map { FileManager.default.fileExists(atPath: $0.path + ".aria2") || FileManager.default.fileExists(atPath: $0.path + ".part") } ?? false
        let technical = [url?.pathExtension.uppercased(), size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }, message]
            .compactMap { $0 }.joined(separator: " · ")
        return BlockingError(
            title: partial ? "Bu dosya tam oynatılamıyor" : "Bu dosya açılamadı",
            message: partial
                ? "\(name) dosyasının bir kısmı eksik. İndirme yarıda kalmış olabilir."
                : "\(name) okunamadı. Dosya bozuk ya da desteklenmeyen bir biçimde olabilir.",
            technical: technical,
            canCompleteDownload: partial && DownloadManagerBridge.isInstalled
        )
    }

    func retry() {
        guard let url else { return }
        blockingError = nil
        player.open(url, startAt: player.time)
    }

    // MARK: Pencere

    func toggleFullScreen() {
        if isMini { toggleMini() }
        window?.toggleFullScreen(nil)
    }

    /// Resim içinde resim: pencere küçülüp ekranın köşesinde her zaman üstte durur.
    func toggleMini() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        if isMini, let frame = miniRestoreFrame {
            window.level = .normal
            window.collectionBehavior.remove(.canJoinAllSpaces)
            window.setFrame(frame, display: true, animate: true)
            isMini = false
        } else {
            miniRestoreFrame = window.frame
            let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let aspect = player.videoSize.width > 0 ? player.videoSize.height / player.videoSize.width : 9 / 16
            let width: CGFloat = 480
            let frame = NSRect(x: screen.maxX - width - 20, y: screen.minY + 20, width: width, height: width * aspect)
            window.level = .floating
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.setFrame(frame, display: true, animate: true)
            isMini = true
            panel = nil
            tracksOpen = false
        }
    }

    // MARK: Klavye

    /// Tek tuşlu kısayollar. Metin alanına odaklıyken çağrılmaz.
    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let shift = modifiers == .shift
        guard modifiers.isSubset(of: .shift) else { return false }
        userActivity()

        switch event.keyCode {
        case 49: // Space
            if listeningForSpeech, subtitles.loaded != nil {
                if subtitles.markSpeech(at: player.time) {
                    hud.show(.subtitleDelay(ms: subtitles.timing.offsetMilliseconds))
                }
            } else {
                togglePlayPause()
            }
            return true
        case 123: seek(by: shift ? -60 : -10); return true
        case 124: seek(by: shift ? 60 : 10); return true
        case 126: changeVolume(by: 5); return true
        case 125: changeVolume(by: -5); return true
        case 36 where inRoom: // Return: sohbete yaz
            withAnimation(Theme.spring) { showsRoomPanel = true; panel = nil }
            chatFocusRequest += 1
            return true
        case 53: // Esc
            if roomSetupVisible { withAnimation(Theme.spring) { roomSetupVisible = false }; return true }
            if tracksOpen { withAnimation(Theme.spring) { tracksOpen = false }; return true }
            if panel != nil { togglePanel(panel!); return true }
            if isMini { toggleMini(); return true }
            if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil); return true }
            return false
        default: break
        }

        switch event.charactersIgnoringModifiers?.lowercased(with: Format.turkish) {
        case "m": toggleMute()
        case "[": changeRate(by: -0.25)
        case "]": changeRate(by: 0.25)
        case "\\": setRate(1)
        case "g": nudgeSubtitle(by: -100)
        case "h": nudgeSubtitle(by: 100)
        case "a": cycleAudio()
        case "s": shift ? togglePanel(.find) : cycleSubtitle()
        case "f": toggleFullScreen()
        case "p": toggleMini()
        case ",": player.step(forward: false)
        case ".": player.step(forward: true)
        default: return false
        }
        return true
    }

    // MARK: Now Playing ve medya tuşları

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        center.playCommand.addTarget { [weak self] _ in self?.player.play(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); return .success }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in self?.seek(by: 10); return .success }
        center.skipBackwardCommand.addTarget { [weak self] _ in self?.seek(by: -10); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.player.seek(to: event.positionTime)
            return .success
        }
    }

    private func updateNowPlaying() {
        guard url != nil else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.time,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? Double(player.rate) : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        MPNowPlayingInfoCenter.default().playbackState = player.isPlaying ? .playing : .paused
    }
}

/// KD Download Manager entegrasyonu: "İndirmeyi tamamla".
enum DownloadManagerBridge {
    static let bundleID = "com.kadirgul.KDDownloadManager"

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func open() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
