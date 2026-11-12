import Foundation

enum FileTransferToolCatalog {
    /// Keeps the base64 payload plus the duplicated MCP text fallback below
    /// common 64 KiB client transport limits.
    static let readFileChunkByteLimit = 16 * 1024

    /// What one request can actually carry. The server accepts requests up to
    /// 128 KiB in total, so advertising more only made larger writes fail.
    static let writeFileDataCharacterLimit = 96 * 1024

    static let builtInTools: [ToolDefinition] = [
        statTool, listTreeTool, findTool, readFileTool, writeFileTool, downloadFileTool, downloadZipTool
    ]

    static func tool(id: String) -> ToolDefinition? {
        builtInTools.first { $0.id == id }
    }

    private static let sharedTimeout: TimeInterval = 30
    private static let sharedOutputLimit = 512 * 1024

    static var statTool: ToolDefinition {
        nativeTool(
            id: "filesystem_stat",
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
            id: "filesystem_list_tree",
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
                    kind: .boolean,
                    required: false,
                    defaultValue: "true"
                )
            ]
        )
    }

    static var findTool: ToolDefinition {
        nativeTool(
            id: "filesystem_find",
            name: "Find Files",
            summary: """
            Find files and folders by name. Plain text matches any name that contains it; with * or ? the pattern must match the whole name (*.pdf, report-??.txt). Case is ignored. \
            With path, walks that folder and everything under it: exact, includes hidden files, and stops after about 20 seconds, so give the smallest folder you can. \
            Without path, asks Spotlight across everything File Transfer reaches: fast on a whole disk, but hidden and unindexed files are missing. \
            Returns matches (path, type, size_bytes, modified_iso8601), newest first, and truncated=true with truncated_reason when there may be more.
            """,
            nativeToolID: .fsFind,
            capability: .readOnly,
            parameters: [
                ToolParameter(
                    name: "name",
                    title: "Name",
                    kind: .string,
                    maximumLength: 255
                ),
                ToolParameter(
                    name: "path",
                    title: "Folder",
                    kind: .string,
                    required: false,
                    maximumLength: 4096
                ),
                ToolParameter(
                    name: "type",
                    title: "Type",
                    kind: .string,
                    required: false,
                    defaultValue: "any",
                    allowedValues: ["any", "file", "directory"]
                ),
                ToolParameter(
                    name: "max_results",
                    title: "Maximum Results",
                    kind: .integer,
                    required: false,
                    defaultValue: "100",
                    integerRange: 1...1000
                )
            ]
        )
    }

    static var readFileTool: ToolDefinition {
        nativeTool(
            id: "filesystem_read_file",
            name: "Read File Chunk",
            summary: """
            Read a chunk from an absolute file path. No shell is used. \
            Expands a leading tilde to the home directory; relative paths are rejected. \
            With encoding utf8, returns the text itself in text; use it for text files. With base64 (the default), returns the bytes in data_base64 and is safe for any file. \
            Use offset and length for chunked reads (length defaults to \(readFileChunkByteLimit) and is clamped to 1...\(readFileChunkByteLimit) bytes per call). \
            Repeat calls with offset plus length_returned until eof is true. For a whole file, prefer filesystem_download_file instead of reading every chunk.
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
                    defaultValue: String(readFileChunkByteLimit),
                    integerRange: 1...readFileChunkByteLimit
                ),
                ToolParameter(
                    name: "encoding",
                    title: "Encoding",
                    kind: .string,
                    required: false,
                    defaultValue: "base64",
                    allowedValues: ["base64", "utf8"]
                )
            ]
        )
    }

    static var writeFileTool: ToolDefinition {
        nativeTool(
            id: "filesystem_write_file",
            name: "Write File",
            summary: """
            Write bytes to an absolute file path. Binary-safe native operation with no shell. \
            Expands a leading tilde to the home directory; relative paths are rejected. \
            Supply data as base64 (default) or utf8. Modes: create (fail if the file exists), overwrite, or append. \
            One call carries at most \(writeFileDataCharacterLimit) characters of data; send a larger file in parts, the first with create and the rest with append. \
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
                    maximumLength: writeFileDataCharacterLimit
                ),
                ToolParameter(
                    name: "encoding",
                    title: "Encoding",
                    kind: .string,
                    required: false,
                    defaultValue: "base64",
                    allowedValues: ["base64", "utf8"]
                ),
                ToolParameter(
                    name: "mode",
                    title: "Mode",
                    kind: .string,
                    required: false,
                    defaultValue: "create",
                    allowedValues: ["create", "overwrite", "append"]
                )
            ]
        )
    }

    static var downloadFileTool: ToolDefinition {
        nativeTool(
            id: "filesystem_download_file",
            name: "Download File",
            summary: """
            Stage a copy of an absolute file path for artifact download. No shell is used. \
            Expands a leading tilde to the home directory; relative paths are rejected. \
            Returns artifact_token, artifact_path (/artifact/<token>), filename, size_bytes, sha256, expires_in_seconds, and downloads_allowed. \
            Fetch bytes with GET on the public download_url the server adds to the result (not via stdout).
            """,
            nativeToolID: .fsDownloadFile,
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

    static var downloadZipTool: ToolDefinition {
        nativeTool(
            id: "filesystem_download_zip",
            name: "Download Zip",
            summary: """
            Zip an absolute file or directory, or selected relative paths under a base directory, for artifact download. \
            No shell is used. Expands a leading tilde on absolute paths; relative paths are rejected. \
            Single-path form: path. Multi-path form: base plus paths (JSON array of relative path strings under base). \
            The files may total at most 512 MiB before compression; a folder that contains a protected location is refused, so zip a subfolder instead. \
            Returns artifact_token, artifact_path (/artifact/<token>), filename, size_bytes, sha256, expires_in_seconds, and downloads_allowed. \
            Fetch bytes with GET on the public download_url the server adds to the result (not via stdout).
            """,
            nativeToolID: .fsDownloadZip,
            capability: .readOnly,
            parameters: [
                ToolParameter(
                    name: "path",
                    title: "Path",
                    kind: .string,
                    required: false,
                    maximumLength: 4096
                ),
                ToolParameter(
                    name: "base",
                    title: "Base Directory",
                    kind: .string,
                    required: false,
                    maximumLength: 4096
                ),
                ToolParameter(
                    name: "paths",
                    title: "Relative Paths",
                    kind: .stringArray,
                    required: false
                )
            ]
        )
    }

    /// Appended to every File Transfer description so a model knows the
    /// boundary before it calls, instead of discovering it by failing.
    private static let reachNote =
        "Reaches only the folders the owner allowed for File Transfer: Desktop, Documents, and Downloads by default, up to the whole Mac if the owner chose that. Other paths return path_denied, and the error names what is reachable."

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
            summary: summary + " " + reachNote,
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
