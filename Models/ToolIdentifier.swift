import CryptoKit
import Foundation

enum ToolIdentifierError: LocalizedError, Equatable, Sendable {
    case invalid(String)
    case duplicate(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let identifier):
            "Invalid tool identifier: \(identifier)"
        case .duplicate(let identifier):
            "Duplicate tool identifier: \(identifier)"
        }
    }
}

/// Stable, MCP-facing tool identifiers. These are API names, persistence keys,
/// and runtime lookup keys, so they are deliberately independent from OAuth
/// clients, tokens, endpoints, executable locations, and editable titles after
/// creation.
enum ToolIdentifier {
    static let maximumLength = 64

    static func isValid(_ identifier: String) -> Bool {
        guard !identifier.isEmpty,
              identifier.count <= maximumLength,
              let first = identifier.utf8.first,
              isASCIILowercaseLetter(first) else {
            return false
        }

        return identifier.utf8.allSatisfy { byte in
            isASCIILowercaseLetter(byte) || (48...57).contains(byte) || byte == 95
        }
    }

    static func validate(_ identifier: String) throws {
        guard isValid(identifier) else {
            throw ToolIdentifierError.invalid(identifier)
        }
    }

    static func presetToolID(from presetID: String) -> String {
        let raw = presetID.hasPrefix("preset.") ? String(presetID.dropFirst("preset.".count)) : presetID
        return fitted(normalizedComponent(raw), discriminator: presetID)
    }

    static func customToolID(title: String, existingIDs: Set<String>) -> String {
        allocatedNumeric(
            base: fitted("custom_\(normalizedComponent(title))", discriminator: "custom:\(title)"),
            existingIDs: existingIDs
        )
    }

    static func scannedToolID(
        source: DiscoveredCLICandidate.Source,
        binaryName: String,
        existingIDs: Set<String> = []
    ) -> String {
        allocatedNumeric(
            base: fitted(
                "scan_\(sourceComponent(source))_\(normalizedComponent(binaryName))",
                discriminator: "scan:\(source.rawValue):\(binaryName)"
            ),
            existingIDs: existingIDs
        )
    }

    /// Imported-tool identity uses only the configured server name and exact
    /// upstream tool name. In particular, URLs, command paths, headers, OAuth
    /// clients, access/refresh tokens, sessions, and schemas never participate.
    static func importedMCPToolID(
        serverName: String,
        upstreamToolName: String,
        existingIDs: Set<String> = [],
        forceStableSuffix: Bool = false
    ) -> String {
        let server = normalizedComponent(serverName)
        let upstream = normalizedComponent(upstreamToolName)
        // A server that already prefixes its tool names with its own name
        // (`notesctl` → `notesctl_search`) keeps `notesctl_search`, not
        // `notesctl_notesctl_search`.
        let base = upstream.hasPrefix(server + "_") ? upstream : "\(server)_\(upstream)"
        let discriminator = "mcp:\(serverName):\(upstreamToolName)"
        let fittedBase = fitted(base, discriminator: discriminator)
        guard forceStableSuffix || existingIDs.contains(fittedBase) else {
            return fittedBase
        }
        return hashSuffixed(base: fittedBase, discriminator: discriminator)
    }

    static func normalizedComponent(_ value: String) -> String {
        var result = ""
        var lastWasSeparator = false

        for byte in value.utf8 {
            let normalized: UInt8?
            switch byte {
            case 65...90:
                normalized = byte + 32
            case 97...122, 48...57:
                normalized = byte
            default:
                normalized = nil
            }

            if let normalized {
                result.append(Character(UnicodeScalar(normalized)))
                lastWasSeparator = false
            } else if !result.isEmpty, !lastWasSeparator {
                result.append("_")
                lastWasSeparator = true
            }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "tool" : trimmed
    }

    private static func allocatedNumeric(base: String, existingIDs: Set<String>) -> String {
        guard !existingIDs.contains(base) else {
            var suffix = 2
            while true {
                let suffixText = "_\(suffix)"
                let prefix = String(base.prefix(maximumLength - suffixText.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
                let candidate = prefix + suffixText
                if !existingIDs.contains(candidate) {
                    return candidate
                }
                suffix += 1
            }
        }
        return base
    }

    private static func fitted(_ value: String, discriminator: String) -> String {
        let component = normalizedComponent(value)
        let normalized = component.utf8.first.map(isASCIILowercaseLetter) == true
            ? component
            : "tool_\(component)"
        guard normalized.count > maximumLength else {
            return normalized
        }
        return hashSuffixed(base: normalized, discriminator: discriminator)
    }

    private static func hashSuffixed(base: String, discriminator: String) -> String {
        let digest = SHA256.hash(data: Data(discriminator.utf8))
            .prefix(5)
            .map { String(format: "%02x", $0) }
            .joined()
        let suffix = "_\(digest)"
        let prefix = String(normalizedComponent(base).prefix(maximumLength - suffix.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return prefix + suffix
    }

    private static func sourceComponent(_ source: DiscoveredCLICandidate.Source) -> String {
        switch source {
        case .homebrewFormula: "homebrew_formula"
        case .homebrewTap: "homebrew_tap"
        case .homebrewCask: "homebrew_cask"
        case .npmGlobal: "npm_global"
        case .uvTool: "uv_tool"
        case .pipx: "pipx"
        case .pipUser: "pip_user"
        case .cargo: "cargo"
        case .goBinary: "go_binary"
        case .application: "application"
        case .looseBinary: "loose_binary"
        }
    }

    private static func isASCIILowercaseLetter(_ byte: UInt8) -> Bool {
        (97...122).contains(byte)
    }
}
