// swift-tools-version:6.0
// macOS app package. `ZagonUIModel` is platform-independent (view models, formatting, mock data) and is
// built and tested on Linux too; the SwiftUI app target exists only when the manifest is evaluated on macOS.
import Foundation
import PackageDescription

// ZagonCore comes from the repository root; a path dependency's identity is its directory name.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let core = Target.Dependency.product(name: "ZagonCore", package: root.lastPathComponent.lowercased())

var products: [Product] = [.library(name: "ZagonUIModel", targets: ["ZagonUIModel"])]
var targets: [Target] = [
    .target(name: "ZagonUIModel", dependencies: [core]),
    .testTarget(name: "ZagonUIModelTests", dependencies: ["ZagonUIModel", core]),
]
#if os(macOS)
products.append(.executable(name: "Zagon", targets: ["ZagonApp"]))
targets.append(.executableTarget(name: "ZagonApp", dependencies: ["ZagonUIModel"],
                                 swiftSettings: [.swiftLanguageMode(.v5)]))
#endif

let package = Package(
    name: "ZagonMac",
    platforms: [.macOS(.v13)],
    products: products,
    dependencies: [.package(path: "../..")],
    targets: targets
)
