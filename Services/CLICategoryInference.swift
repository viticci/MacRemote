import Foundation

/// Cosmetic category inference for scanned candidates (spec §2.7, DL-7).
/// First match wins: keyword table → name patterns → source default. Category
/// gates nothing; capability inference is forbidden and does not exist here.
enum CLICategoryInference {
    /// The AI category ships with the catalog changes (DL-12); until the case
    /// exists, AI-cluster tools degrade to `.developer`.
    static var aiCategory: ToolCategory {
        ToolCategory(rawValue: "ai") ?? .developer
    }

    static func inferredCategory(
        binaryName: String,
        summary: String?,
        keywords: [String],
        source: DiscoveredCLICandidate.Source
    ) -> ToolCategory {
        let name = binaryName.lowercased()
        if name == "notesctl" {
            return .notes
        }
        if name == "alexandria" {
            return aiCategory
        }
        if name == "overctl" || name == "octl" {
            return .podcasts
        }
        if ["musicctl", "mctl", "applemusic"].contains(name) {
            return .music
        }
        if ["goodlinksctl", "matter", "readwise"].contains(name) {
            return .readLater
        }
        if name == "iris" || name == "iphone" {
            return .iphone
        }

        let haystack = ([binaryName, summary ?? ""] + keywords)
            .joined(separator: " ")
            .lowercased()

        for (category, words) in Self.keywordTable {
            for word in words where matchesWholeWord(word, in: haystack) {
                return category
            }
        }

        if name.hasPrefix("git-") {
            return .developer
        }
        if name.hasSuffix("ctl") {
            return .developer
        }
        if name.hasSuffix("-config") || name.hasPrefix("lib") {
            return .developer
        }

        switch source {
        case .npmGlobal, .uvTool, .pipx, .pipUser, .cargo, .goBinary:
            return .developer
        case .homebrewCask, .application, .homebrewFormula, .homebrewTap, .looseBinary:
            return .utilities
        }
    }

    private static func matchesWholeWord(_ word: String, in haystack: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        return haystack.range(of: "\\b\(escaped)\\b", options: .regularExpression) != nil
    }

    /// Ordered per spec §2.7 — earlier rows win.
    private static let keywordTable: [(ToolCategory, [String])] = [
        (.notes, ["notesctl", "apple notes", "notes cli", "note taking", "note-taking", "note manager"]),
        (aiCategory, ["alexandria", "llm", "model", "ai", "agent", "gpt", "claude", "transcribe",
                      "whisper", "embedding", "inference", "prompt"]),
        (.reminders, ["reminder", "todo", "task manager", "calendar"]),
        (.habits, ["habit", "habitify", "streak"]),
        (.podcasts, ["podcast", "episode", "pocket casts", "overcast"]),
        (.music, ["apple music", "music library", "music player", "playlist",
                  "listening history", "now playing"]),
        (.readLater, ["read later", "read-later", "goodlinks", "readwise", "matter reading"]),
        (.imageProcessing, ["image", "photo", "png", "jpeg", "webp", "svg", "ocr",
                            "thumbnail", "screenshot", "video", "audio", "encode",
                            "codec", "color"]),
        (.text, ["text", "markdown", "json", "yaml", "csv", "grep", "search",
                 "regex", "token", "translate", "format", "diff", "parse",
                 "readability", "article"]),
        (.filesystem, ["file", "directory", "folder", "disk", "archive", "compress",
                       "zip", "tar", "sync", "backup", "mount", "tree"]),
        (.developer, ["git", "github", "compiler", "build", "debug", "docker",
                      "container", "kubernetes", "database", "sql", "http", "api",
                      "server", "cloud", "deploy", "package manager", "sdk",
                      "lint", "test"])
    ]
}
