import Foundation

struct ToolRegistryStore: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            return
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.fileURL = base
            .appendingPathComponent("MacRemote", isDirectory: true)
            .appendingPathComponent("tools.json")
    }

    func loadUserDefinedTools() throws -> [ToolDefinition] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let tools = try JSONDecoder().decode([ToolDefinition].self, from: data)
        return try tools.filter(\.isUserDefined).map { tool in
            try ToolArgumentResolver.validate(tool)
            return tool
        }
    }

    func saveUserDefinedTools(_ tools: [ToolDefinition]) throws {
        let userTools = try tools.filter(\.isUserDefined).map { tool in
            try ToolArgumentResolver.validate(tool)
            return tool
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.sortedPrettyPrinted.encode(userTools)
        try data.write(to: fileURL, options: [.atomic])
    }
}

private extension JSONEncoder {
    static var sortedPrettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
