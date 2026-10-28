// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HorizonCore",
    platforms: [.iOS("18.0"), .macOS(.v13)],
    products: [.library(name: "HorizonCore", targets: ["HorizonCore"])],
    targets: [
        .target(name: "HorizonCore"),
        .testTarget(name: "HorizonCoreTests", dependencies: ["HorizonCore"]),
    ]
)
