import Foundation

/// The one sanitizer for text harvested during a CLI scan (spec §4.4, R12–R14).
/// Strangers' package metadata passes through here before it is stored on a
/// candidate; nothing downstream may consume the raw bytes. Suspicious strings
/// are dropped whole, never cleaned (R13) — prefer false positives.
enum CLIHarvestedTextSanitizer {
    static let summaryLimit = 160
    static let nameLimit = 40
    static let versionLimit = 32

    // MARK: Field entry points

    /// Full pipeline for descriptions: normalize → strip invisibles → collapse
    /// → strip links/markup → cap → injection screen. `nil` means "dropped":
    /// the caller substitutes the neutral generated fallback and no provenance
    /// chip renders (R13).
    static func sanitizedSummary(_ raw: String?) -> String? {
        guard let scrubbed = scrubbedDisplayText(raw) else { return nil }
        var stripped = strippingLinksAndMarkup(scrubbed)
        stripped = collapsedWhitespace(stripped)
        guard !stripped.isEmpty else { return nil }
        let capped = truncatedAtWordBoundary(stripped, limit: summaryLimit)
        guard passesInjectionScreen(capped) else { return nil }
        return capped
    }

    static func sanitizedSummary(data: Data) -> String? {
        sanitizedSummary(String(decoding: data, as: UTF8.self))
    }

    /// Display names are additionally restricted to letters/digits/space/._-
    /// (spec §4.4 "name extras"); anything else falls back to the binary
    /// basename the user already trusts on disk.
    static func sanitizedDisplayName(_ raw: String?, fallback: String) -> String {
        guard let scrubbed = scrubbedDisplayText(raw),
              scrubbed.range(of: "^[A-Za-z0-9 ._-]+$", options: .regularExpression) != nil,
              passesInjectionScreen(scrubbed) else {
            return String(fallback.prefix(nameLimit))
        }
        return String(scrubbed.prefix(nameLimit))
    }

    /// Package identifiers keep their native charset ("@readwise/cli") but run
    /// the full pipeline including the injection screen.
    static func sanitizedPackageName(_ raw: String?) -> String? {
        guard let scrubbed = scrubbedDisplayText(raw),
              passesInjectionScreen(scrubbed) else {
            return nil
        }
        return String(scrubbed.prefix(nameLimit))
    }

    static func sanitizedVersion(_ raw: String?) -> String? {
        guard let scrubbed = scrubbedDisplayText(raw),
              passesInjectionScreen(scrubbed) else {
            return nil
        }
        return String(scrubbed.prefix(versionLimit))
    }

    /// Homepages are the one field whose content *is* a link, so the URL-strip
    /// step does not apply; instead the value must look like a URL or a bare
    /// domain path and stays display-only.
    static func sanitizedHomepage(_ raw: String?) -> String? {
        guard let scrubbed = scrubbedDisplayText(raw),
              scrubbed.count <= 200,
              scrubbed.range(
                of: #"^(https?://)?[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}([:/?#][^\s{}<>\\`"']*)?$"#,
                options: .regularExpression
              ) != nil else {
            return nil
        }
        return scrubbed
    }

    static func sanitizedOriginDomain(_ raw: String?) -> String? {
        guard let scrubbed = scrubbedDisplayText(raw),
              scrubbed.count <= 100,
              scrubbed.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else {
            return nil
        }
        return scrubbed
    }

    // MARK: Pipeline steps

    /// Steps 1–3: UTF-8/NFC normalize, strip control + invisible + bidi
    /// characters, collapse whitespace. Also the belt-and-braces pass render
    /// boundaries re-run on stored strings (R14).
    static func scrubbedDisplayText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.precomposedStringWithCanonicalMapping
        var scalars = String.UnicodeScalarView()
        for scalar in normalized.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                scalars.append(" ")
            } else if !Self.strippedScalars.contains(scalar) {
                scalars.append(scalar)
            }
        }
        let collapsed = collapsedWhitespace(String(scalars))
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Step 4: remove URLs and email addresses entirely; strip Markdown and
    /// HTML structure. Harvested text may never contain code formatting — the
    /// backtick style is what MacRemote's *trusted* guidance looks like.
    private static func strippingLinksAndMarkup(_ value: String) -> String {
        var text = value
        let replacements: [(pattern: String, template: String)] = [
            (#"!\[[^\]]*\]\([^)]*\)"#, ""),          // images
            (#"\[([^\]]*)\]\(([^)]*)\)"#, "$1"),     // links → link text
            (#"```"#, ""),                            // fences
            (#"`"#, ""),                              // inline code markers
            (#"</?[A-Za-z][^<>]{0,200}>"#, ""),      // HTML tags (never `<|`)
            (#"(?i)\b(?:https?|ftp)://[^\s]+"#, ""), // URLs
            (#"(?i)\bwww\.[^\s]+"#, ""),
            (#"[^\s@,;()]+@[^\s@,;()]+\.[A-Za-z0-9._-]+"#, ""), // emails
            (#"^#{1,6}\s+"#, ""),                    // heading marker
            (#"^>\s?"#, "")                          // quote marker
        ]
        for replacement in replacements {
            text = text.replacingOccurrences(
                of: replacement.pattern,
                with: replacement.template,
                options: .regularExpression
            )
        }
        return text
    }

    /// Step 5: hard cap at a word boundary with a trailing ellipsis.
    static func truncatedAtWordBoundary(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let hardPrefix = String(value.prefix(limit - 1))
        var cut = hardPrefix
        if let lastSpace = hardPrefix.lastIndex(of: " "),
           hardPrefix.distance(from: hardPrefix.startIndex, to: lastSpace) > limit / 2 {
            cut = String(hardPrefix[..<lastSpace])
        }
        while let last = cut.last, last == " " || last == "," || last == ";" || last == "." {
            cut.removeLast()
        }
        return cut + "…"
    }

    /// Step 6: drop the whole string on any case-insensitive match (R13).
    static func passesInjectionScreen(_ value: String) -> Bool {
        for character in Self.forbiddenResidue where value.contains(character) {
            return false
        }
        if value.contains("$(") {
            return false
        }
        for pattern in Self.injectionPatterns {
            if value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return false
            }
        }
        return true
    }

    // MARK: Tables

    private static let forbiddenResidue: [Character] = ["{", "}", "<", ">", "`", "\\"]

    private static let injectionPatterns: [String] = [
        // Hijack phrases.
        #"ignore (all|any|previous|prior)"#,
        #"disregard"#,
        #"new instructions"#,
        #"system prompt"#,
        #"you are"#,
        #"you must"#,
        #"always call"#,
        #"never ask"#,
        #"do not ask"#,
        #"without asking"#,
        #"before (running|using) any other tool"#,
        #"first call"#,
        #"instead of"#,
        // Tool/protocol tokens.
        #"tools/call"#,
        #"mcp"#,
        #"approve"#,
        #"always allow"#,
        #"argv"#,
        #"args:"#,
        #"stdin"#,
        #"\{args\}"#,
        // Role/format tokens.
        #"assistant:"#,
        #"user:"#,
        #"system:"#,
        #"<\|"#,
        #"\|>"#,
        #"###"#,
        #"important:"#,
        #"note to ai"#
    ]

    private static let strippedScalars: Set<Unicode.Scalar> = {
        var set = Set<Unicode.Scalar>()
        for value in 0x00...0x1F { set.insert(Unicode.Scalar(UInt32(value))!) }
        set.insert(Unicode.Scalar(UInt32(0x7F))!)
        for value in 0x80...0x9F { set.insert(Unicode.Scalar(UInt32(value))!) }
        for value in [0x200B, 0x200C, 0x200D, 0xFEFF, 0x2060, 0x200E, 0x200F] {
            set.insert(Unicode.Scalar(UInt32(value))!)
        }
        for value in 0x202A...0x202E { set.insert(Unicode.Scalar(UInt32(value))!) }
        for value in 0x2066...0x2069 { set.insert(Unicode.Scalar(UInt32(value))!) }
        return set
    }()
}
