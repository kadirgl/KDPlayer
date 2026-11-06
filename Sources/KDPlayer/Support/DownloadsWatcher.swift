import Foundation

/// İndirilenler klasörüne yeni düşen altyazı dosyasını (zip, rar, srt…) bekler. turkcealtyazi.org gibi otomatik
/// erişime kapalı sitelerde kullanıcı tarayıcıda indirir, KD Player dosyayı görünce kendiliğinden ekler.
@MainActor
final class DownloadsWatcher {
    nonisolated static let extensions: Set<String> = ["zip", "rar", "srt", "ass", "ssa", "vtt", "sub"]
    /// Tarayıcıların yarım indirme uzantıları.
    nonisolated static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp"]

    private let folder: URL
    private var task: Task<Void, Never>?
    private(set) var isWatching = false

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }

    /// `since` anından sonra oluşan ve boyutu durulan ilk altyazı dosyasını bildirir; `timeout` sonra vazgeçer.
    func start(since: Date = .now, timeout: TimeInterval = 15 * 60, onFile: @escaping (URL) -> Void, onTimeout: @escaping () -> Void = {}) {
        stop()
        isWatching = true
        let folder = folder
        let deadline = Date.now.addingTimeInterval(timeout)
        task = Task { @MainActor [weak self] in
            var sizes: [URL: Int] = [:]
            while !Task.isCancelled, Date.now < deadline {
                let found = await Task.detached { Self.candidates(in: folder, since: since) }.value
                for (url, size) in found {
                    // İki ardışık taramada aynı boyut: indirme bitti.
                    if let previous = sizes[url], previous == size, size > 0 {
                        self?.isWatching = false
                        onFile(url)
                        return
                    }
                    sizes[url] = size
                }
                try? await Task.sleep(for: .milliseconds(800))
            }
            guard !Task.isCancelled else { return }
            self?.isWatching = false
            onTimeout()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isWatching = false
    }

    nonisolated static func candidates(in folder: URL, since: Date) -> [(URL, Int)] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return files.compactMap { url in
            let ext = url.pathExtension.lowercased()
            guard extensions.contains(ext), !partialExtensions.contains(ext),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            let date = max(values.creationDate ?? .distantPast, values.contentModificationDate ?? .distantPast)
            guard date >= since.addingTimeInterval(-2) else { return nil }
            return (url, values.fileSize ?? 0)
        }
    }
}
