import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Davetle katılma (ekran 12 / A5): oda bilgisi, eşleşen dosya önerisi, görünen ad.
struct JoinRoomView: View {
    let app: AppModel
    let code: String
    /// Video üzerinde mi (koyu cam) yoksa Başlangıç penceresinde mi.
    let onVideo: Bool

    @Query(sort: \WatchRecord.lastOpened, order: .reverse) private var records: [WatchRecord]
    @State private var preview: RoomService.Preview?
    @State private var error: String?
    @State private var match: RoomFileMatcher.Match?
    @State private var searching = true
    @State private var chosenURL: URL?
    @State private var name = ""
    @State private var joining = false
    @State private var appeared = false

    private var session: PlayerSession { app.session }

    var body: some View {
        ZStack {
            Color.black.opacity(onVideo ? 0.55 : 0.3).onTapGesture { close() }
            card
                .scaleEffect(appeared ? 1 : 0.96)
                .opacity(appeared ? 1 : 0)
        }
        .task { await load() }
        .onAppear {
            name = session.displayName
            withAnimation(Theme.spring) { appeared = true }
        }
    }

    @ViewBuilder private var card: some View {
        let content = VStack(alignment: .leading, spacing: 18) {
            if let preview {
                header(preview)
                mediaCard(preview)
                fileSection(preview)
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("Odada görünen adın")
                    TextField("Adın", text: $name)
                        .textFieldStyle(.plain).font(.system(size: 14))
                        .padding(.horizontal, 14).frame(height: 44)
                        .glass(radius: 16)
                }
                footer(preview)
            } else if let error {
                VStack(spacing: 12) {
                    Image(systemName: "person.2.slash").font(.system(size: 26)).frame(width: 56, height: 56).glass(in: Circle())
                    Text(error).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
                    Text("Kod: \(code)").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).monospacedDigit()
                    Button("Kapat") { close() }.buttonStyle(.kdGlass)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                HStack(spacing: 12) {
                    KDSpinner()
                    Text("Oda aranıyor · \(code)").font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(24)
        .frame(width: 560)
        .fittingVertically()

        if onVideo {
            content.overlayGlass(radius: 30).padding(.vertical, 16)
        } else {
            content.windowGlass(radius: 30).shadow(color: Theme.shadow, radius: 30, y: 16).padding(.vertical, 16)
        }
    }

    private func header(_ preview: RoomService.Preview) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: -8) {
                ForEach(preview.members.prefix(4)) { member in
                    KDAvatar(initial: member.initial, color: member.color, size: 30)
                        .overlay(Circle().strokeBorder(onVideo ? Color(hex: 0x2A2730) : Color(hex: 0xF6F4FA), lineWidth: 2.5))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(preview.meta.name).font(.system(size: 20, weight: .semibold)).tracking(-0.3)
                Text(inviteLine(preview)).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func inviteLine(_ preview: RoomService.Preview) -> String {
        let host = preview.members.first { $0.id == preview.meta.createdBy }?.name ?? preview.members.first?.name ?? "Biri"
        var parts = ["\(host) davet etti", "\(preview.members.count) kişi içeride"]
        if let position = preview.playback?.expectedPosition(serverNow: preview.serverNow), position > 5 {
            parts.append("film \(Format.time(position))'ta")
        }
        if preview.meta.locked { parts.append("kilitli") }
        return parts.joined(separator: " · ")
    }

    private func mediaCard(_ preview: RoomService.Preview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldLabel("Odada izlenen")
            HStack(spacing: 12) {
                MediaThumb(seed: preview.media?.fileHash ?? preview.meta.name)
                VStack(alignment: .leading, spacing: 3) {
                    Text(preview.media?.title ?? "Bilinmeyen film").font(.system(size: 14, weight: .semibold))
                    Text(([preview.media?.detail ?? ""] + (preview.hasSubtitle ? ["altyazı odadan gelecek"] : [])).filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
            }
        }
        .padding(12)
        .glass(radius: 20)
    }

    @ViewBuilder private func fileSection(_ preview: RoomService.Preview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel("Senin dosyan")
            if let url = chosenURL ?? match?.url {
                let exact = chosenURL == nil ? (match?.exact ?? false) : false
                HStack(spacing: 12) {
                    Image(systemName: exact ? "checkmark" : "film")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.accent))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Text(chosenURL != nil ? "Seçtiğin dosya · süre katılınca doğrulanır" : match?.reason ?? "")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .glass(.selected, radius: 20)
            } else if searching {
                HStack(spacing: 10) {
                    KDSpinner(size: 18)
                    Text("Dosyan aranıyor…").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 14).frame(height: 56)
            } else {
                Text("Bu film bilgisayarında bulunamadı. Aynı sürümü seç; herkes kendi dosyasını oynatır.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).padding(.horizontal, 4)
            }
            Button("Başka dosya seç…", action: pickFile)
                .buttonStyle(.kd(.glass, fontSize: 13, fullWidth: true))
        }
    }

    private func footer(_ preview: RoomService.Preview) -> some View {
        HStack(spacing: 10) {
            if let position = preview.playback?.expectedPosition(serverNow: preview.serverNow), position > 5 {
                Text("Katılınca film \(Format.time(position))'tan başlar").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            } else if preview.meta.locked {
                Text("Oda sahibinin onayı gerekecek").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Vazgeç") { close() }.buttonStyle(.kdGlass).keyboardShortcut(.cancelAction)
            Button {
                Task { await join() }
            } label: {
                if joining { ProgressView().controlSize(.small).frame(width: 90) } else { Text("Odaya katıl") }
            }
            .buttonStyle(.kdPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(joining || (chosenURL ?? match?.url) == nil || !NetworkMonitor.shared.isOnline)
        }
    }

    // MARK: Eylemler

    private func load() async {
        do {
            let preview = try await session.room.preview(code: code)
            withAnimation(Theme.spring) { self.preview = preview }
            let found = await RoomFileMatcher.find(media: preview.media, current: session.url, currentHash: session.record?.fileHash, records: records)
            withAnimation(Theme.spring) {
                match = found
                searching = false
            }
        } catch {
            withAnimation(Theme.spring) { self.error = error.localizedDescription }
        }
    }

    private func join() async {
        guard let url = chosenURL ?? match?.url else { return }
        joining = true
        UserDefaults.standard.set(name.trimmingCharacters(in: .whitespaces), forKey: SettingsKey.displayName)
        if session.url != url { app.open(url) }
        if await session.joinRoom(code: code) {
            app.joinCode = nil
        }
        joining = false
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video] + AppInfo.videoExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Seç"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chosenURL = url
    }

    private func close() {
        withAnimation(Theme.spring) { app.joinCode = nil }
    }
}

/// Odadaki filmle aynı dosyayı bulur: açık dosya → geçmiş (hash) → son klasörler (hash) → ad benzerliği.
enum RoomFileMatcher {
    struct Match: Equatable {
        let url: URL
        let exact: Bool
        let reason: String
    }

    static func find(media: RoomMedia?, current: URL?, currentHash: String?, records: [WatchRecord]) async -> Match? {
        guard let media else { return nil }
        if let hash = media.fileHash {
            if let current, currentHash == hash { return Match(url: current, exact: true, reason: "Şu an açık · birebir aynı dosya") }
            if let record = records.first(where: { $0.fileHash == hash && $0.fileExists }) {
                return Match(url: record.url, exact: true, reason: "İzleme geçmişinde bulundu · birebir aynı")
            }
        }
        let folders = Set(records.map { $0.url.deletingLastPathComponent() } + [
            FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first,
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
            FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first,
        ].compactMap { $0 })
        let title = media.title.components(separatedBy: " · ").first?.lowercased() ?? media.title.lowercased()
        let hash = media.fileHash
        return await Task.detached(priority: .userInitiated) {
            var nameMatch: URL?
            var scanned = 0
            for folder in folders {
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                for file in files where AppInfo.videoExtensions.contains(file.pathExtension.lowercased()) {
                    scanned += 1
                    if scanned > 400 { break }
                    if let hash, (try? MovieHash.compute(for: file)) == hash {
                        return Match(url: file, exact: true, reason: "\(folder.lastPathComponent) klasöründe bulundu · birebir aynı")
                    }
                    if nameMatch == nil, ParsedFilename(filename: file.lastPathComponent).title.lowercased() == title {
                        nameMatch = file
                    }
                }
            }
            if let nameMatch {
                return Match(url: nameMatch, exact: false, reason: "Adı aynı · sürüm katılınca doğrulanır")
            }
            return nil
        }.value
    }
}
