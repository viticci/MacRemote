import Foundation

/// Sensitive-path denylist for the native file-transfer tools. Paths are
/// checked after symlink resolution so a symlink into a denied tree is blocked.
struct FileTransferPathPolicy: Sendable {
    let homeDirectory: String

    init(homeDirectory: String? = nil) {
        self.homeDirectory = homeDirectory ?? ExecutableLocator.homeDirectory
    }

    var deniedPathPrefixes: [String] {
        let home = (homeDirectory as NSString).standardizingPath
        return [
            home + "/.ssh",
            home + "/.gnupg",
            home + "/.aws",
            home + "/Library/Keychains",
            home + "/.cloudflared",
            home + "/Library/Application Support/MacRemote"
        ].map { ($0 as NSString).standardizingPath }
    }

    enum PathError: Error, Equatable {
        case invalidPath
        case pathDenied
    }

    func resolveUserPath(_ rawPath: String) throws -> String {
        let expanded = expandTilde(in: rawPath)
        guard expanded.hasPrefix("/") else {
            throw PathError.invalidPath
        }

        let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        let normalized = (resolved as NSString).standardizingPath
        if isDenied(normalized) {
            throw PathError.pathDenied
        }
        return normalized
    }

    func isDenied(_ resolvedPath: String) -> Bool {
        let normalized = (resolvedPath as NSString).standardizingPath
        return deniedPathPrefixes.contains { prefix in
            normalized == prefix || normalized.hasPrefix(prefix + "/")
        }
    }

    private func expandTilde(in path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        if path == "~" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return homeDirectory + String(path.dropFirst())
        }
        return path
    }
}
