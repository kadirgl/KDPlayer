import SwiftUI
import UniformTypeIdentifiers
import Observation

/// Uygulamanın kök durumu: hangi ekran açık, tek pencere ve oynatma oturumu.
@Observable
final class AppModel {
    enum Route { case home, player }

    static let shared = AppModel()

    private(set) var route: Route = .home
    /// Başlangıç ekranı her gösterildiğinde artar (pencere boyunu içeriğe göre ayarlamak için).
    private(set) var homeShown = 0
    let session = PlayerSession()
    let toasts = ToastCenter()
    /// Uygulama, pencere hazır olmadan önce bir dosyayla açıldıysa.
    @ObservationIgnored private var pendingURL: URL?
    /// Pencere hazır olunca true (görünümler pencere boyunu ayarlayabilsin diye gözlemlenir).
    private(set) var windowReady = false
    @ObservationIgnored weak var window: NSWindow? {
        didSet {
            guard window !== oldValue, let window else { return }
            configure(window)
            windowReady = true
            MainActor.assumeIsolated { startUpdateChecks() }
            // Pencere çizildikten sonra libVLC'yi ısıt.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [session] in session.player.warmUp() }
            #if DEBUG
            MainActor.assumeIsolated { UITestTour.runIfRequested(app: self) }
            #endif
            if let pendingURL {
                self.pendingURL = nil
                open(pendingURL)
            }
        }
    }

    private init() {
        session.onOpenFilePanel = { [weak self] in self?.presentOpenPanel() }
    }

    // MARK: Gezinme

    func open(_ url: URL) {
        guard window != nil else {
            pendingURL = url
            return
        }
        if AppInfo.subtitleExtensions.contains(url.pathExtension.lowercased()) {
            if route == .player, session.subtitles.loadUserFile(url) {
                session.toasts.show(Toast(kind: .success, title: "Altyazı eklendi", subtitle: url.lastPathComponent))
            }
            return
        }
        let wasHome = route == .home
        #if DEBUG
        PerfTimeline.mark("app.open")
        #endif
        route = .player
        session.open(url)
        if wasHome { resizeForPlayer() }
        window?.makeKeyAndOrderFront(nil)
        #if DEBUG
        debugRoomHooks()
        // Ekran görüntüsü için belirli ana sar: KD_DEBUG_SEEK=142 (oda testinden bağımsız).
        if let seek = ProcessInfo.processInfo.environment["KD_DEBUG_SEEK"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [session] in
                if session.resumePrompt != nil { session.resume(fromStart: false) }
                session.player.seek(to: seek)
            }
        }
        // Ses parçası denemesi: KD_DEBUG_AUDIO=1 (VLC parça kimliği)
        if let id = ProcessInfo.processInfo.environment["KD_DEBUG_AUDIO"].flatMap(Int32.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [session] in session.player.selectAudio(id) }
        }
        // Küçük pencere denemesi: KD_DEBUG_SIZE=640x400
        if let raw = ProcessInfo.processInfo.environment["KD_DEBUG_SIZE"] {
            let parts = raw.split(separator: "x").compactMap { Double($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard parts.count == 2, let window = self?.window else { return }
                window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - parts[1], width: parts[0], height: parts[1]), display: true)
            }
        }
        // Ekran görüntüsü için: KD_DEBUG_UI=find|sync|appearance|tracks
        if let ui = ProcessInfo.processInfo.environment["KD_DEBUG_UI"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [session] in
                if ui == "tracks" { session.toggleTracks() } else if let tab = PlayerSession.PanelTab(rawValue: ui) { session.togglePanel(tab) }
            }
        }
        #endif
    }

    func goHome() {
        session.close()
        if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
        route = .home
        resize(to: CGSize(width: 600, height: 720))
        homeShown += 1
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent] + AppInfo.videoExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.prompt = "Aç"
        panel.message = "Oynatılacak videoyu seç"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// Ayarlar penceresini açar (RootView `openWindow` ile doldurur).
    @ObservationIgnored var openSettings: (() -> Void)?

    /// Davetle katılma ekranı açıkken oda kodu (ekran 12).
    var joinCode: String?

    /// `kdplayer://join/<kod>` davet linkleri ve dosya açma.
    func handle(url: URL) {
        if url.isFileURL {
            open(url)
            return
        }
        guard url.scheme == "kdplayer" else { return }
        join(code: url.absoluteString)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Oda kodu, davet linki ya da web linkiyle katılma ekranını açar.
    func join(code raw: String) {
        let code = RoomService.normalize(raw)
        guard code.count == 6 else {
            toasts.show("Oda kodu 6 karakter olmalı", subtitle: "Örnek: K7X2QM")
            return
        }
        guard RoomService.isConfigured else {
            let target = route == .player ? session.toasts : toasts
            target.show(Toast(kind: .warning, title: "Birlikte izleme şu an kullanılamıyor", subtitle: "Bu sürümde oda sunucusu yok; güncel sürümü indir"))
            return
        }
        withAnimation(Theme.spring) { joinCode = code }
    }

    /// Menüden "Odaya Katıl…": panodaki davet linkini ya da yazılan kodu kullanır.
    func joinPrompt() {
        if let text = NSPasteboard.general.string(forType: .string), text.contains("kdplayer") {
            join(code: text)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Odaya katıl"
        alert.informativeText = "Arkadaşından gelen oda kodunu ya da davet linkini yapıştır."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "K7X2QM"
        alert.accessoryView = field
        alert.addButton(withTitle: "Katıl")
        alert.addButton(withTitle: "Vazgeç")
        if alert.runModal() == .alertFirstButtonReturn { join(code: field.stringValue) }
    }

    #if DEBUG
    /// Uçtan uca oda testi: KD_DEBUG_ROOM=create|join:KOD, KD_DEBUG_CODE, KD_DEBUG_ACTIONS=1
    private func debugRoomHooks() {
        let env = ProcessInfo.processInfo.environment
        if let command = env["KD_DEBUG_ROOM"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [session] in
                Task { @MainActor in
                    if let start = env["KD_DEBUG_START"].flatMap(Double.init) {
                        session.resume(fromStart: false)
                        session.player.seek(to: start)
                    }
                    if command == "create" {
                        _ = await session.createRoom(name: "Test odası", controlMode: .everyone, shareSubtitle: true, readyCheck: env["KD_DEBUG_READY"] != nil,
                                                     locked: false, code: env["KD_DEBUG_CODE"] ?? "TEST22")
                    } else if command.hasPrefix("join:") {
                        _ = await session.joinRoom(code: String(command.dropFirst(5)))
                    }
                }
            }
        }
        if env["KD_DEBUG_ACTIONS"] != nil {
            let steps: [(Double, () -> Void)] = [
                (12, { [session] in session.togglePlayPause() }),
                (16, { [session] in session.seek(by: 60) }),
                (20, { [session] in session.togglePlayPause() }),
                (24, { [session] in session.room.send(text: "şu sahneye bakın 1:05") }),
                (26, { [session] in session.sendReaction("😂") }),
            ]
            for (delay, step) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: step) }
        }
    }
    #endif

    // MARK: Güncelleme

    @MainActor
    private func startUpdateChecks() {
        let updater = AppUpdater.shared
        updater.onAvailable = { [weak self] release in
            guard let self else { return }
            let toast = Toast(kind: .info, title: "KD Player \(release.version) çıktı", subtitle: "Ayarlar › Genel'den kurabilirsin", actions: [
                Toast.Action(title: "Göster", emphasized: true) { [weak self] in
                    SettingsRouter.shared.tab = .general
                    SettingsRouter.shared.focus = "updates"
                    self?.openSettings?()
                },
            ], duration: 8)
            (self.route == .player ? self.session.toasts : self.toasts).show(toast)
        }
        updater.startAutomaticChecks()
        #if DEBUG
        updater.runSelfTestIfRequested()
        if ProcessInfo.processInfo.environment["KD_DEBUG_OPEN_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                SettingsRouter.shared.focus = "updates"
                self?.openSettings?()
            }
        }
        #endif
    }

    // MARK: Pencere

    private func configure(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.hideStandardButtons()
        Appearance.shared.apply()
    }

    /// Başlangıç penceresi: geçmiş varsa 720, ilk açılışta içerik kadar.
    func resizeHome(firstRun: Bool) {
        guard route == .home else { return }
        resize(to: CGSize(width: 600, height: firstRun ? 640 : 720))
    }

    private func resizeForPlayer() {
        let screen = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1200, screen.width * 0.86)
        resize(to: CGSize(width: width, height: width * 0.65))
    }

    private func resize(to size: CGSize) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let current = window.targetFrame
        let center = CGPoint(x: current.midX, y: current.midY)
        let screen = window.screen?.visibleFrame ?? .zero
        var frame = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        if screen != .zero {
            frame.origin.x = frame.origin.x.clamped(to: screen.minX...max(screen.minX, screen.maxX - frame.width))
            frame.origin.y = frame.origin.y.clamped(to: screen.minY...max(screen.minY, screen.maxY - frame.height))
        }
        window.animateFrame(to: frame)
    }
}
