// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenCove",
    // macOS 26 glass APIs are runtime guarded. Building needs the macOS 26 SDK
    // or later; the macOS 15 deployment target is not a tested OS guarantee.
    platforms: [.macOS(.v15)],
    products: [.executable(name: "OpenCove", targets: ["OpenCove"])],
    targets: [.executableTarget(name: "OpenCove", path: "Sources/OpenCove")],
    swiftLanguageModes: [.v5]
)
