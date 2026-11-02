// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GeroDiskManager",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GeroDiskManager", targets: ["GeroDiskManager"])],
    targets: [.executableTarget(name: "GeroDiskManager")]
)
