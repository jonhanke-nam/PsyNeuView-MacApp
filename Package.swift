// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PsyNeuView",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "PsyNeuView",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/PsyNeuView"
        ),
        // `swift build` skips test targets, so this is safe with the
        // CommandLineTools toolchain; `swift test` needs full Xcode (available
        // on CI and via Xcode locally). (#44)
        .testTarget(
            name: "PsyNeuViewTests",
            dependencies: ["PsyNeuView"],
            path: "Tests/PsyNeuViewTests"
        ),
    ]
)
