import AppKit
import CryptoKit
import Observation

/// Uygulamanın kendisini GitHub Releases'ten günceller.
///
/// Her sürüm GitHub'da `v1.5.6` etiketiyle yayımlanır ve iki dosya içerir: uygulamanın zip'i
/// (`KDPlayer-0.2.0.zip`) ve onun Ed25519 imzası (`….zip.sig`, base64). İmzayı yalnızca geliştiricinin
/// Mac'indeki gizli anahtar atabilir (scripts/release.sh); açık anahtar uygulamanın Info.plist'inde
/// (`KDUpdatePublicKey`). Böylece GitHub hesabı ya da indirme yolu ele geçirilse bile sahte bir sürüm
/// kurulmaz. İndirilen paket ayrıca açılıp kimliği, sürümü ve kod imzası denetlenir.
///
/// Kurulum: uygulama kapanır, küçük bir betik eski paketi yenisiyle değiştirip uygulamayı yeniden açar.
/// Oynatma konumu kapanırken kaydedildiği için film açılınca kaldığı yerden devam eder.
/// (KD Download Manager'daki güncelleyiciyle aynı yapı.)
@MainActor
@Observable
final class AppUpdater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release, progress: Double)
        case installing(Release)
        case failed(String)
    }

    struct Release: Equatable {
        let version: String
        let notes: String
        let archive: URL
        let signature: URL
        let size: Int64
        let page: URL?
    }

    static let shared = AppUpdater()

    private(set) var state: State = .idle
    private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: SettingsKey.appUpdateLastCheck) as? Date

    private static let automaticInterval: TimeInterval = 24 * 3600
    private static let maximumSize: Int64 = 600 * 1024 * 1024

    private var downloadTask: Task<Void, Never>?
    /// Yeni sürüm ilk kez bulununca (sürüm başına bir kez) çağrılır: Başlangıç'ta bildirim gösterilir.
    var onAvailable: ((Release) -> Void)?

    // MARK: - Ayarlar

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// "kullanıcı/KDPlayer"; paketlenirken git remote'tan Info.plist'e yazılır.
    private static var repository: String? {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["KD_UPDATE_REPO"] { return value }
        #endif
        return (Bundle.main.object(forInfoDictionaryKey: "KDUpdateRepository") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static var publicKey: Curve25519.Signing.PublicKey? {
        var encoded = Bundle.main.object(forInfoDictionaryKey: "KDUpdatePublicKey") as? String
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["KD_UPDATE_KEY"] { encoded = value }
        #endif
        guard let data = encoded.flatMap({ Data(base64Encoded: $0) }) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    private static var latestAPI: URL? {
        #if DEBUG
        // Denemelerde yerel bir sunucu GitHub'ın yerine geçebilir.
        if let value = ProcessInfo.processInfo.environment["KD_UPDATE_API"] { return URL(string: value) }
        #endif
        return repository.flatMap { URL(string: "https://api.github.com/repos/\($0)/releases/latest") }
    }

    /// Değiştirilecek paket: çalışan uygulamanın kendisi.
    private static var installedApp: URL {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["KD_UPDATE_TARGET"] { return URL(fileURLWithPath: value) }
        #endif
        return Bundle.main.bundleURL
    }

    /// Paketli uygulamada ve depo/anahtar bilgisi varsa güncelleme yapılabilir.
    static var isAvailable: Bool {
        latestAPI != nil && publicKey != nil && (installedApp.pathExtension == "app")
    }

    /// Kurulamayacaksa nedeni (Ayarlar'da gösterilir).
    static var installProblem: String? {
        let app = installedApp
        if app.path.contains("/AppTranslocation/") {
            return "Uygulamayı Uygulamalar klasörüne taşıyıp oradan açın; güncellemeler ancak öyle kurulabilir."
        }
        if !FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) {
            return "\(app.deletingLastPathComponent().path) klasörüne yazma izni yok; yeni sürümü GitHub'dan indirin."
        }
        return nil
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    var availableRelease: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    // MARK: - Denetim

    /// Açılışta ve sonra günde bir: ayar açıksa sessizce denetler. Yeni sürüm bulunursa bildirim gönderilir
    /// (her sürüm için bir kez) ve listenin üstünde band çıkar.
    func startAutomaticChecks() {
        guard Self.isAvailable else { return }
        Task {
            while true {
                let enabled = UserDefaults.standard.object(forKey: SettingsKey.appAutoUpdateCheck) as? Bool ?? true
                let due = lastCheck.map { Date().timeIntervalSince($0) >= Self.automaticInterval } ?? true
                if enabled, due, !isBusy, availableRelease == nil {
                    await check(quietly: true)
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func check(quietly: Bool = false) async {
        guard !isBusy, let api = Self.latestAPI else { return }
        state = .checking
        do {
            let release = try await Self.latestRelease(from: api)
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: SettingsKey.appUpdateLastCheck)
            guard let release, Self.isNewer(release.version, than: Self.currentVersion) else {
                state = .upToDate
                return
            }
            state = .available(release)
            let announced = UserDefaults.standard.string(forKey: SettingsKey.appUpdateAnnounced)
            if announced != release.version {
                UserDefaults.standard.set(release.version, forKey: SettingsKey.appUpdateAnnounced)
                onAvailable?(release)
            }
        } catch {
            // Sessiz denetimde (ağ yok vb.) hata gösterilmez; bir sonraki denemede.
            state = quietly ? .idle : .failed(error.localizedDescription)
        }
    }

    /// "1.5.10" > "1.5.9"; parça parça sayı olarak.
    nonisolated static func isNewer(_ candidate: String, than other: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = other.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    private struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func latestRelease(from api: URL) async throws -> Release? {
        var request = URLRequest(url: api, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Henüz hiç sürüm yayımlanmamış.
        if status == 404 { return nil }
        guard status == 200 else { throw UpdateError(message: "Güncelleme bilgisi alınamadı (HTTP \(status))") }
        guard let info = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = info["tag_name"] as? String else { throw UpdateError(message: "Güncelleme bilgisi okunamadı") }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard version.range(of: #"^\d+(\.\d+){0,3}$"#, options: .regularExpression) != nil else {
            throw UpdateError(message: "Sürüm numarası anlaşılamadı: \(tag)")
        }
        let assets = info["assets"] as? [[String: Any]] ?? []
        func asset(_ name: String) -> (url: URL, size: Int64)? {
            guard let found = assets.first(where: { $0["name"] as? String == name }),
                  let link = found["browser_download_url"] as? String,
                  let url = URL(string: link), url.scheme == "https" || isTesting else { return nil }
            return (url, (found["size"] as? NSNumber)?.int64Value ?? 0)
        }
        let name = "KDPlayer-\(version).zip"
        // İmzasız ya da zip'siz bir sürüm (ör. yalnızca kaynak kod) güncelleme sayılmaz.
        guard let archive = asset(name), let signature = asset(name + ".sig") else { return nil }
        return Release(
            version: version,
            notes: (info["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            archive: archive.url,
            signature: signature.url,
            size: archive.size,
            page: (info["html_url"] as? String).flatMap(URL.init(string:))
        )
    }

    private static var isTesting: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["KD_UPDATE_API"] != nil
        #else
        return false
        #endif
    }

    // MARK: - Kurulum

    func install() {
        guard let release = availableRelease else { return }
        if let problem = Self.installProblem {
            state = .failed(problem)
            return
        }
        state = .downloading(release, progress: 0)
        downloadTask = Task {
            do {
                let staged = try await download(release)
                state = .installing(release)
                // Oynatma konumunu kaydet; yeni sürüm açılınca kaldığı yerden devam edilir.
                AppModel.shared.session.saveProgress(final: true)
                try Self.replaceAndRelaunch(with: staged)
            } catch is CancellationError {
                state = .available(release)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        downloadTask?.cancel()
    }

    private static var workFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KDPlayer/Update", isDirectory: true)
    }

    /// İndirir, imzayı doğrular, açar ve paketi denetler; kurulmaya hazır .app'in yolunu döndürür.
    private func download(_ release: Release) async throws -> URL {
        guard let key = Self.publicKey else { throw UpdateError(message: "Güncelleme anahtarı yok") }
        guard release.size <= Self.maximumSize else { throw UpdateError(message: "Güncelleme dosyası beklenenden büyük") }
        state = .downloading(release, progress: 0)

        let (signatureData, _) = try await URLSession.shared.data(from: release.signature)
        guard let signature = Data(base64Encoded: String(decoding: signatureData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw UpdateError(message: "Güncellemenin imzası okunamadı")
        }

        let file = try await ProgressDownload.run(release.archive, limit: Self.maximumSize) { [weak self] progress in
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                self.state = .downloading(release, progress: progress)
            }
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let archive = try Data(contentsOf: file)
        try Task.checkCancellation()

        guard key.isValidSignature(signature, for: Self.corruptedForTesting(archive)) else {
            throw UpdateError(message: "Güncellemenin imzası doğrulanamadı; kurulmadı")
        }
        state = .downloading(release, progress: 1)
        return try await Self.unpack(archive, version: release.version)
    }

    private static func unpack(_ archive: Data, version: String) async throws -> URL {
        let manager = FileManager.default
        try? manager.removeItem(at: workFolder)
        try manager.createDirectory(at: workFolder, withIntermediateDirectories: true)
        let zip = workFolder.appendingPathComponent("update.zip")
        let folder = workFolder.appendingPathComponent(version, isDirectory: true)
        try archive.write(to: zip)
        defer { try? manager.removeItem(at: zip) }
        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path], failure: "Güncelleme açılamadı")

        let app = folder.appendingPathComponent(installedApp.lastPathComponent)
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == (Bundle.main.bundleIdentifier ?? bundle.bundleIdentifier),
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
            throw UpdateError(message: "İndirilen paket beklenen sürüm değil; kurulmadı")
        }
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path],
                      failure: "İndirilen paketin kod imzası bozuk; kurulmadı")
        return app
    }

    /// Uygulama kapanınca eski paketi yenisiyle değiştiren ve uygulamayı yeniden açan betiği başlatır,
    /// sonra uygulamayı kapatır. Değiştirme başarısız olursa eski paket yerine geri konur.
    private static func replaceAndRelaunch(with staged: URL) throws {
        let script = """
        pid="$1"; target="$2"; staged="$3"; backup="$2.eski"
        i=0
        while kill -0 "$pid" 2>/dev/null && [ $i -lt 300 ]; do sleep 0.2; i=$((i+1)); done
        rm -rf "$backup"
        if mv "$target" "$backup"; then
          if mv "$staged" "$target"; then
            rm -rf "$backup"
          else
            mv "$backup" "$target"
          fi
        fi
        xattr -dr com.apple.quarantine "$target" 2>/dev/null
        rm -rf "$(dirname "$staged")"
        [ "$4" = "relaunch" ] && open "$target"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "kd-update", String(ProcessInfo.processInfo.processIdentifier),
                             installedApp.path, staged.path, relaunchAfterInstall ? "relaunch" : "stay"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        NSApp.terminate(nil)
    }

    #if DEBUG
    /// Deneme: `KD_APP_UPDATE_TEST=1` ile açılışta denetleyip bulursa kendiliğinden kurar (yeniden açmaz).
    func runSelfTestIfRequested() {
        guard ProcessInfo.processInfo.environment["KD_APP_UPDATE_TEST"] != nil else { return }
        Task {
            await check()
            if availableRelease != nil { install() }
        }
    }
    #endif

    private static var relaunchAfterInstall: Bool {
        #if DEBUG
        // Deneme senaryosu yalnızca paketin değiştiğini denetler; kurulan kopyayı açmaz.
        if ProcessInfo.processInfo.environment["KD_APP_UPDATE_TEST"] != nil { return false }
        #endif
        return true
    }

    private static func run(_ tool: String, _ arguments: [String], failure: String) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw UpdateError(message: failure) }
        }.value
    }

    /// DEBUG'da `KD_UPDATE_CORRUPT` ile dosyayı bozar; imza denetiminin bozuk paketi reddettiğini denemek için.
    private static func corruptedForTesting(_ data: Data) -> Data {
        #if DEBUG
        if ProcessInfo.processInfo.environment["KD_UPDATE_CORRUPT"] != nil, !data.isEmpty {
            var corrupted = data
            corrupted[corrupted.count / 2] ^= 0xFF
            return corrupted
        }
        #endif
        return data
    }
}

/// İlerlemesi izlenebilen tek dosyalık indirme; iptal edilince (Task iptali) indirme de durur.
private final class ProgressDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let limit: Int64
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var cancelledByUser = false
    private let lock = NSLock()

    private init(limit: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
        self.limit = limit
        self.onProgress = onProgress
    }

    static func run(_ url: URL, limit: Int64, onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = ProgressDownload(limit: limit, onProgress: onProgress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: URLRequest(url: url, timeoutInterval: 60))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.lock.withLock { delegate.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            delegate.lock.withLock { delegate.cancelledByUser = true }
            task.cancel()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            downloadTask.cancel()
            return
        }
        if totalBytesExpectedToWrite > 0 {
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            finish(.failure(DownloadFailure(message: "Güncelleme indirilemedi")))
            return
        }
        // Geçici dosya bu metottan çıkınca silindiği için hemen taşınır.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("kd-update-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as? URLError)?.code == .cancelled {
            let byUser = lock.withLock { cancelledByUser }
            finish(.failure(byUser ? CancellationError() : DownloadFailure(message: "Güncelleme dosyası beklenenden büyük")))
        } else {
            finish(.failure(error))
        }
    }

    private struct DownloadFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
