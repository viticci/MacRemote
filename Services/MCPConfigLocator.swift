import Foundation

/// Single source of truth for every on-disk MCP config path the scanner reads.
enum MCPConfigLocator {
    struct FileTarget: Sendable {
        let path: URL
    }

    struct DirectoryTarget: Sendable {
        let path: URL
        /// When set, snapshot includes sorted `manifest.json` mtimes under this tree.
        let manifestExtensionSnapshots: Bool
        let manifestSnapshotLimit: Int
    }

    enum ScanKind: Sendable {
        case toml(source: String)
        case json(source: String, rootKey: String)
        case claudeCodeProjects
    }

    /// Every file the scanner reads for configured servers (excluding runtime CLI).
    static func fileTargets(homeDirectory: URL) -> [FileTarget] {
        [
            homeDirectory.appendingPathComponent(".codex/config.toml"),
            homeDirectory.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"),
            homeDirectory.appendingPathComponent(".mcp.json"),
            homeDirectory.appendingPathComponent(".claude.json"),
            homeDirectory.appendingPathComponent(".cursor/mcp.json"),
            homeDirectory.appendingPathComponent(".lmstudio/mcp.json"),
            homeDirectory.appendingPathComponent("Library/Developer/Xcode/CodingAssistant/mcp-servers.json"),
            homeDirectory.appendingPathComponent(".grok/config.toml"),
            homeDirectory.appendingPathComponent(".config/grok/config.toml"),
            homeDirectory.appendingPathComponent(".config/opencode/opencode.json"),
            homeDirectory.appendingPathComponent(".config/opencode/opencode.jsonc"),
            homeDirectory.appendingPathComponent("Library/Application Support/Code/User/mcp.json"),
            homeDirectory.appendingPathComponent("Library/Application Support/Code - Insiders/User/mcp.json"),
            homeDirectory.appendingPathComponent(".codeium/windsurf/mcp_config.json"),
            homeDirectory.appendingPathComponent(".config/zed/settings.json"),
            homeDirectory.appendingPathComponent(".gemini/settings.json"),
            homeDirectory.appendingPathComponent(".gemini/antigravity/mcp_config.json"),
            homeDirectory.appendingPathComponent(".copilot/mcp-config.json"),
            homeDirectory.appendingPathComponent(".cline/data/settings/cline_mcp_settings.json"),
            homeDirectory.appendingPathComponent(".cline/mcp.json"),
            homeDirectory.appendingPathComponent(
                "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json"
            ),
        ]
        .map { FileTarget(path: $0) }
    }

    static func directoryTargets(homeDirectory: URL) -> [DirectoryTarget] {
        [
            DirectoryTarget(
                path: homeDirectory.appendingPathComponent(
                    "Library/Application Support/Claude/Claude Extensions",
                    isDirectory: true
                ),
                manifestExtensionSnapshots: true,
                manifestSnapshotLimit: 64
            ),
        ]
    }

    /// Maps each config file to one or more scanner passes. Keeps path lists in one place.
    static func scanKinds(for path: URL) -> [ScanKind] {
        let name = path.lastPathComponent
        let relative = path.standardizedFileURL.path

        switch name {
        case "config.toml":
            if relative.hasSuffix("/.codex/config.toml") {
                return [.toml(source: "codex")]
            }
            if relative.hasSuffix("/.grok/config.toml") || relative.hasSuffix("/.config/grok/config.toml") {
                return [.toml(source: "grok")]
            }
        case "claude_desktop_config.json":
            return [.json(source: "claude_desktop", rootKey: "mcpServers")]
        case ".mcp.json":
            return [.json(source: "claude_code", rootKey: "mcpServers")]
        case ".claude.json":
            return [
                .json(source: "claude_code", rootKey: "mcpServers"),
                .claudeCodeProjects,
            ]
        case "mcp.json":
            if relative.contains("/Code - Insiders/") || relative.contains("/Code/User/") {
                return [.json(source: "vscode", rootKey: "servers")]
            }
            if relative.hasSuffix("/.cursor/mcp.json") {
                return [.json(source: "cursor", rootKey: "mcpServers")]
            }
            if relative.hasSuffix("/.lmstudio/mcp.json") {
                return [.json(source: "lmstudio", rootKey: "mcpServers")]
            }
            if relative.hasSuffix("/.cline/mcp.json") {
                return [.json(source: "cline", rootKey: "mcpServers")]
            }
        case "mcp-servers.json":
            return [.json(source: "xcode_coding_assistant", rootKey: "mcpServers")]
        case "opencode.json", "opencode.jsonc":
            return [.json(source: "opencode", rootKey: "mcp")]
        case "mcp_config.json":
            if relative.hasSuffix("/.codeium/windsurf/mcp_config.json") {
                return [.json(source: "windsurf", rootKey: "mcpServers")]
            }
            if relative.hasSuffix("/.gemini/antigravity/mcp_config.json") {
                return [.json(source: "antigravity", rootKey: "mcpServers")]
            }
        case "settings.json":
            if relative.hasSuffix("/.config/zed/settings.json") {
                return [.json(source: "zed", rootKey: "context_servers")]
            }
            if relative.hasSuffix("/.gemini/settings.json") {
                return [.json(source: "gemini", rootKey: "mcpServers")]
            }
        case "mcp-config.json":
            return [.json(source: "copilot_cli", rootKey: "mcpServers")]
        case "cline_mcp_settings.json":
            return [.json(source: "cline", rootKey: "mcpServers")]
        default:
            break
        }
        return []
    }

    /// Pure filesystem stats: no subprocess, no network. `additionalPaths`
    /// lets the scanner include installed first-party executables, whose
    /// presence and version define the synthesized first-party candidates.
    static func configSnapshot(homeDirectory: URL, additionalPaths: [String] = []) -> String {
        var lines = [String]()

        for target in fileTargets(homeDirectory: homeDirectory) {
            lines.append(fileStatLine(for: target.path))
        }
        for path in additionalPaths {
            lines.append(fileStatLine(for: URL(fileURLWithPath: path)))
        }

        for target in directoryTargets(homeDirectory: homeDirectory) {
            if target.manifestExtensionSnapshots {
                lines.append(contentsOf: manifestStatLines(
                    under: target.path,
                    limit: target.manifestSnapshotLimit
                ))
            } else {
                lines.append(fileStatLine(for: target.path))
            }
        }

        return lines.sorted().joined(separator: "\n")
    }

    /// The stat line of the file an executable path leads to, symlinks
    /// followed. MacRemote compares it with the line it saved after the last
    /// successful import of a first-party CLI to tell that the CLI changed.
    static func executableStatLine(path: String) -> String {
        fileStatLine(for: URL(fileURLWithPath: path).resolvingSymlinksInPath())
    }

    private static func fileStatLine(for url: URL) -> String {
        let path = url.path
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else {
            return "\(path)|0|0|0"
        }
        guard let attributes = try? manager.attributesOfItem(atPath: path) else {
            return "\(path)|1|0|0"
        }
        let mtime = Int((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        return "\(path)|1|\(mtime)|\(size)"
    }

    /// Stats the `manifest.json` in each extension's own folder, and nothing
    /// deeper: an extension can hold a whole `node_modules` tree, and the
    /// Tools page reads this snapshot on every redraw.
    private static func manifestStatLines(under root: URL, limit: Int) -> [String] {
        guard let extensionFolders = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return ["\(root.path)|0|0|0"]
        }

        var manifests = [(path: String, mtime: Int)]()
        for folder in extensionFolders {
            let fileURL = folder.appendingPathComponent("manifest.json")
            // Throws when the folder has no manifest (or is not a folder).
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]) else {
                continue
            }
            let mtime = Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
            manifests.append((fileURL.path, mtime))
        }

        manifests.sort { $0.path < $1.path }
        if manifests.count > limit {
            manifests = Array(manifests.prefix(limit))
        }

        if manifests.isEmpty {
            return ["\(root.path)|0|0|0"]
        }

        return manifests.map { "\($0.path)|1|\($0.mtime)|0" }
    }
}
