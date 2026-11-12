import Foundation

/// Sparse semantic GoodLinksCTL catalog. Matter and Readwise remain ordinary
/// discovered CLIs and are intentionally not first-party presets.
enum ReadLaterToolPresetCatalog {
    static var goodLinksCTLExecutablePath: String? {
        ExecutableLocator.executablePath(named: "goodlinksctl")
    }

    static var presets: [DefaultToolPreset] {
        goodLinksCTLPresets
    }

    static func presets(executablePath: String?) -> [DefaultToolPreset] {
        goodLinksCTLPresets(executablePath: executablePath)
    }

    static var goodLinksCTLPresets: [DefaultToolPreset] {
        goodLinksCTLPresets(executablePath: goodLinksCTLExecutablePath)
    }

    static func goodLinksCTLPresets(executablePath: String?) -> [DefaultToolPreset] {
        guard let executablePath else { return [] }
        let openWorld = ToolAnnotationOverrides(openWorldHint: true)

        return [
            preset(
                id: "search",
                name: "Find Saved Links",
                summary: "Search and filter GoodLinks metadata with bounded pagination. Repeated tags use GoodLinks’ OR semantics.",
                executablePath: executablePath,
                parameters: [
                    optionalString("query", "Query", "Search title, summary, content, URL, and author.", maximumLength: 1024),
                    ToolParameter(name: "tags", title: "Tags", description: "Optional tag filters; multiple tags use OR semantics.", kind: .stringArray, required: false, maximumLength: 128),
                    stateFilter("read_state", "Read State", "Filter by read state."),
                    stateFilter("starred_state", "Starred State", "Filter by starred state."),
                    ToolParameter(
                        name: "sort",
                        title: "Sort",
                        description: "Official GoodLinks sort order.",
                        kind: .string,
                        required: false,
                        defaultValue: "newestSaved",
                        allowedValues: ["newestSaved", "oldestSaved", "newestRead", "oldestRead", "shortest", "longest", "titleA", "titleZ"]
                    ),
                    ToolParameter(name: "limit", title: "Limit", description: "Maximum links to return across pages.", kind: .integer, required: false, defaultValue: "100", integerRange: 1...1000)
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("--json"), .literal("links"), .literal("list"),
                    .option("--search", "query"),
                    .repeatedOption("--tag", "tags"),
                    .choice("read_state", ["any": [], "true": ["--read", "true"], "false": ["--read", "false"]]),
                    .choice("starred_state", ["any": [], "true": ["--starred", "true"], "false": ["--starred", "false"]]),
                    .option("--sort", "sort"),
                    .literal("--all-pages"),
                    .option("--max-items", "limit")
                ]),
                capability: .readOnly,
                timeoutSeconds: 60,
                outputLimitKB: 8192,
                annotations: openWorld
            ),
            preset(
                id: "get",
                name: "Get Saved Link",
                summary: "Return one exact GoodLinks metadata record by link id.",
                executablePath: executablePath,
                parameters: [linkID],
                invocation: ProcessInvocation(arguments: [
                    .literal("--json"), .literal("links"), .literal("get"), .value("link_id")
                ]),
                capability: .readOnly,
                annotations: openWorld
            ),
            preset(
                id: "read",
                name: "Read Saved Link",
                summary: "Return cached article content as Markdown without silently asking GoodLinks to download missing content.",
                executablePath: executablePath,
                parameters: [linkID],
                invocation: ProcessInvocation(arguments: [
                    .literal("--json"), .literal("links"), .literal("content"),
                    .value("link_id"),
                    .literal("--format"), .literal("markdown"),
                    .literal("--no-auto-download")
                ]),
                capability: .readOnly,
                timeoutSeconds: 60,
                outputLimitKB: 64 * 1024,
                annotations: openWorld
            ),
            preset(
                id: "save",
                name: "Save Link",
                summary: "Save or upsert one absolute HTTP or HTTPS URL in GoodLinks with optional metadata.",
                executablePath: executablePath,
                parameters: [
                    ToolParameter(name: "url", title: "URL", description: "Absolute HTTP or HTTPS URL to save or upsert.", kind: .string, maximumLength: 4096, stringFormat: "uri"),
                    optionalString("title", "Title", "Optional title.", maximumLength: 200),
                    optionalString("summary", "Summary", "Optional summary.", maximumLength: 400),
                    ToolParameter(name: "tags", title: "Tags", description: "Tags to set on the saved link.", kind: .stringArray, required: false, maximumLength: 128),
                    optionalDesiredState("read_state", "Read State", "Optional read state for the saved link.", trueValue: "read", falseValue: "unread"),
                    optionalDesiredState("starred_state", "Starred State", "Optional starred state for the saved link.", trueValue: "starred", falseValue: "unstarred")
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("--json"), .literal("links"), .literal("add"), .value("url"),
                    .option("--title", "title"),
                    .option("--summary", "summary"),
                    .repeatedOption("--tag", "tags"),
                    .choice("read_state", ["unchanged": [], "read": ["--read"], "unread": ["--unread"]]),
                    .choice("starred_state", ["unchanged": [], "starred": ["--starred"], "unstarred": ["--unstarred"]])
                ]),
                capability: .write,
                timeoutSeconds: 60,
                annotations: openWorld
            ),
            preset(
                id: "update",
                name: "Update Saved Link",
                summary: "Update one saved link’s metadata. At least one change is required; clear-tags cannot be combined with tag additions or removals.",
                executablePath: executablePath,
                parameters: [
                    linkID,
                    optionalString("title", "Title", "Replacement title.", maximumLength: 200),
                    optionalString("summary", "Summary", "Replacement summary.", maximumLength: 400),
                    optionalDesiredState("read_state", "Read State", "Desired read state.", trueValue: "read", falseValue: "unread"),
                    optionalDesiredState("starred_state", "Starred State", "Desired starred state.", trueValue: "starred", falseValue: "unstarred"),
                    ToolParameter(name: "add_tags", title: "Add Tags", description: "Tags to add.", kind: .stringArray, required: false, maximumLength: 128),
                    ToolParameter(name: "remove_tags", title: "Remove Tags", description: "Tags to remove.", kind: .stringArray, required: false, maximumLength: 128),
                    ToolParameter(name: "clear_tags", title: "Clear Tags", description: "Remove every tag.", kind: .boolean, required: false, defaultValue: "false")
                ],
                invocation: ProcessInvocation(
                    arguments: [
                        .literal("--json"), .literal("links"), .literal("update"), .value("link_id"),
                        .option("--title", "title"),
                        .option("--summary", "summary"),
                        .choice("read_state", ["unchanged": [], "read": ["--read"], "unread": ["--unread"]]),
                        .choice("starred_state", ["unchanged": [], "starred": ["--starred"], "unstarred": ["--unstarred"]]),
                        .repeatedOption("--add-tag", "add_tags"),
                        .repeatedOption("--remove-tag", "remove_tags"),
                        .flag("--clear-tags", "clear_tags")
                    ],
                    constraints: [
                        .atLeastOne(["title", "summary", "read_state", "starred_state", "add_tags", "remove_tags", "clear_tags"]),
                        .mutuallyExclusive(["clear_tags", "add_tags"]),
                        .mutuallyExclusive(["clear_tags", "remove_tags"])
                    ]
                ),
                capability: .write,
                timeoutSeconds: 60,
                annotations: openWorld
            ),
            preset(
                id: "delete",
                name: "Delete Saved Link",
                summary: "Preflight one exact link id, then move it to GoodLinks trash only when preflight succeeds. This tool asks for every call.",
                executablePath: executablePath,
                parameters: [linkID],
                invocation: ProcessInvocation(
                    arguments: [
                        .literal("--json"), .literal("links"), .literal("delete"),
                        .value("link_id"), .literal("--yes")
                    ],
                    preflightSuffix: ["--dry-run"],
                    preflightRemovingArguments: ["--yes"]
                ),
                capability: .destructive,
                timeoutSeconds: 60,
                approvalPolicy: .everyCall,
                annotations: openWorld
            ),
            preset(
                id: "run",
                name: "GoodLinksCTL Flexible Command",
                summary: "Advanced fallback; prefer the dedicated GoodLinksCTL tools. Pass exact argv items with no shell for highlights, batches, exports, downloads, and uncommon workflows. Authentication, setup, token input, and endpoint overrides are blocked remotely. This tool asks for every call.",
                executablePath: executablePath,
                parameters: [
                    ToolParameter(name: "args", title: "Arguments", description: "Exact GoodLinksCTL argv items. No shell syntax or expansion is available.", kind: .stringArray, required: false)
                ],
                argumentPattern: ["{args}"],
                capability: .destructive,
                timeoutSeconds: 120,
                outputLimitKB: 64 * 1024,
                mode: .cliAdapter,
                approvalPolicy: .everyCall,
                annotations: openWorld
            )
        ]
    }

    private static let linkID = ToolParameter(
        name: "link_id",
        title: "Link ID",
        description: "Exact GoodLinks link id from a fresh read.",
        kind: .string,
        maximumLength: 128
    )

    private static func stateFilter(
        _ name: String,
        _ title: String,
        _ description: String
    ) -> ToolParameter {
        ToolParameter(
            name: name,
            title: title,
            description: description,
            kind: .string,
            required: false,
            defaultValue: "any",
            allowedValues: ["any", "true", "false"]
        )
    }

    private static func optionalDesiredState(
        _ name: String,
        _ title: String,
        _ description: String,
        trueValue: String,
        falseValue: String
    ) -> ToolParameter {
        ToolParameter(
            name: name,
            title: title,
            description: description,
            kind: .string,
            required: false,
            defaultValue: "unchanged",
            allowedValues: ["unchanged", trueValue, falseValue]
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

    private static func preset(
        id: String,
        name: String,
        summary: String,
        executablePath: String,
        parameters: [ToolParameter],
        invocation: ProcessInvocation? = nil,
        argumentPattern: [String] = [],
        capability: ToolCapability,
        timeoutSeconds: Double = 30,
        outputLimitKB: Int = 4096,
        mode: ToolAdapterMode = .commandTemplate,
        approvalPolicy: ToolApprovalPolicy = .standard,
        annotations: ToolAnnotationOverrides?
    ) -> DefaultToolPreset {
        DefaultToolPreset(
            id: "preset.goodlinksctl.\(id)",
            name: name,
            summary: summary,
            executablePath: executablePath,
            argumentPattern: argumentPattern,
            capability: capability,
            category: .readLater,
            timeoutSeconds: timeoutSeconds,
            outputLimitKB: outputLimitKB,
            mode: mode,
            parameters: parameters,
            processInvocation: invocation,
            approvalPolicy: approvalPolicy,
            annotationOverrides: annotations
        )
    }
}
