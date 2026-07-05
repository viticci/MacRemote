import Foundation

struct NativeToolExecutor: Sendable {
    private let pathPolicy: FileTransferPathPolicy

    init(pathPolicy: FileTransferPathPolicy = FileTransferPathPolicy()) {
        self.pathPolicy = pathPolicy
    }

    func execute(
        tool: ToolDefinition,
        parameters: [String: ToolArgumentValue],
        timeoutSeconds: TimeInterval
    ) async throws -> ToolExecutionOutcome {
        let started = Date()
        guard !Task.isCancelled else {
            return timedOutOutcome(tool: tool, started: started)
        }

        guard let nativeToolID = tool.nativeToolID else {
            return failureOutcome(
                tool: tool,
                started: started,
                code: "invalid_native_tool",
                message: "Tool is missing a native operation identifier.",
                stderr: "Native tool configuration is incomplete."
            )
        }

        let result: NativeOperationResult
        switch nativeToolID {
        case .fsStat:
            result = fsStat(parameters: parameters)
        case .fsListTree:
            result = fsListTree(parameters: parameters)
        case .fsReadFile:
            result = fsReadFile(parameters: parameters)
        case .fsWriteFile:
            result = fsWriteFile(parameters: parameters)
        }

        if Date().timeIntervalSince(started) > timeoutSeconds {
            return timedOutOutcome(tool: tool, started: started)
        }

        switch result {
        case .success(let payload):
            let stdout = try encodeJSON(payload)
            return ToolExecutionOutcome(
                toolID: tool.id,
                toolName: tool.name,
                exitCode: 0,
                stdout: stdout,
                stderr: "",
                duration: Date().timeIntervalSince(started),
                timedOut: false,
                truncatedStdout: false,
                truncatedStderr: false
            )
        case .failure(let failure):
            return failureOutcome(
                tool: tool,
                started: started,
                code: failure.code,
                message: failure.message,
                stderr: failure.stderr
            )
        }
    }

    // MARK: - Operations

    private enum NativeOperationResult {
        case success([String: Any])
        case failure(NativeExecutionFailure)
    }

    private func fsStat(parameters: [String: ToolArgumentValue]) -> NativeOperationResult {
        guard let rawPath = requiredString(named: "path", in: parameters) else {
            return .failure(.missingParameter("path"))
        }

        let resolvedPath: String
        do {
            resolvedPath = try pathPolicy.resolveUserPath(rawPath)
        } catch FileTransferPathPolicy.PathError.invalidPath {
            return .failure(.invalidPath)
        } catch FileTransferPathPolicy.PathError.pathDenied {
            return .failure(.pathDenied)
        } catch {
            return .failure(.invalidPath)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) else {
            return .success([
                "exists": false
            ])
        }

        let type = entryType(at: resolvedPath, isDirectory: isDirectory.boolValue)
        var payload: [String: Any] = [
            "exists": true,
            "type": type,
            "is_readable": FileManager.default.isReadableFile(atPath: resolvedPath),
            "is_writable": FileManager.default.isWritableFile(atPath: resolvedPath)
        ]

        if let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath) {
            if let size = attributes[.size] as? NSNumber {
                payload["size_bytes"] = size.int64Value
            }
            if let modified = attributes[.modificationDate] as? Date {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                payload["modified_iso8601"] = formatter.string(from: modified)
            }
        }

        return .success(payload)
    }

    private func fsListTree(parameters: [String: ToolArgumentValue]) -> NativeOperationResult {
        guard let rawPath = requiredString(named: "path", in: parameters) else {
            return .failure(.missingParameter("path"))
        }

        let resolvedPath: String
        do {
            resolvedPath = try pathPolicy.resolveUserPath(rawPath)
        } catch FileTransferPathPolicy.PathError.invalidPath {
            return .failure(.invalidPath)
        } catch FileTransferPathPolicy.PathError.pathDenied {
            return .failure(.pathDenied)
        } catch {
            return .failure(.invalidPath)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(.notADirectory)
        }

        let depth = min(max(integer(named: "depth", in: parameters, default: 2), 0), 5)
        let includeSizes = bool(named: "include_sizes", in: parameters, default: true)
        var entries = [[String: Any]]()
        var truncated = false
        let maxEntries = 2000

        func appendEntry(relativePath: String, at absolutePath: String, isDirectory: Bool) {
            guard entries.count < maxEntries else {
                truncated = true
                return
            }
            var entry: [String: Any] = [
                "relative_path": relativePath,
                "type": entryType(at: absolutePath, isDirectory: isDirectory)
            ]
            if includeSizes, !isDirectory {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: absolutePath),
                   let size = attributes[.size] as? NSNumber {
                    entry["size_bytes"] = size.int64Value
                }
            }
            entries.append(entry)
        }

        func listDirectory(at absolutePath: String, relativePrefix: String, currentDepth: Int) {
            guard entries.count < maxEntries else {
                truncated = true
                return
            }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: absolutePath) else {
                return
            }

            for name in names.sorted() {
                guard entries.count < maxEntries else {
                    truncated = true
                    return
                }

                let childAbsolute = (absolutePath as NSString).appendingPathComponent(name)
                let childRelative = relativePrefix.isEmpty ? name : relativePrefix + "/" + name
                var childIsDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: childAbsolute, isDirectory: &childIsDirectory) else {
                    continue
                }

                appendEntry(
                    relativePath: childRelative,
                    at: childAbsolute,
                    isDirectory: childIsDirectory.boolValue
                )

                if childIsDirectory.boolValue {
                    if !isSymbolicLink(at: childAbsolute), currentDepth + 1 < depth {
                        listDirectory(
                            at: childAbsolute,
                            relativePrefix: childRelative,
                            currentDepth: currentDepth + 1
                        )
                    }
                }
            }
        }

        listDirectory(at: resolvedPath, relativePrefix: "", currentDepth: 0)

        return .success([
            "path": resolvedPath,
            "entries": entries,
            "truncated": truncated
        ])
    }

    private func fsReadFile(parameters: [String: ToolArgumentValue]) -> NativeOperationResult {
        guard let rawPath = requiredString(named: "path", in: parameters) else {
            return .failure(.missingParameter("path"))
        }

        let resolvedPath: String
        do {
            resolvedPath = try pathPolicy.resolveUserPath(rawPath)
        } catch FileTransferPathPolicy.PathError.invalidPath {
            return .failure(.invalidPath)
        } catch FileTransferPathPolicy.PathError.pathDenied {
            return .failure(.pathDenied)
        } catch {
            return .failure(.invalidPath)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .failure(.notAFile)
        }

        let offset = max(integer(named: "offset", in: parameters, default: 0), 0)
        let requestedLength = integer(named: "length", in: parameters, default: 65_536)
        let length = min(max(requestedLength, 0), 65_536)

        let fileURL = URL(fileURLWithPath: resolvedPath)
        let fileSize: Int64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: resolvedPath)
            fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            return .failure(.ioError("Could not read file attributes."))
        }

        if offset >= fileSize {
            return .success([
                "path": resolvedPath,
                "file_size_bytes": fileSize,
                "offset": offset,
                "length_returned": 0,
                "data_base64": "",
                "eof": true
            ])
        }

        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            let data = handle.readData(ofLength: length)
            let nextOffset = offset + data.count
            let eof = nextOffset >= fileSize
            return .success([
                "path": resolvedPath,
                "file_size_bytes": fileSize,
                "offset": offset,
                "length_returned": data.count,
                "data_base64": data.base64EncodedString(),
                "eof": eof
            ])
        } catch {
            return .failure(.ioError("Could not read file: \(error.localizedDescription)"))
        }
    }

    private func fsWriteFile(parameters: [String: ToolArgumentValue]) -> NativeOperationResult {
        guard let rawPath = requiredString(named: "path", in: parameters) else {
            return .failure(.missingParameter("path"))
        }
        guard let rawData = requiredString(named: "data", in: parameters) else {
            return .failure(.missingParameter("data"))
        }

        let resolvedPath: String
        do {
            resolvedPath = try pathPolicy.resolveUserPath(rawPath)
        } catch FileTransferPathPolicy.PathError.invalidPath {
            return .failure(.invalidPath)
        } catch FileTransferPathPolicy.PathError.pathDenied {
            return .failure(.pathDenied)
        } catch {
            return .failure(.invalidPath)
        }

        let encoding = string(named: "encoding", in: parameters, default: "base64").lowercased()
        let mode = string(named: "mode", in: parameters, default: "create").lowercased()

        let payload: Data
        switch encoding {
        case "base64":
            guard let decoded = Data(base64Encoded: rawData) else {
                return .failure(.invalidEncoding)
            }
            payload = decoded
        case "utf8":
            guard let decoded = rawData.data(using: .utf8) else {
                return .failure(.invalidEncoding)
            }
            payload = decoded
        default:
            return .failure(.invalidEncoding)
        }

        let fileURL = URL(fileURLWithPath: resolvedPath)
        let exists = FileManager.default.fileExists(atPath: resolvedPath)

        switch mode {
        case "create":
            if exists {
                return .failure(.alreadyExists)
            }
            do {
                try payload.write(to: fileURL, options: .atomic)
            } catch {
                return .failure(.ioError("Could not create file: \(error.localizedDescription)"))
            }
        case "overwrite":
            do {
                try payload.write(to: fileURL, options: .atomic)
            } catch {
                return .failure(.ioError("Could not overwrite file: \(error.localizedDescription)"))
            }
        case "append":
            if exists {
                do {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: payload)
                } catch {
                    return .failure(.ioError("Could not append to file: \(error.localizedDescription)"))
                }
            } else {
                do {
                    try payload.write(to: fileURL, options: .atomic)
                } catch {
                    return .failure(.ioError("Could not create file for append: \(error.localizedDescription)"))
                }
            }
        default:
            return .failure(.invalidMode)
        }

        return .success([
            "path": resolvedPath,
            "bytes_written": payload.count,
            "mode": mode
        ])
    }

    // MARK: - Helpers

    private struct NativeExecutionFailure {
        let code: String
        let message: String
        let stderr: String

        static let invalidPath = Self(
            code: "invalid_path",
            message: "Path must be absolute after expanding a leading tilde.",
            stderr: "Rejected relative path."
        )
        static let pathDenied = Self(
            code: "path_denied",
            message: "Path is not allowed for file transfer.",
            stderr: "Sensitive path denied."
        )
        static let notADirectory = Self(
            code: "not_a_directory",
            message: "Path is not a directory.",
            stderr: "Expected a directory."
        )
        static let notAFile = Self(
            code: "not_a_file",
            message: "Path is not a regular file.",
            stderr: "Expected a file."
        )
        static let alreadyExists = Self(
            code: "already_exists",
            message: "File already exists.",
            stderr: "Create mode refuses to overwrite an existing file."
        )
        static let invalidEncoding = Self(
            code: "invalid_encoding",
            message: "Data encoding is invalid.",
            stderr: "Use encoding base64 or utf8."
        )
        static let invalidMode = Self(
            code: "invalid_mode",
            message: "Write mode is invalid.",
            stderr: "Use mode create, overwrite, or append."
        )

        static func missingParameter(_ name: String) -> Self {
            Self(
                code: "missing_parameter",
                message: "Missing required parameter: \(name).",
                stderr: "Missing parameter \(name)."
            )
        }

        static func ioError(_ message: String) -> Self {
            Self(code: "io_error", message: message, stderr: message)
        }
    }

    private func entryType(at path: String, isDirectory: Bool) -> String {
        if isSymbolicLink(at: path) {
            return "symlink"
        }
        if isDirectory {
            return "directory"
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return "directory"
        }
        if FileManager.default.isReadableFile(atPath: path) || FileManager.default.isWritableFile(atPath: path) {
            return "file"
        }
        return "other"
    }

    private func isSymbolicLink(at path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func requiredString(named name: String, in parameters: [String: ToolArgumentValue]) -> String? {
        guard let value = parameters[name]?.stringValue, !value.isEmpty else {
            return nil
        }
        return value
    }

    private func string(named name: String, in parameters: [String: ToolArgumentValue], default defaultValue: String) -> String {
        parameters[name]?.stringValue ?? defaultValue
    }

    private func integer(named name: String, in parameters: [String: ToolArgumentValue], default defaultValue: Int) -> Int {
        if let value = parameters[name] {
            switch value {
            case .string(let string):
                return Int(string) ?? defaultValue
            case .json(.number(let number)) where number.rounded() == number:
                return Int(number)
            default:
                break
            }
        }
        return defaultValue
    }

    private func bool(named name: String, in parameters: [String: ToolArgumentValue], default defaultValue: Bool) -> Bool {
        if let value = parameters[name] {
            switch value {
            case .string(let string):
                switch string.lowercased() {
                case "true", "1", "yes": return true
                case "false", "0", "no": return false
                default: break
                }
            case .json(.bool(let bool)):
                return bool
            case .json(.number(let number)):
                return number != 0
            default:
                break
            }
        }
        return defaultValue
    }

    private func encodeJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw ToolValidationError.invalidNativeTool("could not encode JSON result")
        }
        return string
    }

    private func failureOutcome(
        tool: ToolDefinition,
        started: Date,
        code: String,
        message: String,
        stderr: String
    ) -> ToolExecutionOutcome {
        let stdout: String
        if let data = try? JSONSerialization.data(
            withJSONObject: ["error": message, "code": code],
            options: [.sortedKeys]
        ), let string = String(data: data, encoding: .utf8) {
            stdout = string
        } else {
            stdout = "{\"error\":\"\(message)\",\"code\":\"\(code)\"}"
        }

        return ToolExecutionOutcome(
            toolID: tool.id,
            toolName: tool.name,
            exitCode: 1,
            stdout: stdout,
            stderr: stderr,
            duration: Date().timeIntervalSince(started),
            timedOut: false,
            truncatedStdout: false,
            truncatedStderr: false
        )
    }

    private func timedOutOutcome(tool: ToolDefinition, started: Date) -> ToolExecutionOutcome {
        ToolExecutionOutcome(
            toolID: tool.id,
            toolName: tool.name,
            exitCode: 1,
            stdout: "{\"error\":\"Timed out.\",\"code\":\"timeout\"}",
            stderr: "Native tool exceeded the configured timeout.",
            duration: Date().timeIntervalSince(started),
            timedOut: true,
            truncatedStdout: false,
            truncatedStderr: false
        )
    }
}
