import Foundation

enum FileTransferToolCatalog {
    static var builtInTools: [ToolDefinition] {
        [statTool, listTreeTool, readFileTool, writeFileTool]
    }

    static func tool(id: String) -> ToolDefinition? {
        builtInTools.first { $0.id == id }
    }

    private static let sharedTimeout: TimeInterval = 30
    private static let sharedOutputLimit = 512 * 1024

    static var statTool: ToolDefinition {
        nativeTool(
            id: "builtin.fs.stat",
            name: "File Stat",
            summary: """
            Return metadata for an absolute filesystem path. Binary-safe native operation with no shell. \
            Expands a leading tilde to the home directory; relative paths are rejected. \
            Missing paths return exists=false with exit code 0.
            """,
            nativeToolID: .fsStat,
            capability: .readOnly,
            parameters: [
                ToolParameter(
                    name: "path",
                    title: "Path",
                    kind: .string,
                    maximumLength: 4096
                )
            ]
        )
    }

    static var listTreeTool: ToolDefinition {
        nativeTool(
            id: "builtin.fs.list_tree",
            name: "List Directory Tree",
            summary: """
            Recursively list an absolute directory tree. Binary-safe native operation with no shell. \
            Expands a leading tilde to the home directory; relative paths are rejected. \
            Symlinked directories are listed but not followed. Results cap at 2000 entries with truncated=true when capped.
            """,
            nativeToolID: .fsListTree,
            capability: .readOnly,
            parameters: [
                ToolParameter(
                    name: "path",
                    title: "Path",
                    kind: .string,
                    maximumLength: 4096
                ),
                ToolParameter(
                    name: "depth",
                    title: "Depth",
                    kind: .integer,
                    required: false,
                    defaultValue: "2",
                    integerRange: 0...5
                ),
                ToolParameter(
                    name: "include_sizes",
                    title: "Include Sizes",
                    kind: .string,
                    required: false,
                    defaultValue: "true"
                )
            ]
        )
    }

    static var readFileTool: ToolDefinition {
        nativeTool(
            id: "builtin.fs.read_file",
            name: "Read File Chunk",
            summary: """
            Read a binary-safe chunk from an absolute file path. No shell is used. \
            Expands a leading tilde to the home directory; relative paths are rejected. \
            Returns base64-encoded data in data_base64. Use offset and length for chunked reads (length defaults to 65536 and is clamped to 65536 bytes per call). \
            Repeat calls with increasing offset until eof is true.
            """,
            nativeToolID: .fsReadFile,
            capability: .readOnly,
            parameters: [
                ToolParameter(
                    name: "path",
                    title: "Path",
                    kind: .string,
                    maximumLength: 4096
                ),
                ToolParameter(
                    name: "offset",
                    title: "Offset",
                    kind: .integer,
                    required: false,
                    defaultValue: "0",
                    integerRange: 0...Int.max
                ),
                ToolParameter(
                    name: "length",
                    title: "Length",
                    kind: .integer,
                    required: false,
                    defaultValue: "65536",
                    integerRange: 0...65_536
                )
            ]
        )
    }

    static var writeFileTool: ToolDefinition {
        nativeTool(
            id: "builtin.fs.write_file",
            name: "Write File",
            summary: """
            Write bytes to an absolute file path. Binary-safe native operation with no shell. \
            Expands a leading tilde to the home directory; relative paths are rejected. \
            Supply data as base64 (default) or utf8. Modes: create (fail if the file exists), overwrite, or append. \
            Requires host approval before execution.
            """,
            nativeToolID: .fsWriteFile,
            capability: .write,
            parameters: [
                ToolParameter(
                    name: "path",
                    title: "Path",
                    kind: .string,
                    maximumLength: 4096
                ),
                ToolParameter(
                    name: "data",
                    title: "Data",
                    kind: .string,
                    maximumLength: 10 * 1024 * 1024
                ),
                ToolParameter(
                    name: "encoding",
                    title: "Encoding",
                    kind: .string,
                    required: false,
                    defaultValue: "base64"
                ),
                ToolParameter(
                    name: "mode",
                    title: "Mode",
                    kind: .string,
                    required: false,
                    defaultValue: "create"
                )
            ]
        )
    }

    private static func nativeTool(
        id: String,
        name: String,
        summary: String,
        nativeToolID: NativeToolIdentifier,
        capability: ToolCapability,
        parameters: [ToolParameter]
    ) -> ToolDefinition {
        ToolDefinition(
            id: id,
            name: name,
            summary: summary,
            executablePath: "/usr/bin/true",
            argumentPattern: [],
            parameters: parameters,
            capability: capability,
            timeoutSeconds: sharedTimeout,
            outputByteLimit: sharedOutputLimit,
            origin: .builtIn,
            category: .filesystem,
            permissionRequirements: [],
            backend: .native,
            nativeToolID: nativeToolID
        )
    }
}
