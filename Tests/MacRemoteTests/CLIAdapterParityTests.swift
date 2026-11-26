import Foundation
import Testing
@testable import MacRemote

@Suite("Federico CLI catalog parity")
struct CLIAdapterParityTests {
    private static let providers: [(String, Int, Set<String>)] = [
        ("frames", 6, ["devices", "frame_image", "frame_video", "info", "run", "video_info"])
    ]

    @Test("Swift catalog has the exact sparse first-party surface")
    func exactSurface() throws {
        let all = DefaultToolPresetCatalog.presets
        for (provider, count, suffixes) in Self.providers {
            let matching = all.filter { $0.id.hasPrefix("preset.\(provider).") }
            #expect(matching.count == count)
            #expect(Set(matching.map { String($0.id.dropFirst("preset.\(provider).".count)) }) == suffixes)
            #expect(matching.allSatisfy { $0.publisher == .federicoViticci })
            #expect(matching.count(where: { $0.mode == .cliAdapter }) == 1)
            #expect(matching.first(where: { $0.mode == .cliAdapter })?.approvalPolicy == .everyCall)
        }
        let federico = all.filter { $0.publisher == .federicoViticci }
        #expect(federico.count == 6)
        #expect(federico.count(where: { $0.mode == .commandTemplate }) == 5)
        #expect(federico.count(where: { $0.mode == .cliAdapter }) == 1)
        #expect(!all.contains(where: { $0.id.hasPrefix("preset.matter.") }))
        #expect(!all.contains(where: { $0.id.hasPrefix("preset.readwise.") }))
    }

    @Test("Every installed first-party executable still advertises required command families")
    func installedHelp() async throws {
        let checks: [(String?, [String])] = [
            (AppleFramesToolPresetCatalog.detectedExecutablePath, ["list", "info", "frame", "video-info", "video"])
        ]
        for (path, commands) in checks {
            // Each of these command-line tools is optional. On a Mac without
            // one there is nothing to compare, so that tool is skipped.
            guard let executable = path else { continue }
            let result = try await ProcessRunner().run(
                executablePath: executable,
                arguments: ["--help"],
                timeoutSeconds: 10,
                outputByteLimit: 1024 * 1024,
                environment: ExecutableLocator.toolEnvironment
            )
            #expect(result.succeeded)
            let help = result.stdout + result.stderr
            for command in commands {
                #expect(help.contains(command), "\(executable) help is missing \(command)")
            }
        }
    }

    @Test("Installed help advertises every option used by a dedicated recipe")
    func installedRecipeOptions() async throws {
        let checks: [(String?, [String], [String])] = [
            (AppleFramesToolPresetCatalog.detectedExecutablePath, ["frame"], ["--output", "--device", "--color", "--merge"]),
            (AppleFramesToolPresetCatalog.detectedExecutablePath, ["video-info"], ["--device", "--color", "--rotate"]),
            (AppleFramesToolPresetCatalog.detectedExecutablePath, ["video"], ["--output", "--preset", "--device", "--color", "--rotate", "--merge", "--playback-offset"])
        ]
        for (path, arguments, requiredOptions) in checks {
            // Each of these command-line tools is optional. On a Mac without
            // one there is nothing to compare, so that tool is skipped.
            guard let executable = path else { continue }
            let result = try await ProcessRunner().run(
                executablePath: executable,
                arguments: arguments + ["--help"],
                timeoutSeconds: 10,
                outputByteLimit: 1024 * 1024,
                environment: ExecutableLocator.toolEnvironment
            )
            #expect(result.succeeded, "\(executable) \(arguments.joined(separator: " ")) --help")
            let help = result.stdout + result.stderr
            for option in requiredOptions {
                #expect(
                    help.contains(option),
                    "\(executable) \(arguments.joined(separator: " ")) help is missing \(option)"
                )
            }
        }
    }
}
