// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Porthole",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Porthole",
            path: "Sources/Porthole"
        )
    ]
)
