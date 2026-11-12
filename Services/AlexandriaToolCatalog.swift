import Foundation

/// Sparse semantic workflows for Alexandria's local library and agent service.
/// The CLI talks to Alexandria's loopback service, which owns Notes access and
/// writer coordination, so these tools do not require MacRemote itself to hold
/// Full Disk Access.
enum AlexandriaToolCatalog {
    private static let maximumOutputBytes = 64 * 1024 * 1024
    static let maximumStandardInputLength = 64 * 1024

    static var detectedExecutablePath: String? {
        detectedExecutablePath { name in
            ExecutableLocator.executablePath(named: name)
        }
    }

    static func detectedExecutablePath(
        using locate: (String) -> String?
    ) -> String? {
        locate("alexandria")
    }

    static var executablePath: String {
        detectedExecutablePath ?? "\(ExecutableLocator.homeDirectory)/.local/bin/alexandria"
    }

    static var fullCLITool: ToolDefinition {
        tool(
            id: "alexandria_run",
            name: "Alexandria Flexible Command",
            summary: "Advanced fallback; prefer the dedicated Alexandria tools. Pass exact argv items with no shell for filters, rules, configuration, history, diagnostics, and uncommon workflows. Remote deployment, checkout verification, privileged execution, and endpoint redirection stay blocked. This tool asks for every call.",
            parameters: [
                ToolParameter(
                    name: "args",
                    title: "Arguments",
                    description: "Exact Alexandria argv items. No shell syntax or expansion is available.",
                    kind: .stringArray,
                    required: false,
                    maximumLength: maximumStandardInputLength
                ),
                ToolParameter(
                    name: "stdin",
                    title: "Standard Input",
                    description: "Optional UTF-8 input passed directly to Alexandria standard input.",
                    kind: .string,
                    required: false,
                    maximumLength: maximumStandardInputLength
                )
            ],
            argumentPattern: ["{args}"],
            capability: .destructive,
            timeoutSeconds: 600,
            approvalPolicy: .everyCall,
            annotationOverrides: ToolAnnotationOverrides(openWorldHint: true)
        )
    }

    static var dedicatedTools: [ToolDefinition] {
        [
            tool(
                id: "alexandria_health",
                name: "Get Alexandria Health",
                summary: "Return Alexandria's deployed revision, heartbeat, queue, sync, and budget health as JSON. Inspect nested status fields; top-level ok does not make every subsystem healthy.",
                parameters: [],
                invocation: ProcessInvocation(arguments: [
                    .literal("--json"), .literal("health")
                ]),
                capability: .readOnly,
                timeoutSeconds: 30
            ),
            tool(
                id: "alexandria_list_resources",
                name: "List Alexandria Resources",
                summary: "List configured Alexandria rooms or model agents as JSON so later calls can use exact ids and names.",
                parameters: [
                    ToolParameter(
                        name: "resource",
                        title: "Resource",
                        description: "Alexandria resource family to list.",
                        kind: .string,
                        allowedValues: ["rooms", "agents"]
                    )
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("--json"),
                    .choice("resource", [
                        "rooms": ["views", "list"],
                        "agents": ["agents", "list"]
                    ])
                ]),
                capability: .readOnly,
                timeoutSeconds: 30
            ),
            tool(
                id: "alexandria_browse_room",
                name: "Browse Alexandria Room",
                summary: "Return one bounded Alexandria room shelf with optional tab, search, tag, sort, and offset filters.",
                parameters: [
                    requiredString("view_id", "Room ID", "Exact room id from List Alexandria Resources.", maximumLength: 256),
                    optionalString("tab", "Tab", "Optional configured tab id.", maximumLength: 256),
                    optionalString("search", "Search", "Search note titles and indexed text.", maximumLength: 4096),
                    optionalString("tag", "Tag", "Keep only notes carrying this tag.", maximumLength: 256),
                    optionalString("sort", "Sort", "Sort advertised by Alexandria's room vocabulary.", maximumLength: 128),
                    ToolParameter(
                        name: "limit",
                        title: "Limit",
                        description: "Maximum room items to return.",
                        kind: .integer,
                        required: false,
                        defaultValue: "100",
                        integerRange: 1...500
                    ),
                    ToolParameter(
                        name: "offset",
                        title: "Offset",
                        description: "Number of matching room items to skip.",
                        kind: .integer,
                        required: false,
                        defaultValue: "0",
                        integerRange: 0...100_000
                    )
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("--json"), .literal("views"), .literal("items"),
                    .value("view_id"),
                    .option("--tab", "tab"),
                    .option("--search", "search"),
                    .option("--tag", "tag"),
                    .option("--sort", "sort"),
                    .option("--limit", "limit"),
                    .option("--offset", "offset")
                ]),
                capability: .readOnly,
                timeoutSeconds: 60
            ),
            tool(
                id: "alexandria_search_notes",
                name: "Find Alexandria Notes",
                summary: "Search indexed Alexandria note titles, summaries, and metadata as JSON.",
                parameters: [
                    requiredString("query", "Query", "Text to find in Alexandria's note index.", maximumLength: 4096)
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("--json"), .literal("notes"), .literal("search"), .value("query")
                ]),
                capability: .readOnly,
                timeoutSeconds: 60
            ),
            tool(
                id: "alexandria_show_note",
                name: "Get Alexandria Note",
                summary: "Return one Alexandria note's live body and indexed metadata by Apple Notes UUID.",
                parameters: [noteUUID],
                invocation: ProcessInvocation(arguments: [
                    .literal("--json"), .literal("notes"), .literal("show"), .value("note_uuid")
                ]),
                capability: .readOnly,
                timeoutSeconds: 60
            ),
            tool(
                id: "alexandria_capture_clip",
                name: "Capture Alexandria Clip",
                summary: "Capture UTF-8 text or one URL into Alexandria's Clips Inbox. A response with created false is a successful dedupe. After an indeterminate timeout, search before retrying.",
                parameters: [captureInput, captureTitle],
                invocation: ProcessInvocation(arguments: [
                    .literal("--json"), .literal("notes"), .literal("capture"),
                    .literal("-"), .option("--title", "title")
                ]),
                capability: .write,
                timeoutSeconds: 120,
                annotationOverrides: ToolAnnotationOverrides(openWorldHint: true)
            ),
            tool(
                id: "alexandria_capture_in_room",
                name: "Add Note to Alexandria Room",
                summary: "Capture a plain note into one open Alexandria room. willProcess predicts watch-rule coverage, not completed processing. After an indeterminate timeout, inspect the room before retrying.",
                parameters: [
                    requiredString("view_id", "Room ID", "Exact open room id.", maximumLength: 256),
                    captureInput,
                    captureTitle
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("--json"), .literal("views"), .literal("add"),
                    .value("view_id"), .literal("-"), .option("--title", "title")
                ]),
                capability: .write,
                timeoutSeconds: 120,
                annotationOverrides: ToolAnnotationOverrides(openWorldHint: true)
            ),
            tool(
                id: "alexandria_run_agent",
                name: "Run Alexandria Agent",
                summary: "Enqueue one configured Alexandria model agent and return a job_id; this does not prove execution finished. Retain the id and wait for its terminal job and run state. This tool asks for every call.",
                parameters: [
                    requiredString("agent", "Agent", "Exact configured agent name.", maximumLength: 256),
                    ToolParameter(
                        name: "note_uuid",
                        title: "Note UUID",
                        description: "Optional Apple Notes UUID carried in the job and its dedupe identity.",
                        kind: .string,
                        required: false,
                        maximumLength: 128
                    )
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("--json"), .literal("agents"), .literal("run"),
                    .value("agent"), .option("--note-uuid", "note_uuid")
                ]),
                capability: .write,
                timeoutSeconds: 120,
                approvalPolicy: .everyCall,
                annotationOverrides: ToolAnnotationOverrides(openWorldHint: true)
            ),
            tool(
                id: "alexandria_wait_job",
                name: "Wait for Alexandria Job",
                summary: "Poll one exact Alexandria job until done, failed, or skipped, then return it with related runs. This read never retries work.",
                parameters: [
                    ToolParameter(
                        name: "job_id",
                        title: "Job ID",
                        description: "Positive job id returned by Alexandria.",
                        kind: .integer,
                        integerRange: 1...Int.max
                    )
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("--json"), .literal("jobs"), .literal("wait"), .value("job_id")
                ]),
                capability: .readOnly,
                timeoutSeconds: 330
            )
        ]
    }

    static var builtInTools: [ToolDefinition] { dedicatedTools + [fullCLITool] }

    static func tool(id: String) -> ToolDefinition? {
        builtInTools.first { $0.id == id }
    }

    static func arguments(
        for toolID: String,
        parameters: [String: ToolArgumentValue]
    ) throws -> [String] {
        guard let tool = tool(id: toolID) else {
            throw ToolValidationError.unknownTool(toolID)
        }
        return try ToolArgumentResolver.arguments(for: tool, parameters: parameters)
    }

    private static let noteUUID = requiredString(
        "note_uuid", "Note UUID", "Apple Notes UUID returned by Alexandria.", maximumLength: 128
    )

    private static let captureInput = ToolParameter(
        name: "stdin",
        title: "Text",
        description: "Required UTF-8 text passed directly to Alexandria standard input.",
        kind: .string,
        maximumLength: maximumStandardInputLength
    )

    private static let captureTitle = optionalString(
        "title", "Title", "Optional note title.", maximumLength: 4096
    )

    private static func requiredString(
        _ name: String,
        _ title: String,
        _ description: String,
        maximumLength: Int
    ) -> ToolParameter {
        ToolParameter(
            name: name,
            title: title,
            description: description,
            kind: .string,
            maximumLength: maximumLength
        )
    }

    private static func optionalString(
        _ name: String,
        _ title: String,
        _ description: String,
        maximumLength: Int
    ) -> ToolParameter {
        ToolParameter(
            name: name,
            title: title,
            description: description,
            kind: .string,
            required: false,
            maximumLength: maximumLength
        )
    }

    private static func tool(
        id: String,
        name: String,
        summary: String,
        parameters: [ToolParameter],
        invocation: ProcessInvocation? = nil,
        argumentPattern: [String] = [],
        capability: ToolCapability,
        timeoutSeconds: Double,
        approvalPolicy: ToolApprovalPolicy = .standard,
        annotationOverrides: ToolAnnotationOverrides = ToolAnnotationOverrides(openWorldHint: false)
    ) -> ToolDefinition {
        ToolDefinition(
            id: id,
            name: name,
            summary: summary,
            executablePath: executablePath,
            argumentPattern: argumentPattern,
            parameters: parameters,
            processInvocation: invocation,
            capability: capability,
            timeoutSeconds: timeoutSeconds,
            outputByteLimit: maximumOutputBytes,
            category: .ai,
            approvalPolicy: approvalPolicy,
            annotationOverrides: annotationOverrides
        )
    }
}
