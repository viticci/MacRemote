import Foundation

enum FileTransferToolCatalog {
    /// Keeps the base64 payload plus the duplicated MCP text fallback below
    /// common 64 KiB client transport limits.
    static let readFileChunkByteLimit = 16 * 1024

    /// What one request can actually carry. The server accepts requests up to
    /// 128 KiB in total, so advertising more only made larger writes fail.
    static let writeFileDataCharacterLimit = 96 * 1024

    /// Replace in File carries two texts in one request, so each gets half of
    /// what Write File's data may hold.
    static let replaceTextCharacterLimit = writeFileDataCharacterLimit / 2

    /// The largest file Append to File and Replace in File will edit. Both
    /// read the whole file and write a new copy beside it.
    static let editFileByteLimit = 10 * 1024 * 1024

    /// The largest file Upload File takes: the largest download, so staging
    /// holds the same files in both directions.
    static let uploadFileByteLimit = ArtifactStore.defaultMaxSizeBytes

    static let builtInTools: [ToolDefinition] = [
        statTool, listTreeTool, findTool, readFileTool, writeFileTool, uploadFileTool, appendFileTool,
        replaceInFileTool, downloadFileTool, downloadZipTool
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

    /// Saves a whole file an app sends through the MCP files extension
    /// (SPEC D83): the call carries only the file's details, and the bytes
    /// arrive over HTTP once the owner approved. See `FileUploadStore`.
    static var uploadFileTool: ToolDefinition {
        nativeTool(
            id: "filesystem_upload_file",
            name: "Upload File",
            summary: """
            Save a whole file from the app to an absolute path on the Mac, up to \(uploadFileByteLimit / (1024 * 1024)) MiB, without putting its bytes in the conversation. No shell is used. \
            Works only in apps that support MCP file uploads (the io.modelcontextprotocol/files extension): the app sends the file's details, the owner approves on the Mac, and the app then sends the bytes straight to MacRemote. \
            In an app without it, use filesystem_write_file instead. \
            path is where the file goes; its folder must exist. The file must not exist unless overwrite is true; an overwritten file keeps its permissions. \
            Returns path, size_bytes, and overwritten. Asks the owner on the Mac before any bytes are sent.
            """,
            nativeToolID: .fsUploadFile,
            capability: .destructive,
            parameters: [
                ToolParameter(
                    name: "path",
                    title: "Path",
                    kind: .string,
                    maximumLength: 4096
                ),
                ToolParameter(
                    name: "overwrite",
                    title: "Overwrite",
                    description: "Replace the file at path if there is one. Defaults to false.",
                    kind: .boolean,
                    required: false,
                    defaultValue: "false"
                ),
                ToolParameter(
                    name: "file",
                    title: "File",
                    description: "The file to save, as the app's file upload support describes it. Up to \(uploadFileByteLimit / (1024 * 1024)) MiB, of any type.",
                    kind: .json,
                    jsonSchema: uploadFileSchema
                )
            ],
            timeoutSeconds: 60
        )
    }

    /// The `file` argument: the extension's file object with `properties`
    /// and `required` exactly as the draft spells them, because an app
    /// recognizes a file argument by them. `x-mcp-file` marks it.
    static let uploadFileSchema: JSONValue = .object([
        "type": .string("object"),
        "x-mcp-file": .object(["maxSize": .number(Double(uploadFileByteLimit))]),
        "properties": .object([
            "id": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(128)]),
            "name": .object(["type": .string("string")]),
            "mimeType": .object(["type": .string("string")]),
            "size": .object(["type": .string("integer"), "minimum": .number(0)]),
            "digest": .object([
                "type": .string("object"),
                "properties": .object([
                    "algorithm": .object(["const": .string("sha-256")]),
                    "value": .object(["type": .string("string")])
                ]),
                "required": .array([.string("algorithm"), .string("value")])
            ]),
            "data": .object(["type": .string("string")])
        ]),
        "required": .array([.string("id"), .string("mimeType"), .string("size")])
    ])

    static var appendFileTool: ToolDefinition {
        nativeTool(
            id: "filesystem_append_file",
            name: "Append to File",
            summary: """
            Add UTF-8 text to the end of an existing text file at an absolute path, without sending the rest of the file. No shell is used. \
            Expands a leading tilde to the home directory; relative paths are rejected. \
            The text is added exactly as given, so include your own leading or trailing newline. \
            The file must already exist, be UTF-8 text, and be at most \(editFileByteLimit / (1024 * 1024)) MiB; to create a file, use filesystem_write_file. \
            The file is never left half written: the new contents replace it in one step, keeping its permissions. \
            Returns path, bytes_appended, and size_bytes. Asks the owner on the Mac before it runs.
            """,
            nativeToolID: .fsAppendFile,
            capability: .write,
            parameters: [
                ToolParameter(
                    name: "path",
                    title: "Path",
                    kind: .string,
                    maximumLength: 4096
                ),
                ToolParameter(
                    name: "text",
                    title: "Text",
                    description: "UTF-8 text to add at the end of the file, exactly as given.",
                    kind: .string,
                    maximumLength: writeFileDataCharacterLimit
                )
            ]
        )
    }

    static var replaceInFileTool: ToolDefinition {
        nativeTool(
            id: "filesystem_replace_in_file",
            name: "Replace in File",
            summary: """
            Change one passage of an existing UTF-8 text file at an absolute path, without sending the rest of the file. No shell is used. \
            Expands a leading tilde to the home directory; relative paths are rejected. \
            find must appear exactly once in the file. The match is exact and case-sensitive, including spaces and line endings: no patterns. \
            It compares bytes, so find can match part of a character built from several code points, such as a separately stored accent. \
            When find appears zero times or more than once, nothing changes and the error says how many times it appeared; add surrounding text to find until it matches once. \
            replace takes its place; pass an empty replace to delete the passage. Everything else in the file stays byte for byte the same. \
            The file must be UTF-8 text and at most \(editFileByteLimit / (1024 * 1024)) MiB. It is never left half written: the new contents replace it in one step, keeping its permissions. \
            Returns path, replacements (always 1), and size_bytes. Asks the owner on the Mac before it runs.
            """,
            nativeToolID: .fsReplaceInFile,
            capability: .write,
            parameters: [
                ToolParameter(
                    name: "path",
                    title: "Path",
                    kind: .string,
                    maximumLength: 4096
                ),
                ToolParameter(
                    name: "find",
                    title: "Find",
                    description: "The exact text to change. It must appear exactly once in the file.",
                    kind: .string,
                    maximumLength: replaceTextCharacterLimit
                ),
                // Required, and may be empty: an empty string deletes the
                // passage (see ToolArgumentResolver.allowsEmptyString).
                ToolParameter(
                    name: "replace",
                    title: "Replace With",
                    description: "The text to put in its place; an empty string deletes the passage.",
                    kind: .string,
                    maximumLength: replaceTextCharacterLimit
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
    ///
    /// It names no error code on purpose. `path` and `base` are checked
    /// before the call runs, so an app sees `reason: invalid_argument` with
    /// the message, never the executor's own `path_denied`.
    private static let reachNote =
        "Reaches only the folders the owner allowed for File Transfer: Desktop, Documents, and Downloads by default, up to the whole Mac if the owner chose that. A path outside them is refused before anything runs, and the error names what is reachable."

    private static func nativeTool(
        id: String,
        name: String,
        summary: String,
        nativeToolID: NativeToolIdentifier,
        capability: ToolCapability,
        parameters: [ToolParameter],
        timeoutSeconds: TimeInterval = sharedTimeout
    ) -> ToolDefinition {
        ToolDefinition(
            id: id,
            name: name,
            summary: summary + " " + reachNote,
            executablePath: "/usr/bin/true",
            argumentPattern: [],
            parameters: parameters,
            capability: capability,
            timeoutSeconds: timeoutSeconds,
            outputByteLimit: sharedOutputLimit,
            origin: .builtIn,
            category: .filesystem,
            permissionRequirements: [],
            backend: .native,
            nativeToolID: nativeToolID
        )
    }
}
