// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Kura",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6")
    ],
    targets: [
        .executableTarget(
            name: "Kura",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Kura",
            exclude: ["Resources"]
        )
    ]
)
