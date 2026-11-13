#if DEBUG
import AppKit
import QuartzCore
import SwiftUI
import Darwin

/// Görünüm yeniden çizim sayaçları (performans ölçümü; yalnızca debug).
enum PerfTimeline {
    nonisolated(unsafe) static var marks: [(String, CFTimeInterval)] = []
    static func mark(_ name: String) { marks.append((name, CACurrentMediaTime())) }
    static func dump() -> String {
        guard let first = marks.first?.1 else { return "" }
        return marks.map { "\($0.0)=\(Int(($0.1 - first) * 1000))" }.joined(separator: " ")
    }
}

enum PerfCounters {
    nonisolated(unsafe) static var playerView = 0
    nonisolated(unsafe) static var playerContent = 0
    nonisolated(unsafe) static var controlBar = 0
    nonisolated(unsafe) static var subtitleOverlay = 0
    nonisolated(unsafe) static var home = 0

    static func snapshot() -> [String: Int] {
        ["PlayerContent": playerContent, "PlayerView": playerView, "ControlBar": controlBar, "SubtitleOverlay": subtitleOverlay, "Home": home]
    }
}

/// Uçtan uca UI turu: `KD_UITEST=<video>` ile açılınca her ekranı sırayla gösterir, kısayolları gerçek
/// klavye olaylarıyla tetikler ve beklentileri denetler. Her adım `KD_UITEST_LOG` dosyasına
/// "STEP ad pencere-no" olarak yazılır (dışarıdan ekran görüntüsü alınır); denetimler "CHECK".
@MainActor
enum UITestTour {
    private static let env = ProcessInfo.processInfo.environment
    private static var logURL: URL { URL(fileURLWithPath: env["KD_UITEST_LOG"] ?? "/tmp/kd-uitest.log") }
    private static var failures = 0

    static func runIfRequested(app: AppModel) {
        if let path = env["KD_UITEST"] {
            try? "".write(to: logURL, atomically: true, encoding: .utf8)
            Task { await tour(app: app, video: URL(fileURLWithPath: path)) }
        } else if let path = env["KD_PERFTEST"] {
            try? "".write(to: logURL, atomically: true, encoding: .utf8)
            Task { await perf(app: app, video: URL(fileURLWithPath: path)) }
        }
    }

    // MARK: Yardımcılar

    private static func log(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Adımı bildirip ekran görüntüsü için bekler.
    private static func step(_ name: String, _ window: NSWindow?, settle: Double = 1.2, hold: Double = 1.3) async {
        await sleep(settle)
        log("STEP \(name) \(window?.windowNumber ?? 0)")
        await sleep(hold)
    }

    private static func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1 }
        log("CHECK \(condition ? "ok" : "FAIL") \(message)")
    }

    /// Gerçek bir keyDown olayı üretip oturumun kısayol işleyicisine verir.
    @discardableResult
    private static func key(_ characters: String, code: UInt16, shift: Bool = false, session: PlayerSession) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: session.window?.windowNumber ?? 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ) else { return false }
        return session.handleKey(event)
    }

    private static var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.title == "Ayarlar" && $0.isVisible }
    }

    // MARK: Tur

    private static func tour(app: AppModel, video: URL) async {
        await sleep(2)
        let session = app.session
        await step("01-home", app.window)

        // Ayarlar
        app.openSettings?()
        await sleep(1)
        check(settingsWindow != nil, "Ayarlar penceresi açıldı")
        if let settings = settingsWindow {
            let close = settings.standardWindowButton(.closeButton)
            check(close == nil || close?.isHidden == true, "Ayarlar'da sistem trafik ışıkları gizli")
        }
        for tab in SettingsView.Tab.allCases {
            SettingsRouter.shared.tab = tab
            await step("02-settings-\(tab.rawValue)", settingsWindow)
        }
        let originalTheme = Appearance.shared.theme
        Appearance.shared.theme = .light
        SettingsRouter.shared.tab = .general
        await step("03-settings-light", settingsWindow)
        app.window?.makeKeyAndOrderFront(nil)
        await step("03-home-light", app.window)
        Appearance.shared.theme = .dark
        await step("03-home-dark", app.window)
        Appearance.shared.theme = originalTheme
        settingsWindow?.close()

        // Oynatıcı
        app.open(video)
        await sleep(4)
        check(app.route == .player, "Dosya açılınca oynatıcı ekranı")
        if session.resumePrompt != nil { session.resume(fromStart: true) }
        await sleep(1.5)
        check(session.player.isPlaying, "Video oynuyor")
        check(session.player.duration > 0, "Süre okundu (\(Int(session.player.duration)) sn)")
        check(session.player.videoSize.width > 0, "Görüntü boyutu \(Int(session.player.videoSize.width))×\(Int(session.player.videoSize.height))")
        session.userActivity()
        await step("10-player", app.window, settle: 0.3)

        let volume = session.player.volume
        key("", code: 126, session: session)
        check(session.player.volume == min(100, volume + 5), "↑ ses +5 (\(volume) → \(session.player.volume))")
        await step("11-hud-volume", app.window, settle: 0.2, hold: 0.6)
        key("", code: 125, session: session)

        let before = session.player.time
        key("", code: 124, session: session)
        await sleep(0.8)
        check(session.player.time - before > 8, "→ 10 sn ileri (\(Int(before)) → \(Int(session.player.time)))")
        await step("12-hud-seek", app.window, settle: 0.1, hold: 0.5)

        key("]", code: 30, session: session)
        check(session.player.rate == 1.25, "] hız 1,25×")
        await step("13-hud-rate", app.window, settle: 0.2, hold: 0.6)
        key("\\", code: 42, session: session)
        check(session.player.rate == 1, "\\ hız normale döndü")

        if session.subtitles.hasSubtitle {
            let offset = session.subtitles.timing.offsetMilliseconds
            key("h", code: 4, session: session)
            check(session.subtitles.timing.offsetMilliseconds == offset + 100, "H altyazı +100 ms")
            await step("14-hud-subtitle-delay", app.window, settle: 0.2, hold: 0.6)
            key("g", code: 5, session: session)
            check(session.subtitles.timing.offsetMilliseconds == offset, "G altyazı −100 ms")
        } else {
            check(false, "Altyazı otomatik yüklendi")
        }

        key("m", code: 46, session: session)
        check(session.player.muted, "M sessiz")
        key("m", code: 46, session: session)
        check(!session.player.muted, "M sesi açtı")

        key(" ", code: 49, session: session)
        await sleep(0.8)
        check(!session.player.isPlaying, "Space duraklattı")
        await step("15-paused", app.window, settle: 0.2)
        key(" ", code: 49, session: session)
        await sleep(0.8)
        check(session.player.isPlaying, "Space devam ettirdi")

        session.toggleTracks()
        await step("20-tracks", app.window)
        check(session.tracksOpen, "Parça popover'ı açık")
        key("", code: 53, session: session)
        check(!session.tracksOpen, "Esc popover'ı kapattı")

        for tab in PlayerSession.PanelTab.allCases {
            session.togglePanel(tab)
            if session.panel != tab { session.togglePanel(tab) }
            await step("21-panel-\(tab.rawValue)", app.window)
        }
        session.panel = .sync
        session.listeningForSpeech = true
        await step("22-sync-listen", app.window)
        session.listeningForSpeech = false
        session.panel = .appearance
        let style = SubtitleStyleStore.shared.style
        SubtitleStyleStore.shared.style.look = .box
        SubtitleStyleStore.shared.style.color = .yellow
        SubtitleStyleStore.shared.style.size = .extraLarge
        await step("23-appearance-box", app.window)
        SubtitleStyleStore.shared.style = style
        key("", code: 53, session: session)
        check(session.panel == nil, "Esc paneli kapattı")

        session.toggleMini()
        await step("30-mini", app.window, settle: 1.5)
        check(session.isMini, "Resim içinde resim açık")
        check((app.window?.frame.width ?? 999) <= 490, "Mini pencere küçüldü (\(Int(app.window?.frame.width ?? 0)) pt)")
        session.toggleMini()
        await sleep(1)
        check(!session.isMini, "Resim içinde resim kapandı")

        session.presentRoomSetup()
        await step("40-room-setup", app.window)
        session.cancelRoomSetup()
        await sleep(0.8)
        check(session.player.isPlaying, "Oda kur'dan vazgeçince film devam etti")

        app.join(code: "ZZZZ22")
        await step("41-join-notfound", app.window, settle: 4)
        app.joinCode = nil

        // Kontrollerin kendiliğinden gizlenmesi
        session.panel = nil
        session.hoveringControls = false
        session.userActivity()
        await sleep(3.4)
        check(!session.controlsVisible, "Kontroller 2,5 sn sonra gizlendi")
        await step("42-controls-hidden", app.window, settle: 0.1)

        // Kaldığın yerden devam
        if !session.player.isPlaying { session.player.play() }
        session.player.seek(to: 90)
        await sleep(1)
        session.saveProgress(final: true)
        app.goHome()
        await sleep(1)
        app.open(video)
        await sleep(3)
        check(session.resumePrompt != nil, "Kaldığın yerden devam kartı çıktı")
        await step("50-resume", app.window, settle: 0.2)
        session.resume(fromStart: false)
        await sleep(1)
        // Kart engellemez: film açılır açılmaz kaldığı yerden oynar.
        check(session.player.isPlaying && (88...100).contains(session.player.time), "Kaldığı yerden açıldı (\(Int(session.player.time)) sn)")

        // Bozuk dosya
        let broken = FileManager.default.temporaryDirectory.appendingPathComponent("Bozuk.Film.2024.mkv")
        try? Data(repeating: 0x42, count: 4096).write(to: broken)
        app.open(broken)
        await step("60-broken-file", app.window, settle: 9.5)
        check(session.blockingError != nil, "Bozuk dosyada hata kartı")

        app.goHome()
        await step("70-home-continue", app.window, settle: 1.5)
        check(app.route == .home, "Başlangıç ekranına dönüldü")

        log("DONE failures=\(failures)")
    }

    // MARK: Performans

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    private static func measure(_ name: String, seconds: Double, during: (() -> Void)? = nil) async {
        let counters = PerfCounters.snapshot()
        let cpu = cpuSeconds()
        let start = Date.now
        let ticker = during.map { action in
            Task { @MainActor in
                while !Task.isCancelled {
                    action()
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
        }
        await sleep(seconds)
        ticker?.cancel()
        let elapsed = Date.now.timeIntervalSince(start)
        let deltas = PerfCounters.snapshot().map { "\($0.key)=\(String(format: "%.1f", Double($0.value - (counters[$0.key] ?? 0)) / elapsed))/s" }.sorted()
        log("PERF \(name) cpu=\(String(format: "%.1f", (cpuSeconds() - cpu) / elapsed * 100))% rss=\(Int(residentMB()))MB \(deltas.joined(separator: " "))")
    }

    private static func perf(app: AppModel, video: URL) async {
        await sleep(2)
        await measure("home-idle", seconds: 5)
        let launch = Date.now
        PerfTimeline.marks = []
        PerfTimeline.mark("start")
        app.open(video)
        while !app.session.player.hasVideoFrame && Date.now.timeIntervalSince(launch) < 10 { await sleep(0.005) }
        PerfTimeline.mark("firstFrameSeen")
        log("PERF open-to-play \(Int(Date.now.timeIntervalSince(launch) * 1000))ms")
        log("PERF timeline \(PerfTimeline.dump())")
        let session = app.session
        if session.resumePrompt != nil { session.resume(fromStart: true) }
        await sleep(2)
        session.userActivity()
        await measure("playing-controls-visible", seconds: 2)
        await sleep(2)
        await measure("playing-controls-hidden", seconds: 8)
        // Fare hareketi: onContinuousHover'ın her olayda yaptığı işin bedeli.
        await measure("playing-mouse-moving", seconds: 6) { session.userActivity() }
        session.togglePanel(.find)
        await measure("playing-panel-open", seconds: 8)
        session.panel = .sync
        await measure("playing-sync-strip", seconds: 8)
        session.panel = nil
        session.player.pause()
        await sleep(1)
        await measure("paused", seconds: 6)
        // Seek gecikmesi: hedefe varana kadar geçen süre.
        session.player.play()
        await sleep(1)
        for target in [30.0, 90.0, 140.0] {
            let start = Date.now
            session.player.seek(to: target)
            while abs(session.player.time - target) > 0.6 && Date.now.timeIntervalSince(start) < 5 { await sleep(0.01) }
            await sleep(0.0)
            log("PERF seek-\(Int(target)) \(Int(Date.now.timeIntervalSince(start) * 1000))ms")
        }
        app.goHome()
        await sleep(1.5)
        await measure("home-after", seconds: 5)
        // Bellek: 5 kez aç / kapat.
        for cycle in 1...5 {
            let begin = Date.now
            app.open(video)
            while !session.player.hasVideoFrame && Date.now.timeIntervalSince(begin) < 10 { await sleep(0.005) }
            log("PERF reopen-\(cycle) \(Int(Date.now.timeIntervalSince(begin) * 1000))ms prompt=\(session.resumePrompt != nil)")
            if session.resumePrompt != nil { session.resume(fromStart: true) }
            await sleep(2)
            app.goHome()
            await sleep(1.5)
            log("PERF cycle-\(cycle) rss=\(Int(residentMB()))MB")
        }
        log("DONE")
    }
}
#endif
