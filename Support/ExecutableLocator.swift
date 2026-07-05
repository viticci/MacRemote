import Foundation

enum ExecutableLocator {
    static var homeDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    static var toolEnvironment: [String: String] {
        [
            "HOME": homeDirectory,
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": searchDirectories.joined(separator: ":"),
            "PAGER": "cat",
            "MANPAGER": "cat",
            "GIT_PAGER": "cat",
            "TERM": "dumb"
        ]
    }

    static var searchDirectories: [String] {
        uniqued(
            // GUI-launched apps inherit a minimal macOS PATH that often puts
            // /usr/bin first. Keep user/Homebrew tool roots first so
            // /usr/bin/env shebangs resolve the same way they do in Terminal.
            userBinDirectories +
                [
                    "/opt/homebrew/bin",
                    "/opt/homebrew/sbin",
                    "/usr/local/bin",
                    "/usr/local/sbin",
                    "/usr/bin",
                    "/bin",
                    "/usr/sbin",
                    "/sbin"
                ] +
                environmentPATHDirectories
        )
    }

    static func executablePath(named name: String) -> String? {
        executablePath(named: [name])
    }

    static func executablePath(named names: [String]) -> String? {
        for name in names {
            for directory in searchDirectories {
                let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
                if FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }

    static func executablePath(candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static var environmentPATHDirectories: [String] {
        ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init) ?? []
    }

    private static var userBinDirectories: [String] {
        [
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/bin",
            "\(homeDirectory)/.cargo/bin",
            "\(homeDirectory)/.bun/bin",
            "\(homeDirectory)/.deno/bin",
            "\(homeDirectory)/.grok/bin",
            "\(homeDirectory)/.matter/bin"
        ]
    }

    private static func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                continue
            }
            result.append(normalized)
        }
        return result
    }
}
