// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Duet",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Duet", targets: ["Duet"]),
        .executable(name: "duet-lab", targets: ["DuetLab"]),
    ],
    targets: [
        .target(
            name: "DuetCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Duet",
            dependencies: ["DuetCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DuetLab",
            dependencies: ["DuetCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
