// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ArchiveDesk", platforms: [.macOS(.v14)], products: [.executable(name: "ArchiveDesk", targets: ["ArchiveDesk"])], targets: [.target(name: "ArchiveCore"), .executableTarget(name: "ArchiveDesk", dependencies: ["ArchiveCore"]), .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"])])
