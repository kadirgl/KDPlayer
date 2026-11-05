import Foundation

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("KDPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let thumbnailsDirectory: URL = {
        let url = supportDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let subtitlesDirectory: URL = {
        let url = supportDirectory.appendingPathComponent("Subtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Oynatıcının açabildiği dosya uzantıları (sürükle-bırak ve Aç penceresi).
    static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "wmv", "flv", "webm", "ts", "m2ts", "mts", "mpg", "mpeg",
        "vob", "ogv", "3gp", "divx", "xvid", "rm", "rmvb", "asf", "f4v", "mxf",
    ]
    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub"]
}
