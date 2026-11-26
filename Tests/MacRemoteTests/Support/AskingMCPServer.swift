import Foundation
@testable import MacRemote

/// A made-up legacy (2025-11-25) stdio MCP server whose one tool, `ask`,
/// asks the person questions with `elicitation/create` before it answers
/// (SPEC D82). Arguments: `kind` is `"form"` (the default, one `color` text
/// field) or `"url"`; `rounds` is how many questions it asks, one after
/// another (default 1). Its result's `structuredContent.answers` lists the
/// answer MacRemote sent back for each question, so a test can see what the
/// upstream received. Used by the relay tests and the stress harness.
struct AskingMCPServer {
    static let serverName = "fixture"

    let directory: URL
    let scriptURL: URL

    init(in directory: URL) throws {
        self.directory = directory
        scriptURL = directory.appendingPathComponent("asking_server.py")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// The bridged tool, named `id`, that runs this server's `ask`.
    func tool(id: String, timeoutSeconds: TimeInterval = 30) -> ToolDefinition {
        ToolDefinition(
            id: id,
            name: id,
            summary: "Asks the person a question, then reports the answer.",
            executablePath: "",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: timeoutSeconds,
            outputByteLimit: 64 * 1024,
            origin: .userDefined,
            category: .developer,
            backend: .mcpStdioBridge,
            mcpStdioBridge: MCPStdioBridgeConfiguration(
                serverName: Self.serverName,
                command: scriptURL.path,
                startupTimeoutSeconds: 10,
                toolName: "ask",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "kind": .object(["type": .string("string")]),
                        "rounds": .object(["type": .string("integer")])
                    ])
                ]),
                protocolVersion: "2025-11-25"
            )
        )
    }

    /// The question's `requestedSchema`, exactly as the server sends it.
    static var colorSchema: [String: Any] {
        [
            "type": "object",
            "properties": ["color": ["type": "string", "title": "Color"]],
            "required": ["color"]
        ]
    }

    private static let script = """
    #!/usr/bin/env python3
    import json
    import sys

    COLOR_SCHEMA = {
        "type": "object",
        "properties": {"color": {"type": "string", "title": "Color"}},
        "required": ["color"],
    }

    def send(message):
        print(json.dumps(message), flush=True)

    def answer_to(request_id):
        # Anything else MacRemote sends meanwhile is not this answer.
        while True:
            line = sys.stdin.readline()
            if not line:
                sys.exit(0)
            message = json.loads(line)
            if message.get("id") == request_id and "method" not in message:
                return message.get("result", {"error": message.get("error")})

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        request_id = message.get("id")
        if method == "server/discover":
            send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Method not found"}})
        elif method == "initialize":
            send({"jsonrpc": "2.0", "id": request_id, "result": {
                "protocolVersion": message["params"]["protocolVersion"],
                "serverInfo": {"name": "asking", "version": "1.0"},
                "capabilities": {"tools": {}},
            }})
        elif method == "tools/call":
            arguments = message.get("params", {}).get("arguments", {})
            answers = []
            for index in range(int(arguments.get("rounds", 1))):
                if arguments.get("kind") == "url":
                    params = {"mode": "url", "message": "Open the page to continue.", "url": "https://example.com/continue"}
                else:
                    params = {"message": "Pick a color.", "requestedSchema": COLOR_SCHEMA}
                question_id = "ask-%d" % index
                send({"jsonrpc": "2.0", "id": question_id, "method": "elicitation/create", "params": params})
                answers.append(answer_to(question_id))
            send({"jsonrpc": "2.0", "id": request_id, "result": {
                "content": [{"type": "text", "text": json.dumps({"answers": answers})}],
                "structuredContent": {"answers": answers},
            }})
        elif request_id is not None:
            send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Method not found"}})
    """
}
