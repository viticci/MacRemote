// swift-tools-version: 6.2

import Foundation
import PackageDescription

// CLT-only workarounds: with Command Line Tools (no Xcode), Testing.framework
// lives under the CLT tree and Swift Build handles it incompletely:
// 1. The dependency scanner intermittently omits the resolved TestingMacros
//    plugin from some test-target frontend jobs ("plugin for module
//    'TestingMacros' not found"), so force-load the CLT copy of the plugin.
// 2. The linked test bundle references @rpath/Testing.framework but no rpath
//    covers the CLT frameworks directory, so add one — plus a second rpath for
//    lib_TestingInterop.dylib, which Testing.framework references relative to
//    an Xcode-style layout that does not match the CLT tree.
// Xcode-based environments skip both (the paths do not exist there).
let cltTestingMacrosPlugin =
    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
let cltTestingFrameworks =
    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltTestingInteropDir =
    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let testSwiftSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: cltTestingMacrosPlugin)
    ? [.unsafeFlags(["-load-plugin-library", cltTestingMacrosPlugin])]
    : []
let testLinkerSettings: [LinkerSetting] = FileManager.default.fileExists(atPath: cltTestingFrameworks)
    ? [.unsafeFlags([
        "-Xlinker", "-rpath", "-Xlinker", cltTestingFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", cltTestingInteropDir
    ])]
    : []

let package = Package(
    name: "MacRemote",
    platforms: [
        // Liquid Glass UI: the app builds from source on a macOS 27 host against the
        // 26.5 SDK (CLT's 27.0 SDK lacks the SwiftUIMacros plugin — see docs/design).
        .macOS(.v26)
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
                "AGENTS.md",
                "CONTRIBUTING.md",
                "INSTALL.md",
                "LICENSE",
                "SECURITY.md",
                "Resources",
                "script",
                "Tests",
                "Tools",
                // Compiled out-of-band by script/compile_shaders.sh (no Metal
                // compiler on the CLT host). Shaders/default.metallib is picked
                // up as a bundle resource automatically; ShaderLibrary.bundle(
                // .module) loads the bundle's default library by that name.
                "Shaders/ConduitLight.metal"
            ],
            sources: [
                "App",
                "Models",
                "Services",
                "Stores",
                "Support",
                "Views"
            ],
            resources: [
                .copy("Shaders/default.metallib"),
                // MCP Apps widget (SEP-1865): one adaptive HTML document,
                // linked selectively by curated categories (see
                // docs/design/MCP-UI-SPEC.md).
                .copy("Widget/MacRemoteWidget.html")
            ]
        ),
        .testTarget(
            name: "MacRemoteTests",
            dependencies: ["MacRemote"],
            path: "Tests/MacRemoteTests",
            // Scanner fixtures are read via #filePath, not Bundle.module.
            exclude: ["Fixtures"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        )
    ]
)
