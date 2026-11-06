import AppKit

/// turkcealtyazi.org: sitenin robots.txt'i arama ve indirme sayfalarını (`/search.php`, `/down.php`, `/dl.php`)
/// otomatik erişime kapatıyor; bu yüzden kazıma yapılmaz. Arama kullanıcının tarayıcısında açılır, kullanıcı indirince
/// KD Player İndirilenler'e düşen zip/srt'yi görür, altyazıyı çıkarıp videonun yanına kaydeder ve açar.
extension PlayerSession {
    static func turkceAltyaziSearchURL(for query: String) -> URL {
        var components = URLComponents(string: "https://turkcealtyazi.org/find.php")!
        components.queryItems = [URLQueryItem(name: "cat", value: "sub"), URLQueryItem(name: "find", value: query)]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "%20", with: "+")
        return components.url!
    }

    @MainActor
    func searchTurkceAltyazi() {
        let query = subtitles.query.isEmpty ? parsed.query : subtitles.query
        NSWorkspace.shared.open(Self.turkceAltyaziSearchURL(for: query))
        watchingDownloads = true
        toasts.show(Toast(kind: .info, title: "turkcealtyazi.org tarayıcında açıldı",
                          subtitle: "Altyazıyı indirdiğinde KD Player kendiliğinden ekleyecek"))
        downloadsWatcher.start(onFile: { [weak self] url in
            self?.handleDownloadedSubtitle(url)
        }, onTimeout: { [weak self] in
            self?.watchingDownloads = false
        })
    }

    @MainActor
    func cancelDownloadsWatch() {
        downloadsWatcher.stop()
        watchingDownloads = false
    }

    @MainActor
    func handleDownloadedSubtitle(_ file: URL) {
        watchingDownloads = false
        guard url != nil else { return }
        do {
            let loaded = try subtitles.importDownloaded(file)
            toasts.show(Toast(kind: .success, title: "turkcealtyazi.org altyazısı eklendi",
                              subtitle: loaded.fileURL?.lastPathComponent ?? loaded.name))
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } catch SubtitleArchive.ArchiveError.rarUnsupported {
            toasts.show(Toast(kind: .warning, title: "RAR arşivi açılamıyor",
                              subtitle: "Arşivi Finder'da açıp içindeki .srt'yi oynatıcıya sürükle"))
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } catch {
            toasts.show(Toast(kind: .warning, title: "Altyazı eklenemedi",
                              subtitle: (error as? LocalizedError)?.errorDescription ?? file.lastPathComponent))
        }
    }
}
