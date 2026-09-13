// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kylmora",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Kylmora", targets: ["Kylmora"])
    ],
    targets: [
        .executableTarget(name: "Kylmora", path: "Sources/Kylmora"),
        .testTarget(name: "KylmoraTests", dependencies: ["Kylmora"], path: "Tests/KylmoraTests")
    ]
)
