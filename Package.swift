// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ensemble",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Ensemble", targets: ["App"]),
        .executable(name: "ensemble-lab", targets: ["EnsembleLab"]),
    ],
    targets: [
        .target(
            name: "EnsembleCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "App",
            dependencies: ["EnsembleCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EnsembleCoreTests",
            dependencies: ["EnsembleCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "EnsembleLab",
            dependencies: ["EnsembleCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
