import Foundation

/// The app, command-line tool, or server a tool comes from, as the owner
/// thinks of it: RemCTL, Apple Frames, File Transfer, `rg`.
///
/// One rule, used by the Tools page's server groups and by per-family
/// preferences such as result cards (SPEC D77):
///
/// 1. A bridged MCP server is one family, keyed by the same server identity
///    the Tools page groups by.
/// 2. The built-in File Transfer tools are one family.
/// 3. A catalog provider (`provider.frames`) is one family, matched by its
///    stable tool-ID prefix, so the key does not depend on where the
///    executable is installed or whether it is detected right now.
/// 4. Every other process tool groups by its executable's file name.
///
/// The ID is a local preference key only. It never reaches an app, never
/// enters `tools.json`, and never affects a security decision.
struct ToolFamily: Identifiable, Hashable, Sendable {
    let id: String
    let name: String

    static let fileTransferID = "builtin.file-transfer"
    static let unnamedServerName = "Local MCP Server"

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(_ tool: ToolDefinition) {
        if tool.isMCPBridge {
            self.init(
                id: Self.bridgeIdentity(of: tool),
                name: tool.mcpBridgeServerName ?? Self.unnamedServerName
            )
        } else if tool.backend == .native {
            self.init(id: Self.fileTransferID, name: "File Transfer")
        } else if let provider = DefaultToolPresetCatalog.provider(forToolID: tool.id) {
            self.init(id: provider.id, name: provider.name)
        } else {
            let basename = (tool.executablePath as NSString).lastPathComponent
            let name = basename.isEmpty ? tool.name : basename
            self.init(id: "executable:\(name.lowercased())", name: name)
        }
    }

    /// The key the Tools page uses for a bridged server's group and its scan
    /// candidate. Kept unprefixed so existing selections keep working.
    static func bridgeIdentity(of tool: ToolDefinition) -> String {
        tool.mcpBridgeServerIdentity ?? tool.mcpBridgeIdentity ?? tool.id
    }

    /// Distinct families for `tools`, sorted by name.
    static func families(of tools: [ToolDefinition]) -> [ToolFamily] {
        var seen: Set<String> = []
        return tools
            .map(ToolFamily.init)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
