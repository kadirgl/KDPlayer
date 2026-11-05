import Foundation

/// UserDefaults anahtarları (tek yerden).
enum SettingsKey {
    static let volume = "volume"
    static let hardwareDecodingDisabled = "hardwareDecodingDisabled"
    static let embeddedSubtitleScale = "embeddedSubtitleScale"
    static let resumeMode = "resumeMode"
    static let autoplayNextEpisode = "autoplayNextEpisode"

    // Altyazı
    static let subtitleAutoLoad = "subtitleAutoLoad"
    static let subtitlePreferEmbedded = "subtitlePreferEmbedded"
    static let subtitleAutoSync = "subtitleAutoSync"
    static let subtitleEncoding = "subtitleEncoding"
    static let subtitleLanguages = "subtitleLanguages"
    static let openSubtitlesAPIKey = "openSubtitlesAPIKey"
    static let subtitleStyle = "subtitleStyle"
    static let rememberTrackLanguages = "rememberTrackLanguages"
    static let preferredAudioLanguage = "preferredAudioLanguage"
    static let preferredSubtitleLanguage = "preferredSubtitleLanguage"
    static let secondarySubtitleEnabled = "secondarySubtitleEnabled"

    // Oda
    static let displayName = "displayName"
    static let roomDefaultControl = "roomDefaultControl"
    static let roomAutoAcceptSubtitle = "roomAutoAcceptSubtitle"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            volume: 80,
            resumeMode: ResumeMode.ask.rawValue,
            autoplayNextEpisode: true,
            subtitleAutoLoad: true,
            subtitlePreferEmbedded: true,
            subtitleAutoSync: false,
            subtitleEncoding: "auto",
            subtitleLanguages: ["tr", "en"],
            rememberTrackLanguages: true,
            roomDefaultControl: "everyone",
        ])
    }
}

/// Kaldığın yerden devam davranışı.
enum ResumeMode: String, CaseIterable, Identifiable {
    case ask, always, never
    var id: Self { self }
    var title: String {
        switch self {
        case .ask: "Sor"
        case .always: "Her zaman"
        case .never: "Baştan başla"
        }
    }
}
