import CryptoKit
import Foundation

/// Additive discovery metadata for clients that want a compact view of the
/// catalog. Standard `tools/list` remains the authoritative tool contract.
enum MCPCatalogMetadata {
    static let resourceURI = "macremote://catalog/v1"
    static let resourceMIMEType = "application/json"
    static let revisionMetaKey = "net.viticci.macremote/catalogRevision"

    /// Canonical, order-independent digest of the published tool contract.
    /// Each descriptor is serialized exactly once; sorting compares those
    /// strings instead of re-serializing inside the comparator.
    static func revision(for descriptors: [[String: Any]]) -> String {
        let serialized = descriptors.map { descriptor in
            (name: descriptor["name"] as? String ?? "", json: canonicalJSONString(descriptor))
        }
        .sorted { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.json < rhs.json
        }
        var payload = Data("{\"tools\":[".utf8)
        payload.append(serialized.map(\.json).joined(separator: ",").data(using: .utf8) ?? Data())
        payload.append(Data("],\"version\":1}".utf8))
        let hash = SHA256.hash(data: payload)
        return "sha256:" + hash.map { String(format: "%02x", $0) }.joined()
    }

    static func manifest(
        tools: [ToolDefinition],
        descriptors: [[String: Any]]
    ) -> [String: Any] {
        var descriptorByName: [String: [String: Any]] = [:]
        for descriptor in descriptors {
            guard let name = descriptor["name"] as? String,
                  descriptorByName[name] == nil else { continue }
            descriptorByName[name] = descriptor
        }
        let entries: [[String: Any]] = tools.sorted { $0.id < $1.id }.compactMap { tool in
            guard let descriptor = descriptorByName[tool.id] else { return nil }
            return [
                "name": tool.id,
                "title": tool.name,
                "category": tool.category.rawValue,
                "capability": tool.capability.rawValue,
                "source": [
                    "origin": tool.origin.rawValue,
                    "backend": sourceBackend(tool.backend)
                ],
                "schemaRevision": schemaRevision(for: descriptor)
            ]
        }

        return [
            "version": 1,
            "revision": revision(for: descriptors),
            "tools": entries
        ]
    }

    static func suggestions(
        for unknownName: String,
        tools: [ToolDefinition],
        limit: Int = 3
    ) -> [[String: Any]] {
        guard limit > 0,
              !unknownName.isEmpty,
              unknownName.utf8.count <= 64 else {
            return []
        }

        let needles = [
            unknownName.lowercased(),
            ToolIdentifier.normalizedComponent(unknownName)
        ]
        let maximumDistance = max(2, min(6, needles[1].count / 3))
        return tools.compactMap { tool -> (distance: Int, name: String, title: String)? in
            let candidates = [
                tool.id.lowercased(),
                tool.name.lowercased(),
                ToolIdentifier.normalizedComponent(tool.name)
            ]
            let distance = needles.flatMap { needle in
                candidates.map { editDistance(needle, $0) }
            }.min() ?? Int.max
            let sharesPrefix = needles.contains { needle in
                candidates.contains { candidate in
                    candidate.hasPrefix(needle) || needle.hasPrefix(candidate)
                }
            }
            guard distance <= maximumDistance || sharesPrefix else { return nil }
            return (distance, tool.id, tool.name)
        }
        .sorted { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            return lhs.name < rhs.name
        }
        .prefix(limit)
        .map { suggestion in
            [
                "name": suggestion.name,
                "title": suggestion.title
            ]
        }
    }

    private static func schemaRevision(for descriptor: [String: Any]) -> String {
        var contract: [String: Any] = [:]
        for key in ["inputSchema", "outputSchema", "annotations", "securitySchemes"] {
            if let value = descriptor[key] {
                contract[key] = value
            }
        }
        return digest(contract)
    }

    private static func sourceBackend(_ backend: ToolBackend) -> String {
        switch backend {
        case .process: "process"
        case .mcpHTTPBridge: "mcp_http"
        case .mcpStdioBridge: "mcp_stdio"
        case .native: "native"
        }
    }

    private static func digest(_ object: Any) -> String {
        let data = canonicalJSONData(object)
        let hash = SHA256.hash(data: data)
        return "sha256:" + hash.map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalJSONData(_ object: Any) -> Data {
        (try? JSONSerialization.checkedData(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("null".utf8)
    }

    private static func canonicalJSONString(_ object: Any) -> String {
        String(decoding: canonicalJSONData(object), as: UTF8.self)
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(right.count + 1)
            for (rightIndex, rightCharacter) in right.enumerated() {
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                let substitution = previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                current.append(min(insertion, deletion, substitution))
            }
            previous = current
        }
        return previous[right.count]
    }
}
