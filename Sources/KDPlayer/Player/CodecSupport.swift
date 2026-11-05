import Darwin

/// Uygulamaya gömülü VLCKit'in (statik FFmpeg'i içinde) hangi çözücülerle derlendiği.
/// VLCKit FFmpeg'in `ff_<ad>_decoder` sembollerini dışa açar; sembol yoksa çözücü derlenmemiştir.
enum CodecSupport {
    /// Dolby TrueHD / MLP (Blu-ray 7.1 ve Atmos parçaları).
    static let trueHD = hasDecoder("truehd")

    static func hasDecoder(_ name: String) -> Bool {
        // RTLD_DEFAULT: yüklü tüm imajlarda ara (VLCKit.framework dinamik bağlı).
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ff_\(name)_decoder") != nil
    }
}
