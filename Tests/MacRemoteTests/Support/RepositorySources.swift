import Foundation
import Testing

/// The checked-out repository root, derived from this file's own location so the
/// scan works from any build directory and hardcodes nobody's home path.
private let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Support
    .deletingLastPathComponent()   // MacRemoteTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // repository root

/// Every `.swift` file under one top-level source directory.
///
/// AGENTS.md states several architectural rules as falsifiable `grep`s
/// ("`grep -rn 'ConnectedAppIdentity' Services Stores` must stay empty"). This
/// is how those become tests instead of review folklore. An unreadable or empty
/// directory throws rather than passing vacuously — a rule that silently stops
/// checking anything is worse than no rule.
func swiftSources(
    in directory: String,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> [URL] {
    let root = repositoryRoot.appendingPathComponent(directory, isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey]
    ) else {
        Issue.record("Could not read \(directory) at \(root.path).", sourceLocation: sourceLocation)
        throw NSError(domain: "MacRemoteTests", code: 1)
    }
    let files = enumerator
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }
    guard !files.isEmpty else {
        Issue.record("Found no Swift sources under \(directory).", sourceLocation: sourceLocation)
        throw NSError(domain: "MacRemoteTests", code: 1)
    }
    return files
}
