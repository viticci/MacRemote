import AppKit
import Foundation
import Testing
@testable import MacRemote

/// D46, second half. The catalog picks a picture; these tests police the three
/// places a picture can come from — a curated file, the vendor's own installed
/// app, and whatever the app said about itself — and the rule that none of them
/// may become a permission.
struct ConnectedAppArtworkTests {

    // MARK: - Precedence

    @Test func curatedArtworkOutranksBothOtherTiers() throws {
        let provider = RecordingArtworkProvider(installed: ["com.example.installed": Self.blankImage()])
        let resolver = ConnectedAppArtworkResolver(installedArtwork: provider)
        let identity = Self.fixture(
            light: "t3code",
            dark: "t3code",
            bundleIdentifiers: ["com.example.installed"]
        )

        let resolved = try #require(resolver.artwork(
            for: identity,
            clientSuppliedIcons: Self.suppliedSet(),
            isDarkAppearance: false
        ))
        #expect(resolved.tier == .bundled)
        // The installed-app tier was not even consulted.
        #expect(provider.requests.isEmpty)
    }

    @Test func theInstalledAppOutranksWhatTheAppSentAboutItself() throws {
        let provider = RecordingArtworkProvider(installed: ["com.example.installed": Self.blankImage()])
        let resolver = ConnectedAppArtworkResolver(installedArtwork: provider)
        let identity = Self.fixture(bundleIdentifiers: ["com.example.installed"])

        let resolved = try #require(resolver.artwork(
            for: identity,
            clientSuppliedIcons: Self.suppliedSet(),
            isDarkAppearance: false
        ))
        #expect(resolved.tier == .installedApp)
    }

    @Test func anAppSuppliedIconIsUsedOnlyWhenNothingCuratedExists() throws {
        let resolver = ConnectedAppArtworkResolver(installedArtwork: RecordingArtworkProvider())
        let identity = Self.fixture(bundleIdentifiers: ["com.example.notinstalled"])

        let resolved = try #require(resolver.artwork(
            for: identity,
            clientSuppliedIcons: Self.suppliedSet(),
            isDarkAppearance: false
        ))
        #expect(resolved.tier == .clientSupplied)
    }

    @Test func nothingAnywhereMeansTheSymbolFallback() {
        let resolver = ConnectedAppArtworkResolver(installedArtwork: RecordingArtworkProvider())
        let identity = Self.fixture()

        // nil is the signal for "draw the SF Symbol" — never an error state.
        #expect(resolver.artwork(for: identity, isDarkAppearance: false) == nil)
        #expect(resolver.artwork(for: identity, isDarkAppearance: true) == nil)
        #expect(!identity.fallbackSymbol.isEmpty)
    }

    @Test func theTierOrderIsTheDeclaredPrecedenceOrder() {
        #expect(ConnectedAppArtworkTier.bundled < ConnectedAppArtworkTier.installedApp)
        #expect(ConnectedAppArtworkTier.installedApp < ConnectedAppArtworkTier.clientSupplied)
    }

    // MARK: - Local extraction

    @Test func aMissingAppYieldsNilRatherThanThrowingOrHanging() {
        // The real provider, deliberately: bundle-ID resolution has to be safe
        // for an app that is not installed, and that is not something a fake can
        // prove. Nothing named this can exist.
        let provider = SystemInstalledArtworkProvider()
        #expect(provider.image(
            bundleIdentifier: "com.macremote.tests.absent",
            resource: nil,
            minimumPixelWidth: 56
        ) == nil)
        #expect(provider.image(
            bundleIdentifier: "com.macremote.tests.absent",
            resource: "Icon",
            minimumPixelWidth: 128
        ) == nil)
        #expect(provider.image(bundleIdentifier: "", resource: nil, minimumPixelWidth: 0) == nil)
    }

    @Test func eachRenderSizeAsksForARasterThatWouldActuallyLookSharp() {
        // A vendor's menu-bar asset is right for a 24 pt row and too small for
        // the 64 pt approval ring, so the size travels with the request and the
        // provider is the one that decides whether the named file qualifies.
        #expect(AppIconSize.compact.minimumPixelWidth == 48)
        #expect(AppIconSize.card.minimumPixelWidth == 56)
        #expect(AppIconSize.hero.minimumPixelWidth == 128)

        let provider = RecordingArtworkProvider(installed: ["com.example.installed": Self.blankImage()])
        let resolver = ConnectedAppArtworkResolver(installedArtwork: provider)
        let identity = Self.fixture(bundleIdentifiers: ["com.example.installed"], localLight: "Mark")

        _ = resolver.artwork(for: identity, isDarkAppearance: false, minimumPixelWidth: 128)
        #expect(provider.requests.last?.minimumPixelWidth == 128)

        // A different size is a different lookup, not a cache hit — otherwise a
        // row's answer would decide the ring's.
        _ = resolver.artwork(for: identity, isDarkAppearance: false, minimumPixelWidth: 48)
        #expect(provider.requests.count == 2)
    }

    @Test func everyBundleIdentifierInTheCatalogIsAnExactReverseDNSString() {
        for identity in ConnectedAppIdentity.catalog {
            for bundleIdentifier in identity.bundleIdentifiers {
                #expect(!bundleIdentifier.isEmpty)
                // Exact strings only — the same discipline as the alias table.
                // A wildcard or prefix here would be a new matching strategy.
                #expect(!bundleIdentifier.contains("*"))
                #expect(bundleIdentifier.contains("."))
                #expect(bundleIdentifier == bundleIdentifier.lowercased())
            }
        }
    }

    @Test func eachAppearanceAsksTheInstalledBundleForItsOwnVariant() throws {
        let provider = RecordingArtworkProvider(installed: ["com.openai.codex": Self.blankImage()])
        let resolver = ConnectedAppArtworkResolver(installedArtwork: provider)
        let codex = try #require(ConnectedAppIdentity.catalog.first { $0.id == "codex" })

        _ = resolver.artwork(for: codex, isDarkAppearance: false)
        _ = resolver.artwork(for: codex, isDarkAppearance: true)

        #expect(provider.requests.contains(where: {
            $0.bundleIdentifier == "com.openai.codex" && $0.resource == "icon-codex-light"
        }))
        #expect(provider.requests.contains(where: {
            $0.bundleIdentifier == "com.openai.codex" && $0.resource == "icon-codex-dark-color"
        }))
    }

    @Test func aBrandWithOneNamedVariantUsesItForBothAppearances() throws {
        let chatgpt = try #require(ConnectedAppIdentity.catalog.first { $0.id == "chatgpt" })
        #expect(chatgpt.localResource(forDarkAppearance: false) == "icon-chatgpt")
        #expect(chatgpt.localResource(forDarkAppearance: true) == "icon-chatgpt")

        // Notion ships no variant worth naming, so the tier falls through to the
        // app icon rather than inventing a resource name.
        let notion = try #require(ConnectedAppIdentity.catalog.first { $0.id == "notion" })
        #expect(notion.localResource(forDarkAppearance: false) == nil)
        #expect(notion.localResource(forDarkAppearance: true) == nil)
    }

    @Test func aResolvedLookupIsMemoizedRatherThanRepeated() throws {
        let provider = RecordingArtworkProvider(installed: ["com.example.installed": Self.blankImage()])
        let resolver = ConnectedAppArtworkResolver(installedArtwork: provider)
        let identity = Self.fixture(bundleIdentifiers: ["com.example.installed"])

        for _ in 0..<5 {
            _ = resolver.artwork(for: identity, isDarkAppearance: false)
        }
        #expect(provider.requests.count == 1)
    }

    // MARK: - What the app sent about itself: data: only

    @Test func onlyDataURIsAreAccepted() throws {
        let png = try Self.pngDataURI()
        #expect(throws: Never.self) { try ClientSuppliedIcon.parse(src: png).get() }

        // The no-runtime-fetch rule is the whole point: a remote src would mean
        // MacRemote making a request to a host the app chose.
        for rejected in [
            "https://example.com/logo.png",
            "http://example.com/logo.png",
            "HTTPS://EXAMPLE.COM/logo.png",
            "//example.com/logo.png",
            "file:///Applications/Claude.app/Contents/Resources/TrayIconTemplate.png",
            "javascript:alert(1)",
            "JavaScript:alert(1)",
            "dataxdata:image/png;base64,AAAA"
        ] {
            let result = ClientSuppliedIcon.parse(src: rejected)
            guard case .failure(let reason) = result else {
                Issue.record("\(rejected) was accepted.")
                continue
            }
            guard case .notADataURI = reason else {
                Issue.record("\(rejected) was refused for the wrong reason: \(reason).")
                continue
            }
        }
    }

    @Test func malformedDataURIsAreRefusedRatherThanGuessedAt() {
        for malformed in [
            "data:",
            "data:image/png;base64,",
            "data:image/png,not-base64-at-all",
            "data:image/png;base64,!!!!",
            "data:,"
        ] {
            let result = ClientSuppliedIcon.parse(src: malformed)
            guard case .failure = result else {
                Issue.record("\(malformed) was accepted.")
                continue
            }
        }
    }

    @Test func onlyRasterBytesAreAcceptedAndTheLabelIsNotTrusted() throws {
        // SVG is scriptable, so it is refused even when it is honestly labelled.
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)
        let svgURI = "data:image/svg+xml;base64,\(svg.base64EncodedString())"
        #expect(ClientSuppliedIcon.parse(src: svgURI) == .failure(.unsupportedImageFormat("image/svg+xml")))

        // And the declared MIME type is self-reported too: bytes decide.
        let liar = "data:image/png;base64,\(svg.base64EncodedString())"
        #expect(ClientSuppliedIcon.parse(src: liar) == .failure(.unsupportedImageFormat("image/png")))

        // A real PNG is accepted, and reports the type its bytes prove.
        let accepted = try ClientSuppliedIcon.parse(src: try Self.pngDataURI()).get()
        #expect(accepted.mimeType == "image/png")
    }

    @Test func anOversizedIconIsRefusedBeforeItIsEverDecoded() {
        let oversized = Data(count: ClientSuppliedIcon.maximumImageByteCount + 1)
        let uri = "data:image/png;base64,\(oversized.base64EncodedString())"

        #expect(
            ClientSuppliedIcon.parse(src: uri)
                == .failure(.tooLarge(bytes: ClientSuppliedIcon.maximumImageByteCount + 1))
        )

        // Right at the cap is fine as far as the cap is concerned; it then fails
        // the format check, which proves the cap ran first on the oversized one.
        let atCap = Data(count: ClientSuppliedIcon.maximumImageByteCount)
        let atCapURI = "data:image/png;base64,\(atCap.base64EncodedString())"
        guard case .failure(let reason) = ClientSuppliedIcon.parse(src: atCapURI) else {
            Issue.record("All-zero bytes decoded as an image.")
            return
        }
        #expect(reason == .unsupportedImageFormat("image/png"))
    }

    @Test func aClientCannotParkUnlimitedIconsInTheProcess() throws {
        let entries = try (0..<12).map { _ in ["src": try Self.pngDataURI()] as [String: Any] }
        var rejections: [ClientSuppliedIcon.RejectionReason] = []
        let set = try #require(
            ClientSuppliedIconSet.parse(clientInfoIcons: entries, rejections: &rejections)
        )
        #expect(set.icons.count == ClientSuppliedIcon.maximumIconsPerClient)
    }

    @Test func parsingReportsNothingSuppliedApartFromNothingUsable() throws {
        var rejections: [ClientSuppliedIcon.RejectionReason] = []
        #expect(ClientSuppliedIconSet.parse(clientInfoIcons: nil, rejections: &rejections) == nil)
        #expect(ClientSuppliedIconSet.parse(clientInfoIcons: [], rejections: &rejections) == nil)
        #expect(rejections.isEmpty)

        // Everything refused is also "nothing supplied", with the reasons out.
        let remote: [[String: Any]] = [["src": "https://example.com/a.png"]]
        #expect(ClientSuppliedIconSet.parse(clientInfoIcons: remote, rejections: &rejections) == nil)
        #expect(rejections.count == 1)

        // A mixed batch keeps the good one and reports the bad one.
        rejections = []
        let mixed: [[String: Any]] = [
            ["src": "https://example.com/a.png"],
            ["src": try Self.pngDataURI(), "theme": "dark"]
        ]
        let set = try #require(
            ClientSuppliedIconSet.parse(clientInfoIcons: mixed, rejections: &rejections)
        )
        #expect(set.icons.count == 1)
        #expect(set.icons.first?.theme == .dark)
        #expect(rejections.count == 1)
    }

    @Test func theSuppliedThemeSelectsTheVariantAndDegradesGracefully() throws {
        let light = try ClientSuppliedIcon.parse(src: try Self.pngDataURI(), theme: .light).get()
        let dark = try ClientSuppliedIcon.parse(src: try Self.pngDataURI(width: 6), theme: .dark).get()
        let untagged = try ClientSuppliedIcon.parse(src: try Self.pngDataURI(width: 7)).get()

        let pair = ClientSuppliedIconSet(icons: [light, dark])
        #expect(pair.icon(forDarkAppearance: false) == light)
        #expect(pair.icon(forDarkAppearance: true) == dark)

        // Only an untagged icon: usable on either appearance.
        let neutral = ClientSuppliedIconSet(icons: [untagged])
        #expect(neutral.icon(forDarkAppearance: false) == untagged)
        #expect(neutral.icon(forDarkAppearance: true) == untagged)

        // Only the wrong-appearance variant: recognition beats appearance, same
        // rule the bundled tier follows.
        let lightOnly = ClientSuppliedIconSet(icons: [light])
        #expect(lightOnly.icon(forDarkAppearance: true) == light)

        // An untagged icon is preferred over a mismatched tagged one.
        let mixed = ClientSuppliedIconSet(icons: [light, untagged])
        #expect(mixed.icon(forDarkAppearance: true) == untagged)
    }

    @Test func theMCPThemeSpellingIsTheOneTheSpecificationUses() throws {
        // "light" means designed for a light background (MCP 2026-07-28 Icon).
        let uri = try Self.pngDataURI()
        let light = try ClientSuppliedIcon.parse(["src": uri, "theme": "light"]).get()
        let dark = try ClientSuppliedIcon.parse(["src": uri, "theme": "dark"]).get()
        let absent = try ClientSuppliedIcon.parse(["src": uri]).get()
        let nonsense = try ClientSuppliedIcon.parse(["src": uri, "theme": "chartreuse"]).get()

        #expect(light.theme == .light)
        #expect(dark.theme == .dark)
        #expect(absent.theme == .any)
        // An unknown theme is not a rejection; it just carries no preference.
        #expect(nonsense.theme == .any)

        // A missing src is not an icon.
        #expect(ClientSuppliedIcon.parse(["theme": "dark"]) == .failure(.malformedDataURI))
    }

    // MARK: - The invariant: a picture is never a permission

    @Test func noDecisionMakingSourceFileCanSeeAnArtworkTier() throws {
        // The catalog invariant in AGENTS.md is `grep -rn 'ConnectedAppIdentity'
        // Services Stores` staying empty. The two new types cannot be held to
        // exactly that — the MCP server is where an app's icons arrive, and
        // AppModel is where they are kept — so the rule is applied where it
        // actually matters: the files that decide authentication, authorization,
        // approval, and tool access must not mention them at all.
        let deciders = [
            "Services/OAuthCoordinator.swift",
            "Services/OAuthGrantStore.swift",
            "Services/OAuthClientCredentialStore.swift",
            "Services/ToolCallApprovalCoordinator.swift",
            "Services/ToolExecutionService.swift",
            "Services/ToolExecutionLimiter.swift",
            "Stores/ClientToolPermissionStore.swift"
        ]
        let forbidden = ["ClientSuppliedIcon", "ConnectedAppArtwork", "ConnectedAppIdentity"]

        var offenders: [String] = []
        for path in deciders {
            let url = Self.repositoryRoot.appending(path: path)
            let source = try String(contentsOf: url, encoding: .utf8)
            for symbol in forbidden where source.contains(symbol) {
                // The OAuth coordinator names `ClientSuppliedIcon` in one prose
                // comment explaining why logo_uri is dropped. A comment is not a
                // read, so only code references count.
                let referencesInCode = source
                    .split(separator: "\n")
                    .filter { $0.contains(symbol) }
                    .contains { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                if referencesInCode {
                    offenders.append("\(path): \(symbol)")
                }
            }
        }
        #expect(offenders.isEmpty, "An artwork type reached a decision: \(offenders.joined(separator: ", "))")
    }

    @Test func anAppSuppliedIconCannotOverrideACuratedMarkOrEarnAnything() throws {
        let resolver = ConnectedAppArtworkResolver(installedArtwork: RecordingArtworkProvider())
        let grok = try #require(ConnectedAppIdentity.catalog.first { $0.id == "grok" })

        // Whatever the app sends, a brand with a curated mark keeps its mark.
        let withoutIcons = try #require(resolver.artwork(for: grok, isDarkAppearance: false))
        let withIcons = try #require(resolver.artwork(
            for: grok,
            clientSuppliedIcons: Self.suppliedSet(),
            isDarkAppearance: false
        ))
        #expect(withoutIcons.tier == .bundled)
        #expect(withIcons.tier == .bundled)

        // And the identity itself has no icon input at all: sending art cannot
        // move an app from generic into a brand.
        #expect(ConnectedAppIdentity.resolve(name: "Definitely Claude") == .generic)
    }

    @Test func theRegistrationTimeLogoURICannotBecomeAnIcon() throws {
        // OAuth DCR happens before any approval, so `logo_uri` stays dropped.
        // The mechanism is the data:-only rule: every form a logo_uri can take
        // is refused by the same parser that accepts handshake icons.
        let coordinator = OAuthCoordinator()
        let response = try coordinator.registerClient(from: [
            "client_name": "Claude",
            "logo_uri": "https://attacker.example/claude.png",
            "redirect_uris": ["https://claude.ai/api/mcp/auth_callback"],
            "scope": "mcp:tools"
        ])
        // RFC 7591 says echo it back; nothing says draw it.
        let echoed = try #require(response["logo_uri"] as? String)
        guard case .failure(.notADataURI(let scheme)) = ClientSuppliedIcon.parse(src: echoed) else {
            Issue.record("A registration-time logo_uri was accepted as an icon.")
            return
        }
        #expect(scheme == "https")
    }

    @MainActor
    @Test func signingAppsOutTakesTheirPicturesWithThem() throws {
        let model = try Self.isolatedAppModel()
        let icons = try #require(Self.suppliedSet())
        model.clientSuppliedIcons = ["mcp-client-aaa": icons, "mcp-client-bbb": icons]
        #expect(model.clientSuppliedIcons(forClientID: "mcp-client-aaa") == icons)
        #expect(model.clientSuppliedIcons(forClientID: nil) == nil)
        #expect(model.clientSuppliedIcons(forClientID: "mcp-client-unknown") == nil)

        // Sign-out empties the app list, and pruning is keyed off that list, so
        // no picture outlives the app it belonged to.
        model.signOutAllApps()
        #expect(model.clientSuppliedIcons.isEmpty)
    }

    // MARK: - Fixtures

    private static var repositoryRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // MacRemoteTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
    }

    @MainActor
    private static func isolatedAppModel() throws -> AppModel {
        let suiteName = "MacRemoteTests.artwork.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ToolRegistryStore(fileURL: directory.appendingPathComponent("tools.json"))
        return makeTestAppModel(userDefaults: defaults, toolStore: store)
    }

    private static func fixture(
        light: String? = nil,
        dark: String? = nil,
        bundleIdentifiers: Set<String> = [],
        localLight: String? = nil,
        localDark: String? = nil
    ) -> ConnectedAppIdentity {
        ConnectedAppIdentity(
            id: "fixture",
            displayName: "Fixture",
            exactAliases: [],
            redirectHostEvidence: [],
            lightIconResource: light,
            darkIconResource: dark,
            bundleIdentifiers: bundleIdentifiers,
            localLightResource: localLight,
            localDarkResource: localDark,
            fallbackSymbol: "network"
        )
    }

    /// A 4x4 opaque bitmap encoded as a real PNG, built without a graphics
    /// context so it works in a headless test process.
    private static func pngData(width: Int = 4) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private static func pngDataURI(width: Int = 4) throws -> String {
        "data:image/png;base64,\(try pngData(width: width).base64EncodedString())"
    }

    private static func suppliedSet() -> ClientSuppliedIconSet? {
        guard let data = try? pngData(),
              case .success(let icon) = ClientSuppliedIcon.parse(
                  src: "data:image/png;base64,\(data.base64EncodedString())"
              ) else {
            return nil
        }
        return ClientSuppliedIconSet(icons: [icon])
    }

    private static func blankImage() -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16))
    }
}

/// Records what the installed-app tier was asked for, so precedence and
/// appearance can be asserted without depending on which apps this machine has.
private final class RecordingArtworkProvider: ConnectedAppInstalledArtworkProviding, @unchecked Sendable {
    struct Request: Equatable {
        let bundleIdentifier: String
        let resource: String?
        let minimumPixelWidth: Int
    }

    private(set) var requests: [Request] = []
    private let installed: [String: NSImage]
    private let lock = NSLock()

    init(installed: [String: NSImage] = [:]) {
        self.installed = installed
    }

    func image(bundleIdentifier: String, resource: String?, minimumPixelWidth: Int) -> NSImage? {
        lock.withLock {
            requests.append(Request(
                bundleIdentifier: bundleIdentifier,
                resource: resource,
                minimumPixelWidth: minimumPixelWidth
            ))
            return installed[bundleIdentifier]
        }
    }
}
