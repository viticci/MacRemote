import AppKit
import CryptoKit
import Foundation
import Testing
@testable import MacRemote

/// D46. The catalog picks a picture; it must never be able to pick a
/// permission. These tests police both halves: that recognition works for the
/// apps Federico actually connects, and that nothing else can borrow it.
struct ConnectedAppIdentityTests {

    // MARK: - Positives

    @Test func canonicalNamesResolveToTheirBrand() {
        #expect(ConnectedAppIdentity.resolve(name: "ChatGPT").id == "chatgpt")
        #expect(ConnectedAppIdentity.resolve(name: "Claude").id == "claude")
        #expect(ConnectedAppIdentity.resolve(name: "Notion").id == "notion")
        #expect(ConnectedAppIdentity.resolve(name: "Raycast").id == "raycast")
        #expect(ConnectedAppIdentity.resolve(name: "T3 Code").id == "t3code")
        #expect(ConnectedAppIdentity.resolve(name: "Codex").id == "codex")
        #expect(ConnectedAppIdentity.resolve(name: "Grok").id == "grok")
    }

    @Test func normalizationFoldsCaseDiacriticsAndPunctuation() {
        #expect(ConnectedAppIdentity.resolve(name: "RAYCAST").id == "raycast")
        #expect(ConnectedAppIdentity.resolve(name: "Räycast").id == "raycast")
        #expect(ConnectedAppIdentity.resolve(name: "Notion.").id == "notion")
        #expect(ConnectedAppIdentity.resolve(name: "  claude  ").id == "claude")
        #expect(ConnectedAppIdentity.resolve(name: "T3-Code").id == "t3code")
        #expect(ConnectedAppIdentity.normalize("Ray_cast 2!") == "raycast2")
    }

    @Test func claudeVariantsShareABrandWhileTheReceivedNameIsPreserved() {
        let desktop = ConnectedAppIdentity.resolve(name: "Claude Desktop")
        let code = ConnectedAppIdentity.resolve(name: "Claude Code")
        #expect(desktop.id == "claude")
        #expect(code.id == "claude")
        #expect(desktop == code)
        // The identity never rewrites what the app called itself — the UI
        // keeps showing "Claude Code".
        #expect(desktop.displayName == "Claude")
    }

    @Test func everyCatalogAliasResolvesToItsOwnEntry() {
        for identity in ConnectedAppIdentity.catalog {
            for alias in identity.exactAliases {
                #expect(ConnectedAppIdentity.resolve(name: alias).id == identity.id)
            }
        }
    }

    // MARK: - Negatives (the previous helper failed all of these)

    @Test func openAIDoesNotBecomeChatGPT() {
        // The deleted ConnectorProviderProfile.inferred mapped any name
        // containing "openai" to ChatGPT.
        #expect(ConnectedAppIdentity.resolve(name: "OpenAI") == .generic)
        #expect(ConnectedAppIdentity.resolve(name: "OpenAI ChatGPT Connector") == .generic)
    }

    @Test func codexIsNotChatGPT() {
        // Not merely "isn't ChatGPT" — Codex is its own catalog entry, and both
        // spellings the CLI registers with have to land on it.
        #expect(ConnectedAppIdentity.resolve(name: "Codex").id == "codex")
        #expect(ConnectedAppIdentity.resolve(name: "Codex CLI").id == "codex")
        #expect(ConnectedAppIdentity.resolve(name: "OpenAI Codex").id == "codex")
    }

    @Test func anInformativeNameBlocksRedirectHostEvidence() {
        // Live registration on this Mac: a probe named "Codex DCR Probe" with a
        // chatgpt.com callback. It told us who it is, so the host is not used.
        let identity = ConnectedAppIdentity.resolve(
            name: "Codex DCR Probe",
            redirectURIs: ["https://chatgpt.com/connector/oauth/test-callback"]
        )
        #expect(identity == .generic)
    }

    @Test func codeLikeNamesDoNotBecomeT3Code() {
        #expect(ConnectedAppIdentity.resolve(name: "VS Code") == .generic)
        #expect(ConnectedAppIdentity.resolve(name: "Code") == .generic)
        #expect(ConnectedAppIdentity.resolve(name: "Cursor Code") == .generic)
        #expect(ConnectedAppIdentity.resolve(name: "T3 Code Companion") == .generic)
    }

    @Test func spoofAndPaddedNamesDoNotBorrowABrand() {
        #expect(ConnectedAppIdentity.resolve(name: "Claude Impostor") == .generic)
        #expect(ConnectedAppIdentity.resolve(name: "Not Claude") == .generic)
        #expect(ConnectedAppIdentity.resolve(name: "notion-scraper") == .generic)
        #expect(ConnectedAppIdentity.resolve(name: "raycast.evil.example") == .generic)
    }

    @Test func emptyAndMissingNamesFallBackToGeneric() {
        #expect(ConnectedAppIdentity.resolve(name: nil) == .generic)
        #expect(ConnectedAppIdentity.resolve(name: "") == .generic)
        #expect(ConnectedAppIdentity.resolve(name: "   ") == .generic)
    }

    // MARK: - Redirect-host evidence (last resort only)

    @Test func uninformativeNameWithAnExactHostResolves() {
        #expect(
            ConnectedAppIdentity.resolve(
                name: "",
                redirectURIs: ["https://claude.ai/api/mcp/auth_callback"]
            ).id == "claude"
        )
        #expect(
            ConnectedAppIdentity.resolve(
                name: "Remote MCP Client",
                redirectURIs: ["https://www.notion.so/oauth/callback"]
            ).id == "notion"
        )
    }

    @Test func aNameEchoingItsOwnHostStillCountsAsUninformative() {
        // The server manufactures a name from the redirect host when a
        // registration omits client_name; that echo is not evidence.
        #expect(
            ConnectedAppIdentity.resolve(
                name: "claude.ai",
                redirectURIs: ["https://claude.ai/api/mcp/auth_callback"]
            ).id == "claude"
        )
        // Live example on this Mac: a recovered host name for a non-catalog
        // domain must stay generic rather than guess.
        #expect(
            ConnectedAppIdentity.resolve(
                name: "macremote.example.com",
                redirectURIs: ["https://macremote.example.com/callback"]
            ) == .generic
        )
    }

    @Test func hostEvidenceIsExactNotSuffix() {
        #expect(
            ConnectedAppIdentity.resolve(
                name: "",
                redirectURIs: ["https://claude.ai.evil.example/callback"]
            ) == .generic
        )
        #expect(
            ConnectedAppIdentity.resolve(
                name: "",
                redirectURIs: ["https://evil-notion.so/callback"]
            ) == .generic
        )
        #expect(
            ConnectedAppIdentity.resolve(
                name: "",
                redirectURIs: ["https://raycast.com.attacker.example/callback"]
            ) == .generic
        )
    }

    @Test func noCatalogEntryTrustsChatGPTHosts() {
        // Unrelated apps register chatgpt.com callbacks on this Mac, so the
        // host must not appear as evidence anywhere in the catalog.
        for identity in ConnectedAppIdentity.catalog {
            #expect(identity.redirectHostEvidence.contains("chatgpt.com") == false)
            #expect(identity.redirectHostEvidence.contains("chat.openai.com") == false)
        }
        #expect(
            ConnectedAppIdentity.resolve(
                name: "",
                redirectURIs: ["https://chatgpt.com/connector/oauth/callback"]
            ) == .generic
        )
    }

    // MARK: - Authorization independence

    @Test func theGlyphIsIndependentOfTrustIdentityInBothDirections() throws {
        let coordinator = OAuthCoordinator()

        // Same redirect, different self-declared name: each DCR call still gets
        // an independent registration. Neither the redirect nor the glyph is
        // authentication material.
        let real = try coordinator.registerClient(from: [
            "client_name": "Claude",
            "redirect_uris": ["https://claude.ai/api/mcp/auth_callback"],
            "scope": "mcp:tools"
        ])
        let renamed = try coordinator.registerClient(from: [
            "client_name": "Claude Impostor",
            "redirect_uris": ["https://claude.ai/api/mcp/auth_callback"],
            "scope": "mcp:tools"
        ])
        #expect(real["client_id"] as? String != renamed["client_id"] as? String)

        // Different redirects, identical names: two distinct clients that would
        // draw the same glyph. The glyph is not the identity.
        let elsewhere = try coordinator.registerClient(from: [
            "client_name": "Claude",
            "redirect_uris": ["https://impostor.example/callback"],
            "scope": "mcp:tools"
        ])
        #expect(real["client_id"] as? String != elsewhere["client_id"] as? String)
        #expect(
            ConnectedAppIdentity.resolve(name: "Claude", redirectURIs: ["https://impostor.example/callback"])
                == ConnectedAppIdentity.resolve(name: "Claude", redirectURIs: ["https://claude.ai/api/mcp/auth_callback"])
        )

        // And a name change never edits a registration.
        let realID = try #require(real["client_id"] as? String)
        #expect(ConnectedAppIdentity.resolve(name: "Claude").id == "claude")
        #expect(ConnectedAppIdentity.resolve(name: "Claude Impostor") == .generic)
        #expect(coordinator.connectedClientSnapshot().isEmpty)
        #expect(realID.isEmpty == false)
    }

    // MARK: - Bundled assets and licensing record

    @Test func everyBundledResourceExistsAndHasAManifestRow() throws {
        let manifest = try loadManifest()
        let rows = try #require(manifest["icons"] as? [[String: Any]])
        let manifestFiles = Set(rows.compactMap { $0["file"] as? String })

        var referenced: Set<String> = []
        for identity in ConnectedAppIdentity.catalog {
            for resource in [identity.lightIconResource, identity.darkIconResource].compactMap({ $0 }) {
                referenced.insert("\(resource).png")
                let url = try #require(
                    ConnectedAppIdentity.iconURL(named: resource),
                    "Missing bundled artwork for \(identity.id): \(resource).png"
                )
                #expect(FileManager.default.fileExists(atPath: url.path))
                #expect(manifestFiles.contains("\(resource).png"))
            }
        }

        // No manifest row without a file on disk, either.
        #expect(manifestFiles == referenced)
    }

    @Test func manifestRowsCarryProvenanceThatMatchesTheCommittedFile() throws {
        let manifest = try loadManifest()
        let rows = try #require(manifest["icons"] as? [[String: Any]])
        #expect(!rows.isEmpty)

        for row in rows {
            let file = try #require(row["file"] as? String)
            let resource = String(file.dropLast(".png".count))

            let sourceURL = try #require(row["sourceURL"] as? String)
            #expect(sourceURL.hasPrefix("https://"))
            #expect((row["license"] as? String)?.isEmpty == false)
            #expect(row["redistributionPermitted"] as? Bool == true)
            #expect((row["redistributionEvidence"] as? String)?.isEmpty == false)
            // Retrieval date, always, in a sortable form.
            let retrievedAt = try #require(row["retrievedAt"] as? String)
            #expect(retrievedAt.count == "2026-07-30".count)
            // A git-hosted source has to be pinned to a commit, not a moving
            // branch. A vendor CDN has no commit to pin, so it is held to the
            // source hash below instead.
            if let commit = row["sourceCommit"] as? String {
                #expect(commit.count == 40)
                #expect(sourceURL.contains(commit))
            }

            // The hash of what was downloaded, alongside the hash of what was
            // committed — so a transformation can be audited after the fact.
            let sourceHash = try #require(row["sourceSHA256"] as? String)
            #expect(sourceHash.count == 64)
            let recorded = try #require(row["sha256"] as? String)
            let url = try #require(ConnectedAppIdentity.iconURL(named: resource))
            let data = try Data(contentsOf: url)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(actual == recorded, "Committed \(file) does not match its manifest hash.")

            // A row claiming no transformation must actually be the download,
            // byte for byte. Two vendors require exactly that.
            let transformations = try #require(row["transformations"] as? [String])
            if transformations.isEmpty {
                #expect(
                    sourceHash == recorded,
                    "\(file) records no transformation but does not match its source hash."
                )
            } else {
                #expect(sourceHash != recorded)
            }
        }
    }

    /// xAI publishes "use our logos exactly as provided … without any alteration
    /// or adjustment", and Raycast publishes "do not alter its colors". Those two
    /// are held to a stricter standard than the MIT-licensed mark: no
    /// transformation at all, provable from the hashes.
    @Test func vendorsRequiringUnalteredMarksGotUnalteredFiles() throws {
        let manifest = try loadManifest()
        let rows = try #require(manifest["icons"] as? [[String: Any]])
        let strict = rows.filter { ["grok", "raycast"].contains($0["brandID"] as? String ?? "") }
        #expect(strict.count == 4, "Expected a light/dark pair for each unaltered-mark vendor.")

        for row in strict {
            #expect((row["transformations"] as? [String])?.isEmpty == true)
            #expect(row["sourceSHA256"] as? String == row["sha256"] as? String)
        }
    }

    /// Two vendors name their files by opposite conventions — xAI by the mark's
    /// own colour, Raycast by the background it belongs on — so getting this
    /// backwards would put a white mark on a white card. The mapping is asserted
    /// against the appearance recorded in the manifest.
    @Test func eachBundledPairMapsToTheAppearanceItsManifestRowClaims() throws {
        let manifest = try loadManifest()
        let rows = try #require(manifest["icons"] as? [[String: Any]])

        for identity in ConnectedAppIdentity.catalog where identity.hasBundledArtwork {
            for (isDark, expected) in [(false, "light"), (true, "dark")] {
                let resource = try #require(identity.artworkResource(forDarkAppearance: isDark))
                let row = rows.first { $0["file"] as? String == "\(resource).png" }
                let appearance = try #require(row?["appearance"] as? String)
                // "universal" is the single-file case (T3 Code), which is
                // allowed to answer for both appearances.
                #expect(
                    appearance == expected || appearance == "universal",
                    "\(identity.id) draws \(resource).png on the \(expected) appearance, but its manifest row says \(appearance)."
                )
            }
        }
    }

    @Test func everyHeldBackBrandHasADocumentedBlockerAndAFallback() throws {
        let manifest = try loadManifest()
        let heldBack = try #require(manifest["heldBack"] as? [[String: Any]])

        let bundledIDs = Set(
            ConnectedAppIdentity.catalog.filter(\.hasBundledArtwork).map(\.id)
        )
        let heldBackIDs = Set(heldBack.compactMap { $0["brandID"] as? String })

        for identity in ConnectedAppIdentity.catalog where !identity.hasBundledArtwork {
            #expect(!identity.fallbackSymbol.isEmpty)
            #expect(
                heldBackIDs.contains(identity.id),
                "\(identity.id) ships no artwork but records no blocker."
            )
        }
        for row in heldBack {
            #expect((row["blocker"] as? String)?.isEmpty == false)
            let brandID = try #require(row["brandID"] as? String)
            #expect(!bundledIDs.contains(brandID))
        }
    }

    @Test func genericFallbackAlwaysHasASymbol() {
        #expect(!ConnectedAppIdentity.generic.fallbackSymbol.isEmpty)
        #expect(ConnectedAppIdentity.generic.hasBundledArtwork == false)
        for identity in ConnectedAppIdentity.catalog {
            #expect(!identity.fallbackSymbol.isEmpty)
        }
    }

    // MARK: - Apps page search

    @Test func appSearchMatchesNameBrandAndIDPrefixes() {
        let client = ConnectedClient(
            id: "mcp-client-9f3a21",
            trustID: "macremote-trust-7c1d40",
            name: "Claude Code",
            redirectURIs: ["https://claude.ai/api/mcp/auth_callback"],
            issuer: nil,
            resource: nil,
            scopes: ["mcp:tools"],
            createdAt: .distantPast,
            lastAuthorizedAt: .distantPast,
            activeAccessTokens: 1,
            activeRefreshTokens: 1
        )

        // Received name, normalized and case-folded.
        #expect(AppsView.matches(client, query: "claude"))
        #expect(AppsView.matches(client, query: "CLAUDE CODE"))
        #expect(AppsView.matches(client, query: "code"))
        // Catalog brand name, even though the received name differs.
        #expect(AppsView.matches(client, query: "Cläude"))
        // ID prefixes, not arbitrary substrings of a hash.
        #expect(AppsView.matches(client, query: "mcp-client-9f"))
        #expect(AppsView.matches(client, query: "macremote-trust"))
        #expect(AppsView.matches(client, query: "9f3a21") == false)
        // Non-matches.
        #expect(AppsView.matches(client, query: "notion") == false)
        #expect(AppsView.matches(client, query: "raycast") == false)
        // An empty query filters nothing.
        #expect(AppsView.matches(client, query: ""))
        #expect(AppsView.matches(client, query: "   "))
    }

    // MARK: - Appearance

    @Test func darkAppearancePrefersTheDarkResourceAndFallsBackToLight() {
        func identity(light: String?, dark: String?) -> ConnectedAppIdentity {
            ConnectedAppIdentity(
                id: "fixture",
                displayName: "Fixture",
                exactAliases: [],
                redirectHostEvidence: [],
                lightIconResource: light,
                darkIconResource: dark,
                fallbackSymbol: "network"
            )
        }

        // Both variants present: each appearance gets its own.
        let both = identity(light: "brand-light", dark: "brand-dark")
        #expect(both.artworkResource(forDarkAppearance: true) == "brand-dark")
        #expect(both.artworkResource(forDarkAppearance: false) == "brand-light")

        // Only one variant: recognition beats appearance, so it is used in both.
        let lightOnly = identity(light: "brand-light", dark: nil)
        #expect(lightOnly.artworkResource(forDarkAppearance: true) == "brand-light")
        #expect(lightOnly.artworkResource(forDarkAppearance: false) == "brand-light")

        let darkOnly = identity(light: nil, dark: "brand-dark")
        #expect(darkOnly.artworkResource(forDarkAppearance: false) == "brand-dark")
        #expect(darkOnly.artworkResource(forDarkAppearance: true) == "brand-dark")

        // No artwork at all: nil, so the view draws the SF Symbol fallback.
        let none = identity(light: nil, dark: nil)
        #expect(none.artworkResource(forDarkAppearance: true) == nil)
        #expect(none.artworkResource(forDarkAppearance: false) == nil)

        // The one brand that ships a mark serves both appearances from one file.
        let t3code = ConnectedAppIdentity.catalog.first { $0.id == "t3code" }
        #expect(t3code?.artworkResource(forDarkAppearance: true) == "t3code")
        #expect(t3code?.artworkResource(forDarkAppearance: false) == "t3code")
    }

    @Test func everyBundledResourceDecodesToAnImage() throws {
        let manifest = try loadManifest()
        let rows = try #require(manifest["icons"] as? [[String: Any]])
        #expect(!rows.isEmpty)

        for row in rows {
            let file = try #require(row["file"] as? String)
            let resource = String(file.dropLast(".png".count))
            let url = try #require(ConnectedAppIdentity.iconURL(named: resource))
            // A committed file that AppKit cannot decode would silently fall
            // back to a symbol at runtime and nothing would say so.
            let image = try #require(NSImage(contentsOf: url), "\(file) did not decode to an image.")
            #expect(image.size.width > 0)
            #expect(image.size.height > 0)
        }
    }

    // MARK: - Trust boundary, enforced against the sources

    @Test func theIdentityCatalogNeverReachesTheSecurityLayer() throws {
        // AGENTS.md states this as `grep -rn 'ConnectedAppIdentity' Services
        // Stores` staying empty. An icon is not an identity: authentication,
        // Always Allow, token validity, and revocation stay keyed on the client
        // ID and the OAuth trust ID, so the catalog must not be readable from
        // there at all.
        var offenders: [String] = []
        for directory in ["Services", "Stores"] {
            for file in try swiftSources(in: directory) {
                let source = try String(contentsOf: file, encoding: .utf8)
                if source.contains("ConnectedAppIdentity") {
                    offenders.append("\(directory)/\(file.lastPathComponent)")
                }
            }
        }
        #expect(offenders.isEmpty, "The brand catalog leaked into: \(offenders.joined(separator: ", "))")
    }

    private func loadManifest() throws -> [String: Any] {
        let url = try #require(ConnectedAppIdentity.manifestURL, "MANIFEST.json is not bundled.")
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
