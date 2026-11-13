import SwiftUI

// MARK: - Oda kur (ekran 8)

struct RoomSetupSheet: View {
    let session: PlayerSession

    @AppStorage(SettingsKey.roomDefaultControl) private var defaultControl = "everyone"
    @State private var name = "Film gecesi"
    @State private var control: ControlMode = .everyone
    @State private var shareSubtitle = true
    @State private var readyCheck = true
    @State private var locked = false
    @State private var code = RoomService.generateCode()
    @State private var working = false
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).onTapGesture { close() }
            VStack(spacing: 16) {
                // Kısa pencerede form kayar; butonlar her zaman görünür.
                VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Oda kur").font(.system(size: 22, weight: .semibold)).tracking(-0.3)
                    Text("Herkes filmi kendi bilgisayarından izler. Odada sadece oynatma, altyazı ve sohbet paylaşılır.")
                        .font(.system(size: 13)).foregroundStyle(Overlay.secondary).lineSpacing(2)
                }

                HStack(spacing: 12) {
                    MediaThumb(seed: session.record?.fileHash ?? session.title, url: session.record?.thumbnailURL)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text([session.detailLine, "arkadaşların aynı sürümü kullanmalı"].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(Overlay.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .glass(radius: 20)

                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("Oda adı")
                    TextField("Oda adı", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                        .glass(radius: 16)
                }

                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("Kim kontrol edebilir?")
                    HStack(spacing: 8) {
                        ForEach(ControlMode.allCases) { mode in
                            Button { control = mode } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.title).font(.system(size: 13.5, weight: .semibold))
                                    Text(mode.caption).font(.system(size: 11.5)).foregroundStyle(Overlay.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                                .padding(.horizontal, 14)
                                .glass(control == mode ? .selected : .glass, radius: 16)
                                .contentShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(PressScale())
                            .accessibilityAddTraits(control == mode ? .isSelected : [])
                        }
                    }
                }

                VStack(spacing: 14) {
                    KDSwitchRow(title: "Altyazımı paylaş", subtitle: subtitleCaption, isOn: $shareSubtitle)
                        .disabled(session.shareableSubtitle == nil)
                    KDSwitchRow(title: "Herkes hazır olunca başlat", subtitle: "Hazır kontrolü ve 3 sn geri sayım", isOn: $readyCheck)
                    KDSwitchRow(title: "Kilitli oda", subtitle: "Yeni gelenler senin onayınla girer", isOn: $locked)
                }
                .padding(14)
                .glass(radius: 20)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Oda kodu").font(.system(size: 11)).foregroundStyle(Overlay.secondary)
                        Text(code).font(.system(size: 18, weight: .bold)).tracking(3).monospacedDigit()
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button {
                        session.copyInviteLink(code: code)
                    } label: {
                        Label("Linki kopyala", systemImage: "link")
                    }
                    .buttonStyle(.kd(.raised, height: 40, fontSize: 12.5))
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .frame(height: 56)
                .glass(radius: 18)
                }
                .padding([.horizontal, .top], 24)
                .fittingVertically()

                HStack(spacing: 10) {
                    Spacer()
                    Button("Vazgeç") { close() }
                        .buttonStyle(.kdGlass)
                        .keyboardShortcut(.cancelAction)
                    Button {
                        working = true
                        Task {
                            let ok = await session.createRoom(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Film gecesi" : name,
                                                              controlMode: control, shareSubtitle: shareSubtitle && session.shareableSubtitle != nil,
                                                              readyCheck: readyCheck, locked: locked, code: code)
                            working = false
                            if !ok { code = RoomService.generateCode() }
                        }
                    } label: {
                        if working { ProgressView().controlSize(.small).frame(width: 80) } else { Text("Odayı aç") }
                    }
                    .buttonStyle(.kdPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
                }
                .padding([.horizontal, .bottom], 24)
            }
            .foregroundStyle(Overlay.text)
            .frame(width: 540)
            .overlayGlass(radius: 30)
            .padding(.vertical, 16)
            .scaleEffect(appeared ? 1 : 0.96)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            control = ControlMode(rawValue: defaultControl) ?? .everyone
            shareSubtitle = session.shareableSubtitle != nil
            withAnimation(Theme.spring) { appeared = true }
        }
    }

    private var subtitleCaption: String {
        guard session.shareableSubtitle != nil, let loaded = session.subtitles.loaded else {
            return session.subtitles.embeddedTrackID != nil
                ? "Dosyanın içindeki altyazıyı herkes kendi dosyasından seçer"
                : "Paylaşılacak altyazı yok"
        }
        return "\(Language.name(for: loaded.language) ?? "Altyazı") · \(Format.milliseconds(session.subtitles.timing.offsetMilliseconds)) senkron ayarı dahil gönderilir"
    }

    private func close() {
        session.cancelRoomSetup()
    }
}

extension View {
    /// Pencereye sığmazsa kaydırılabilir olur (kısa pencerede yazılar kırpılmasın).
    func fittingVertically() -> some View {
        ViewThatFits(in: .vertical) {
            self
            ScrollView { self }.scrollIndicators(.never)
        }
    }
}

struct MediaThumb: View {
    let seed: String
    var url: URL?
    var width: CGFloat = 84

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Group {
            if let url, let image = ThumbnailCache.image(for: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Palette.gradient(for: seed)
            }
        }
        .frame(width: width, height: width * 0.57)
        .clipShape(shape)
    }
}

// MARK: - Hazır kontrolü (ekran 9)

struct ReadyCheckView: View {
    @Bindable var session: PlayerSession
    private var room: RoomService { session.room }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.5)
            HStack(spacing: 8) {
                Circle().fill(Theme.success).frame(width: 8, height: 8)
                Text("\(room.meta?.name ?? "") · \(room.connectionLabel) · \(Int(room.rttMs)) ms").font(.system(size: 12.5))
            }
            .padding(.horizontal, 16).frame(height: 40)
            .overlayGlass(in: Capsule())
            .padding(.top, 18)

            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Text("Herkes hazır mı?").font(.system(size: 22, weight: .semibold)).tracking(-0.3)
                    Text("\(room.media?.title ?? session.title) · herkes hazır olunca 3 saniyelik geri sayım başlar")
                        .font(.system(size: 13)).foregroundStyle(Overlay.secondary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(room.activeMembers.filter { $0.status != .waiting }) { member in
                        PersonCard(member: member, room: room, isMe: member.id == room.uid, localStatus: room.localStatus)
                    }
                }
                ForEach(room.activeMembers.filter { room.isMismatch($0) && $0.id != room.uid }) { member in
                    HStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xFF9CBC))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(member.name)'in dosyası farklı bir sürüm olabilir").font(.system(size: 13, weight: .semibold))
                            Text("Senin dosyan \(Format.duration((room.media?.durationMs ?? 0) / 1000)), onunki \(Format.duration(member.durationMs / 1000)). Sahneler birkaç saniye kayabilir.")
                                .font(.system(size: 12)).foregroundStyle(Overlay.text.opacity(0.78)).lineSpacing(2)
                        }
                        Spacer(minLength: 0)
                        if room.isHost {
                            Button("Yine de izlesin") { room.acceptMismatch(member) }
                                .buttonStyle(.kd(.raised, height: 36, fontSize: 12))
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(hex: 0xFF3D7F, opacity: 0.10))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color(hex: 0xFF3D7F, opacity: 0.35), lineWidth: 1)))
                }
                HStack(spacing: 12) {
                    if room.isHost, let waiting = notReady.first {
                        Button(notReady.count == 1 ? "\(waiting.name)'i bekleme, başlat" : "Beklemeden başlat") { session.startRoomNow() }
                            .buttonStyle(.kd(.glass, fontSize: 13))
                    } else if !room.isHost {
                        Text("Oda sahibi herkes hazır olunca başlatır").font(.system(size: 12)).foregroundStyle(Overlay.secondary)
                    }
                    Spacer()
                    Text("\(readyCount) / \(participants.count) hazır").font(.system(size: 12.5)).foregroundStyle(Overlay.secondary).monospacedDigit()
                    Button { session.toggleReady() } label: {
                        Label(room.localStatus == .ready ? "Hazırım" : "Hazırım", systemImage: room.localStatus == .ready ? "checkmark.circle.fill" : "checkmark")
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.kd(room.localStatus == .ready ? .raised : .primary))
                }
            }
            .foregroundStyle(Overlay.text)
            .padding(26)
            .frame(maxWidth: 640)
            .overlayGlass(radius: 30)
            .padding(.horizontal, 16)
            .fittingVertically()
            .frame(maxHeight: .infinity)
        }
        .onChange(of: readyCount) { session.maybeStartWhenAllReady() }
    }

    private var participants: [RoomMember] { room.activeMembers.filter { $0.status != .waiting } }
    private var readyCount: Int { participants.filter { $0.id == room.uid ? room.localStatus == .ready : $0.status == .ready }.count }
    private var notReady: [RoomMember] { participants.filter { $0.id != room.uid && $0.status != .ready } }
}

private struct PersonCard: View {
    let member: RoomMember
    let room: RoomService
    let isMe: Bool
    let localStatus: RoomMember.Status

    var body: some View {
        let mismatch = room.isMismatch(member)
        let ready = (isMe ? localStatus : member.status) == .ready
        VStack(spacing: 8) {
            KDAvatar(initial: member.initial, color: member.color, size: 56,
                     status: mismatch ? Color(hex: 0xFF3D7F) : ready ? Theme.success : Theme.warning)
            Text(isMe ? "\(member.name) (sen)" : member.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(mismatch ? mismatchText : ready ? "Hazır" : member.status == .buffering ? "Yükleniyor…" : "Dosyayı açıyor…")
                .font(.system(size: 11.5))
                .foregroundStyle(mismatch ? Color(hex: 0xFF9CBC) : ready ? Color(hex: 0x7EE0B5) : Color(hex: 0xFFD27A))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .background {
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            if mismatch {
                shape.fill(Color(hex: 0xFF3D7F, opacity: 0.12)).overlay(shape.strokeBorder(Color(hex: 0xFF3D7F, opacity: 0.55), lineWidth: 1.5))
            } else {
                shape.fill(Theme.glassFill).glassEdge(shape, highlight: Theme.glassHighlight, edge: Theme.glassEdge)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var mismatchText: String {
        let diff = ((room.media?.durationMs ?? 0) - member.durationMs) / 60_000
        let minutes = max(1, Int(abs(diff).rounded()))
        return "Dosya \(minutes) dk \(diff > 0 ? "kısa" : "uzun")"
    }
}

// MARK: - Oda başlığı (ekran 3)

struct RoomHeader: View {
    let session: PlayerSession
    private var room: RoomService { session.room }

    var body: some View {
        // Dar pencerede önce kontrol modu hapı, sonra "Davet linki" yazısı düşer.
        ViewThatFits(in: .horizontal) {
            content(showsMode: true, linkTitle: true)
            content(showsMode: false, linkTitle: true)
            content(showsMode: false, linkTitle: false)
        }
        .foregroundStyle(Overlay.text)
    }

    private func content(showsMode: Bool, linkTitle: Bool) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(Theme.success).frame(width: 8, height: 8).shadow(color: Theme.success.opacity(0.8), radius: 4)
                Text(room.meta?.name ?? "Oda").font(.system(size: 14, weight: .semibold)).lineLimit(1).fixedSize()
                Text(room.code ?? "")
                    .font(.system(size: 12, weight: .semibold)).tracking(1.5).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Overlay.raised))
                    .fixedSize()
                Button { session.copyInviteLink() } label: {
                    if linkTitle { Label("Davet linki", systemImage: "link") } else { Image(systemName: "link") }
                }
                .buttonStyle(.kdPill(height: 36))
                .fixedSize()
                .help("Davet linkini kopyala")
            }
            .padding(.leading, 16).padding(.trailing, 6)
            .frame(height: 48)
            .overlayGlass(in: Capsule(), shadow: false)

            if showsMode, let meta = room.meta {
                Label(meta.controlMode.badge, systemImage: meta.controlMode == .everyone ? "person.2.fill" : "person.fill.checkmark")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 14).frame(height: 48)
                    .overlayGlass(in: Capsule(), shadow: false)
                    .fixedSize()
            }
        }
    }
}

/// "Herkes senkron · 38 ms" / "Mert bekleniyor…"
struct RoomSyncStatus: View {
    let room: RoomService
    /// Dar kontrol çubuğunda yalnızca renkli nokta; yazı ipucunda (kesik "Herkes s…" görünmesin).
    var dotOnly = false

    var body: some View {
        let waiting = room.bufferingMembers
        let reconnecting = room.reconnectingMembers
        let label = text(waiting: waiting, reconnecting: reconnecting)
        HStack(spacing: 6) {
            Circle().fill(color(waiting: waiting, reconnecting: reconnecting)).frame(width: 8, height: 8)
            if !dotOnly {
                Text(label)
                    .font(.system(size: 12)).foregroundStyle(Overlay.text.opacity(0.8)).monospacedDigit().lineLimit(1)
            }
        }
        .frame(minWidth: dotOnly ? 20 : nil, minHeight: dotOnly ? 20 : nil)
        .contentShape(Rectangle())
        .help(label)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private func text(waiting: [RoomMember], reconnecting: [RoomMember]) -> String {
        if let first = waiting.first { return waiting.count == 1 ? "\(first.name) bekleniyor…" : "\(waiting.count) kişi bekleniyor…" }
        if let first = reconnecting.first { return "\(first.name) yeniden bağlanıyor…" }
        if room.playback?.playing == false { return room.meta?.readyCheck == true ? "Hazır kontrolü" : "Duraklatıldı · herkes aynı karede" }
        let drift = room.worstDriftMs
        return drift < 150 ? "Herkes senkron · \(Int(drift)) ms" : "Eşitleniyor · \(Int(drift)) ms"
    }

    private func color(waiting: [RoomMember], reconnecting: [RoomMember]) -> Color {
        if !waiting.isEmpty || !reconnecting.isEmpty { return Theme.warning }
        return room.worstDriftMs < 150 ? Theme.success : Theme.warning
    }
}

// MARK: - Oda paneli (ekran 3)

struct RoomPanel: View {
    @Bindable var session: PlayerSession
    @State private var draft = ""
    @FocusState private var chatFocused: Bool

    private var room: RoomService { session.room }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Oda").font(.system(size: 18, weight: .semibold))
                Spacer()
                Text("\(room.activeMembers.filter { $0.status != .waiting }.count) kişi izliyor").font(.system(size: 12)).foregroundStyle(Overlay.secondary)
                Menu {
                    Button("Davet linkini kopyala") { session.copyInviteLink() }
                    Button("Altyazımı paylaş") { session.shareSubtitleToRoom() }
                        .disabled(session.subtitles.loaded == nil)
                    Divider()
                    Button("Odadan ayrıl", role: .destructive) { session.leaveRoom() }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 30, height: 30).glass(in: Circle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                KDIconButton(systemName: "xmark", label: "Paneli kapat", size: 30) {
                    withAnimation(Theme.spring) { session.showsRoomPanel = false }
                }
            }

            VStack(spacing: 2) {
                ForEach(room.members) { member in
                    MemberRow(member: member, room: room)
                }
            }
            .padding(4)
            .glass(radius: 18)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(room.messages) { message in
                            MessageRow(message: message, room: room) { ms in session.jump(toMilliseconds: ms) }
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, minHeight: 10, alignment: .bottom)
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.bottom)
                .onChange(of: room.messages.last?.id) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 6) {
                ForEach(PlayerSession.reactions, id: \.self) { emoji in
                    Button { session.sendReaction(emoji) } label: {
                        Text(emoji).font(.system(size: 18)).frame(maxWidth: .infinity, minHeight: 40)
                            .glass(radius: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel(["Kalp", "Gülme", "Şaşırma", "Alkış"][PlayerSession.reactions.firstIndex(of: emoji) ?? 0])
                }
            }

            HStack(spacing: 8) {
                TextField("Mesaj yaz · 12:34 yazınca zaman damgası olur", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($chatFocused)
                    .onSubmit(send)
                    .onExitCommand { chatFocused = false }
                    .accessibilityLabel("Mesaj")
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.onAccent)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Theme.accent).shadow(color: Theme.accentGlow, radius: 7, y: 4))
                }
                .buttonStyle(PressScale())
                .accessibilityLabel("Gönder")
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.leading, 16).padding(.trailing, 4)
            .frame(height: 48)
            .glass(in: Capsule())
        }
        .foregroundStyle(Overlay.text)
        .padding(16)
        .frame(width: Theme.panelWidth)
        .frame(maxHeight: .infinity)
        .overlayGlass(radius: Theme.panelRadius)
        .onHover { session.hoveringControls = $0 }
        .onChange(of: session.chatFocusRequest) { chatFocused = true }
    }

    private func send() {
        room.send(text: draft)
        draft = ""
    }
}

private struct MemberRow: View {
    let member: RoomMember
    let room: RoomService

    var body: some View {
        HStack(spacing: 10) {
            KDAvatar(initial: member.initial, color: member.color, size: 32)
            (Text(member.name).fontWeight(.semibold) + Text(member.id == room.uid ? " (sen)" : "").foregroundColor(Overlay.tertiary))
                .font(.system(size: 13))
                .lineLimit(1)
            if member.id == room.meta?.createdBy {
                Image(systemName: "crown.fill").font(.system(size: 9)).foregroundStyle(Color(hex: 0xFFD27A)).accessibilityLabel("Oda sahibi")
            }
            Spacer(minLength: 4)
            if member.status == .waiting, room.isHost {
                Button("İçeri al") { room.approve(member) }.buttonStyle(.kd(.primary, height: 26, fontSize: 11.5))
            } else {
                Text(status.text).font(.system(size: 11.5)).foregroundStyle(status.color).lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .opacity(room.isStale(member) ? 0.55 : 1)
    }

    private var status: (text: String, color: Color) {
        if room.isStale(member) { return ("Yeniden bağlanıyor…", Color(hex: 0xFFD27A)) }
        if room.isMismatch(member) {
            let diff = ((room.media?.durationMs ?? 0) - member.durationMs) / 60_000
            return ("Dosya \(max(1, Int(abs(diff).rounded()))) dk \(diff > 0 ? "kısa" : "uzun")", Color(hex: 0xFF9CBC))
        }
        let status = member.id == room.uid ? room.localStatus : member.status
        switch status {
        case .waiting: return ("Onay bekliyor", Color(hex: 0xFFD27A))
        case .buffering: return ("Yükleniyor… herkes bekliyor", Color(hex: 0xFFD27A))
        case .loading: return (room.meta?.readyCheck == true ? "Hazır değil" : "Açılıyor…", Color(hex: 0xFFD27A))
        case .ready, .mismatch:
            let drift = member.id == room.uid ? room.localDriftMs : member.driftMs
            return abs(drift) < 500 ? ("Senkron", Color(hex: 0x7EE0B5)) : ("Eşitleniyor", Color(hex: 0xFFD27A))
        }
    }
}

private struct MessageRow: View {
    let message: RoomMessage
    let room: RoomService
    let onJump: (Double) -> Void

    var body: some View {
        switch message.kind {
        case .system:
            HStack(spacing: 8) {
                Image(systemName: message.text.contains("altyazı") ? "captions.bubble" : "info.circle").font(.system(size: 11))
                Text(message.text).multilineTextAlignment(.center)
            }
            .font(.system(size: 12))
            .foregroundStyle(message.text.contains("kısa") || message.text.contains("uzun") ? Color(hex: 0xFF9CBC) : Overlay.secondary)
            .frame(maxWidth: .infinity)
        case .text, .reaction:
            let mine = message.uid == room.uid
            let member = room.member(message.uid)
            HStack(alignment: .bottom, spacing: 8) {
                if mine { Spacer(minLength: 40) } else {
                    KDAvatar(initial: member?.initial ?? String(message.name.prefix(1)), color: member?.color ?? 0, size: 26)
                }
                VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                    if !mine { Text(member?.name ?? message.name).font(.system(size: 11)).foregroundStyle(Overlay.secondary) }
                    HStack(spacing: 6) {
                        Text(message.text).font(.system(size: 13)).lineSpacing(2)
                            .foregroundStyle(mine ? Theme.onAccent : Overlay.text)
                            .textSelection(.enabled)
                        if let at = message.atMs {
                            Button(Format.time(at / 1000)) { onJump(at) }
                                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                .buttonStyle(.plain)
                                .padding(.horizontal, 7).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 8).fill(mine ? Color.black.opacity(0.14) : Overlay.raised))
                                .foregroundStyle(mine ? Theme.onAccent : Overlay.text)
                                .help("Bu ana git")
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background {
                        let shape = UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: mine ? 16 : 6, bottomTrailingRadius: mine ? 6 : 16, topTrailingRadius: 16, style: .continuous)
                        if mine { shape.fill(Theme.accent) } else { shape.fill(Theme.glassFill).glassEdge(shape, highlight: Theme.glassHighlight, edge: Theme.glassEdge) }
                    }
                }
                .frame(maxWidth: 270, alignment: mine ? .trailing : .leading)
                if !mine { Spacer(minLength: 20) }
            }
        }
    }
}

// MARK: - Video üstü geri bildirimler

/// "Ayşe 42:10'a sardı · şimdi"
struct RoomEventView: View {
    let event: PlayerSession.RoomEvent

    var body: some View {
        HStack(spacing: 10) {
            KDAvatar(initial: event.initial, color: event.color, size: 32)
            (Text(event.name).fontWeight(.semibold) + Text(event.name.isEmpty ? event.text : " \(event.text)"))
                .font(.system(size: 13)).lineLimit(2)
            Text("· şimdi").font(.system(size: 13)).foregroundStyle(Overlay.tertiary)
        }
        .foregroundStyle(Overlay.text)
        .padding(.leading, 6).padding(.trailing, 16)
        .frame(minHeight: 44)
        .overlayGlass(in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Bekleyen üyelerin hapları (sağ altta).
struct WaitingChips: View {
    let room: RoomService

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(room.reconnectingMembers + room.bufferingMembers) { member in
                let stale = room.isStale(member)
                HStack(spacing: 8) {
                    Image(systemName: stale ? "wifi.exclamationmark" : "hourglass")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(stale ? Color(hex: 0xFF3D7F) : Color(hex: 0xF5B82E)))
                    Text(member.name).font(.system(size: 12, weight: .semibold))
                }
                .padding(.leading, 8).padding(.trailing, 12)
                .frame(height: 40)
                .overlayGlass(in: Capsule())
                .opacity(stale ? 0.6 : 1)
                .help(stale ? "\(member.name) yeniden bağlanıyor; film durmaz" : "\(member.name) bekleniyor")
            }
        }
        .foregroundStyle(Overlay.text)
    }
}

/// Tepkiler video üzerinde 3 sn uçar.
struct ReactionsLayer: View {
    let reactions: [PlayerSession.FlyingReaction]

    var body: some View {
        GeometryReader { proxy in
            ForEach(reactions) { reaction in
                FlyingEmoji(reaction: reaction)
                    .position(x: proxy.size.width * reaction.x, y: proxy.size.height - 160)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct FlyingEmoji: View {
    let reaction: PlayerSession.FlyingReaction
    @State private var flying = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 4) {
            Text(reaction.emoji).font(.system(size: 40))
            if !reaction.name.isEmpty {
                Text(reaction.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(RoomPalette.gradient(reaction.color)))
            }
        }
        .offset(y: flying && !reduceMotion ? -260 : 0)
        .opacity(flying ? 0 : 1)
        .scaleEffect(flying && !reduceMotion ? 1.15 : 0.8)
        .onAppear {
            withAnimation(.easeOut(duration: 3)) { flying = true }
        }
    }
}

/// Paylaşılan altyazı karşılaştırma kartı (ekran 15).
struct SharedSubtitleCard: View {
    let pending: PlayerSession.PendingSharedSubtitle
    let session: PlayerSession
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                KDAvatar(initial: String(pending.from.prefix(1)).uppercased(), color: pending.color, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(pending.from) altyazısını paylaştı").font(.system(size: 14, weight: .semibold))
                    Text("Herkes aynı satırı aynı anda görsün").font(.system(size: 12)).foregroundStyle(Overlay.secondary)
                }
            }
            HStack(spacing: 8) {
                Compare(title: "Odanın altyazısı", value: "\(Language.name(for: pending.subtitle.lang) ?? "Altyazı") · \(ParsedFilename(filename: pending.subtitle.name).release ?? pending.subtitle.source)",
                        detail: pending.subtitle.offsetMs == 0 ? "Senkron ayarı yok" : "\(Format.milliseconds(pending.subtitle.offsetMs)) senkronlu", selected: true)
                Compare(title: "Seninki", value: mine, detail: session.subtitles.timing.offsetMilliseconds == 0 ? "Senkron ayarı yok" : "\(Format.milliseconds(session.subtitles.timing.offsetMilliseconds)) senkronlu", selected: false)
            }
            HStack(spacing: 8) {
                Button("Odanınkini kullan") { session.acceptSharedSubtitle(pending.subtitle, announce: false, remember: remember) }
                    .buttonStyle(.kd(.primary, height: 42, fontSize: 13, fullWidth: true))
                Button("Benimkini koru") { session.keepOwnSubtitle(remember: remember) }
                    .buttonStyle(.kd(.raised, height: 42, fontSize: 13, fullWidth: true))
            }
            Toggle("Bu odada paylaşılan altyazıyı sormadan kullan", isOn: $remember)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
        }
        .foregroundStyle(Overlay.text)
        .padding(16)
        .frame(width: 400)
        .overlayGlass(radius: 24)
        .accessibilityAddTraits(.isModal)
    }

    private var mine: String {
        guard let loaded = session.subtitles.loaded else { return "Dosyanın içindeki" }
        return "\(Language.name(for: loaded.language) ?? "Altyazı") · \(ParsedFilename(filename: loaded.name).release ?? loaded.source.title)"
    }

    private struct Compare: View {
        let title: String
        let value: String
        let detail: String
        let selected: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 11.5)).foregroundStyle(Overlay.secondary)
                Text(value).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Overlay.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .glass(selected ? .selected : .glass, radius: 16)
        }
    }
}

/// 3-2-1 geri sayım.
struct CountdownOverlay: View {
    let value: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            Text("\(value)")
                .font(.system(size: 120, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white)
                .shadow(color: Theme.accentGlow, radius: 30)
                .contentTransition(.numericText(countsDown: true))
                .animation(Theme.spring, value: value)
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Film \(value) saniye sonra başlıyor")
    }
}
