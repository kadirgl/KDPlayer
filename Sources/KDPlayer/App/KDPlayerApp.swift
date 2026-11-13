import SwiftUI
import SwiftData

@main
struct KDPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let app = AppModel.shared
    private let container: ModelContainer

    /// İzleme geçmişi. Açılamazsa (bozuk ya da uyumsuz) silinmez, yanına yedeklenip yenisi açılır.
    private static func makeContainer() -> ModelContainer {
        #if DEBUG
        // Testler kullanıcının gerçek geçmişine yazmasın.
        let env = ProcessInfo.processInfo.environment
        if env["KD_UITEST"] != nil || env["KD_PERFTEST"] != nil || env["KD_TEMP_HISTORY"] != nil {
            return try! ModelContainer(for: WatchRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        if let path = env["KD_HISTORY_STORE"] {
            return try! ModelContainer(for: WatchRecord.self, configurations: ModelConfiguration(url: URL(fileURLWithPath: path)))
        }
        #endif
        let store = AppInfo.supportDirectory.appendingPathComponent("History.store")
        if let container = try? ModelContainer(for: WatchRecord.self, configurations: ModelConfiguration(url: store)) {
            return container
        }
        let stamp = Int(Date.now.timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: store.path + suffix)
            try? FileManager.default.moveItem(at: file, to: URL(fileURLWithPath: store.path + ".yedek-\(stamp)" + suffix))
        }
        return try! ModelContainer(for: WatchRecord.self, configurations: ModelConfiguration(url: store))
    }

    init() {
        SettingsKey.registerDefaults()
        container = Self.makeContainer()
    }

    var body: some Scene {
        Window("KD Player", id: "main") {
            RootView(app: app)
                .modelContainer(container)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 600, height: 720)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Ayarlar…") { app.openSettings?() }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("Dosya Aç…") { app.presentOpenPanel() }
                    .keyboardShortcut("o")
                Button(app.session.inRoom ? "Oda Paneli" : "Oda Kur") { app.session.presentRoomSetup() }
                    .keyboardShortcut("r")
                    .disabled(app.route != .player)
                Button("Odaya Katıl…") { app.joinPrompt() }
                    .keyboardShortcut("j")
                if app.session.inRoom {
                    Button("Odadan Ayrıl") { app.session.leaveRoom() }
                }
                Divider()
                Button("Başlangıç Ekranı") { app.goHome() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(app.route != .player)
            }
            CommandMenu("Oynatma") {
                Button(app.session.player.isPlaying ? "Duraklat" : "Oynat") { app.session.togglePlayPause() }
                    .disabled(app.route != .player)
                Button("Altyazı Paneli") { app.session.togglePanel(.find) }
                    .disabled(app.route != .player)
                Button("Ses ve Altyazı Parçaları") { app.session.toggleTracks() }
                    .disabled(app.route != .player)
                Divider()
                Button("Resim İçinde Resim") { app.session.toggleMini() }
                    .disabled(app.route != .player)
            }
        }

        // Hazır `Settings` sahnesi kendi başlık çubuğunu çizip trafik ışıklarını kesiyordu; başlıksız pencere.
        Window("Ayarlar", id: "settings") {
            SettingsView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// Pencere içeriği: Başlangıç ya da Oynatıcı.
struct RootView: View {
    let app: AppModel
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch app.route {
            case .home:
                HomeView(app: app)
                    .transition(.opacity)
            case .player:
                PlayerView(session: app.session, onHome: app.goHome)
                    .frame(minWidth: app.session.isMini ? 240 : 640, minHeight: app.session.isMini ? 135 : 400)
                    .transition(.opacity)
            }
        }
        .overlay {
            if let code = app.joinCode {
                JoinRoomView(app: app, code: code, onVideo: app.route == .player)
                    .environment(\.colorScheme, app.route == .player ? .dark : colorScheme)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.25), value: app.route)
        .animation(Theme.spring, value: app.joinCode)
        .background(WindowAccessor { window in
            if app.window !== window { app.window = window }
        })
        .onAppear {
            app.session.modelContext = context
            app.openSettings = { openWindow(id: "settings") }
        }
        .onOpenURL { app.handle(url: $0) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        AppModel.shared.handle(url: url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.session.saveProgress(final: true)
    }

    /// Odadaysa önce odadan ayrıl (son üyeysek oda silinir).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let session = AppModel.shared.session
        guard session.inRoom else { return .terminateNow }
        Task { @MainActor in
            await session.room.leave()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
