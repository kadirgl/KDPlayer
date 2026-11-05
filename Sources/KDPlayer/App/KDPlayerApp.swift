import SwiftUI
import SwiftData

@main
struct KDPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let app = AppModel.shared
    private let container: ModelContainer

    init() {
        SettingsKey.registerDefaults()
        do {
            container = try ModelContainer(for: WatchRecord.self, configurations: ModelConfiguration(url: AppInfo.supportDirectory.appendingPathComponent("History.store")))
        } catch {
            // Bozuk veritabanı: sıfırdan başla (geçmiş kaybolur ama uygulama açılır).
            try? FileManager.default.removeItem(at: AppInfo.supportDirectory.appendingPathComponent("History.store"))
            container = try! ModelContainer(for: WatchRecord.self, configurations: ModelConfiguration(url: AppInfo.supportDirectory.appendingPathComponent("History.store")))
        }
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

        Settings {
            SettingsView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

/// Pencere içeriği: Başlangıç ya da Oynatıcı.
struct RootView: View {
    let app: AppModel
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch app.route {
            case .home:
                HomeView(app: app)
                    .transition(.opacity)
            case .player:
                PlayerView(session: app.session, onHome: app.goHome)
                    .frame(minWidth: 640, minHeight: 400)
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
        .onAppear { app.session.modelContext = context }
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
