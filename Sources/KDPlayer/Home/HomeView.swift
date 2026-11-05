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

    private var continueItems: [WatchRecord] {
        records.filter { $0.isResumable && $0.fileExists }.prefix(6).map { $0 }
    }

    private var isFirstRun: Bool { continueItems.isEmpty }

    var body: some View {
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
            SettingsLink {
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
                Text("İzlemeye devam et").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
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
                        ContinueRow(record: record) { app.open(record.url) }
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
                        Text("\(Format.duration(record.remaining)) kaldı")
                            .font(.system(size: 12)).monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
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
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .glass(in: Circle())
                    .accessibilityHidden(true)
            }
            .padding(10)
            .glass(radius: 22)
            .brightness(hovering ? 0.03 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .accessibilityLabel("\(record.title), \(Format.time(record.position)) konumundan devam et")
    }

    private var subtitle: String {
        var parts = [Format.time(record.position)]
        if !record.detail.isEmpty { parts.append(record.detail) }
        if let language = record.subtitleLanguage, let name = Language.name(for: language) { parts.append("\(name) altyazı") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Group {
            if let image = NSImage(contentsOf: record.thumbnailURL) {
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
