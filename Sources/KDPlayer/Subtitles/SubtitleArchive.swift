import Foundation

/// İndirilen altyazı paketleri: zip'i açar, içinden en uygun altyazı dosyasını seçer; videonun yanına kaydeder.
/// Zip, macOS'in kendi `ditto` aracıyla açılır (ek kitaplık yok). RAR desteklenmez: kullanıcıya sürükle-bırak önerilir.
enum SubtitleArchive {
    enum ArchiveError: LocalizedError {
        case rarUnsupported
        case noSubtitle
        case unreadable

        var errorDescription: String? {
            switch self {
            case .rarUnsupported: "RAR arşivi açılamıyor; içindeki .srt dosyasını oynatıcıya sürükle"
            case .noSubtitle: "Arşivde altyazı dosyası yok"
            case .unreadable: "Arşiv bozuk ya da şifreli"
            }
        }
    }

    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub"]

    enum Kind { case zip, rar, subtitle }

    static func kind(of data: Data) -> Kind {
        let head = [UInt8](data.prefix(4))
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .zip }
        if head.starts(with: [0x52, 0x61, 0x72, 0x21]) { return .rar } // "Rar!"
        return .subtitle
    }

    /// İndirilen veriden altyazının ham baytları. Zip ise içinden `episode` (S01E02) ile eşleşeni, yoksa en büyük
    /// .srt'yi seçer; düz altyazı ise olduğu gibi döner.
    static func subtitleData(from data: Data, episode: String? = nil) throws -> (data: Data, name: String?) {
        switch kind(of: data) {
        case .rar: throw ArchiveError.rarUnsupported
        case .subtitle: return (data, nil)
        case .zip:
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("kd-sub-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let zip = work.appendingPathComponent("pack.zip")
            try data.write(to: zip)
            let files = try extractSubtitles(zip: zip, into: work.appendingPathComponent("out", isDirectory: true))
            guard let best = pick(files, episode: episode) else { throw ArchiveError.noSubtitle }
            return (try Data(contentsOf: best), best.lastPathComponent)
        }
    }

    /// Zip'i açar ve içindeki altyazı dosyalarını döndürür (alt klasörler dahil, __MACOSX hariç).
    static func extractSubtitles(zip: URL, into folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ArchiveError.unreadable }
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard !url.path.contains("__MACOSX"), subtitleExtensions.contains(url.pathExtension.lowercased()) else { continue }
            files.append(url)
        }
        return files
    }

    /// Bölüm koduna uyan, sonra .srt olan, sonra en büyük dosya.
    static func pick(_ files: [URL], episode: String?) -> URL? {
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        var pool = files
        if let episode {
            let code = episode.lowercased()
            let alt = code.replacingOccurrences(of: "s0", with: "").replacingOccurrences(of: "e", with: "x") // s01e02 → 1x02
            let matching = files.filter {
                let name = $0.lastPathComponent.lowercased()
                return name.contains(code) || name.contains(alt)
            }
            if !matching.isEmpty { pool = matching }
        }
        let srt = pool.filter { $0.pathExtension.lowercased() == "srt" }
        return (srt.isEmpty ? pool : srt).max { size($0) < size($1) }
    }

    /// Videonun yanına `<video adı>.<dil>.<uzantı>` olarak UTF-8 kaydeder (VLC, IINA ve KD Player'ın kendisi de
    /// bir dahaki açılışta bunu "yanındaki dosya" olarak bulur). Aynı adda dosya varsa ya da klasör yazılamıyorsa nil.
    static func saveNextToVideo(text: String, video: URL, language: String, format: String) -> URL? {
        guard video.isFileURL else { return nil }
        let base = video.deletingPathExtension().lastPathComponent
        let target = video.deletingLastPathComponent().appendingPathComponent("\(base).\(language).\(format)")
        if FileManager.default.fileExists(atPath: target.path) {
            // Aynı içerikse yeniden yazmaya gerek yok; farklıysa kullanıcının dosyasına dokunma.
            return (try? String(contentsOf: target, encoding: .utf8)) == text ? target : nil
        }
        do {
            try text.write(to: target, atomically: true, encoding: .utf8)
            return target
        } catch {
            return nil
        }
    }
}
