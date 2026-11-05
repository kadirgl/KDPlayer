import SwiftUI
import UniformTypeIdentifiers

/// Ayarlar (ekran 13 / A3): Genel · Altyazı · Oda · Kısayollar.
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general, subtitles, room, shortcuts
        var id: Self { self }
        var title: String {
            switch self {
            case .general: "Genel"
            case .subtitles: "Altyazı"
            case .room: "Oda"
            case .shortcuts: "Kısayollar"
            }
        }
    }

    @State private var tab: Tab = .general
    @State private var window: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                TrafficLights(window: window)
                Text("Ayarlar")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.leading, 4)
            }
            .frame(height: 28)
            KDSegmented(selection: $tab, options: Tab.allCases.map { ($0, $0.title) })
            ScrollView {
                Group {
                    switch tab {
                    case .general: GeneralSettings()
                    case .subtitles: SubtitleSettings()
                    case .room: RoomSettings()
                    case .shortcuts: ShortcutSettings()
                    }
                }
                .padding(.bottom, 6)
            }
            .scrollIndicators(.never)
        }
        .padding(20)
        .frame(width: 620, height: 640)
        .windowGlass()
        .background(WindowAccessor { window in
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.hideStandardButtons()
            if self.window !== window { self.window = window }
        })
        .ignoresSafeArea()
    }
}

// MARK: - Ortak

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.top, 4)
            content
        }
    }
}

/// Cam kart içinde, aralarında ince çizgi olan satırlar.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Group {
            if #available(macOS 15, *) {
                VStack(spacing: 0) {
                    Group(subviews: content) { subviews in
                        ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                            if index > 0 { Rectangle().fill(Theme.divider).frame(height: 1) }
                            subview.frame(minHeight: 50).padding(.vertical, 4)
                        }
                    }
                }
            } else {
                VStack(spacing: 4) { content.frame(minHeight: 46) }.padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .glass(radius: 20)
    }
}

/// Satır sonundaki küçük cam buton ("Sor ▾", "Hesap bağla").
struct MiniMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { option in
                Button(option.1) { selection = option.0 }
            }
        } label: {
            HStack(spacing: 4) {
                Text(options.first { $0.0 == selection }?.1 ?? "")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .glass(in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Genel

private struct GeneralSettings: View {
    @Bindable private var appearance = Appearance.shared
    @AppStorage(SettingsKey.resumeMode) private var resumeMode = ResumeMode.ask.rawValue
    @AppStorage(SettingsKey.autoplayNextEpisode) private var autoplayNext = true
    @AppStorage(SettingsKey.hardwareDecodingDisabled) private var hardwareDisabled = false
    @State private var madeDefault = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection(title: "Görünüm") {
                HStack(spacing: 10) {
                    ForEach(AppTheme.allCases) { theme in
                        ThemeTile(theme: theme, selected: appearance.theme == theme) { appearance.theme = theme }
                    }
                }
                Text("Video üzerindeki kontroller okunaklı kalması için her temada koyu cam olarak görünür.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                HStack(spacing: 12) {
                    Text("Vurgu rengi").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    ForEach(AccentChoice.allCases) { choice in
                        Button { appearance.accent = choice } label: {
                            Circle().fill(choice.color)
                                .frame(width: 26, height: 26)
                                .padding(3)
                                .overlay(Circle().strokeBorder(appearance.accent == choice ? choice.color : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.title)
                        .accessibilityAddTraits(appearance.accent == choice ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 54)
                .glass(radius: 20)
            }

            SettingsSection(title: "Oynatma") {
                SettingsCard {
                    HStack {
                        TitleSubtitle(title: "Kaldığın yerden devam", subtitle: "Yarım kalan filmi açınca")
                        Spacer()
                        MiniMenu(selection: $resumeMode, options: ResumeMode.allCases.map { ($0.rawValue, $0.title) })
                    }
                    KDSwitchRow(title: "Sonraki bölümü otomatik oynat", subtitle: "Jenerikte 10 sn geri sayım", isOn: $autoplayNext)
                    KDSwitchRow(
                        title: "Donanım hızlandırma",
                        subtitle: "4K ve HEVC'de pil ve ısı için önerilir",
                        isOn: Binding(get: { !hardwareDisabled }, set: { hardwareDisabled = !$0 })
                    )
                    HStack {
                        TitleSubtitle(title: "Varsayılan oynatıcı", subtitle: madeDefault ? "Video dosyaları KD Player ile açılıyor" : "Video dosyaları KD Player ile açılsın")
                        Spacer()
                        Button(madeDefault ? "Varsayılan" : "Varsayılan yap", action: makeDefault)
                            .buttonStyle(.kd(.glass, height: 30, fontSize: 12.5))
                            .foregroundStyle(Theme.accentInk)
                            .disabled(madeDefault)
                    }
                }
            }

            SettingsSection(title: "Hakkında") {
                SettingsCard {
                    HStack {
                        TitleSubtitle(title: "KD Player \(AppInfo.version)", subtitle: "Oynatma motoru: VLCKit (libVLC 3), LGPL 2.1 lisansıyla dinamik bağlanır")
                        Spacer()
                        if let url = Bundle.main.url(forResource: "VLCKit-LICENSE", withExtension: "txt") {
                            Button("Lisans") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.kd(.glass, height: 30, fontSize: 12.5))
                        }
                    }
                }
            }
        }
    }

    private func makeDefault() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            madeDefault = false
            return
        }
        for type in [UTType.movie, .mpeg4Movie, .quickTimeMovie, .avi] + ["mkv", "webm", "m2ts"].compactMap({ UTType(filenameExtension: $0) }) {
            NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpen: type) { _ in }
        }
        madeDefault = true
    }
}

private struct ThemeTile: View {
    let theme: AppTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview
                    .frame(height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(theme.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background {
                let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
                if selected {
                    shape.fill(Theme.selectedFill)
                        .overlay(shape.strokeBorder(Theme.accent, lineWidth: 2))
                        .shadow(color: Theme.accentGlow, radius: 7, y: 4)
                } else {
                    shape.fill(Theme.glassFill).glassEdge(shape, highlight: Theme.glassHighlight, edge: Theme.glassEdge)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressScale())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var preview: some View {
        let light = Color(hex: 0xF4F2F8), dark = Color(hex: 0x2A2730)
        ZStack(alignment: .topLeading) {
            switch theme {
            case .system: HStack(spacing: 0) { light; dark }
            case .light: light
            case .dark: dark
            }
            VStack(alignment: .leading, spacing: 8) {
                Capsule().fill(theme == .dark ? Color.white.opacity(0.25) : Color.black.opacity(0.12)).frame(height: 6)
                Capsule().fill(Theme.accent).frame(width: 40, height: 6)
            }
            .padding(12)
        }
    }
}

// MARK: - Altyazı

private struct SubtitleSettings: View {
    @AppStorage(SettingsKey.subtitleAutoLoad) private var autoLoad = true
    @AppStorage(SettingsKey.subtitlePreferEmbedded) private var preferEmbedded = true
    @AppStorage(SettingsKey.subtitleAutoSync) private var autoSync = false
    @AppStorage(SettingsKey.subtitleEncoding) private var encoding = "auto"
    @AppStorage(SettingsKey.openSubtitlesAPIKey) private var apiKey = ""
    @State private var languages: [String] = UserDefaults.standard.stringArray(forKey: SettingsKey.subtitleLanguages) ?? ["tr", "en"]

    private let allLanguages = ["tr", "en", "de", "fr", "es", "it", "ru", "ar", "ja", "ko", "pt", "nl"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection(title: "Dil önceliği") {
                SettingsCard {
                    ForEach(Array(languages.enumerated()), id: \.element) { index, code in
                        HStack(spacing: 12) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(Theme.textTertiary)
                            Text("\(index + 1)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(index == 0 ? Theme.accentInk : Theme.textSecondary)
                                .frame(width: 14)
                            Text(Language.name(for: code) ?? code).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text(index == 0 ? "Her zaman ara" : "\(Language.name(for: languages[index - 1]) ?? "") yoksa")
                                .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                            Menu {
                                if index > 0 { Button("Yukarı taşı") { move(index, by: -1) } }
                                if index < languages.count - 1 { Button("Aşağı taşı") { move(index, by: 1) } }
                                if languages.count > 1 { Button("Kaldır", role: .destructive) { remove(index) } }
                            } label: {
                                Image(systemName: "ellipsis").frame(width: 24, height: 24)
                            }
                            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                            .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Menu {
                        ForEach(allLanguages.filter { !languages.contains($0) }, id: \.self) { code in
                            Button(Language.name(for: code) ?? code) { languages.append(code); save() }
                        }
                    } label: {
                        Text("+ Dil ekle").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accentInk)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            SettingsSection(title: "Otomatik") {
                SettingsCard {
                    KDSwitchRow(title: "Film açılınca altyazıyı bul ve yükle", subtitle: "Birebir eşleşme varsa sormadan açılır", isOn: $autoLoad)
                    KDSwitchRow(title: "Önce dosyanın içindekini kullan", subtitle: "Gömülü ya da yanındaki .srt varsa internete bakılmaz", isOn: $preferEmbedded)
                    KDSwitchRow(title: "Her altyazıda otomatik senkron", subtitle: "Ses analiziyle hizalama sonraki sürümde geliyor", isOn: $autoSync)
                        .disabled(true)
                    HStack {
                        TitleSubtitle(title: "Karakter kodlaması", subtitle: "Bozuk Türkçe karakterleri düzeltir")
                        Spacer()
                        MiniMenu(selection: $encoding, options: SubtitleTextDecoder.Preference.allCases.map { ($0.rawValue, $0.title) })
                    }
                }
            }

            SettingsSection(title: "Kaynaklar") {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        TitleSubtitle(
                            title: "OpenSubtitles",
                            subtitle: apiKey.isEmpty ? "İnternetten altyazı için API anahtarı gerekli · opensubtitles.com › API consumers" : "Anahtar kayıtlı · hesapsız günlük 5 indirme"
                        )
                        HStack(spacing: 8) {
                            SecureField("API anahtarı", text: $apiKey)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textPrimary)
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .glass(in: Capsule())
                            Link("Anahtar al", destination: URL(string: "https://www.opensubtitles.com/consumers")!)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Theme.accentInk)
                        }
                    }
                    .padding(.vertical, 8)
                    KDSwitchRow(title: "Subdl", subtitle: "Kullanım şartları doğrulanınca açılacak", isOn: .constant(false)).disabled(true)
                    KDSwitchRow(title: "Podnapisi", subtitle: "Kullanım şartları doğrulanınca açılacak", isOn: .constant(false)).disabled(true)
                }
            }
        }
    }

    private func move(_ index: Int, by offset: Int) {
        languages.swapAt(index, index + offset)
        save()
    }

    private func remove(_ index: Int) {
        languages.remove(at: index)
        save()
    }

    private func save() {
        UserDefaults.standard.set(languages, forKey: SettingsKey.subtitleLanguages)
    }
}

// MARK: - Oda

private struct RoomSettings: View {
    @AppStorage(SettingsKey.displayName) private var displayName = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    @AppStorage(SettingsKey.roomDefaultControl) private var control = "everyone"
    @AppStorage(SettingsKey.roomAutoAcceptSubtitle) private var autoAccept = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection(title: "Kimlik") {
                SettingsCard {
                    HStack {
                        TitleSubtitle(title: "Görünen ad", subtitle: "Odadakiler seni bu adla görür")
                        Spacer()
                        TextField("Adın", text: $displayName)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 180)
                    }
                }
            }
            SettingsSection(title: "Yeni oda") {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        TitleSubtitle(title: "Varsayılan kontrol", subtitle: "Oynat, durdur ve sar kimde")
                        KDSegmented(selection: $control, options: [("everyone", "Herkes kontrol eder"), ("host", "Sadece ben")], style: .neutral)
                    }
                    .padding(.vertical, 8)
                    KDSwitchRow(title: "Paylaşılan altyazıyı sormadan kullan", subtitle: "Biri altyazı paylaşınca karşılaştırma kartı açılmaz", isOn: $autoAccept)
                }
            }
            HStack(spacing: 8) {
                Circle().fill(RoomService.isConfigured ? Theme.success : Theme.warning).frame(width: 8, height: 8)
                Text(RoomService.isConfigured
                     ? "Birlikte izleme hazır. Video paylaşılmaz; odada yalnızca oynatma durumu, altyazı ve sohbet dolaşır."
                     : "Bu sürümde birlikte izleme kullanılamıyor.")
            }
            .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).padding(.horizontal, 6)
        }
    }
}

// MARK: - Kısayollar

private struct ShortcutSettings: View {
    private let rows: [(String, String)] = [
        ("Oynat / duraklat", "Space"), ("10 sn geri / ileri", "← / →"), ("60 sn geri / ileri", "⇧← / ⇧→"),
        ("Ses", "↑ / ↓"), ("Sessiz", "M"), ("Hız", "[ / ]  ·  \\ normal"), ("Altyazı gecikmesi", "G / H"),
        ("Ses parçası döngüsü", "A"), ("Altyazı döngüsü / paneli", "S / ⇧S"), ("Tam ekran", "F  ·  ⌃⌘F"),
        ("Resim içinde resim", "P"), ("Dosya aç", "⌘O"), ("Ayarlar", "⌘,"), ("Kare kare", ",  /  ."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection(title: "Klavye") {
                SettingsCard {
                    ForEach(rows, id: \.0) { row in
                        HStack {
                            Text(row.0).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Kbd(row.1)
                        }
                    }
                }
            }
            SettingsSection(title: "Jestler") {
                SettingsCard {
                    HStack { Text("Videoya tek tık").font(.system(size: 13, weight: .semibold)); Spacer(); Text("Oynat / duraklat").font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
                    HStack { Text("Sol / sağ yarıya çift tık").font(.system(size: 13, weight: .semibold)); Spacer(); Text("10 sn geri / ileri").font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
                    HStack { Text("Ortaya çift tık").font(.system(size: 13, weight: .semibold)); Spacer(); Text("Tam ekran").font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
                    HStack { Text("İki parmak dikey kaydırma").font(.system(size: 13, weight: .semibold)); Spacer(); Text("Ses").font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
                }
                .foregroundStyle(Theme.textPrimary)
            }
            Text("Mesaj alanına odaklıyken tek tuşlu kısayollar devre dışı kalır. Medya tuşları ve Now Playing desteklenir.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).padding(.horizontal, 6)
        }
    }
}
