import Foundation

enum ExecutableLocator {
    static var homeDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// The whole environment a tool process starts with. It is built from
    /// scratch so nothing from the app's own environment, such as an API key,
    /// leaks into a tool. TMPDIR, USER, and LOGNAME are the exceptions:
    /// without them Python and other tools fall back to the shared /tmp and
    /// cannot tell who they run as.
    static var toolEnvironment: [String: String] {
        [
            "HOME": homeDirectory,
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": searchDirectories.joined(separator: ":"),
            "PAGER": "cat",
            "MANPAGER": "cat",
            "GIT_PAGER": "cat",
            "TERM": "dumb",
            "TMPDIR": NSTemporaryDirectory(),
            "USER": NSUserName(),
            "LOGNAME": NSUserName()
        ]
    }

    static var searchDirectories: [String] {
        uniqued(
            // GUI-launched apps inherit a minimal macOS PATH that often puts
            // /usr/bin first. Keep user/Homebrew tool roots first so
            // /usr/bin/env shebangs resolve the same way they do in Terminal.
            userBinDirectories + systemBinDirectories + environmentPATHDirectories
        )
    }

    /// Where MacRemote looks for a helper it launches itself (Cloudflare's
    /// helper). Package-manager and system folders come first, so a file with
    /// the same name in a folder inside the home folder cannot take the place
    /// of the copy the owner installed with Homebrew.
    static var systemFirstSearchDirectories: [String] {
        uniqued(systemBinDirectories + userBinDirectories + environmentPATHDirectories)
    }

    static func executablePath(named name: String) -> String? {
        executablePath(named: [name])
    }

    static func executablePath(named names: [String]) -> String? {
        for name in names {
            if let path = executablePath(named: name, in: searchDirectories) {
                return path
            }
        }
        return nil
    }

    /// The first executable called `name` in `directories`, in the order given.
    static func executablePath(named name: String, in directories: [String]) -> String? {
        for directory in directories {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
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

    private static let systemBinDirectories = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    private static var userBinDirectories: [String] {
        [
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/bin",
            "\(homeDirectory)/.cargo/bin",
            "\(homeDirectory)/.bun/bin",
            "\(homeDirectory)/.deno/bin",
            "\(homeDirectory)/.grok/bin",
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
