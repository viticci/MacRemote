import Foundation

/// Pure-read file typing for discovered binaries (spec §2.4 step 2): magic
/// bytes, shebang extraction, wrapper-script sniffing, and Go buildinfo
/// parsing. Operates on in-memory head bytes only — nothing is ever run.
enum CLIBinaryInspector {
    static let scriptSniffByteLimit = 4096

    enum Inspection: Equatable, Sendable {
        case machO(architectures: [String])
        case universal(architectures: [String])
        case script(interpreterLine: String)
        case unknown
    }

    /// Classifies the first bytes of a file (pass up to 4 KB).
    static func inspect(headData data: Data) -> Inspection {
        guard data.count >= 4 else { return .unknown }
        let bytes = [UInt8](data.prefix(8))

        switch (bytes[0], bytes[1], bytes[2], bytes[3]) {
        case (0xCF, 0xFA, 0xED, 0xFE):   // 64-bit thin, little-endian on disk
            return .machO(architectures: [thinArchitecture(data, littleEndian: true, is64: true)])
        case (0xCE, 0xFA, 0xED, 0xFE):   // legacy 32-bit thin
            return .machO(architectures: [thinArchitecture(data, littleEndian: true, is64: false)])
        case (0xCA, 0xFE, 0xBA, 0xBE):
            // Shared magic with Java class files: fat headers keep
            // nfat_arch < 30, class files put a version ≥ 45 here.
            let count = bigEndianUInt32(data, at: 4)
            guard count < 30 else { return .unknown }
            return .universal(architectures: fatArchitectures(data, count: Int(count), is64: false))
        case (0xCA, 0xFE, 0xBA, 0xBF):
            let count = bigEndianUInt32(data, at: 4)
            guard count < 30 else { return .unknown }
            return .universal(architectures: fatArchitectures(data, count: Int(count), is64: true))
        case (0x23, 0x21, _, _):         // "#!"
            let firstLine = String(decoding: data.prefix(scriptSniffByteLimit), as: UTF8.self)
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            let interpreterLine = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return .script(interpreterLine: interpreterLine)
        default:
            return .unknown              // ELF and anything else: skip
        }
    }

    /// "#!/usr/bin/env python3" → (path: "/usr/bin/env", arguments: ["python3"]).
    static func shebangComponents(_ interpreterLine: String) -> (path: String, arguments: [String])? {
        let parts = interpreterLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first, first.hasPrefix("/") else { return nil }
        return (first, Array(parts.dropFirst()))
    }

    /// A wrapper script whose only statement is `exec /abs/path "$@"` reveals
    /// the real target (spec §2.4 step 3). Only sniffed for scripts ≤ 4 KB.
    static func wrapperScriptTarget(inScriptData data: Data) -> String? {
        guard data.count <= scriptSniffByteLimit else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        var execTarget: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let match = line.range(
                of: #"^exec\s+"?(/[^"\s]+)"?(\s+("\$@"|\$@|"\$\{@\}"))?\s*$"#,
                options: .regularExpression
            ) {
                guard execTarget == nil else { return nil }   // one statement only
                let statement = String(line[match])
                let afterExec = statement.dropFirst("exec".count).trimmingCharacters(in: .whitespaces)
                let target = afterExec
                    .split(separator: " ", omittingEmptySubsequences: true)
                    .first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                execTarget = target
            } else {
                return nil   // any other statement disqualifies the sniff
            }
        }
        return execTarget
    }

    /// The file that running `path` actually executes: the end of its
    /// symlinks or, for a wrapper script whose only statement is
    /// `exec /abs/path "$@"` (Homebrew's `command_wrapper`), the program it
    /// hands off to (spec §2.4 step 3). Provenance records and rechecks the
    /// signature of this file, so adding a tool and revalidating it (R16)
    /// always read the same one. Any other script resolves to itself.
    static func executionTarget(
        ofExecutableAt path: String,
        fileReader: any FileReading = DefaultFileReader()
    ) -> String {
        let resolved = fileReader.realPath(path)
        guard let attributes = fileReader.attributes(atPath: resolved),
              !attributes.isDirectory,
              attributes.fileSize <= scriptSniffByteLimit,
              let head = fileReader.contents(atPath: resolved, maxBytes: scriptSniffByteLimit),
              case .script = inspect(headData: head),
              let target = wrapperScriptTarget(inScriptData: head),
              fileReader.fileExists(atPath: target) else {
            return resolved
        }
        return fileReader.realPath(target)
    }

    // MARK: Go buildinfo

    struct GoBuildInfo: Equatable, Sendable {
        let goVersion: String?
        let modulePath: String?
        let moduleVersion: String?
    }

    /// "\u{FF} Go buildinf:" — the 14-byte header magic.
    static let goBuildInfoMagic = Data([0xFF] + Array(" Go buildinf:".utf8))

    /// Scans one in-memory window for the buildinfo header and, for Go ≥ 1.18
    /// inline-string layouts, extracts the toolchain version and module facts.
    static func goBuildInfo(inWindow data: Data) -> GoBuildInfo? {
        guard let magicRange = data.range(of: goBuildInfoMagic) else { return nil }
        let headerStart = magicRange.lowerBound
        guard data.endIndex - headerStart >= 32 else { return nil }
        let flags = data[headerStart + 15]
        guard flags & 0x2 != 0 else {
            // Pointer-based layout (Go < 1.18): out of budget for a pure
            // window read; the candidate stays path-only.
            return GoBuildInfo(goVersion: nil, modulePath: nil, moduleVersion: nil)
        }

        var cursor = headerStart + 32
        guard let version = readGoString(data, at: &cursor) else {
            return GoBuildInfo(goVersion: nil, modulePath: nil, moduleVersion: nil)
        }
        var modulePath: String?
        var moduleVersion: String?
        if let modInfo = readGoString(data, at: &cursor) {
            let trimmed = strippedModInfoSentinel(modInfo)
            for line in trimmed.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: "\t").map(String.init)
                if fields.count >= 2, fields[0] == "path" {
                    modulePath = fields[1]
                }
                if fields.count >= 3, fields[0] == "mod" {
                    if modulePath == nil || fields[1] == modulePath {
                        modulePath = modulePath ?? fields[1]
                        moduleVersion = fields[2]
                    }
                }
            }
        }
        return GoBuildInfo(goVersion: version, modulePath: modulePath, moduleVersion: moduleVersion)
    }

    private static func strippedModInfoSentinel(_ value: String) -> String {
        // cmd/go wraps modinfo in 16-byte sentinels; strip when present.
        let bytes = Array(value.utf8)
        let sentinel: [UInt8] = [
            0x30, 0x77, 0xAF, 0x0C, 0x92, 0x74, 0x08, 0x02,
            0x41, 0xE1, 0xC1, 0x07, 0xE6, 0xD6, 0x18, 0xE6
        ]
        guard bytes.count > 32, Array(bytes.prefix(16)) == sentinel else { return value }
        let inner = Array(bytes.dropFirst(16).dropLast(16))
        return String(decoding: inner, as: UTF8.self)
    }

    private static func readGoString(_ data: Data, at cursor: inout Int) -> String? {
        guard let length = readUvarint(data, at: &cursor), length > 0, length < 1024 * 1024,
              cursor + Int(length) <= data.endIndex else {
            return nil
        }
        let stringData = data[cursor..<(cursor + Int(length))]
        cursor += Int(length)
        return String(decoding: stringData, as: UTF8.self)
    }

    private static func readUvarint(_ data: Data, at cursor: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while cursor < data.endIndex, shift < 64 {
            let byte = data[cursor]
            cursor += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
        }
        return nil
    }

    // MARK: Mach-O helpers

    private static func thinArchitecture(_ data: Data, littleEndian: Bool, is64: Bool) -> String {
        guard data.count >= 8 else { return is64 ? "unknown-64" : "unknown-32" }
        let raw = littleEndian ? littleEndianUInt32(data, at: 4) : bigEndianUInt32(data, at: 4)
        return architectureName(cpuType: raw)
    }

    private static func fatArchitectures(_ data: Data, count: Int, is64: Bool) -> [String] {
        var architectures = [String]()
        let entrySize = is64 ? 32 : 20
        for index in 0..<count {
            let offset = 8 + index * entrySize
            guard data.count >= offset + 4 else { break }
            architectures.append(architectureName(cpuType: bigEndianUInt32(data, at: offset)))
        }
        return architectures
    }

    private static func architectureName(cpuType: UInt32) -> String {
        switch cpuType {
        case 0x0100_000C: "arm64"
        case 0x0100_0007: "x86_64"
        case 0x0000_0007: "i386"
        case 0x0000_000C: "arm"
        case 0x0000_0012: "ppc"
        case 0x0100_0012: "ppc64"
        default: String(format: "cpu-0x%x", cpuType)
        }
    }

    private static func bigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        let start = data.startIndex + offset
        return (UInt32(data[start]) << 24) | (UInt32(data[start + 1]) << 16)
            | (UInt32(data[start + 2]) << 8) | UInt32(data[start + 3])
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        let start = data.startIndex + offset
        return UInt32(data[start]) | (UInt32(data[start + 1]) << 8)
            | (UInt32(data[start + 2]) << 16) | (UInt32(data[start + 3]) << 24)
    }
}
