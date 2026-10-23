// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenCove",
    // macOS 26 glass APIs are runtime guarded. Building needs the macOS 26 SDK
    // or later; the macOS 15 deployment target is not a tested OS guarantee.
    platforms: [.macOS(.v15)],
    products: [.executable(name: "OpenCove", targets: ["OpenCove"])],
    targets: [
        // Sparkle 2.10.0's official binary SDK, pinned to its upstream checksum.
        // A binary target has no floating Git dependency or Package.resolved.
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"
        ),
        .executableTarget(
            name: "OpenCove", dependencies: ["Sparkle"], path: "Sources/OpenCove",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ],
    swiftLanguageModes: [.v5]
)
