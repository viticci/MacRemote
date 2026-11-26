import Foundation

/// Shared MCP Apps wire constants and JSON metadata builders.
///
/// `LocalMCPServer` owns protocol negotiation and decides whether a client is
/// eligible to receive these fields. This type only keeps the emitted metadata
/// internally consistent across initialize, tools/list, resources/read, and
/// CallToolResult.
enum MCPAppsMetadata {
    static let extensionIdentifier = "io.modelcontextprotocol/ui"
    static let protocolVersion = "2026-01-26"
    // v9: a result without MacRemote's card metadata draws nothing, so a
    // host that still links the card from a cached tool list shows no card
    // once the owner turns cards off. v8: the color scheme follows the app's
    // theme. Prior cache keys remain readable for existing conversations.
    static let resourceURI = "ui://macremote/output-v9.html"
    static let priorResourceURIs = [
        "ui://macremote/output-v8.html",
        "ui://macremote/output-v7.html",
        "ui://macremote/output-v6.html",
        "ui://macremote/output-v5.html",
        "ui://macremote/output-v4.html",
        "ui://macremote/output-v3.html",
        "ui://macremote/output-v2.html"
    ]
    static let legacyResourceURI = "ui://macremote/output"
    static let readableResourceURIs =
        [resourceURI] + priorResourceURIs + [legacyResourceURI]
    static let resourceMIMEType = "text/html;profile=mcp-app"
    static let toolUIKey = "ui"
    static let deprecatedResourceURIKey = "ui/resourceUri"
    static let openAIOutputTemplateKey = "openai/outputTemplate"
    static let openAIWidgetAccessibleKey = "openai/widgetAccessible"
    static let widgetDescription =
        "Displays MacRemote tool results as safe semantic summaries, adaptive tables, cards, documents, related content, attachments, and approved row actions."

    /// Outside origins the widget may load images from: none. The Pocket
    /// Casts artwork origin left with the podcast catalogs (SPEC D88).
    static let resourceDomains: [String] = []

    static var serverExtensionCapability: [String: Any] {
        [extensionIdentifier: [:]]
    }

    static var clientExtensionCapability: [String: Any] {
        [
            extensionIdentifier: [
                "mimeTypes": [resourceMIMEType]
            ]
        ]
    }

    /// Canonical form of a media type: lowercased type/subtype, parameters
    /// trimmed, unquoted, and order-independent. Parameter *values* keep their
    /// case (only `charset` is case-insensitive, and we don't use it).
    ///
    /// A byte-exact comparison was wrong here. RFC 9110 permits optional
    /// whitespace around parameters, allows a quoted parameter value, and lets a
    /// host add unrelated parameters, so `text/html; profile="mcp-app"` and
    /// `text/html;profile=mcp-app;charset=utf-8` both mean exactly what our
    /// `text/html;profile=mcp-app` means.
    ///
    /// What this fixes is the LEGACY negotiation path: a legacy client whose
    /// `initialize` spelled the media type legally but differently was recorded
    /// as not supporting Apps, so it kept getting the deprecated URI aliases
    /// while `resources/read` withheld the standard `_meta.ui` sandbox block —
    /// pointed at a resource it could not instantiate. That is a real
    /// correctness bug on that path, and it is all this change fixes.
    /// (Since 2026-07-30 nothing withholds that block: the sandbox policy goes
    /// to every client on every path — see `widgetContentMetadata`. Recognizing
    /// the spelling still decides the *linkage*, which stays capability-scoped.)
    ///
    /// It does NOT explain the 2026-07-30 "Failed to load the MCP app" incident
    /// in claude.ai. A modern client whose spelling we failed to recognize is
    /// never offered the widget in the first place — no tool linkage, no
    /// resource entry — so there is nothing for it to fail to load. The
    /// `resources/read` path was audited for that incident and came back clean:
    /// no reachable 5xx or JSON-RPC error past authentication. That failure
    /// remains unexplained and is consistent with a transient transport or
    /// tunnel failure.
    static func normalizedMediaType(_ raw: String) -> String {
        let pieces = raw.split(separator: ";", omittingEmptySubsequences: false)
        guard let essence = pieces.first else { return "" }
        var parameters: [String] = []
        for piece in pieces.dropFirst() {
            let parameter = piece.trimmingCharacters(in: .whitespaces)
            guard !parameter.isEmpty else { continue }
            guard let separator = parameter.firstIndex(of: "=") else {
                parameters.append(parameter.lowercased())
                continue
            }
            let name = parameter[..<separator]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            var value = parameter[parameter.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            parameters.append("\(name)=\(value)")
        }
        return essence.trimmingCharacters(in: .whitespaces).lowercased()
            + parameters.sorted().map { ";" + $0 }.joined()
    }

    /// Normalized type/subtype plus its set of normalized parameters.
    private static func mediaTypeParts(
        _ raw: String
    ) -> (essence: String, parameters: Set<String>) {
        let pieces = normalizedMediaType(raw)
            .split(separator: ";", omittingEmptySubsequences: false)
            .map(String.init)
        return (pieces.first ?? "", Set(pieces.dropFirst()))
    }

    /// True for the Apps media type, including a host that adds unrelated
    /// parameters: `text/html;profile=mcp-app;charset=utf-8` is the same media
    /// type as ours. Everything we require must still be there — a bare
    /// `text/html`, a different `profile`, or another type/subtype fails.
    /// Extra parameters are forgiven; a missing or wrong `profile` never is.
    static func isHTMLAppMediaType(_ raw: String) -> Bool {
        let expected = mediaTypeParts(resourceMIMEType)
        let actual = mediaTypeParts(raw)
        guard actual.essence == expected.essence else { return false }
        return expected.parameters.isSubset(of: actual.parameters)
    }

    static func clientSupportsHTMLApp(capabilities: [String: Any]?) -> Bool {
        guard let extensions = capabilities?["extensions"] as? [String: Any],
              let appCapability = extensions[extensionIdentifier] as? [String: Any],
              let mimeTypes = appCapability["mimeTypes"] as? [String] else {
            return false
        }
        return mimeTypes.contains(where: isHTMLAppMediaType)
    }

    /// Adds the standard nested tool linkage first, then compatibility mirrors.
    static func toolMetadata(merging existing: [String: Any] = [:]) -> [String: Any] {
        var metadata = existing
        var ui = metadata[toolUIKey] as? [String: Any] ?? [:]
        ui["resourceUri"] = resourceURI
        if ui["visibility"] == nil {
            ui["visibility"] = ["model", "app"]
        }
        metadata[toolUIKey] = ui
        metadata[deprecatedResourceURIKey] = resourceURI
        metadata[openAIOutputTemplateKey] = resourceURI
        metadata[openAIWidgetAccessibleKey] =
            (ui["visibility"] as? [String])?.contains("app") == true
        return metadata
    }

    /// The widget's sandbox policy: no fetch/XHR origins, no outside image
    /// origins, and a clipboard-write request.
    ///
    /// Hosts read this from two places — the `resources/list` descriptor and
    /// the `resources/read` content item, where the content item wins — so both
    /// declare it from this one source and can never drift apart.
    static var uiPolicy: [String: Any] {
        [
            "prefersBorder": true,
            "csp": [
                "connectDomains": [],
                "resourceDomains": resourceDomains
            ],
            "permissions": [
                "clipboardWrite": [:]
            ]
        ]
    }

    static var resourceContentMetadata: [String: Any] {
        [
            "ui": uiPolicy,
            "openai/widgetDescription": widgetDescription,
            "openai/widgetPrefersBorder": true,
            "openai/widgetCSP": [
                "connect_domains": [],
                "resource_domains": resourceDomains
            ]
        ]
    }

    static var resourceDescriptor: [String: Any] {
        [
            "uri": resourceURI,
            "name": "macremote-output",
            "title": "MacRemote Tool Output",
            "description": "Safe rendering of any MacRemote tool result: semantic summaries, tables, cards, documents, related content, attachments, and declared row actions.",
            "mimeType": resourceMIMEType,
            // The Apps spec has hosts check the descriptor as well as the read
            // result, so a host that applies its sandbox from the listing —
            // before it ever reads the resource — still gets the CSP allowlist.
            "_meta": ["ui": uiPolicy]
        ]
    }
}
