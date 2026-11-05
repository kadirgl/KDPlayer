import Foundation
import SwiftData

/// İzleme geçmişi: dosya başına konum, seçilen altyazı ve senkron ayarı. Dosya hash'iyle eşleşir;
/// dosya tekrar açıldığında aynı altyazı ve offset gelir (spesifikasyon › Senkron).
@Model
final class WatchRecord {
    @Attribute(.unique) var fileHash: String
    var path: String
    var title: String
    /// "2025 · 2 sa 1 dk · 1080p HEVC"
    var detail: String
    var position: Double
    var duration: Double
    var lastOpened: Date
    var finished: Bool

    // Altyazı
    var subtitlePath: String?
    var subtitleName: String?
    var subtitleSource: String?
    var subtitleLanguage: String?
    var embeddedSubtitleID: Int?
    var subtitleOffset: Double
    var subtitleScale: Double
    var subtitleEnabled: Bool

    // Ses
    var audioTrackID: Int?
    var audioDelay: Int

    init(fileHash: String, path: String, title: String) {
        self.fileHash = fileHash
        self.path = path
        self.title = title
        detail = ""
        position = 0
        duration = 0
        lastOpened = .now
        finished = false
        subtitleOffset = 0
        subtitleScale = 1
        subtitleEnabled = true
        audioDelay = 0
    }

    var url: URL { URL(fileURLWithPath: path) }
    var progress: Double { duration > 0 ? min(1, position / duration) : 0 }
    var remaining: Double { max(0, duration - position) }
    var fileExists: Bool { FileManager.default.fileExists(atPath: path) }

    var thumbnailURL: URL { AppInfo.thumbnailsDirectory.appendingPathComponent("\(fileHash).png") }

    var subtitleTiming: SubtitleTiming {
        get { SubtitleTiming(scale: subtitleScale, offset: subtitleOffset) }
        set { subtitleScale = newValue.scale; subtitleOffset = newValue.offset }
    }

    /// Kaldığı yerden devam sorulmalı mı (ilk dakikayı ve son %5'i sayma).
    var isResumable: Bool {
        !finished && position > 60 && (duration <= 0 || position < duration * 0.95)
    }
}
