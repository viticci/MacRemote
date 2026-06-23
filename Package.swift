// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacRemote",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacRemote", targets: ["MacRemote"])
    ],
    targets: [
        .executableTarget(
            name: "MacRemote",
            path: ".",
            exclude: [
                ".codex",
                ".git",
                "dist",
                "docs",
                "README.md",
                "script",
                "Tests"
            ],
            sources: [
                "App",
                "Models",
                "Services",
                "Stores",
                "Support",
                "Views"
            ]
        ),
        .testTarget(
            name: "MacRemoteTests",
            dependencies: ["MacRemote"],
            path: "Tests/MacRemoteTests"
        )
    ]
)
