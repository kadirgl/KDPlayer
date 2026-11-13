import SwiftUI
import SwiftData

/// Başlangıç (ekran 4 / A1) ve ilk açılış (ekran 11 / A2): dosya bırak/aç, oda koduyla katıl,
/// İzlemeye devam et listesi ya da 3 adımlık tanıtım.
struct HomeView: View {
    let app: AppModel

    @Environment(\.modelContext) private var context
    @Query(sort: \WatchRecord.lastOpened, order: .reverse) private var records: [WatchRecord]
    @State private var roomCode = ""
    @State private var dropTargeted = false
    /// Bulunamayan dosyalar (fileHash). Arka planda bakılır; taşınan dosyanın yeni yeri yer iminden bulunur.
    @State private var missing: Set<String> = []

    /// Son açılan videolar: yarım kalan, bitirilen ve kısa izlenenler dahil (geçmiş "kaybolmasın").
    private var continueItems: [WatchRecord] {
        records.filter(\.isPlayable).prefix(12).map { $0 }
    }

    private var isFirstRun: Bool { continueItems.isEmpty }

    var body: some View {
        #if DEBUG
        let _ = PerfCounters.home += 1
        #endif
        VStack(spacing: 16) {
            header
            dropZone
            joinRoom
            if isFirstRun {
                steps.fixedSize(horizontal: false, vertical: true)
            } else {
                continueSection
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 22)
        .frame(minWidth: 560, idealWidth: 600, minHeight: 560, idealHeight: 720)
        .windowGlass()
        .overlay(alignment: .top) {
            if let toast = app.toasts.current {
                ToastView(toast: toast, center: app.toasts)
                    .padding(.top, 70)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear { app.resizeHome(firstRun: isFirstRun) }
        .task(id: continueItems.map { $0.fileHash + $0.path }) { await locateFiles() }
        .onChange(of: isFirstRun) { _, value in app.resizeHome(firstRun: value) }
        .onChange(of: app.homeShown) { app.resizeHome(firstRun: isFirstRun) }
        .onChange(of: app.windowReady) { app.resizeHome(firstRun: isFirstRun) }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { app.open(url) } }
            }
            return true
        }
    }

    // MARK: Parçalar

    private var header: some View {
        HStack(spacing: 14) {
            TrafficLights(window: app.window)
            Text("KD Player")
                .font(.system(size: 20, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(Theme.textPrimary)
                .padding(.leading, 4)
            Spacer()
            Button { app.openSettings?() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.kdIcon())
            .accessibilityLabel("Ayarlar")
            .help("Ayarlar (⌘,)")
        }
        .frame(height: 44)
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            AppGlyph(size: isFirstRun ? 72 : 64)
            VStack(spacing: 6) {
                Text(isFirstRun ? "Bir film aç, gerisini KD Player halletsin" : "Filmi buraya bırak")
                    .font(.system(size: isFirstRun ? 20 : 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(isFirstRun ? "MKV, MP4, AVI ve diğer tüm formatlar · sürükle bırak da olur" : "Türkçe altyazı otomatik bulunur ve eşleştirilir")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .multilineTextAlignment(.center)
            Button { app.presentOpenPanel() } label: {
                HStack(spacing: 8) {
                    Text("Dosya aç")
                    Kbd("⌘O", onAccent: true)
                }
            }
            .buttonStyle(.kdPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, isFirstRun ? 40 : 30)
        .padding(.horizontal, 24)
        .background(DropZoneBorder(radius: 24, targeted: dropTargeted))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Film aç")
    }

    private var joinRoom: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            TextField(isFirstRun ? "Arkadaşından gelen oda kodu ya da link" : "Oda kodu ya da davet linki", text: $roomCode)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
                .onSubmit(join)
                .accessibilityLabel("Oda kodu")
            Button("Katıl", action: join)
                .buttonStyle(.kd(.raised))
                .disabled(roomCode.trimmingCharacters(in: .whitespaces).count < 6 || !NetworkMonitor.shared.isOnline)
                .help(NetworkMonitor.shared.isOnline ? "Odaya katıl" : "İnternet bağlantısı yok")
        }
        .padding(.leading, 18)
        .padding([.trailing, .vertical], 8)
        .glass(radius: 24)
    }

    private var steps: some View {
        HStack(spacing: 10) {
            StepCard(number: 1, title: "Filmi aç", detail: "Her formatı oynatır")
            StepCard(number: 2, title: "Altyazı kendiliğinden gelir", detail: "Türkçe bulunur, senkronlanır")
            StepCard(number: 3, title: "Oda kur", detail: "Arkadaşlarınla aynı anda izle")
        }
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Son izlenenler").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Geçmişi temizle", action: clearHistory)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 6)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(continueItems) { record in
                        let isMissing = missing.contains(record.fileHash)
                        ContinueRow(record: record, missing: isMissing) {
                            if isMissing { relink(record) } else { app.open(record.url) }
                        }
                        .contextMenu {
                            if !isMissing {
                                Button("Finder'da göster") { NSWorkspace.shared.activateFileViewerSelecting([record.url]) }
                            } else {
                                Button("Dosyanın yerini göster…") { relink(record) }
                            }
                            Button("Geçmişten kaldır", role: .destructive) { remove(record) }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func join() {
        let code = roomCode.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return }
        app.join(code: code)
        roomCode = ""
    }

    /// Dosyalar arka planda aranır; taşınanın kaydı yeni yerine güncellenir, bulunamayan soluk gösterilir.
    private func locateFiles() async {
        let items = continueItems.map { ($0.fileHash, $0.path, $0.bookmark) }
        let states = await Task.detached(priority: .utility) {
            items.map { item in (item.0, RecordLocator.locate(path: item.1, bookmark: item.2)) }
        }.value
        var gone: Set<String> = []
        for (hash, state) in states {
            switch state {
            case .available: break
            case .missing: gone.insert(hash)
            case .moved(let path): records.first { $0.fileHash == hash }?.path = path
            }
        }
        if states.contains(where: { if case .moved = $0.1 { true } else { false } }) { try? context.save() }
        missing = gone
    }

    /// Taşınmış/yeniden adlandırılmış dosyayı kullanıcıya seçtirir; aynı dosyaysa (hash) kayıt kendiliğinden eşleşir.
    private func relink(_ record: WatchRecord) {
        let panel = NSOpenPanel()
        panel.message = "\(record.title) dosyasını bul"
        panel.prompt = "Aç"
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent]
        panel.directoryURL = record.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.open(url)
    }

    private func remove(_ record: WatchRecord) {
        try? FileManager.default.removeItem(at: record.thumbnailURL)
        context.delete(record)
        try? context.save()
    }

    private func clearHistory() {
        for record in records {
            try? FileManager.default.removeItem(at: record.thumbnailURL)
            context.delete(record)
        }
        try? context.save()
    }
}

private struct StepCard: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.accent))
                .padding(.bottom, 4)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineSpacing(2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .padding(14)
        .glass(radius: 20)
    }
}

private struct ContinueRow: View {
    let record: WatchRecord
    var missing = false
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                thumbnail
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(record.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(status)
                            .font(.system(size: 12)).monospacedDigit()
                            .foregroundStyle(missing ? Theme.warning : Theme.textSecondary)
                    }
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.track)
                        GeometryReader { proxy in
                            Capsule().fill(Theme.accent).frame(width: proxy.size.width * record.progress)
                        }
                    }
                    .frame(height: 5)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                .foregroundStyle(Theme.textPrimary)
                Image(systemName: missing ? "magnifyingglass" : record.finished ? "arrow.counterclockwise" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .glass(in: Circle())
                    .accessibilityHidden(true)
            }
            .padding(10)
            .opacity(missing ? 0.6 : 1)
            .glass(radius: 22)
            .brightness(hovering ? 0.03 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .accessibilityLabel(missing ? "\(record.title), dosya bulunamadı, yerini göster" : "\(record.title), \(status)")
        .help(missing ? "Dosya taşınmış ya da silinmiş: tıklayıp yerini göster" : record.path)
    }

    /// "12 dk kaldı" · "İzlendi" · "Dosya bulunamadı"
    private var status: String {
        if missing { return "Dosya bulunamadı" }
        if record.finished || record.position >= record.duration * 0.95 { return "İzlendi" }
        if !record.isResumable { return Format.duration(record.duration) }
        return Format.remainingText(record.remaining)
    }

    private var subtitle: String {
        if missing { return "Taşındıysa tıklayıp yerini göster · \(record.url.deletingLastPathComponent().lastPathComponent)" }
        var parts = record.isResumable ? [Format.time(record.position)] : []
        if !record.detail.isEmpty { parts.append(record.detail) }
        if let language = record.subtitleLanguage, let name = Language.name(for: language) { parts.append("\(name) altyazı") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Group {
            if let image = ThumbnailCache.image(for: record.thumbnailURL) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Palette.gradient(for: record.fileHash)
            }
        }
        .frame(width: 96, height: 56)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.black.opacity(0.2), lineWidth: 0.5))
    }
}

/// Küçük resimler her hover'da diskten okunmasın: dosya değişme tarihine göre bellekte tutulur.
enum ThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for url: URL) -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        guard modified > 0 else { return nil }
        let key = "\(url.path)#\(modified)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
