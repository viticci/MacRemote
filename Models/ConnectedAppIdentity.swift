import Foundation

// TRUST BOUNDARY — READ BEFORE EXTENDING THIS FILE.
//
// A connected app's identity here is a *picture and a label*, nothing else.
// It is derived from strings the app itself supplied at registration (its
// `client_name` and its redirect URIs), which are attacker-controlled. Any app
// can register as "Claude". Therefore:
//
//   - Nothing in Services/, Stores/, or the MCP server may read this type.
//     Authentication, authorization, Always Allow rules, token validity, and
//     revocation are keyed on the client ID and the OAuth trust ID only.
//   - Matching a brand here grants zero additional privilege and changes no
//     security decision. It only selects which glyph is drawn.
//   - `grep -rn 'ConnectedAppIdentity' Services Stores` must stay empty.
//
// The matching itself is deliberately narrow: exact alias membership after a
// deterministic normalization, plus one last-resort exact-host rule that only
// applies when the app supplied no informative name at all. There is no
// substring/`contains` matching anywhere — that is how the previous glyph
// helper turned every name containing "openai" into ChatGPT.
//
// `bundleIdentifiers` does not widen any of that. It is not a *matching*
// strategy: nothing an app says is ever compared against it. It is only asked,
// after a brand has already been resolved by name, whether a copy of that
// vendor's app happens to be installed here so its own mark can be drawn. An
// app that claims to be Claude therefore gets Claude's picture whether or not
// Claude is installed, and gets no trust either way. A locally extracted mark
// is *not* stronger evidence than a bundled one — same picture, same nothing.

/// Presentation-only brand identity for a connected app (decision D46).
struct ConnectedAppIdentity: Equatable, Hashable, Sendable, Identifiable {
    /// Stable catalog key. Not a security identifier.
    let id: String
    /// Canonical product name, used for search and accessibility text only —
    /// the received `client_name` is what the UI actually shows.
    let displayName: String
    /// Normalized names that identify this brand exactly.
    let exactAliases: Set<String>
    /// Exact redirect hosts (never suffixes) usable only as last-resort
    /// evidence when the app supplied no informative name.
    let redirectHostEvidence: Set<String>
    /// Bundled artwork file name (without extension) for light appearance.
    /// `nil` means no redistributable mark is available — see
    /// `Resources/ConnectedAppIcons/THIRD-PARTY-NOTICES.md`.
    let lightIconResource: String?
    /// Bundled artwork for dark appearance. May equal `lightIconResource` when
    /// a single mark reads correctly in both.
    let darkIconResource: String?
    /// Bundle identifiers of this vendor's own macOS apps. Read only to ask
    /// whether one is installed here, never compared against anything an app
    /// supplied — see the note above. Exact strings, no prefixes.
    let bundleIdentifiers: Set<String>
    /// Resource base name inside such a bundle to prefer for light appearance,
    /// when the vendor ships a named variant worth having. `nil` falls back to
    /// the app icon.
    let localLightResource: String?
    /// Same for dark appearance.
    let localDarkResource: String?
    /// Always present. Every entry has to survive with no artwork at all.
    let fallbackSymbol: String

    init(
        id: String,
        displayName: String,
        exactAliases: Set<String>,
        redirectHostEvidence: Set<String>,
        lightIconResource: String?,
        darkIconResource: String?,
        bundleIdentifiers: Set<String> = [],
        localLightResource: String? = nil,
        localDarkResource: String? = nil,
        fallbackSymbol: String
    ) {
        self.id = id
        self.displayName = displayName
        self.exactAliases = exactAliases
        self.redirectHostEvidence = redirectHostEvidence
        self.lightIconResource = lightIconResource
        self.darkIconResource = darkIconResource
        self.bundleIdentifiers = bundleIdentifiers
        self.localLightResource = localLightResource
        self.localDarkResource = localDarkResource
        self.fallbackSymbol = fallbackSymbol
    }

    var hasBundledArtwork: Bool {
        lightIconResource != nil || darkIconResource != nil
    }

    /// Which named resource inside an installed vendor bundle an appearance
    /// prefers. Mirrors `artworkResource(forDarkAppearance:)` so both tiers
    /// resolve appearance by the same rule.
    func localResource(forDarkAppearance isDarkAppearance: Bool) -> String? {
        isDarkAppearance
            ? localDarkResource ?? localLightResource
            : localLightResource ?? localDarkResource
    }
}

extension ConnectedAppIdentity {
    /// Placeholder for an app that matched nothing. Never a failure state.
    static let generic = ConnectedAppIdentity(
        id: "generic",
        displayName: "App",
        exactAliases: [],
        redirectHostEvidence: [],
        lightIconResource: nil,
        darkIconResource: nil,
        fallbackSymbol: "network"
    )

    /// The catalog. Adding a row is a licensing decision, not a code decision:
    /// artwork may only be bundled when redistribution is documented in
    /// `Resources/ConnectedAppIcons/MANIFEST.json`.
    static let catalog: [ConnectedAppIdentity] = [
        ConnectedAppIdentity(
            id: "chatgpt",
            displayName: "ChatGPT",
            exactAliases: ["chatgpt"],
            // Deliberately empty: this Mac has seen unrelated apps register
            // chatgpt.com callbacks (a DCR probe), so the host proves nothing.
            redirectHostEvidence: [],
            // OpenAI's guidelines permit unaltered use but publish no
            // downloadable file, so there is nothing to bundle.
            lightIconResource: nil,
            darkIconResource: nil,
            bundleIdentifiers: ["com.openai.codex"],
            localLightResource: "icon-chatgpt",
            localDarkResource: "icon-chatgpt",
            fallbackSymbol: "sparkles"
        ),
        ConnectedAppIdentity(
            id: "claude",
            displayName: "Claude",
            exactAliases: ["claude", "claudedesktop", "claudecode", "claudeai"],
            redirectHostEvidence: ["claude.ai"],
            // Anthropic publishes no brand terms at all, so nothing is bundled.
            lightIconResource: nil,
            darkIconResource: nil,
            bundleIdentifiers: ["com.anthropic.claudefordesktop"],
            // Template artwork: the plain file is the black mark, `-Dark` the
            // white one. Used as published, unrecoloured.
            localLightResource: "TrayIconTemplate",
            localDarkResource: "TrayIconTemplate-Dark",
            fallbackSymbol: "bubble.left.and.bubble.right"
        ),
        ConnectedAppIdentity(
            id: "notion",
            displayName: "Notion",
            exactAliases: ["notion"],
            redirectHostEvidence: ["notion.so", "www.notion.so", "api.notion.com"],
            lightIconResource: nil,
            darkIconResource: nil,
            bundleIdentifiers: ["notion.id"],
            fallbackSymbol: "square.grid.2x2"
        ),
        ConnectedAppIdentity(
            id: "raycast",
            displayName: "Raycast",
            exactAliases: ["raycast"],
            redirectHostEvidence: ["raycast.com"],
            // Press-kit logos, byte-for-byte. Raycast names each variant after
            // the background it belongs on, which matches these fields.
            lightIconResource: "raycast-light",
            darkIconResource: "raycast-dark",
            bundleIdentifiers: ["com.raycast.macos"],
            fallbackSymbol: "rays"
        ),
        ConnectedAppIdentity(
            id: "t3code",
            displayName: "T3 Code",
            exactAliases: ["t3code"],
            redirectHostEvidence: ["t3.codes"],
            // MIT-licensed mark; the single macOS icon reads on both
            // appearances (dark squircle, light wordmark, own margins).
            lightIconResource: "t3code",
            darkIconResource: "t3code",
            bundleIdentifiers: ["com.t3tools.t3code"],
            fallbackSymbol: "chevron.left.forwardslash.chevron.right"
        ),
        ConnectedAppIdentity(
            id: "codex",
            displayName: "Codex",
            exactAliases: ["codex", "openaicodex", "codexcli"],
            redirectHostEvidence: [],
            lightIconResource: nil,
            darkIconResource: nil,
            // Codex ships inside the ChatGPT app, with a real appearance pair.
            bundleIdentifiers: ["com.openai.codex"],
            localLightResource: "icon-codex-light",
            localDarkResource: "icon-codex-dark-color",
            fallbackSymbol: "terminal"
        ),
        ConnectedAppIdentity(
            id: "grok",
            displayName: "Grok",
            exactAliases: ["grok"],
            redirectHostEvidence: ["grok.com", "x.ai"],
            // Official xAI logomarks. xAI requires them "exactly as provided",
            // so they are bundled with no transformation whatsoever. Their file
            // names are the mark's own colour, i.e. the opposite of Raycast's
            // convention — hence dark mark for light appearance.
            lightIconResource: "grok-light",
            darkIconResource: "grok-dark",
            fallbackSymbol: "bolt.horizontal"
        )
    ]

    /// Names apps hand over when they have nothing to say about themselves.
    /// Only these unlock redirect-host evidence.
    private static let uninformativeNames: Set<String> = [
        "",
        "remotemcpclient",
        "mcpclient",
        "unknownclient",
        "app"
    ]

    /// Lowercase, fold diacritics, drop everything that is not `[a-z0-9]`.
    /// Deterministic and locale-independent.
    static func normalize(_ value: String?) -> String {
        guard let value else { return "" }
        let folded = value.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        return String(folded.filter { $0.isASCII && ($0.isLowercase || $0.isNumber) })
    }

    /// Resolve a brand for display. See the trust-boundary note above: the
    /// result must never gate behavior.
    static func resolve(name: String?, redirectURIs: [String] = []) -> ConnectedAppIdentity {
        let normalizedName = normalize(name)

        // 1. Exact alias membership. No substrings, no prefixes.
        if !normalizedName.isEmpty,
           let match = catalog.first(where: { $0.exactAliases.contains(normalizedName) }) {
            return match
        }

        // 2. Last resort only: the app told us nothing usable about itself, so
        //    fall back to the exact host of a redirect it registered. An
        //    informative-but-unknown name ("Codex DCR Probe", "AIApp") blocks
        //    this path entirely.
        guard isUninformative(normalizedName, redirectURIs: redirectURIs) else {
            return .generic
        }
        for host in hosts(of: redirectURIs) {
            if let match = catalog.first(where: { $0.redirectHostEvidence.contains(host) }) {
                return match
            }
        }
        return .generic
    }

    private static func isUninformative(_ normalizedName: String, redirectURIs: [String]) -> Bool {
        if uninformativeNames.contains(normalizedName) {
            return true
        }
        // The server manufactures a display name from the redirect host when a
        // registration omits `client_name`; that echo is not evidence either.
        return hosts(of: redirectURIs).contains { normalize($0) == normalizedName }
    }

    /// Exact lowercased hosts, never suffix-matched: `claude.ai.evil.example`
    /// is its own host and matches nothing.
    private static func hosts(of redirectURIs: [String]) -> [String] {
        redirectURIs.compactMap {
            URLComponents(string: $0)?.host?.lowercased()
        }
    }
}

extension ConnectedAppIdentity {
    /// Bundled artwork lookup. Files are `.copy`-ed as a directory, so
    /// `Image(_:bundle:)` cannot see them — callers load the URL directly.
    static func iconURL(named resource: String) -> URL? {
        Bundle.module.url(
            forResource: resource,
            withExtension: "png",
            subdirectory: "ConnectedAppIcons"
        )
    }

    /// Which bundled resource an appearance prefers, and what it falls back to
    /// when only one variant exists. Lifted out of `ConnectedAppIconView` so the
    /// rule is provable without rendering a view — the view calls this and
    /// decides nothing itself.
    func artworkResource(forDarkAppearance isDarkAppearance: Bool) -> String? {
        isDarkAppearance
            ? darkIconResource ?? lightIconResource
            : lightIconResource ?? darkIconResource
    }

    /// The licensing record shipped next to the artwork.
    static var manifestURL: URL? {
        Bundle.module.url(
            forResource: "MANIFEST",
            withExtension: "json",
            subdirectory: "ConnectedAppIcons"
        )
    }
}
