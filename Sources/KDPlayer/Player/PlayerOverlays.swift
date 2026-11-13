import SwiftUI

/// "Kaldığın yerden devam ediliyor" kartı: film zaten kaldığı yerden oynar; sol altta birkaç saniye
/// "Baştan başla" seçeneği sunar ve kendiliğinden kaybolur (video sitelerindeki gibi, engellemez).
struct ResumePromptView: View {
    let prompt: PlayerSession.ResumePrompt
    let session: PlayerSession
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Kaldığın yerden devam ediliyor").font(.system(size: 13, weight: .semibold))
                Text("\(Format.time(prompt.position)) · \(Format.relative(prompt.lastOpened)) izledin")
                    .font(.system(size: 11.5)).foregroundStyle(Overlay.secondary).monospacedDigit()
            }
            Button("Baştan başla") { session.resume(fromStart: true) }
                .buttonStyle(.kd(.raised, height: 32, fontSize: 12))
            Button { session.dismissResumePrompt() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Overlay.secondary)
            .accessibilityLabel("Kapat")
        }
        .foregroundStyle(Overlay.text)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .overlayGlass(radius: 18)
        .offset(y: appeared ? 0 : 12)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(Theme.spring) { appeared = true } }
        .onHover { session.hoveringControls = $0 }
    }
}

/// Sonraki bölüm kartı: jenerikte geri sayım; odada herkes için geçer.
struct NextEpisodeCard: View {
    let episode: PlayerSession.NextEpisode
    let countdown: Int
    let session: PlayerSession

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button("İptal") { session.cancelNextEpisode() }
                .buttonStyle(.kd(.raised, height: 26, fontSize: 11.5))
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.gradient(for: episode.url.lastPathComponent))
                    .frame(width: 72, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sonraki bölüm").font(.system(size: 11)).foregroundStyle(Overlay.secondary)
                    Text("\(episode.code) · \(episode.title)").font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { session.playNextEpisodeNow() } label: {
                    ZStack {
                        Circle().fill(Overlay.track)
                        Circle().trim(from: 0, to: CGFloat(countdown) / 10)
                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: countdown)
                        Text("\(countdown)").font(.system(size: 13, weight: .bold)).monospacedDigit()
                    }
                    .frame(width: 40, height: 40)
                }
                .buttonStyle(PressScale())
                .accessibilityLabel("Sonraki bölümü şimdi oynat, \(countdown) saniye")
            }
            .padding(10)
            .frame(width: 260)
            .overlayGlass(radius: 20)
        }
        .foregroundStyle(Overlay.text)
    }
}

/// Engelleyen hata kartı (ekran 14). Yalnızca oynatma imkânsızsa açılır.
struct ErrorCard: View {
    let error: PlayerSession.BlockingError
    let session: PlayerSession
    @State private var showsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color(hex: 0xFF9CBC))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(hex: 0xFF3D7F, opacity: 0.2)))
                VStack(alignment: .leading, spacing: 6) {
                    Text(error.title).font(.system(size: 18, weight: .semibold))
                    Text(error.message).font(.system(size: 13)).foregroundStyle(Overlay.text.opacity(0.78)).lineSpacing(3)
                }
            }
            VStack(spacing: 8) {
                if error.canCompleteDownload {
                    ActionRow(icon: "arrow.down.circle", title: "İndirmeyi tamamla", subtitle: "KD Download Manager'da kaldığı yerden devam eder", primary: true) {
                        DownloadManagerBridge.open()
                    }
                }
                ActionRow(icon: "play.circle", title: error.canCompleteDownload ? "Yine de oynat" : "Tekrar dene", subtitle: error.canCompleteDownload ? "Eksik kısma gelince durur" : "Dosyayı yeniden açar", primary: !error.canCompleteDownload) {
                    session.retry()
                }
                ActionRow(icon: "folder", title: "Başka dosya seç", subtitle: nil, primary: false) {
                    session.onOpenFilePanel?()
                }
            }
            DisclosureGroup(isExpanded: $showsDetail) {
                Text(error.technical)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            } label: {
                Text("Teknik ayrıntı").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Overlay.secondary)
        }
        .foregroundStyle(Overlay.text)
        .padding(24)
        .frame(maxWidth: 520)
        .overlayGlass(radius: 28)
        .padding(16)
        .fittingVertically()
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

private struct ActionRow: View {
    let icon: String
    let title: String
    let subtitle: String?
    let primary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 17)).frame(width: 24)
                TitleSubtitle(title: title, subtitle: subtitle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                if primary {
                    shape.fill(Overlay.selected).overlay(shape.strokeBorder(Theme.accent, lineWidth: 1.5))
                } else {
                    shape.fill(Theme.glassFill).glassEdge(shape, highlight: Theme.glassHighlight, edge: Theme.glassEdge)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressScale())
    }
}
