// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "StarPaper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "StarPaper",
            path: "Sources/StarPaper",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
