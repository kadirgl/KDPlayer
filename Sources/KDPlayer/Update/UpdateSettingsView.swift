import SwiftUI

/// Ayarlar › Genel › Uygulama güncellemesi: GitHub Releases'teki imzalı sürümleri denetler ve kurar.
struct UpdateSettingsSection: View {
    @Bindable private var updater = AppUpdater.shared
    @AppStorage(SettingsKey.appAutoUpdateCheck) private var autoCheck = true

    var body: some View {
        SettingsSection(title: "Uygulama güncellemesi") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        TitleSubtitle(title: "KD Player \(AppUpdater.currentVersion)", subtitle: statusText)
                        Spacer(minLength: 8)
                        actionButton
                    }
                    if case .downloading(_, let progress) = updater.state {
                        ProgressBar(progress: progress)
                    }
                    if let release = currentRelease, !release.notes.isEmpty, showsNotes {
                        Text(Self.summary(of: release.notes))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .lineSpacing(2)
                            .lineLimit(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.glassFill))
                    }
                    if let problem = AppUpdater.installProblem, currentRelease != nil {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.warningText)
                    }
                }
                .padding(.vertical, 8)
                KDSwitchRow(
                    title: "Güncellemeleri otomatik denetle",
                    subtitle: "Günde bir kez GitHub'daki son sürüme bakar; kurmadan önce sorar",
                    isOn: $autoCheck
                )
                .disabled(!AppUpdater.isAvailable)
            }
        }
    }

    private var currentRelease: AppUpdater.Release? {
        switch updater.state {
        case .available(let release), .downloading(let release, _), .installing(let release): release
        default: nil
        }
    }

    private var showsNotes: Bool {
        if case .available = updater.state { return true }
        return false
    }

    private var statusText: String {
        guard AppUpdater.isAvailable else {
            return "Bu derleme uygulama içinden güncellenmez (paketlenmiş sürümü kullan)"
        }
        switch updater.state {
        case .idle:
            if let last = updater.lastCheck { return "Son denetim: \(Format.relative(last))" }
            return "Henüz denetlenmedi"
        case .checking: return "Denetleniyor…"
        case .upToDate: return "Güncel · son sürüm kurulu"
        case .available(let release): return "Yeni sürüm: \(release.version) · \(ByteCountFormatter.string(fromByteCount: release.size, countStyle: .file))"
        case .downloading(let release, let progress): return "\(release.version) indiriliyor · %\(Int(progress * 100))"
        case .installing(let release): return "\(release.version) kuruluyor, uygulama yeniden açılacak…"
        case .failed(let message): return message
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch updater.state {
        case .available:
            Button("Güncelle ve yeniden başlat") { updater.install() }
                .buttonStyle(.kd(.primary, height: 32, fontSize: 12.5))
                .disabled(AppUpdater.installProblem != nil)
        case .downloading:
            Button("İptal") { updater.cancel() }
                .buttonStyle(.kd(.glass, height: 32, fontSize: 12.5))
        case .checking, .installing:
            KDSpinner(size: 18)
        default:
            Button("Güncellemeleri denetle") { Task { await updater.check() } }
                .buttonStyle(.kd(.glass, height: 32, fontSize: 12.5))
                .disabled(!AppUpdater.isAvailable)
        }
    }

    /// Sürüm notlarının "Kurulum" bölümünden önceki kısmı.
    static func summary(of notes: String) -> String {
        let body = notes.components(separatedBy: "\n---").first ?? notes
        return body
            .replacingOccurrences(of: "## Değişiklikler", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(Theme.accent).frame(width: max(6, proxy.size.width * progress))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.2), value: progress)
        .accessibilityElement()
        .accessibilityLabel("İndirme")
        .accessibilityValue("%\(Int(progress * 100))")
    }
}
