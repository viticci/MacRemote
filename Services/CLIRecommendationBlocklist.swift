import Foundation

/// The three blocklist rings for CLI discovery (spec §4.3). Matched on the
/// symlink-resolved basename (case-insensitive, version-suffix aware) plus
/// path patterns. Ring 1 governs what the product *recommends*, never what the
/// owner may hand-add (R8). This file is also the catalog's written denylist
/// policy (§6.4): no preset may wrap anything in `neverSuggestNames`.
enum CLIRecommendationBlocklist {
    enum Verdict: Equatable, Sendable {
        case suggest
        case interpreter   // Ring 2 — suggest with friction
        case drop          // Ring 1 (⊇ Ring 0) — never suggest
    }

    /// Ring 0 — hard validation block. Mirrors (and extends, per R6) the
    /// validator's shell list; these cannot exist as tools at all.
    static let hardBlockedNames: Set<String> = [
        "sh", "bash", "zsh", "csh", "tcsh", "fish", "env", "dash", "ksh"
    ]

    /// Ring 1 — never suggest. Ring 0 is a subset.
    static let neverSuggestNames: Set<String> = hardBlockedNames.union([
        // Shells & shell-equivalents
        "screen", "tmux", "expect", "script",
        // Privilege & identity
        "sudo", "doas", "su", "login", "visudo", "dscl", "sysadminctl", "dseditgroup",
        // System config & boot
        "launchctl", "csrutil", "spctl", "nvram", "bless", "kmutil", "kextload",
        "kextunload", "systemsetup", "profiles", "softwareupdate", "startosinstall",
        "defaults",
        // Disk & data destruction
        "rm", "srm", "dd", "diskutil", "hdiutil", "asr",
        // Permission / trust mutation
        "chmod", "chown", "chflags", "xattr", "codesign", "notarytool", "stapler",
        // Secrets & keychains — also written catalog policy (§6.4)
        "security", "op", "op-get", "pass", "gopass", "bw", "vault", "gpg", "gpgsm",
        "certutil", "pk12util",
        // Remote-exec / tunnel primitives
        "ssh", "scp", "sftp", "nc", "ncat", "netcat", "socat", "telnet", "mosh",
        // Package managers as mutators (DL-16)
        "installer", "pkgutil", "brew", "port"
    ])

    /// Ring 1 name-prefix patterns: `newfs_*`, `fsck_*`, `mkfs*`, `pinentry*`.
    static let neverSuggestPrefixes: [String] = ["newfs_", "fsck_", "mkfs", "pinentry"]

    /// Ring 2 — interpreters & agent CLIs, suggested with friction (DL-8).
    static let interpreterNames: Set<String> = [
        "node", "python", "python3", "ruby", "perl", "php", "lua", "deno", "bun",
        "julia", "rscript", "swift", "osascript", "automator", "shortcuts",
        "claude", "codex", "grok"
    ]

    /// Staging locations whose binaries are auto-Ring-1 (R21 / §2.6).
    static func stagingPathPrefixes(homeDirectory: String) -> [String] {
        [
            "/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/",
            homeDirectory + "/Downloads/",
            homeDirectory + "/.Trash/"
        ]
    }

    static func isStagingPath(_ path: String, homeDirectory: String) -> Bool {
        stagingPathPrefixes(homeDirectory: homeDirectory).contains { path.hasPrefix($0) }
    }

    /// Ring verdict for a candidate. `shellPaths` is the resolved contents of
    /// `/etc/shells`; both the literal and the resolved basename are checked so
    /// a `notes → /bin/zsh` symlink cannot evade the ring (G2).
    static func verdict(
        literalBasename: String,
        resolvedBasename: String,
        resolvedPath: String,
        shellPaths: Set<String>
    ) -> Verdict {
        if shellPaths.contains(resolvedPath) {
            return .drop
        }
        for basename in [literalBasename, resolvedBasename] {
            if matches(basename, in: neverSuggestNames, prefixes: neverSuggestPrefixes) {
                return .drop
            }
        }
        for basename in [literalBasename, resolvedBasename] {
            if matches(basename, in: interpreterNames, prefixes: []) {
                return .interpreter
            }
        }
        return .suggest
    }

    static func matches(_ basename: String, in names: Set<String>, prefixes: [String]) -> Bool {
        let lowered = basename.lowercased()
        if names.contains(lowered) || names.contains(normalizedName(lowered)) {
            return true
        }
        return prefixes.contains { lowered.hasPrefix($0) }
    }

    /// Strips a trailing version suffix so `python3.12`, `ksh93`, and `node22`
    /// match their unversioned ring entries.
    static func normalizedName(_ basename: String) -> String {
        basename.lowercased().replacingOccurrences(
            of: #"[._-]?[0-9]+(\.[0-9]+)*$"#,
            with: "",
            options: .regularExpression
        )
    }

    /// Parses `/etc/shells` content into absolute shell paths (Ring 0's
    /// path-based rule, R6 hardening).
    static func shellPaths(fromEtcShells content: String) -> Set<String> {
        var paths = Set<String>()
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("/") else { continue }
            paths.insert(trimmed)
        }
        return paths
    }
}
