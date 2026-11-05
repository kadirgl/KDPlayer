// swift-tools-version: 6.0
import PackageDescription

// VLCKit, `scripts/fetch-vlckit.sh` ile Vendor/ altına indirilir (depoya girmez).
let package = Package(
    name: "KDPlayer",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(name: "VLCKit", path: "Vendor/VLCKit.xcframework"),
        .executableTarget(
            name: "KDPlayer",
            dependencies: ["VLCKit"],
            path: "Sources/KDPlayer",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Paketlenmiş uygulamada VLCKit.framework Contents/Frameworks altında durur.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-Xlinker", "-rpath", "-Xlinker", "@loader_path"])
            ]
        ),
        .testTarget(
            name: "KDPlayerTests",
            dependencies: ["KDPlayer"],
            path: "Tests/KDPlayerTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
