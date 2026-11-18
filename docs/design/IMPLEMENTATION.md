# MacRemote — Implementation Map (as built)

> Companion to `DESIGN-SPEC.md` (what each screen does) and `DESIGN-GUIDELINES.md`
> (tokens, components, glass, copy). This file is the **as-built architecture**:
> where things live and how the pieces connect, so an agent can navigate the code
> without re-deriving it. Produced alongside the 2026-07-01 redesign
> implementation. When code and this file disagree, fix whichever is wrong in the
> same change.

## Build & run

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift test   # Swift Testing
script/build_and_run.sh              # builds (auto-pins SDK), signs, installs in /Applications, relaunches
script/build_and_run.sh --build-only # build without killing a running instance / its tunnel
```

See `AGENTS.md` for why the SDK pin is mandatory (Command Line Tools: broken 27
SDK `@State` macro + no XCTest). `Package.swift` targets `.macOS(.v26)` and
carries path-guarded CLT test-linking workarounds.

**Bundled resources.** `Resources/` is no longer excluded wholesale. The app's
own icon/favicon art (`AppIcon.icon`, `Assets.car`, `AppIcon.icns`,
`Favicon.{ico,png}`, `MacRemoteConnectorIcon{,128,64}.png`) is excluded file by file — it is copied
into the `.app` by `script/build_and_run.sh` and served from disk through
`LocalMCPServer.staticResourceData`, not from `Bundle.module`. What *is* declared
as a resource: `Shaders/default.metallib`, `Widget/MacRemoteWidget.html`, and
`.copy("Resources/ConnectedAppIcons")`. The connected-app icons are copied as a
**directory** so the artwork, `MANIFEST.json`, and `THIRD-PARTY-NOTICES.md` stay
together and the manifest's hashes stay checkable from tests. A `.copy`
subdirectory is invisible to `Image(_:bundle:)`, so callers resolve
`Bundle.module.url(forResource:withExtension:subdirectory:)` and load the file
themselves. Adding a file under `Resources/` that must **not** reach
`Bundle.module` means adding it to the `exclude` list.

## Scenes (`App/MacRemoteApp.swift`)

Window IDs are centralized in `MacRemoteWindowID` (`Models/NavigationSection.swift`).

| Scene | ID | Notes |
|---|---|---|
| Main window | `MacRemoteWindowID.main` | `NavigationSplitView`; system glass sidebar + detail. Min 1040×680. Installs `AppSkeletonInstaller` (wires `appModel.windowOpener`, the AppDelegate quit bridge, and first-run Welcome). |
| Approval window | `MacRemoteWindowID.approval` | Floating, `.windowLevel(.floating)`, hidden title bar, `.contentSize`. **Non-activating** — presented via `AppModel.presentApprovalWindow()` (decision D4). `ApprovalWindowConfigurator` (NSViewRepresentable) adds all-Spaces + full-screen-auxiliary collection behavior and `hidesOnDeactivate = false`. |
| Welcome window | `MacRemoteWindowID.welcome` | Fixed 760×560, first run only (gated on `hasCompletedWelcome`), reopenable from Help. |
| Settings | `Settings` scene (⌘,) | The **only** settings surface (no sidebar Settings section). Toolbar-tab `TabView`: General / Notifications / Security. Notifications holds only the macOS notifications status (D65). Security also hosts the File Transfer Folders list (D67) and the D24 token-lifetime pickers (access / refresh). |
| MenuBarExtra | — | `.menuBarExtraStyle(.menu)`, toggled by `appModel.isMenuBarExtraEnabled`. Status line + Copy URL + server verbs + "N requests waiting…" (opens the Approval window, never resolves inline — D3). Glyph rendered by `MenuBarIconRenderer` as a template `NSImage` so the badge dot survives menu-bar tinting. |

Menu commands live in `MacRemoteCommands` (same file): Server
(⌘R/⌘./⇧⌘R/⇧⌘./⇧⌘C), File (⌘N/⇧⌘N/⇧⌘L), Edit ▸ Find (⌘F), View ▸ sections
(⌘1–⌘5) + Inspector (⌥⌘I), Requests (⌘⏎/⌥⌘⏎/⌘⌫ acting only on the request the Approval
window is showing, D70), Help (Welcome).

## Navigation (`Models/NavigationSection.swift`, `Views/ContentView.swift`, `Views/SidebarView.swift`)

Five sections, single-line sidebar labels, two scoped numeric badges plus one
failure dot. Requests counts pending approvals; Tools counts unimported MCP
candidates marked **New**. Only Requests escalates to the Dock, menu bar,
notifications, and Approval window (D54).

| Section | Symbol | ⌘ | Detail view | Badge |
|---|---|---|---|---|
| Connection | `dot.radiowaves.left.and.right` | ⌘1 | `ConnectionView` | failure dot |
| Tools | `wrench.and.screwdriver` | ⌘2 | `ToolsView` | unimported New candidates |
| Apps | `app.badge.checkmark` | ⌘3 | `AppsView` | — |
| Requests | `hand.raised` | ⌘4 | `RequestsView` | pending approvals |
| Activity | `waveform.path.ecg` | ⌘5 | `ActivityView` | — |

`ContentView` switches on `appModel.selection`. Selection is set programmatically
in a few places (menu commands, Setup-checklist jumps, privacy-failure reveal),
so it stays app-assignable — but **approvals never navigate** (D4).

## View files (`Views/`)

| File | Surface | Spec |
|---|---|---|
| `ContentView.swift` | Split-view shell + FDA sheet host | §2 |
| `SidebarView.swift` | Sidebar (badge/failure dot) | §2.2 |
| `ConnectionView.swift` | The cockpit page; hosts hero + cards + Setup checklist + activity strip | §4 |
| `ConnectionHero.swift` | **The one custom-glass component** (`GlassEffectContainer`); pure (`ConnectionHeroState`/`ConnectionHeroActions`/`isCompact`) so onboarding reuses it | §4.1 |
| `ConnectionReadinessCard.swift` | Real five-row readiness card (`AppModel.connectionReadiness`); rows expandable in every state (D1) | §4.2 |
| `ConnectionAddressCard.swift` | Instant Link / Your Domain, ordered sign-in (Wrangler or pasted token) → domain load → domain/subdomain → deploy flow, `DeployStageList`, AppKit-backed secure token field (AutoFill disabled for opaque API credentials); also **defines `CloudflaredHelperSetup`**, the shared managed-helper offer that `WelcomeView` reuses | §4.3 |
| `ToolsView.swift` | The Tools page (D63): `HSplitView` of the source column and one page per source; filter chips, Group By, category/source/capability sections, server sections with **Open**, the candidate tool preview, the All MCP Servers scan status, Scan, Add ▾ | §5.1 |
| `ToolsSourceColumn.swift` | `ToolsSource` (persisted selection), the source list, `MCPServerStatus` (chip + column glyph per state) | §5.1, D63 |
| `ToolsServerHeader.swift` | `ToolsPageHeader` plus the imported-server and candidate pages: Sign In…/Sign Out (D62), Refresh, Share All, Import, endpoint, progress, errors | §5.1, D62/D63 |
| `ToolInspector.swift` | `.inspector` — Overview; Definition owns the 1 s–24 h timeout; Permissions/Activity + Test/Duplicate/Remove | §5.1 |
| `ToolLibrarySheet.swift` | Bundles / Found on This Mac / Presets / Custom | §5.1 |
| `AppsView.swift` | `AppCard` per connected app + per-category policy groups; page-level app search (`AppsView.matches(_:query:)`), in-card tool filter, three session chips, **Sign Out…**, 30 s liveness `.task` | §5.2 |
| `RequestsView.swift` | Pending (`ApprovalCard` inline) + session history + Deny-All bar | §5.3 |
| `ApprovalCard.swift` | The approval anatomy (actor/capability/scope/countdown); window + inline + onboarding variants. `ApprovalArgumentList` shows every argument of a tool call in full (D68); `consequenceSection` shows a sign-in's matching code and return destination (D69) | §5.4 |
| `ApprovalWindowView.swift` | Floating-window host; "1 of N" paging over `pendingInterrupts`; reports the card on screen through `AppModel.presentedInterruptID` (D70) | §5.4 |
| `ActivityView.swift` | Log list, level + Events/Everything filters, Export/Copy/Clear | §5.5 |
| `SettingsView.swift` | General / Notifications / Security panes. General splits into `ConnectorSetupSteps`, `ConnectorSignInMethodRow` (read-only), `ConnectorAdvancedSignIn` (**the only** `setConnectorAuthMode` call site), `ResultCardsSettingsSection` (own file, `ResultCardsSettingsSection.swift`, D77), `StartupSettingsSection` (Open at login and Go public at launch, D76), and `CloudflareHelperSettingsSection` | §5.6 |
| `WelcomeView.swift` | Five-screen onboarding; reuses ConnectionHero + ApprovalCard + AccessFixer; S2 keeps all catalog bundles and adds an explicit optional Current Date starter card for Macs with no optional CLIs; S4 chooses Instant Link or hands Your Domain off to the expanded Address form; S1 flags copies running outside `/Applications` | §3, D59 |

## Design system (`Views/DesignSystem/`) — replaces the old `SharedViews.swift`

- `Tokens.swift` — `Space` (spacing scale), `TypeRamp` (text-style helpers,
  e.g. `heroStatus`, `rowDetail`, `truthNote`), semantic color roles, concentric
  radii. **The only source of spacing/type/color.**
- `Components.swift` — `StatusOrb`, `FlowLayout` (wrapping chip rows), `StatChip`, `StateChip`, `Card` (collapsed-
  summary variant), `KeyValueGrid`/`KeyValueRow`, `CopyButton` (writes pasteboard
  + calls injected audit closure), `MonoValue`, `CountdownRing`, `ActivityLogRow`,
  `EmptyState` (ContentUnavailableView wrapper), `DetailsDisclosure` (+ ⌥-click
  expand-all via `DetailsExpandAll`).
- `ConnectedAppIconView.swift` — `AppIconSize` (`.compact` 24 / `.card` 28 /
  `.hero` 64 — the complete set of app-icon sizes) and `ConnectedAppIconView`,
  which resolves a `ConnectedAppIdentity`, loads bundled artwork through a
  process-wide `NSImage` cache (misses are memoized too), and falls back to the
  brand's SF Symbol. `.accessibilityHidden(true)` by default; `isDimmed` for
  non-active sessions.
- `Checklists.swift` — `DeployStageList` (four named Cloudflare deploy stages),
  `SetupChecklist` (self-retiring, D16).
- `AccessFixer.swift` — `TargetRow`, `AccessFixerActions` (all six troubleshoot
  actions injected as closures), `AccessFixer`. One component, three hosts: the
  app-global FDA sheet, the Connection Readiness FDA expansion, onboarding S3.
  The only target is `MacRemote.app` (D71); bridged RemCTL and NotesCTL tools
  never produce one.

All design-system components are **pure** (data injected via init; no
`@Environment(AppModel.self)`) so they work in the main window, the floating
Approval window, and onboarding alike.

## AppModel (`Stores/AppModel.swift`) — key API the views bind to

`@MainActor @Observable`. Selected surface added/changed by the redesign:

- Navigation/scenes: `selection`, `windowOpener`, `presentApprovalWindow()`,
  `openMainWindow()`, `hasCompletedWelcome`, `readinessRowToExpand` +
  `revealReadinessRow(_:)` / `clearReadinessRowToExpand()`, the session-only
  `connectionAddressSetupRequested` + `requestConnectionAddressSetup()` /
  `clearConnectionAddressSetupRequest()` Welcome handoff, `focusSearchField()`.
- Approvals (D4, D70): `pendingInterrupts`, `pendingRequestCount`,
  `presentedPendingInterrupt` (the request the Approval window is showing),
  `canAlwaysAllowPresentedRequest`, and
  `approve/deny/alwaysAllowPresentedRequest()`. The Requests menu uses only
  these. `handleNotificationResponse(action:requestID:kind:)` can deny and can
  open the request; it never approves (D68).
- Quit gate (D2.6): `shouldConfirmQuit` drives the confirmation in
  `AppDelegate.applicationShouldTerminate`. `prepareForConfirmedQuit()` stops
  the public link from `applicationWillTerminate`, so every quit path stops
  Cloudflare's helper.
- Public link: `requestGoPublic()` and `startTunnel()` open the Address card
  instead of starting an Instant Link when Your Domain is the chosen address.
  `goPublicConfirmationMessage` is the confirmation body Connection and
  Settings share.
- Startup (D76): `openAtLoginStatus` (the `SMAppService.Status` macOS reports;
  `refreshOpenAtLoginStatus()` re-reads it), `setOpenAtLogin(_:)` (sets
  `openAtLoginError` when macOS refuses), `openLoginItemsSettings()`.
  `goPublicAtLaunchHostname` is the confirmed hostname
  (`MacRemote.goPublicAtLaunch.hostname`; nil = off),
  `goPublicAtLaunchCandidateHostname` is the deployed, chosen Your Domain it
  can be turned on for (never an Instant Link), and
  `turnOnGoPublicAtLaunch(hostname:)` / `turnOffGoPublicAtLaunch()` change
  it; the view calls turn-on only after its one-time confirmation, passing the
  hostname the dialog showed, which is saved only if it is still the candidate.
  `goPublicAtLaunchIfEnabled()` runs once per launch from `AppModel.init`
  when the app passes `runsLaunchActions: true` (tests never do), so it needs
  no window. Each run holds an attempt ID that every owner action changing
  sharing clears (`cancelGoPublicAtLaunchAttempt()`: `startLocalServer()`,
  `stopLocalServer()`, `startTunnel()`, `stopTunnel()`,
  `deployCustomDomainTunnel()`, `rotateInstanceID()`, turning the setting
  off); the attempt checks it after every wait and stops quietly once it is
  gone. The launch itself starts the link through the private
  `startTunnelForOwnerOrLaunch()`, so it does not cancel itself.
  `waitForNetworkAtLaunch` is the network wait, replaceable by tests. The decision is the pure `GoPublicAtLaunchCheck`
  (`Models/GoPublicAtLaunch.swift`), asked before and after
  `ensureLocalServerRunning()`; a block is written to Activity and posted as a
  status notification. Before the helper starts it waits up to 2 minutes for
  a network (`Support/NetworkReadiness.swift`); the watchdog's reconnect
  attempts cover the rest. The `started` event of that session posts "Your
  public link is live" once; `deactivateTunnelWatchdog()` drops the pending
  notice when the session ends first.
- File Transfer folders (D67): `fileTransferFolders`,
  `addFileTransferFolder(_:)` (returns the reason a folder was refused), and
  `removeFileTransferFolder(_:)`. The list is saved under
  `FileTransferPathPolicy.allowedFoldersDefaultsKey` and read on every call.
- Result cards (D77, `Stores/AppModel+ResultCards.swift`):
  `resultCardPreferences` (saved under `ResultCardPreferences.showsCardsKey` and
  `hiddenFamiliesKey`; the server reads the saved value on every request),
  `resultCardFamilies` (families of shared, eligible tools),
  `isResultCardFamilyOn(_:)` / `setResultCardFamily(_:isOn:)`, and
  `resultCardStatus(for:)` for the Tools inspector's **Result Card** row.
- Menu bar: `isMenuBarExtraEnabled`, `menuBarStatusLine`.
- Tools: `updateUserTool(id:draft:)` (**transactional**, D8 — preserves semantic
  ID and permission epoch, retains only grants whose security fingerprint still
  matches, and rolls back on failure; covered by `AppModelToolUpdateTests`),
  `requestNewTool()`,
  `requestAddFromLibrary()`, `isToolInspectorPresented`, `builtInCatalogTools`
  (native File Transfer group, never persisted), `allTools` (= built-in + user),
  `catalogUpdateCount(in:)`, and `updateUserToolsFromCatalog(_:sourceName:)`.
  The catalog count is zero for a wholly fresh scope and includes refresh,
  unique scan-provenance adoption, missing additions, and retirements once the
  scope is represented.
- Token lifetimes (D24): `oauthAccessTokenTTLSeconds` /
  `setOAuthAccessTokenTTLSeconds(_:)`, `oauthRefreshTokenTTLSeconds` /
  `setOAuthRefreshTokenTTLSeconds(_:)` — bound by the Settings › Security pickers.
- Notifications: `refreshNotificationPermissionStatus()`,
  `requestNotificationPermission()`, `notificationPermissionStatus`. Guarded
  behind a bundle check — no-ops under `swift run`/`swift test` (UNUserNotification
  crashes unbundled).
- Credentials: `oauthClientCredentials`, `lockedOAuthClientIDs` /
  `hasLockedOAuthCredentials`, `unlockOAuthCredentials()` — see next section.
  `deleteConnectorHeaderToken()` clears the Single Header token from its Keychain
  store and revokes it at the coordinator;
  `generateConnectorHeaderTokenIfNeeded()` mints one **without** changing the
  sign-in method (D43). The header-token store is injectable through
  `init(connectorHeaderTokenStore:)` for tests.
- Connected apps (D45): `signOutApp(id:)` returns
  `Result<ConnectedAppSignOutResult, ConnectedAppSignOutError>`;
  `signOutAllApps()` returns the aggregate `ConnectedAppSignOutResult`;
  `refreshConnectedClients()` re-snapshots live token state (called by the Apps
  page every 30 s). **`deleteOAuthClient(id:)` and `revokeOAuthGrants()` are
  gone** — do not reintroduce a revocation entry point that returns a `String?`
  error and discards the real counts. `ConnectedAppSignOutResult.revoke(...)` is
  the single revocation set: `OAuthCoordinator.revokeClient(id:)` (registration,
  authorizations, access + refresh tokens) → `denyPending(clientTrustID:clientID:)`
  → `ClientToolPermissionStore.removeClientTrustID(_:)`, all keyed on client ID
  and OAuth trust ID only. `summary` omits zero clauses and inflects plurals;
  `logLine` always states all six counts.
- Cloudflare helper (D44): `cloudflaredManager` (a `let`, not a global),
  `cloudflaredHelperState`, `refreshCloudflaredHelper()`,
  `installCloudflaredHelper()`, `cancelCloudflaredHelperInstall()`,
  `removeCloudflaredHelper()`.
- Your Domain: `cloudflareDraft` (its API token is session-only),
  `savedCloudflareDomain`, `rememberCloudflareDomain(_:)`,
  `refreshCloudflareDomains()`, `deployCustomDomainTunnel()`.
  `Models/CloudflareCustomDomainPreferences.swift` persists only the chosen
  zone and subdomain plus the last deployed account/zone/hostname/tunnel IDs,
  zone name, and local server port (`MacRemote.cloudflare.customDomain`);
  restoring it never deploys. A deploy also saves the tunnel's run token in
  the Keychain (`CloudflareRunTokenStore`, one item, bound to the tunnel ID).
  With it, `startTunnel()` in Your Domain mode starts the deployed tunnel
  directly, with no API token and no Wrangler, when the saved address is still
  the chosen one and the local server is on the saved port
  (`LocalMCPServer.start(preferredPort:)` asks for that port first, because
  Cloudflare's copy of the tunnel's settings names it). Otherwise Go Public
  opens the Address card to deploy. Choosing another address deletes the
  token, and so does a start that Cloudflare rejects
  (`TunnelServiceEvent.runTokenRefused`). `chosenDeployedHostname` lets the
  Address card say a domain is deployed before this launch brought it up. A deploy
  of the saved address passes `expectedTunnelID`, and `CloudflareService`
  throws `savedTunnelChanged` before any Cloudflare write when that tunnel is
  gone or replaced. With no pasted token, `CloudflareService` runs
  `wrangler auth token --json` through `ProcessRunner(allowsStdoutSpooling:
  false)` with `WRANGLER_WRITE_LOGS=false`, and never puts Wrangler's output
  in an error.
- Sign-in (D42/D43): `connectorAuthMode` defaults to
  `ConnectorAuthMode.productDefault`; `setConnectorProvider(_:)` persists the
  provider and nothing else; `setConnectorAuthMode(_:)` remains the only mutator
  and logs the transition. One method is accepted at a time: each change calls
  `signOutOtherSignInMethods(leaving:)`, which signs out every app the new
  method does not admit, and `setConnectorAuthMode` returns the sentence
  `ConnectorAdvancedSignIn` shows under the picker. `allowsDynamicClientRegistration` and
  `acceptsConnectorHeaderToken(_:issuer:resource:)` expose coordinator ground
  truth so tests assert against what the server accepts, not against the model's
  own copy.

`NSApp` is nil in test processes; the window/dock/notification helpers guard it.
Do not remove those guards.

## Stable tool identity and permission binding

`Models/ToolIdentifier.swift` is the single semantic-ID policy. An ID starts
with a lowercase ASCII letter, continues with lowercase letters/digits/
underscores, and is at most 64 characters. Presets, custom tools, CLI scan
results, imported MCP tools, persistence, runtime dispatch, widget actions, and
the public MCP `name` all use that same ID. There is no random public ID and no
second permission-only tool name.

A saved tool whose ID is invalid or duplicated, including a clash with a
built-in tool, starts Not Shared and blocks catalog writes so `tools.json` is
preserved. `AppModel.init` also compares every saved tool's security
fingerprint with the set recorded at the last save
(`knownToolFingerprintsKey`). A tool that is new or changed since then starts
Not Shared and is named in Activity; with the preferences missing, every saved
tool starts Not Shared.

`Services/ToolSecurityFingerprint.swift` hashes the parts of a definition that
set execution authority: semantic ID, persisted `permissionEpoch`, backend,
capability, macOS permission requirements, argv and validation schema,
executable/provenance, upstream bridge contract, credential binding, timeout,
and output limits. It excludes display copy/category, OAuth client IDs, access and
refresh tokens, token hashes, sessions, connection IDs, issuer/resource,
expiry, and DCR timestamps. Source-backed rotating credentials bind their stable
locator; literal credentials bind a hash of the literal without logging it.

`Stores/ClientToolPermissionStore.swift` v2 persists grants by a
registration-scoped OAuth trust ID plus `(semanticToolID,
securityFingerprint)`. OAuth reconnect within one stored registration,
access-token refresh, and refresh-token rotation keep an unchanged grant. Every
new DCR registration receives a new trust ID, even for identical self-reported
metadata, and asks again. Persisted legacy metadata-derived IDs migrate to the
per-registration v2 form, so old broad grants become unreachable. A changed
trust identity, tool security contract, or recreated installation does not keep
the grant. `ToolCallApprovalRequest` captures
the fingerprint shown to the user, and `ToolSurfaceRuntime`/
`ToolExecutionService` verify it again after approval and immediately before
execution, closing the approve-then-edit race.

## Catalog revision and compact discovery

`Services/MCPCatalogMetadata.swift` computes a deterministic `sha256:` revision
from sorted public tool descriptors. `LocalMCPServer` adds it to the complete,
unpaginated `tools/list` result at
`_meta["net.viticci.macremote/catalogRevision"]`. `initialize` always advertises
Resources support, and `resources/list` always includes the standard JSON
resource `macremote://catalog/v1` (`macremote-catalog`) alongside the optional
widget resource. Its manifest contains only version, revision, and compact
name/title/category/capability/source/schema-revision entries.

An unknown tool remains a `-32602` protocol error. Its `error.data` includes
`reason: "unknown_tool"`, `refreshRequired: true`, the current catalog revision,
the compact resource URI, and at most three fuzzy semantic suggestions. The
server never dispatches a suggestion. Standard full tool schemas stay primary;
the revision, manifest, and OpenAI aliases are additive cross-host metadata.

## Locked-credential handling (`Services/OAuthClientCredentialStore.swift`)

Startup loads OAuth client secrets **non-interactively**
(`loadAllDetailed(interactive: false)`) so a re-signed rebuild can never trigger a
blocking macOS Keychain password prompt before the first window (it did, on macOS
27 — the app hung windowless). Locked entries are surfaced, not fatal:
`lockedOAuthClientIDs` drives a warning in Activity and an **Unlock…** button in
Settings ▸ Security, which calls `unlockOAuthCredentials()` (an *interactive*
read, so the prompt appears at a user-chosen moment). Suppression uses both
`LAContext.interactionNotAllowed` (data-protection keychain) and a scoped
`SecKeychainSetUserInteractionAllowed(false)` (legacy file keychain, where the
existing secrets live).

## Product connection paths

MacRemote has two product connection paths and one Connection state machine:
Off → Local → Public.

- **Local:** the MCP server binds to loopback for apps running on this Mac.
  Same-Mac apps may connect while the Connection surface says Local; remote
  devices cannot reach it.
- **Public:** the app-managed Cloudflare process forwards the public link to the
  same local server. Remote apps use that link and the configured sign-in
  method. ChatGPT's developer-mode app uses Dynamic OAuth with Dynamic Client
  Registration through the public `/authorize`, `/token`, and `/register`
  routes.

There is no third product path, connection profile, managed process, or fourth
Connection state. The managed Cloudflare helper (below)
is an implementation detail *of* the Public path — a binary MacRemote may install
and launch — not a path, a mode, or a Connection state of its own.

Dynamic registration supports public and confidential clients. Discovery
advertises the supported token authentication methods; confidential clients bind
to the declared Basic or POST method, registration returns a one-time secret,
and only its hash persists. Metadata and registration responses are non-cacheable.
Client Identifier Metadata Document (CIMD) support is a deferred, unadvertised
SHOULD, so this implementation map does not claim complete 2026 OAuth
conformance. The one exception fetches nothing:
`Services/PublishedOAuthClient.swift` lists the published client IDs MacRemote
knows by heart (Claude's hosted apps), and
`OAuthCoordinator.publishedClientLocked` accepts exactly those. Add an entry
only from a document you read, with its date, and add a test.

`LocalMCPServer.beginAuthorization` logs every refused sign-in request to
Activity and answers a browser with `signInRefusedPageHTML` instead of bare
JSON.

The 2026 protocol implementation is covered by local conformance tests.
Historical 2025-era live-host checks remain useful product evidence for the
public link and widget, but they are not proof of the 2026 protocol.

## Sign-in method (added 2026-07-29)

Spec: DESIGN-SPEC D42/D43. One persisted setting, one editor, one default.

- Type: `ConnectorAuthMode` (`Models/ConnectorProfile.swift`). Live raw values:
  `oauthClientSecret`, `macRemoteOAuthOnly`, `singleHeaderToken`. Retired
  Cloudflare Access raw values (`serviceTokenHeaders`,
  `serviceTokenAuthorizationHeader`) still migrate to `.macRemoteOAuthOnly`
  inside `from(persistedRawValue:)`; an unknown value resolves to `nil`.
- Persisted key: **`MacRemote.connector.accessMode`** — a historical name kept
  deliberately. There is no rename, no migration pass, and no normalize-on-launch
  write.
- Default: `ConnectorAuthMode.productDefault == .macRemoteOAuthOnly`. `AppModel`
  reads `loadConnectorAuthMode(from:) ?? .productDefault`. The default is
  **independent of the selected app** — the old
  `provider.recommendedAuthMode` fallback is gone, and `recommendedAuthMode` now
  returns `.productDefault` for every provider.
- Compatibility: `status(for:)` marks Dynamic OAuth `.recommended` for every
  provider; `.oauthClientSecret` is `.blocked` for ChatGPT and Claude (a
  confidential client disables self-registration server-wide, so both fail at
  `/register`) and `.works` elsewhere; `.singleHeaderToken` stays `.blocked` for
  ChatGPT, Claude, and Notion. `blockedLine(for:)` states which wall was hit
  rather than claiming the header reason for both cases.
- Falsifiable rule: `grep -rn 'setConnectorAuthMode' Views` must return only
  `Views/SettingsView.swift`, inside `ConnectorAdvancedSignIn`. Any second call
  site is a D11/D43 violation.
- Coverage: `Tests/MacRemoteTests/ConnectorSignInTests.swift` (fresh-install
  default, provider independence, per-raw-value persistence round-trips, retired
  value migration through `AppModel`, provider changes never touching method or
  credentials, explicit change generating exactly one credential, switching away
  from Single Header revoking at the coordinator, DCR on/off ground truth) plus
  the revised matrix in `ConnectorProfileTests`.

## Managed Cloudflare helper (added 2026-07-29)

Spec: DESIGN-SPEC D44, parity CH-1…CH-8. MacRemote can install, verify, launch,
update, and remove its own copy of Cloudflare's tunnel client. It is **app
infrastructure**: never a user tool, never a preset, never in
`ExecutableLocator`.

- **Pin:** `Models/CloudflaredManifest.swift` is a compile-time constant —
  version `2026.10.3`, publisher, release date, expected Developer ID team
  `68WVV388M8`, expected archive entry name `cloudflared`, license/source/release
  URLs, a three-host download allowlist (`github.com`,
  `release-assets.githubusercontent.com`, `objects.githubusercontent.com`),
  `maxRedirectCount` 5, a 64 MiB streaming cap, and one `CloudflaredArtifact` per
  architecture carrying exact archive bytes + SHA-256, exact executable bytes +
  SHA-256, and the exact uncompressed tar length. **Nothing is fetched at runtime
  to decide what is correct**. Maintenance checks archive digests against GitHub
  asset metadata and executable digests against Cloudflare's release notes, then
  verifies both Developer ID signatures. Version 2026.10.3 is the macOS
  direct-download minimum for the October 2026 certificate security update.
  Cloudflare ships thin per-architecture binaries, so `hostArchitecture` reads
  `hw.optional.arm64` /
  `hw.machine` at runtime rather than using `#if arch`; the mapping is exposed as
  the pure `architecture(isARM64Hardware:machine:)` so it is testable off-host.
- **Store:** `Services/CloudflaredInstallStore.swift` owns
  `~/Library/Application Support/MacRemote/CloudflaredHelper/` and nothing else:
  `bin/cloudflared` (0500), `install.json` (0600, the `CloudflaredInstallRecord`),
  `staging/<uuid>/` (0700, cleared before each install), `quarantine/<uuid>/`.
  `verifyInstalledBinary` re-checks the whole chain before launch — both
  directories are 0700 and owned by this uid, the binary is a regular file (not a
  symlink) at mode 0500, the byte count and streaming SHA-256 match
  `install.json`, and `CodeSignatureReader` reports Developer ID team
  `68WVV388M8`. Any failure **quarantines** the copy and throws, so the app can
  never launch what it could not prove. `commit` publishes atomically via
  `replaceItemAt` and rolls the binary back if the record cannot be written — an
  unrecorded binary can never be proven again. `remove()` refuses unless the root
  is literally named `CloudflaredHelper`.
- **Download:** `Services/CloudflaredDownloader.swift` uses an injected (default
  ephemeral, no-cookie, no-cache) `URLSession`. A per-task delegate enforces the
  https + host allowlist on the initial request *and* every redirect, caps the
  redirect chain, and aborts the transfer the moment bytes exceed the published
  size. Completion refuses a non-200, a non-HTTP response, or any file whose size
  is not exactly `archiveByteCount`; refused transfers delete their temporary
  file. Cancellation is wired through `withTaskCancellationHandler`.
- **Extraction:** `Services/CloudflaredArchiveExtractor.swift` is fully
  in-process — no `tar`, no subprocess, no shell. It verifies the archive's size
  and SHA-256 *before opening it*, hand-parses the gzip container, inflates
  through `compression_stream` capped at the published uncompressed length, and
  checks the container's own CRC-32 and length trailer. The USTAR reader accepts
  exactly one shape: plain `ustar` magic (GNU's `ustar  \0` variant is refused),
  typeflag `0`/NUL, empty prefix and linkname fields, the exact entry name, the
  exact size, and nothing but zero padding after the payload. Symlinks, hard
  links, directories, path traversal, PAX/GNU extensions, and any second entry
  are rejected by name. The unpacked file is then re-read **from disk** and
  re-checked for size, SHA-256, and Developer ID team, so what gets launched is
  what was checked.
- **Manager:** `Services/CloudflaredManager.swift` is `@MainActor @Observable`
  and a `let` on `AppModel`. State:
  `checking · notInstalled · downloading(progress) · verifying · ready(version, source) · updateAvailable(installed, available, source) · failed(CloudflaredInstallFailure)`.
  `updateAvailable` is computed purely by comparing `install.json` against the
  compile-time manifest — there is no network poll. `install()` is single-flight
  and user-initiated. `remove()` returns a refusal message while a tunnel is
  running. Resolution lives in the separate `CloudflaredResolutionCore`
  (`@unchecked Sendable`, lock-guarded) because `TunnelService` resolves a path
  off the main actor; a proven copy is remembered by
  `CloudflaredIntegrityKey` (inode, mtime, size) so a 38 MB hash is not recomputed
  on every status refresh, and any stat change re-runs the full check.
- **Precedence:** `TunnelService.resolvedExecutablePath(launched:session:external:)`
  is a pure function — **the running process's path wins, then the current
  supervised session's path, then whatever the app resolves today.** `startProcess`
  pins both; termination clears the launched pin but keeps the session pin, so a
  watchdog restart relaunches the same binary instead of silently switching
  mid-session. `AppModel.deactivateTunnelWatchdog()` calls `clearSessionPin()`, so
  the next start may pick up a newly installed helper. Below that pin,
  `CloudflaredResolutionCore.resolvedExecutablePath()` prefers the verified
  managed copy and falls back to the external one.
- **Injection seams:** `TunnelService(resolveCloudflared:)` and
  `CloudflareService(executablePath:)` are both closures supplied by `AppModel`
  (`wrangler` still falls through to `ExecutableLocator`). `CloudflaredManager`
  injects its store root, `URLSession`, external resolver, artifact provider, and
  `SignatureReading`. Tests never touch the real Application Support directory
  and never reach the network.
- **Readiness and diagnostics:** `AppModel.tunnelReadinessCheck` reports
  `downloading`/`verifying` as `checking` with live detail, and
  `TunnelStatus.unavailable` as **blocked** — "Cloudflare's helper isn't
  installed." — instead of the old "waiting".
- **Activity log:** install start (architecture, download URL), success
  (version, install path, SHA-256, expected Developer ID team), failure with the
  specific mismatch, quarantine, and removal.
- **Deliberately unchanged:** `Models/DefaultToolPresetCatalog.swift`'s
  `preset.cloudflared.*` entries still resolve only through `ExecutableLocator`,
  so they keep reflecting a helper the *user* installed. MacRemote's own pinned
  binary is never offerable as a tool. See `CLI-DISCOVERY-SPEC.md §4.1`.
- **Coverage:** `Tests/MacRemoteTests/CloudflaredManagerTests.swift` (manifest
  sanity, redirect predicate, synthetic golden archives plus the rejection
  matrix — symlink entry, `../` name, two entries, PAX/GNU, size and hash
  mismatch — precedence, atomic install and rollback, owner-only permissions,
  removal leaving an external copy alone, refusal while running).

## Connected-app identity and brand assets (added 2026-07-29)

Spec: DESIGN-SPEC D46, parity AI-1…AI-5. Distinct from the **Connector icon**
section below, which is about MacRemote's *own* mark as other apps see it.

- **Matcher:** `Models/ConnectedAppIdentity.swift` carries a trust-boundary
  comment at the top and must keep it. `normalize(_:)` lowercases, folds
  diacritics and width, and strips everything outside `[a-z0-9]`.
  `resolve(name:redirectURIs:)` runs exactly two steps: (1) exact membership in a
  catalog entry's `exactAliases`; (2) **only** when the supplied name is
  uninformative — empty, one of a small set of placeholder names, or an echo of
  the app's own redirect host — the exact lowercased host of a registered
  redirect. Hosts are matched exactly, never by suffix, so
  `claude.ai.evil.example` matches nothing. There is no `contains` anywhere; the
  helper this replaced turned every name containing "openai" into ChatGPT.
  ChatGPT's entry deliberately carries **no** redirect-host evidence, because
  unrelated apps on this Mac have registered `chatgpt.com` callbacks.
- **Evidence column, not a matcher (D48):** each row also carries
  `bundleIdentifiers` plus optional `localLightResource`/`localDarkResource`.
  Nothing an app supplies is ever compared against a bundle identifier — it is
  asked, only after a brand has already resolved by exact alias, whether a copy of
  that vendor's app is installed here. `localResource(forDarkAppearance:)` mirrors
  `artworkResource(forDarkAppearance:)` so both tiers pick appearance by one rule.
- **Firewall:** nothing in `Services/` or `Stores/` may read this type.
  `grep -rn 'ConnectedAppIdentity' Services Stores` must stay empty. The only
  consumers are `ConnectedAppArtworkResolver`, `ConnectedAppIconView`, `AppsView`
  (icon + search filter), `ApprovalCard`, and `RequestsView`.
- **Four tiers (D48):** `Views/DesignSystem/ConnectedAppArtwork.swift` owns
  `ConnectedAppArtworkTier` (`.bundled` < `.installedApp` < `.clientSupplied`),
  the `ConnectedAppInstalledArtworkProviding` protocol with its `NSWorkspace`
  implementation, and `ConnectedAppArtworkResolver`, which memoizes all three
  tiers behind one `NSLock` — hits and misses both, with a 300 s TTL on
  "not installed" so installing an app mid-session starts working without a
  relaunch. `ConnectedAppIconView` asks the resolver once per body and draws the
  SF Symbol when it answers `nil`. The tier is never rendered.
- **Retina gate:** `AppIconSize.minimumPixelWidth` is `points * 2`, and the
  installed-app tier only accepts a named vendor resource whose largest
  representation meets it. Claude's tray art is 72 px, so the 24 pt and 28 pt
  sites use it and the 64 pt ring falls through to Claude's own app icon.
- **What an app may send about itself:** `Models/ClientSuppliedIcon.swift` parses
  MCP 2026-07-28 `Icon` objects. `data:` URIs only — an `http(s)` src is refused
  with `notADataURI`, which is also what keeps OAuth `logo_uri` out. Base64 only,
  PNG or JPEG decided by **magic bytes** rather than the declared MIME type, size
  capped before sniffing (`maximumImageByteCount` 256 KiB,
  `maximumIconsPerClient` 4). `theme` follows the spec's meaning: `light` is for a
  light background. Intake is `LocalMCPServer.recordClientSuppliedIcons`, which
  reads both the modern `_meta["io.modelcontextprotocol/clientInfo"]` and legacy
  `initialize`'s `params.clientInfo`, stores into an in-memory
  `MCPClientSuppliedIconStore` (never disk), logs a refusal once per client, and
  emits `.clientSuppliedIconsChanged` only when the stored set actually changed.
  `AppModel.clientSuppliedIcons` holds them keyed by client ID and
  `setConnectedClients` prunes to the live list, so signing an app out takes its
  picture with it.
- **Assets:** `Resources/ConnectedAppIcons/` ships as a `Bundle.module`
  `.copy` subdirectory. Because `.copy` preserves the directory,
  `Image(_:bundle:)` cannot see the files — `ConnectedAppIdentity.iconURL(named:)`
  and `manifestURL` resolve them with
  `Bundle.module.url(forResource:withExtension:subdirectory:)` and
  `ConnectedAppIconView` loads through `NSImage(contentsOf:)`.
- **PNG, not an asset catalog:** Command Line Tools ship no `actool`, so there is
  no `.xcassets`, no `@2x` machinery, and no PDF. One PNG per appearance (a
  single file when one mark reads on both) is the whole format.
- **Provenance is required, not optional.** `MANIFEST.json` records per file:
  brand ID, product, owner, source URL, source SHA-256, retrieval date, license +
  license URL, `redistributionPermitted` with the evidence quoted, original
  format, every transformation applied, the committed file's SHA-256, and the
  appearance it serves. A git-hosted source must also pin a 40-character
  `sourceCommit` contained in its URL; a vendor CDN has no commit to pin and is
  held to the hashes instead. A row claiming **no** transformation must have
  `sourceSHA256 == sha256`, which is how the two "use it exactly as provided"
  vendors are audited. `THIRD-PARTY-NOTICES.md` reproduces each bundled license
  verbatim and tabulates both the locally-extracted brands and the held-back ones.
  A file with no manifest row, or a manifest row with no file, is a defect the
  tests catch.
- **Bundled scope (D48):** T3 Code (MIT, downscaled to 512), Grok
  (`grok-light`/`grok-dark`, official xAI logomarks byte-for-byte), Raycast
  (`raycast-light`/`raycast-dark`, press-kit logos byte-for-byte). Held back from
  bundling: Claude (Anthropic publishes no terms), ChatGPT and Codex (OpenAI's
  guidelines do grant conditional unaltered use — the earlier "written permission
  required" claim was wrong — but OpenAI publishes no downloadable file), Notion
  (brand page sign-in-gated, terms unreadable). All four resolve from the
  installed app instead of a symbol on this Mac.
- **Two opposite naming conventions:** xAI names its files after the mark's own
  colour (`Grok_Logomark_Dark` is the near-black mark, so it is the *light*
  appearance); Raycast names its files after the background (`raycast-logo-light`
  is for light backgrounds). Every file was decoded and checked rather than
  trusted by name, and `eachBundledPairMapsToTheAppearanceItsManifestRowClaims`
  keeps it that way.
- **Snapshot plumbing:** `ConnectedClient` (`Models/RuntimeState.swift`) gained
  `authenticationMethod` (`ConnectedAppAuthMethod`, mirroring the coordinator's
  stored method) and `sessionState` (`ConnectedAppSessionState`: `.active` ·
  `.awaitingSignIn` · `.expired`), both with defaults in the memberwise init so
  existing call sites compile. `connectedClientSnapshotLocked(now:)` computes the
  state and sorts by `sessionState.sortRank`, then last-authorized descending,
  then name. `ToolCallApprovalCoordinator.denyPending(clientTrustID:clientID:)`
  matches by trust ID, falls back to client ID, **never** matches a display name,
  and resolves waiters outside the lock.
- **Coverage:** `ConnectedAppIdentityTests` (aliases, normalization, negative
  cases including "Codex DCR Probe" + a `chatgpt.com` redirect resolving to
  generic, exact-host-not-suffix, every non-nil resource resolving in
  `Bundle.module`, manifest ↔ file hash agreement, no orphan rows,
  unaltered-mark vendors proven unaltered from the hashes, appearance ↔ manifest
  agreement), `ConnectedAppArtworkTests` (tier precedence in all four
  combinations, the real `NSWorkspace` provider returning `nil` for an app that
  is not installed, per-appearance and per-size lookups, memoization, `data:`-only
  enforcement against `http(s)`/`file:`/`javascript:`, magic-byte format checks
  that ignore a lying MIME type, the size cap running before decoding, the icon
  and theme caps, a registration-time `logo_uri` failing the same parser, no
  decision-making source file naming an artwork type, and sign-out pruning the
  pictures), and `ConnectedAppSignOutTests` (exact counts against ground truth,
  pending denial scoped to one app, rules cleared for one trust ID only, two
  same-named clients staying independent, unknown client mutating nothing).

## Cloudflare custom-domain browser compatibility

`CloudflareService.deployCustomDomain` first reads the existing named tunnel and
hostname DNS record,
then rejects a record that is neither free nor MacRemote-owned (a CNAME matching
the tunnel target or carrying the exact `MacRemote Cloudflare Tunnel` marker).
Other record types and similarly prefixed comments fail closed. An existing
same-name tunnel must report
`config_src: cloudflare`; MacRemote reuses it only when the DNS content targets
that tunnel ID or its current ingress already contains the exact hostname. A DNS
comment proves ownership of the hostname record, not ownership of a specific
tunnel. An unproven tunnel is rejected before any write. They next provision an
exact-hostname rule with action `set_config`,
`action_parameters.bic = false`, and a stable SHA-256-derived `ref`.
Provisioning creates the phase ruleset when absent, appends the MacRemote rule,
patches only a drifted rule with the matching ref, and no-ops when it is already
correct and last. Because the desired ensure itself must succeed before legacy
cleanup, tunnel creation/configuration, or DNS writes, Config Rules Read without
Edit cannot leave a partial deployment. New and repaired rules are forced to
last precedence. It never replaces the full ruleset or changes unrelated rules.
This prevents Cloudflare error 1010 for non-browser MCP/API clients while
leaving Browser Integrity Check unchanged on every other hostname. The app's
token contract is exactly `Account -> Cloudflare Tunnel -> Edit`, plus
`Zone -> Zone -> Read`, `Zone -> DNS -> Edit`, and
`Zone -> Config Rules -> Edit`. Account Resources must include only the account
that owns the domain; Zone Resources must include only the selected zone. Just
before the DNS write, the app re-reads all exact-host records and
repeat the count and ownership checks, so a concurrent replacement cannot be
overwritten through the earlier preflight snapshot.

Cloudflare displays a newly created API-token secret once. MacRemote keeps that
secret in memory only and never persists it. The operator must store it securely
outside the repository. After revoking a token, paste a valid replacement before
the next **Load Domains** or custom-domain deploy.

The Address form keeps domain loading separate from deployment. Load failures
render directly beneath **Load Domains**; an empty result remains unselected,
and a refresh retains only a domain the user previously selected. Deployment
progress comes from typed `CloudflareService` boundaries in this exact order:
access check → tunnel creation or update → DNS configuration → start. A failure
stays attached to the active boundary, with stage-specific human copy and a
separate sanitized technical detail. The named tunnel remains at start until
`TunnelService` sees Cloudflare's registered-connection output; process spawn
alone is not readiness, and the bounded startup timeout enters the existing
watchdog retry path.

`TunnelService` records the helper it starts (process ID, start time,
executable path) in `tunnel-helper.json`. `stopHelperLeftByPreviousLaunch()`
stops a helper that still matches that record at the next launch.

`Services/HelperTether.swift` stops the helper when the app dies without
quitting (crash, Force Quit, kill signal). `TunnelService.startProcess` starts
the app's own executable again with `--tether-helper <app pid> <helper pid>
<helper path>`. `MacRemoteMain.main()` checks for that flag before SwiftUI
starts, so a tether never opens a window or appears in the Dock. It waits on
both processes with `kqueue` and uses no CPU. `AppModel` passes the executable
in (`helperTetherExecutableURL`); tests leave it nil, because their running
executable is not the app.
`firstPublicURL(in:)` reads an Instant Link's address from the helper's output.
`CloudflaredManifest.earlierExecutableSHA256` lists the helper digests earlier
releases installed, so those copies still verify.

## MCP Apps widget compatibility

`Services/MCPAppsMetadata.swift` is the single metadata builder. The Apps
extension is `io.modelcontextprotocol/ui`, Apps protocol version `2026-01-26`,
and the exact supported MIME type is `text/html;profile=mcp-app`. A client is
Apps-capable only when its `capabilities.extensions` entry names that extension
and its `mimeTypes` array contains that exact MIME type.

The server deliberately supports two protocol eras:

- **Modern MCP `2026-07-28`:** `server/discover` advertises the UI extension,
  while each request's capability metadata gates the actual UI surface. A
  client without the exact Apps capability receives no widget tool metadata and
  no widget resource in `resources/list`. A capable client gets standard nested
  `_meta.ui.resourceUri` plus additive compatibility aliases.
- **Legacy MCP `2025-11-25`, `2025-06-18`, and `2025-03-26`:** initialize state
  stores client capabilities. The server advertises the UI extension and lists
  the widget resource only for the exact Apps capability. For compatibility,
  an incapable legacy client may still receive the deprecated flat
  `ui/resourceUri` and `openai/outputTemplate` mirrors, but never the standard
  nested `ui` object.

The versioned resource is `ui://macremote/output-v9.html`; the prior
`ui://macremote/output-v8.html`, `ui://macremote/output-v7.html`, `ui://macremote/output-v6.html`, `ui://macremote/output-v5.html`, `ui://macremote/output-v4.html`, `ui://macremote/output-v3.html`,
`ui://macremote/output-v2.html`, and old `ui://macremote/output` URIs remain
readable but are not listed. Standard
metadata defaults `ui.visibility` to `["model", "app"]`.
`openai/widgetAccessible` is derived from that array and is true only when it
contains `"app"`. Resource reads carry standard `_meta.ui` sandbox policy plus
additive OpenAI description, border, and CSP aliases.

Every registered tool is widget-eligible unless its catalog presentation sets
`automatic: false`, but an eligible tool links the widget only while the
owner's result-card choice allows it (D77). `ResultCardPreferences`
(`Models/ResultCardPreferences.swift`) holds the global switch (off by default)
and the families switched off; `ToolFamily` (`Models/ToolFamily.swift`) is the
one family rule, shared with the Tools page's server groups. `AppModel` passes
`LocalMCPServer` a `resultCardPreferences` provider that reads the saved value
on every request; `toolJSON` and `resultUIMeta` consult it, so an unlinked
tool's descriptor and results carry no UI metadata while `content` and
`structuredContent` stay identical. `ToolWidgetPresentation` is an
optional catalog-authored refinement: its typed profiles are `reminderRows`,
`episodeRows`, `habitRows`, and `noteRows`; its optional `accent` and `rootPath`
are presentation only and do not enter the security fingerprint. A tool without
explicit metadata gets the schema-free `semanticResult` profile. Explicit
metadata lets PocketCTL and OverCTL share an episode shape while keeping
separate red and orange accents, and lets the first-party provider table give
bridged NotesCTL reads a yellow note shape and bridged RemCTL reads purple
reminder rows. Fixed Reminders, Podcasts, and Habits tools installed before
this field retain their richer historical category fallback. Flexible Commands
always use `semanticResult` unless a catalog explicitly authored a profile. No
provider ID, executable name, semantic tool-name switch, or product payload
schema selects a profile.

Widget v8 keeps the v7 renderer and fixes legibility: the color scheme lives on
the document root and follows the app's theme, and host colors apply only when
they fit it (D77; MCP-UI-SPEC "Theme and legibility").

Widget v6 links every tool and replaces raw JSON/terminal views with safe
semantic summaries, text content, and attachment affordances. The v5 features
remain: nested `rootPath` selection, safe document previews, `documentList`
transcript sections, full-envelope context chips, richer change outcomes, and
submitted-but-unverified write warnings. Presentation may select a nested value,
while the safe generic renderer never displays raw wire or execution details.
Plain text and `structuredContent` fallbacks remain available to non-rendering
hosts. Standard MCP Apps fields stay primary;
ChatGPT's `openai/*` fields are additive aliases only. This is implementation
compatibility, not evidence of live ChatGPT publication or submission.

## MCP protocol eras (added 2026-07-29)

MacRemote's current protocol is `2026-07-28`; the retained legacy versions are
`2025-11-25`, `2025-06-18`, and `2025-03-26`. Modern requests are stateless and
carry their protocol/capability metadata per request. Legacy initialize state is
kept only for the older negotiation model. Era assignment is per request: the
exact `2026-07-28` header or namespaced protocolVersion key selects strict
modern validation; legacy initialize and explicit legacy headers stay legacy.
A lone namespaced clientCapabilities object is inert without a version claim,
which admits ChatGPT's captured hybrid legacy call. Claimless
`server/discover` receives legacy Method not found so clients can fall back to
initialize. `-32022` offers remain era-specific (`modernProtocolVersions` /
`legacyProtocolVersions`), and a bare modern header never downgrades (D52;
`unsupportedProtocolVersionFailure` / `carriesModernProtocolClaim`).

Every `tools/call` runs synchronously inside its request (D66).
`MCPUpstreamProtocol.validateCompleteResultType` requires a complete upstream
result, so an upstream task handle is rejected rather than proxied.

## Requests, approval, and sign-in (added 2026-11-11)

- `LocalMCPServer.executeToolCall` runs in a fixed order:
  `ToolExecuting.validate` → `ToolDefinition.asksBeforeRunning` and the Always
  Allow grant → `ToolCallApprovalCoordinator.requestApproval` →
  `ToolExecutionLimiter` → execute with the approved security fingerprint.
- `ToolCallApprovalCoordinator`: 90-second wait (`defaultTimeoutSeconds`),
  `maximumPendingPerClient = 4`, `maximumPending = 16`, 50 resolved requests of
  history. A cancelled wait (the app disconnected) is recorded as expired.
- `ToolCallApprovalArgument` (`Models/RuntimeState.swift`) holds one argument in
  full; `displayValue` writes control and invisible characters as escapes.
- `OAuthCoordinator`: `maxPendingAuthorizationsPerClient = 2`,
  `maxPendingAuthorizations = 16`, `pendingAuthorizationLifetime = 300`;
  `scheduleExpiration` removes an unanswered request from the queue;
  `sanitizeClientName`, `recoveredClientName`, `parseRedirectURIs`, and
  `clientForAuthorization` treat what a client says about itself as untrusted.
  `ApprovalRequest.verificationCode` is the six-digit code;
  `authorizationPageHTML` shows it in the browser.
- `PublicRequestRateLimiter` (`LocalMCPServer.swift`): per-caller limits keyed
  on `CF-Connecting-IP`, with a total ceiling eight times higher.
  `maximumConnections = 96`, `requestReadTimeout = 30`.
- `FullDiskAccessService`: one target, `MacRemote.app`, tested by reading a
  protected folder in-process; `.confirmationRequired` when it cannot test.

## Connector icon (`Services/LocalMCPServer.swift`, `Resources/`)

> This section is about **MacRemote's own mark, as connected apps see it**:
> favicon routes, `serverInfo.icons`, and the landing page. It has nothing to do
> with the marks MacRemote draws *for* connected apps — those are
> `Resources/ConnectedAppIcons/` and the "Connected-app identity and brand
> assets" section above. The two never share assets, code, or a resource route.

Goal: publish standards-based icon metadata for MCP apps while retaining the
favicon route used by hosts that resolve connector identity from the public
URL's registrable domain instead of `serverInfo.icons`. App-side is fully wired:

- Routes: `GET /` (branded landing page whose `<head>` carries the favicon link
  tags Google's fetcher parses), `/favicon.ico` (lean multi-size ≈8 KB),
  `/favicon.png` (32px), `/macremote-icon.png` (512px), `/macremote-icon-128.png`,
  and `/macremote-icon-256.png` (256px, under 10 KB: ChatGPT shows no icon for a
  custom server unless the person uploads a PNG of at most 10 KB, so the guide
  points them at this one).
- `serverInfo` (in the `initialize` result) carries `description`, `websiteUrl`
  (`MacRemoteProductInfo.websiteURL`, the product's home rather than this Mac's
  private link), and a 3-entry `icons` array (128px + 512px URLs + a 64px `data:` URI hedge that
  needs no fetch) — spec-correct for the day Claude honors SEP-973.
- Resources: `MacRemoteConnectorIcon{,128,256,64}.png` and `Favicon.{ico,png}`, all
  rendered from the app icon (next section). The 256px file uses a fixed
  palette to stay under 10 KB. They are the default appearance,
  8-bit sRGB, with transparent corners.

## App icon (`Resources/AppIcon.icon`, `Tools/icon/`)

The icon is one Icon Composer document, `Resources/AppIcon.icon`: your Mac, lit,
at the far end of a glass tunnel (SPEC D75). It has four groups, front to back:
Pointer, Mac, Far End (two rings and three soft light layers), Tunnel (two
rings). Shapes are flat SVGs; the system adds the glass edges and shadows.

Every other icon file is built from that document and committed, because the
Command Line Tools toolchain has neither the asset compiler nor Icon
Composer's renderer (the same reason `Shaders/default.metallib` is committed):

- `Assets.car` is the layered icon macOS draws, in every icon style (Default,
  Dark, Clear, Tinted). The bundle's `CFBundleIconName` names it;
  `script/verify_release.sh` fails a release without that key, because the
  system would then quietly draw the flat fallback.
- `AppIcon.icns` is that flat fallback (`CFBundleIconFile`).
- The connector icons and favicons above.

To change the icon: edit the document in Icon Composer, or change the numbers
in `Tools/icon/draw_icon.py` and run it (it rewrites the whole document, so it
overwrites edits made by hand). Then run `python3 Tools/icon/build_assets.py`
and commit everything under `Resources/`, plus the README banner it redraws at
`docs/images/banner.png`. Both scripts need Pillow;
`build_assets.py` also needs Xcode 26 or later.

## Testing

Tests use Swift Testing (`import Testing`). Suites that share mock statics or
bind ports are `.serialized`: `CloudflareServiceTests`, `LocalMCPServerTests`,
`StdoutArtifactTests`, `MCPHTTPBridgeClientTests`, and the gated
`StressHarnessServerTests` suite. They would race under Swift Testing's default
parallelism.
New suites from the redesign: `AppModelToolUpdateTests` (transactional tool edit).
`ToolCallApprovalCoordinatorTests` and `ToolCallApprovalArgumentTests` cover
the approval queue caps and full-argument rendering.

Added 2026-07-29:

- `CloudflaredManagerTests` (`.serialized`) — manifest sanity, the redirect
  allowlist predicate, synthetic golden USTAR archives plus the full rejection
  matrix, precedence, atomic install/rollback, owner-only permissions, removal,
  and the refusal to swap a helper while the link is running. Injected store
  root, `URLSession`, resolver, and signature reader: no network, no real
  Application Support.
- `ConnectedAppIdentityTests` — matching positives and negatives, and the
  asset/manifest agreement checks that make `Bundle.module` resource wiring
  falsifiable.
- `ConnectedAppSignOutTests` — the exact per-app revocation set, measured
  against ground truth rather than the view's copy.
- `ConnectorSignInTests` — the D42/D43 default, persistence, and
  no-side-effects contract.
- Extended: `OAuthCoordinatorTests` (session-state derivation, first/last
  connected, ordering, per-client isolation), `ConnectorProfileTests` (revised
  compatibility matrix; the `inferred(fromClientName:)` test is deleted with the
  code), and `ConnectionReadinessTests` (helper-blocked readiness).

Current protocol/Apps coverage includes:

- `LocalMCPProtocolConformanceTests` — modern stateless discovery and request
  validation, retained legacy negotiation, and exact Apps gating.
- `MCPAppsMetadataTests` — exact MIME capability, standard `ui` metadata,
  visibility defaults, and `openai/widgetAccessible` derivation.

## CLI discovery (added 2026-07-02)

Spec: `docs/design/CLI-DISCOVERY-SPEC.md` (binding decision log DL-1…DL-27 + security
rules). Spine: **FOUND ≠ ADDED ≠ SHARED ≠ TRUSTED.**

- Scanner: `Services/LocalCLIScanner.swift` + helpers (`HomebrewCatalogIndex`,
  `ManPageNameParser`, `CodeSignatureReader`, `CLIHarvestedTextSanitizer`,
  `CLIRecommendationBlocklist`, `CLIBinaryInspector`, `CLICategoryInference`).
  **Zero-execution is falsifiable**: no `Process`/`URLSession`/`NSTask` in any of
  these files — grep before review. Sources: Homebrew receipts + JWS catalog
  caches, npm `package.json`, uv/pipx/pip dist-info, cargo/go records, man-page
  NAME sections, static code signatures, quarantine xattrs.
- Models: `DiscoveredCLICandidate`, `CLIScanState` (persisted stable-command-path
  seen-set drives "New since last scan" without treating versioned Homebrew
  payload changes as new tools; package sources compare within their source
  ledger, while PATH candidates compare only within directories represented by
  the prior cache; source fingerprints include a scan-policy revision so filter
  changes invalidate stale rows once); `ToolProvenance` on `ToolDefinition`
  (Codable back-compat with pre-provenance tools.json).
- AppModel: `cliScanState`, `scanInstalledCLIs()/cancelCLIScan()/
  retryCLIScanSource(_:)`, `addToolsFromScan(_:)` — forces Flexible Command +
  Destructive + Not Shared transactionally. R16: provenance identity change
  auto-unshares and blocks remote execution (`ToolSurfaceRuntime`
  pre-execution gate). Known gap: no re-confirm verb yet — a flagged tool stays
  off until re-added (fail-safe; needs a small re-baseline verb).
- UI: the Library sheet's **Found on This Mac** tab is the scan home (invitation
  leads before first scan; consent copy; per-source progress ledger; grouped
  checkbox review; counted Add commit). Toolbar + menu gains "Scan for
  Command-Line Tools…" (⌥⌘L) — navigation only, never auto-scans (DL-4).
- Catalog: launch-cached presets and sets include the ten Federico catalogs
  described below. Preset detection,
  category/path indexes, and resolved bundle membership are one immutable
  process-lifetime snapshot, so opening or invalidating the Library does not
  repeat executable searches or resolve hundreds of IDs again.
- Tests use fixtures under `Tests/MacRemoteTests/Fixtures/CLIDiscovery/`.
- **Out of scope: MacRemote's own managed Cloudflare helper.**
  `~/Library/Application Support/MacRemote/CloudflaredHelper/` is not on `PATH`,
  is not in `ExecutableLocator.searchDirectories`, and is never visited by the
  scanner or by preset resolution. `preset.cloudflared.*` continues to resolve
  only a helper the user installed. If the managed path ever entered discovery,
  MacRemote would offer its own pinned binary as a remotely callable Flexible
  Command — `cloudflared` is not on the Ring-1 denylist, so nothing else would
  stop it.

## Federico CLI integration (updated 2026-09-16)

Federico Viticci's ten CLIs use two surfaces. The complete contract is
`docs/FEDERICO_CLI_TOOLS.md`.

### First-party MCP providers (RemCTL, NotesCTL)

`Services/FirstPartyMCPProviderCatalog.swift` declares each CLI that ships its
own MCP server: provider id, display name, server name, category, executable
names, the argv that starts the server, a default widget presentation, and a
per-tool policy table (`approvalPolicy`, `widgetPresentation`, `uiActions`).
That table is the only product knowledge; every tool contract comes from the
CLI's `tools/list`.

- Discovery: `LocalMCPScanner.firstPartyCandidates()` synthesizes one stdio
  candidate per installed provider with source `first_party`, owned by the
  executable path. `deduplicated` processes those first and folds any config
  row whose launch `FirstPartyMCPProviderCatalog.provider(launchedBy:args:)`
  attributes to the same provider (direct, interpreter, or symlink launch)
  into it as extra owners. `configSnapshot()` includes the executables' stat
  lines so a CLI install or upgrade counts as a config change.
- Import: `bridgeTools(for:)` mints ids with
  `ToolIdentifier.importedMCPToolID`, which no longer doubles a prefix the
  server already uses, then calls `FirstPartyMCPProviderCatalog.applyPolicy`.
  The result is a normal `mcpStdioBridge` tool with the provider's category,
  approval policy, presentation, and row actions, the upstream title as its
  name, and no permission requirements.
- AppModel: `firstPartyMCPCandidate(for:)`, `importedFirstPartyMCPTools(for:)`,
  `importFirstPartyMCPProvider(_:)` (synthesizes the candidate on demand when
  no scan has run), and `refreshImportedFirstPartyMCPProviders()`. All import
  goes through `importLocalMCPServer(candidateID:)`, so probe, id reservation,
  epoch preservation, and replacement are shared with every other server.
- Library: `ToolLibrarySheet` renders `DefaultToolPresetCatalog.mcpProviders(in:)`
  as one row per provider (Add / Update) in the Federico Viticci tab;
  `categories(for: .federicoViticci)` includes the providers' categories, and
  **Update from Catalog** on that tab also refreshes installed providers.
- Tools: bridged first-party tools appear as imported server groups with the
  source chip **Federico Viticci**.
- Execution: `MCPStdioSessionPool` keeps one idle upstream process per
  `(command, args, environment)` warm for 60 seconds (capacity 16). `checkout`
  requires a live process and an unchanged executable stamp (mtime and size of
  the command and, for interpreter launches, the script); `probe` evicts the
  key; a failed exchange stops the process instead of returning it; the app
  drains the pool on quit. `MCPBridgeArgumentCoercion` converts string
  arguments to the scalar type the upstream schema declares before
  `tools/call`, in both bridge clients. One whole exchange with a server, the
  pipe readers, and the wait for the server to exit each run on a thread of
  their own (`onBlockingThread` in `Support/BlockingThread.swift`), never on
  Swift's async threads.
- Coverage: `FirstPartyMCPProviderCatalogTests`, `FirstPartyMCPScannerTests`,
  `MCPBridgeArgumentCoercionTests`, the pool tests in
  `MCPStdioBridgeClientTests`.

### Process catalog (eight providers)

The eight process catalogs share one semantic architecture: 66 dedicated Fixed
Commands backed by typed `ProcessInvocation` recipes, plus eight Destructive
every-call Flexible Commands: 74 tools total.

- `Services/AlexandriaToolCatalog.swift`: 9 dedicated + 1 Flexible.
- `Services/HabitCTLToolPresetCatalog.swift`: 5 dedicated + 1 Flexible.
- `Services/PocketCTLToolPresetCatalog.swift`: 7 dedicated + 1 Flexible.
- `Services/OverCTLToolCatalog.swift`: 8 dedicated + 1 Flexible.
- `Services/ReadLaterToolPresetCatalog.swift`: 6 GoodLinksCTL dedicated + 1
  Flexible.
- `Services/AppleFramesToolPresetCatalog.swift`: 5 dedicated + 1 Flexible.
- `Services/IrisToolPresetCatalog.swift`: 11 dedicated + 1 Flexible.
- `Services/MusicCTLToolCatalog.swift`: 15 dedicated + 1 Flexible.

`ToolArgumentResolver` validates types, formats, enum choices, ranges, JSON
bounds, and cross-field constraints before lowering one exact argv array.
`ToolExecutionService` runs declared CLI preflights before supported mutations.
No recipe or Flexible Command uses a shell.

## Alexandria integration details

`Services/AlexandriaToolCatalog.swift` is the source of truth for the curated
local-library and agent-service surface. `DefaultToolPresetCatalog` mirrors it
as `set.alexandria` / `preset.alexandria.*`.

- Category: `ToolCategory.ai` (title **AI & Agents**).
- Surface: nine dedicated tools plus `alexandria_run`: health; resource listing;
  room browsing; indexed note search and live note read; clip capture; room
  capture; agent enqueue; and exact job wait.
- Execution: exact executable path + argv, never a shell. API-backed commands
  use Alexandria's loopback default; captures pass bounded UTF-8 over stdin.
  The Alexandria service owns Notes access and writer coordination, so these
  tools declare no Full Disk Access requirement in MacRemote.
- Boundary: the Flexible Command rejects `--host` and `--port` in split,
  `--option=value`, and accepted argparse-abbreviation forms. Root-command
  parsing also follows global-option abbreviations and the `--` terminator, so
  `deploy`, `check`, and `privileged` cannot hide behind either. It cannot
  redirect MacRemote to another endpoint or enter deployment,
  checkout-verification, or FDA-helper execution.
- Async truth: agent execution returns an enqueued `job_id`; it does not claim
  completion. Wait Job polls one exact job to a terminal state and never
  retries work.
- Coverage: `AlexandriaToolCatalogTests`, catalog parity tests, scanner category
  inference tests, and `AlwaysAllowPolicyTests` cover exact argv,
  bounds, category, permission, and blocked-command behavior.

## PocketCTL integration details

`Services/PocketCTLToolPresetCatalog.swift` is the source of truth for
`set.podcasts` / `preset.pocketctl.*`.

- Surface: seven dedicated tools plus `pocketctl_run` — triage, online search,
  episode detail, transcript, Up Next changes, episode state, and progress.
- Discovery: all three installed entry points are accepted: `pocketctl`,
  `pocketcasts`, and `pctl`.
- Execution: exact argv, no shell. Every write runs PocketCTL's non-mutating
  `--dry-run` first.
- Boundary: `pocketctl_run` rejects login, password/API-key file and environment
  arguments, and `gemini key` under every entry-point alias. It installs Not
  Shared and carries no explicit widget presentation, so it uses
  `semanticResult`.
- MCP Apps: all seven dedicated tools explicitly carry `.episodeRows` with
  Pocket Casts red (`#f43e37`). Triage and episode detail add Play Next, Play
  Last, Star, and Archive actions. Combined search groups podcast and episode
  rows but deliberately carries no row actions. Published dates accept the
  current PocketCTL `published` field plus `publishedAt` and `publishedDate`
  compatibility shapes.

## OverCTL integration details

`Services/OverCTLToolCatalog.swift` is the source of truth for `set.overctl` /
`preset.overctl.*`.

- Surface: eight dedicated tools plus `overctl_run` — Up Next, search, episode,
  transcript, queue change, episode state, progress, and archive.
- Execution: exact argv, no shell. Every write runs OverCTL's non-mutating
  `--dry-run` first. Archive removes `--yes` during preview and is Destructive,
  every-call; the reversible state commands are Write.
- Boundary: `overctl_run` rejects sign-in/session removal, experimental upload,
  credential-bearing exports and URLs, forced replacement, receipt clearing,
  and secret display. It installs Not Shared and carries no explicit widget
  presentation, so it uses `semanticResult`.
- MCP Apps: dedicated tools carry `.episodeRows`, orange
  `light-dark(#9a4300, #ff9f0a)`, and `rootPath: "data"`. Up Next and episode
  rows offer Play Next, Play Last, Star, and destructive-confirmed Archive.
  Context chips read the complete `{schemaVersion, ok, command, data, meta}`
  payload. Preview remains visibly a preview; a submitted write without positive
  read-back becomes amber **Completed with warnings**, never unqualified success.
- Coverage: `OverCTLToolCatalogTests`, catalog parity, registry/update tests,
  MCP Apps server tests, and the browser harness cover recipes, policy,
  persistence, nested rendering, actions, themes, and warnings.

## Iris integration details

`Services/IrisToolPresetCatalog.swift` is the source of truth for `set.iris` /
`preset.iris.*`. `DefaultToolPresetCatalog` mirrors it.

- Category: `ToolCategory.iphone` (title **iPhone**, `iphone` symbol, indigo
  tint in `Views/ToolsView.swift`).
- Surface: eleven dedicated tools plus `iris_run` — battery, now playing,
  calendar day, alarms, alarm set, timer start, open URL, unsent message
  compose, action list, action schema, and doctor. IDs: `iris_battery`,
  `iris_now_playing`, `iris_calendar_day`, `iris_alarms`, `iris_alarm_set`,
  `iris_timer_start`, `iris_open_url`, `iris_message_compose`, `iris_actions`,
  `iris_action_schema`, `iris_doctor`, `iris_run`.
- Discovery: both installed entry points are accepted: `iris` and `iphone`.
- Execution: exact argv, no shell. The four writes (`iris_alarm_set`,
  `iris_timer_start`, `iris_open_url`, `iris_message_compose`) run Iris's
  non-mutating `--dry-run --offline` first. Dedicated tools declare no
  permission requirements. `openWorldHint` is true except `iris_actions` and
  `iris_action_schema` (local manifest reads).
- Boundary: dedicated tools stay non-sensitive. Credential-class reads
  (screen read/capture, clipboard get) and Iris's 13 `--confirm` actions are
  reachable only through `iris_run`, so every such call gets per-call owner
  approval. MacRemote's Approval window is the confirmation; no `--confirm`
  flags appear on dedicated tools. `iris_run` rejects
  `devices pair|authorize|revoke|use`, `transport configure`, and root
  `migrate`, including global-option interleaving. It installs Not Shared and
  carries no explicit widget presentation or `uiActions`.
- MCP Apps: Iris tools use `semanticResult`; none carries richer catalog
  presentation metadata or `uiActions`.
- Coverage: `IrisToolCatalogTests`, catalog parity, registry/update tests,
  `AlwaysAllowPolicyTests`, and scanner category inference cover recipes,
  policy, persistence, and the iPhone category.

## MusicCTL integration details

`Services/MusicCTLToolCatalog.swift` is the source of truth for
`provider.musicctl` / `set.music` / `preset.musicctl.*`.

- Category: `ToolCategory.music` (title **Music**, `music.note` symbol, pink tint
  in `Views/ToolsView.swift`).
- Surface: fifteen dedicated tools plus `musicctl_run` — doctor; catalog/cloud
  search; cloud-library collections, playlists, tracks, listening history, and
  new releases; Music.app status and output routes; and typed player, seek,
  volume, shuffle, repeat, and route-selection writes.
- Discovery: `musicctl`, `mctl`, and `applemusic` resolve to Music before generic
  suffix or keyword inference.
- Execution: exact argv, no shell. Music.app writes run MusicCTL's non-applying
  preview before the identical command adds `--apply`. `musicctl_new_releases`
  scans the complete cloud library and uses a 3,600-second timeout.
- Boundary: on macOS, protected MusicKit, Keychain, and Music.app operations
  route automatically through the signed MusicCTL Capability Host over protocol
  1. It reports role `capability-host` and scope
  `music-app+musickit+keychain`; it does not provide a network proxy. The
  Flexible Command blocks authentication setup, configuration writes,
  onboarding, and raw request commands. It is Destructive, asks every time,
  installs Not Shared, and carries no explicit widget presentation.
- MCP Apps: all MusicCTL tools use `semanticResult`; none carries richer catalog
  presentation metadata or `uiActions`.

## Catalog ownership and refresh (updated 2026-08-28)

The curated Federico Viticci process catalog contains Alexandria, HabitCTL,
PocketCTL, OverCTL, GoodLinksCTL, Apple Frames CLI, Iris, and MusicCTL.
`DefaultToolPresetPublisher` classifies those stable preset prefixes; every
other catalog entry is **Everything Else**. RemCTL and NotesCTL are bridged
MCP providers (`FirstPartyMCPProviderCatalog`), not presets. Matter and Readwise are not catalog integrations. The
generic scanner can still discover either executable and add it as an ordinary
third-party Flexible Command.

- GoodLinksCTL contributes six dedicated tools plus one Flexible Command.
  Cached Markdown reads never download missing content; delete runs a real
  dry-run before the confirmed every-call mutation.
- Apple Frames contributes five dedicated tools plus one Flexible Command.
  Rendering takes absolute paths and asks every time because deterministic
  output files may be overwritten.
- Iris contributes eleven dedicated tools plus one Flexible Command.
  Dedicated recipes stay non-sensitive; screen/clipboard reads and
  `--confirm` actions run only through `iris_run`. Pairing and transport
  management stay blocked.
- MusicCTL contributes fifteen dedicated tools plus one Flexible Command.
  Music.app writes use MusicCTL's preview/apply contract.
- UI: Bundles, Found, Presets, and Tools grouped by Source visibly separate
  **Federico Viticci** from **Everything Else**. The all-catalog bundle remains
  available as an explicit cross-publisher action.
- Installation identity: `DefaultToolPresetInstallationIndex` distinguishes
  **current**, **update available**, **equivalent custom tool**, **adoptable
  scanned tool**, and **not installed**. Stable ID or exact signature still
  prevents duplicate adds. Adoption requires exactly one catalog preset and one
  saved user-defined process tool with scan provenance and the same complete
  execution signature; hand-authored, provenance-free, duplicate, ambiguous,
  and partial-provider matches remain untouched.
- Update from Catalog: `AppModel.updateUserToolsFromCatalog` reconciles a
  complete first-party provider in one transaction: refresh retained IDs, add
  current missing IDs, adopt the unique scan-provenance equivalent, and retire
  obsolete provider-owned IDs. An adoption replaces the scan ID with the stable
  catalog ID, preserves sharing, and clears Always Allow grants for both
  identities. Exact-ID refresh preserves
  semantic ID, permission epoch, sharing state, and unchanged grants. Every
  Flexible Command added from the Library starts Not Shared (`addUserTools`).
  Any failure rolls back tools, sharing, and grants together. A wholly fresh scope has update count
  zero and shows **Add**; any installed, adoptable, or retired representation
  shows **Update from Catalog**, whose count includes refreshes, adoptions,
  additions, and retirements.
- Performance: `DefaultToolPresetCatalog.Storage` caches the launch catalog and
  its lookup indexes. `DefaultToolPresetSet` stores resolved presets. The Tools
  view modifier chain is split into identity-preserving getters to remove the
  previous multi-second Swift type-check hotspot without changing behavior.
  A pinned-SDK LLDB benchmark with the then-current 229-preset catalog measured ten
  preset reads at 22.062 ms including cold initialization, ten preset-set reads
  at 0.025 ms, ten category reads at 0.086 ms, and one full 516-membership
  resolution at 0.044 ms. Three full membership passes took 0.040 ms.
  Clean compiler diagnostics no longer report `ToolsView.body` above 100 ms
  (previously 5.88–6.21 s).

## Upstream sign-in for imported HTTP MCP servers (added 2026-09-16)

Spec: DESIGN-SPEC D62. Some local MCP servers (Paste 2.x) protect their HTTP
endpoint with OAuth instead of a static token. MacRemote signs in to them
itself, the way Codex and Claude Code do.

- Client: `Services/MCPUpstreamOAuth.swift`. `MCPUpstreamOAuthClient.discover`
  reads `/.well-known/oauth-protected-resource` (with the MCP path first, then
  the root) and the authorization server's `/.well-known/oauth-authorization-server`
  or `/.well-known/openid-configuration`. Discovery refuses metadata that
  names a different issuer than the one it was fetched for, refuses endpoints
  that are neither HTTPS nor on this Mac, and ignores a protected-resource
  document for another origin. `signIn` requires PKCE S256, opens
  `MCPUpstreamOAuthRedirectListener` on a free `127.0.0.1` port, registers a
  public client (`token_endpoint_auth_method: none`) with that exact redirect
  URI, opens the authorization URL through the injected `openURL`, waits up to
  five minutes for `GET /callback`, checks `state`, and exchanges the code with
  `code_verifier` and `resource`. The wait ends at the timeout or when the
  sign-in is cancelled, and the listener closes either way. `refresh` runs
  only when the server issued a refresh token, and callers that overlap for
  one server share one exchange (`MCPUpstreamOAuthStore.refreshOnce`);
  `accessToken(for:)` refreshes an expired token; `forget` drops a token a 401
  proved dead; `signOut` revokes when the server offers `revocation_endpoint`,
  then forgets. Each sign-in request has a 30-second deadline and a 1 MiB
  response limit.
- Store: `MCPUpstreamOAuthStore` — one Keychain item per normalized server URL
  (service `MacRemote.upstream-mcp-oauth`), memoized in memory, read
  non-interactively. `InMemoryKeychainSecretStore` backs tests.
- Model: `MCPBridgeHeaderValueSourceKind.oauth` and
  `MCPBridgeHeader.upstreamOAuthAuthorization`. The kind enters the security
  fingerprint and the canonical runtime identity like any other binding, so a
  family that moves from a manifest token to MacRemote's sign-in asks again.
  The validator accepts the kind only on `Authorization`; stdio environment
  variables never carry it.
- Bridge: `MCPHTTPBridgeClient` resolves the header from the store and retries
  a 401 once after a refresh. With no refresh token, or when the server refuses
  it, the bridge forgets the token and fails the call with "Sign in to ‹server›
  in MacRemote › Tools to use its tools." A refresh that fails because the
  server or the network did leaves the sign-in in place. Every bridged HTTP
  call runs under one deadline equal to the tool's timeout (`withDeadline` in
  `Support/Deadline.swift`), and one response is capped at 32 MiB
  (`MCPHTTPResponseBody.data`).
- Scanner: `LocalMCPScanner.probe` turns a 401 into
  `LocalMCPScannerError.signInRequired` when the candidate already uses the
  sign-in (forgetting the dead token) or when the server publishes OAuth
  metadata. `scan` records it as `candidate.needsSignIn`.
  `LocalMCPServerCandidate.signedInWithMacRemote()` replaces any configured
  `Authorization` binding with the sign-in; `bridgeTools(preferredServerName:)`
  lets a refresh keep the imported family's name when the config row spells it
  differently (`paste` vs "Paste"), and legacy-family matching in `AppModel`
  compares names case-insensitively for the same reason.
- AppModel: `mcpSignInServerID`, `mcpSignInErrorMessage`,
  `isMCPServerSignedIn(serverURL:)`, `signInToMCPServer(candidateID:)` (sign in,
  re-check, refresh an already-imported family), `signOutOfMCPServer(candidateID:)`,
  `checkMCPServer(candidateID:)` (the read-only HTTP check a server page runs
  on open; `localMCPCheckingServerID` while it runs). An import that gets
  "sign in first" marks the candidate `needsSignIn` instead of reporting an
  import failure.
- Tests: `Tests/MacRemoteTests/MCPUpstreamOAuthTests.swift` (real loopback
  listener, mocked server).

## Automatic discovery (added 2026-07-04)

Spec: DESIGN-SPEC LM-19…LM-22, decisions D21 and D54. No auto-import or auto-share, and
no subprocess/network on the automatic path. The same config-only pass also
removes previously imported families whose readable source no longer defines
their server; configured-but-offline servers are preserved.

- Config paths: `Services/MCPConfigLocator.swift` (single source of truth for
  scanner paths + `configSnapshot(homeDirectory:)` freshness fingerprint).
- Scanner: `LocalMCPScanner.scan(..., includeRuntimeSources:)` — quiet refresh
  passes `includeRuntimeSources: false` and `probe: false`.
  `configuredCandidatesForReconciliation()` returns the raw, non-deduplicated
  ownership view. The displayed scan deduplicates by a credential-safe canonical
  runtime identity derived from transport plus its complete binding descriptor;
  source labels do not enter that identity, while arguments, environment, and
  headers do. Equivalent Codex and Claude entries therefore become one candidate
  with multiple `MCPDiscoveryOwner` claims, but different credentials or runtime
  arguments remain different candidates.
- Models: `DiscoveryFreshness`, `LocalMCPScanCache` (persisted at
  `~/Library/Application Support/MacRemote/mcp-scan-cache.json` — hashed
  seen-set + config snapshot only; raw URLs never hit disk).
- AppModel: `startAutomaticDiscovery()`, `refreshLocalMCPDiscovery(trigger:)`,
  `reconcileImportedMCPTools(with:)`, `localMCPFreshness`, `cliFreshness`,
  `newUnimportedMCPCandidateCount`. Reconciliation requires explicit persisted
  config ownership. Import/Refresh matches an existing row through owner
  intersection before runtime identity, so an owner whose endpoint, argv, or
  environment changed keeps the semantic IDs and permission epochs while the
  changed security fingerprint asks again. Reconciliation removes a family only
  after every readable non-manual owner is absent; provenance-less legacy rows
  remain until a selected Import/Refresh stamps them.
  Wired from `MacRemoteApp` `.task`. Activation observer debounces 5 s.
- UI: Tools MCP area (LM-19 stale line, LM-20 New chip, LM-3 summary), Tools
  sidebar badge (LM-21), CLI Found tab stale banner (`cliFreshness`). The badge
  help/accessibility text says the count is new MCP servers to review and that
  nothing was imported automatically; it never becomes an approval escalation.
- Tests: `Tests/MacRemoteTests/AutomaticDiscoveryTests.swift`.

## File Transfer & artifacts (added 2026-07-05)

Spec: DESIGN-SPEC decisions D22–D24, parity FT-1…FT-6. First native tool
backend (`ToolBackend.native`) — no subprocess.

- Catalog: `Services/FileTransferToolCatalog.swift` — seven `filesystem_*` tools
  (`filesystem_stat`, `filesystem_list_tree`, `filesystem_find`, `filesystem_read_file`,
  `filesystem_write_file`, `filesystem_download_file`,
  `filesystem_download_zip`), placeholder `executablePath` `/usr/bin/true`, empty argv,
  `origin .builtIn`, `category .filesystem`, `backend .native`. `write_file` is
  `capability .write`; the rest read-only.
- Executor: `Services/NativeToolExecutor.swift` — dispatches on
  `NativeToolIdentifier` (`Models/ToolDefinition.swift`), returns the same
  `ToolExecutionOutcome` envelope. Chunked reads, base64 by default or text with
  `encoding: "utf8"` (1 byte...16 KiB so the
  complete native JSON and duplicated MCP text fallback stay below common
  64 KiB client transport limits), list depth
  ≤5 / ≤2000 entries, `download_zip` uses `/usr/bin/tar` argv (no shell):
  it sums the source sizes first (`totalSize`, 512 MiB cap), then zips in
  place into an `ArtifactStore` reservation, with no staging copy.
  `filesystem_find` uses `Services/FileNameSearch.swift`: `walk` reads a named
  folder with `getattrlistbulk` and skips protected entries; `spotlight` asks
  Spotlight within the allowed folders and re-checks every result against the
  policy.
- Path policy: `Services/FileTransferPathPolicy.swift` — a path is reachable
  only inside `allowedFolders` (default Desktop, Documents, Downloads) and never
  inside `protectedFolders`; both tests compare file identity. Paths with `..`
  are refused. `reasonFolderCannotBeAllowed` refuses only a folder that does
  not exist or is protected, so the owner may allow `/` (Allow Whole Mac,
  `reachesWholeMac`). `isProtected(path:)` filters listings and
  `containsProtectedFolder` refuses archives. `NativeToolExecutor.validatePaths`
  runs the same checks before approval. `resolveRelativePath` guards the
  `download_zip` multi-path form.
- Artifacts: `Services/ArtifactStore.swift` — every staged file lives under one
  folder, `<tmp>/MacRemoteStaging/` (`ArtifactStore.stagingRoot`): downloads in
  `<artifact-uuid>/` subfolders and `ProcessRunner` output spools beside them.
  `MacRemoteApp.init` empties it at launch. A store deletes only its own
  subfolders, so one server's purge cannot remove another store's files.
  256-bit base64url token, streamed SHA-256, 600 s expiry (a timer deletes the
  file then), 3 downloads, 512 MiB per download, 2 GiB for all staged downloads
  together (`stagingFull`). `reserve` → write → `commit`/`discard` keeps the
  copy and the hash outside the lock; `resolve` (HEAD) vs `consume` (GET);
  `purgeAll()` on server stop. A GET is read from disk and sent in 256 KiB
  pieces (`FileBody`), never loaded whole. Route + `download_url`
  injection live in `LocalMCPServer` (`artifactResponse`, `.artifact`
  rate-limit group, `augmentStructuredContentWithArtifactDownloadURL`, applied
  only when `tool.backend == .native`).
- MCP surface: `tools/list` returns the **entire** shared catalog in one
  response with no `nextCursor` (cursor pagination was removed 2026-07-05,
  decision D30 — Raycast/Minis/Claude.ai fetch only the first page and ignored
  `nextCursor`, silently hiding every tool past 60). An unsolicited `cursor`
  param is ignored, never a `-32602`. A present-but-rejected bearer gets RFC
  6750 `error="invalid_token"` in the `WWW-Authenticate` challenge. D33 adds the
  deterministic revision, compact `macremote://catalog/v1` resource, and
  structured unknown-tool recovery without changing this full-list contract.
- AppModel: `builtInCatalogTools` (never persisted), `allTools`
  (= built-in + user), private `artifactStore` shared into the server and
  `ConfiguredToolExecutor`; purged on stop. Default-Not-Shared via the
  first-seen set `seenBuiltInFileTransferToolIDsKey`, DL-2 pattern. Views bind to `allTools`; the "Built-in" source group in
  `ToolsView` shows them; `ToolInspector.BuiltInDefinitionView` renders them
  read-only and shows "Runs natively in MacRemote" for `backend == .native`.
- Tests: `Tests/MacRemoteTests/FileTransferToolTests.swift`,
  `ArtifactStoreTests.swift`, plus full-catalog `tools/list` and
  `invalid_token` coverage in `LocalMCPServerTests.swift`, token-lifetime
  coverage in `OAuthCoordinatorTests.swift`.

## Reliability & MCP conformance (added 2026-07-05; updated 2026-07-29)

Spec: DESIGN-SPEC decisions D25–D29, D36, and D41. Reliability + protocol hardening
that landed after three iOS-client stress runs crashed the server. Nothing here
is a new user-facing page — these are runtime/behavior changes to how the
in-process server survives hostile or heavy remote traffic.

- Process hardening (`Services/ProcessRunner.swift`): stdout/stderr drain on
  two threads of their own (fixes a single-pipe fill/deadlock without holding
  Swift's async threads); `Process` starts the child as its own process-group
  leader, so timeout and cancellation kills reach the whole group via
  `kill(-pid, …)`, plus a process-tree walk and a direct-pid signal; the kill
  escalates SIGTERM → (2 s) → SIGKILL, and a group member that ignored SIGTERM
  is killed even when the tool itself already exited. Stdin is `/dev/null`
  unless a tool passes explicit `standardInput`. Tool environment
  (`Support/ExecutableLocator.toolEnvironment`) pins `PAGER`/`MANPAGER`/
  `GIT_PAGER=cat` and `TERM=dumb` so a child never blocks on a pager, and
  passes `TMPDIR`, `USER`, and `LOGNAME` so a tool gets this Mac's per-user
  temporary folder.
- Missing executable contract (`ToolArgumentResolver.validate(_:)` plus
  `ProcessRunner` launch-error mapping): first-party CLIs remain optional. A
  missing, non-executable, or invalid executable fails that call as
  `isError:true` with `reason:"unavailable"`; the user-facing message asks the
  owner to install or restore the command without returning the configured path,
  working directory, or launch exception. The server and unrelated tools stay
  available.
- Execution limiter (`Services/ToolExecutionLimiter.swift`, D25): `actor` with
  `maxConcurrentExecutions = 8`, `withSlot(timeout:)` (default 3 s). Acquired in
  `LocalMCPServer` **around `toolExecutor.execute` only**, *after* the approval
  await — so a pending approval never occupies a slot. Saturation →
  `toolExecutionError(tool:reason:message:)` with `reason: "unavailable"`.
- MCP error model (`Services/LocalMCPServer.swift`, D26): tool-execution
  failures are `isError:true` results carrying a `reason` on
  `structuredContent`; the `reason` enum is declared in `outputSchema()`
  (`ok / nonzero_exit / timeout / output_limit / killed / invalid_argument /
  not_approved / unavailable / internal_error` — `killed` is reserved in the
  schema; `internal_error` reports a post-execution preservation failure).
  `executionReason(for:…)` maps a
  finished run; `toolExecutionError` maps pre-execution failures
  (`unavailable`, `not_approved`) and `ToolValidationError.callToolReason`
  (`invalid_argument`, or `unavailable` for
  unavailable/blocked/write-disabled/identity-changed). JSON-RPC errors are
  reserved for the envelope (`-32600/-32700/-32601/-32602/-32603`, in
  `mcp`/`dispatchMCP`/`callTool`/`toolsList`); unknown notifications and
  `notifications/cancelled` return `202` with no body. Protocol versions
  supported: modern `2026-07-28`; legacy `2025-11-25`, `2025-06-18`, and
  `2025-03-26`. This does not claim complete 2026 OAuth conformance: CIMD
  remains deferred and unadvertised.
- Numeric parsing (D29): `ToolArgumentValue.integerString(from:)`
  (`Models/ToolDefinition.swift`) and `NativeToolExecutor` route every JSON
  number→Int through `Int(exactly:)` after an `isFinite` guard; out-of-range
  values surface `invalidInteger`/`invalid_argument` instead of trapping the
  in-process server.
- Bridge result normalization (D36):
  `Services/MCPBridgeToolResultNormalizer.swift` is shared by HTTP and stdio
  bridge clients. It places the assistant-visible upstream semantic payload in
  `stdout`: `structuredContent` first, otherwise a sole assistant-visible text
  block, otherwise the assistant-visible content-block array. User-only blocks
  retain their original audience annotations but never enter unannotated
  stdout. A bare JSON text fallback structurally equal to
  `structuredContent` is omitted. Other distinct, annotated, or multimodal
  blocks remain real outer MCP content. A bridge-only lossless JSON value keeps
  booleans distinct from numeric 0/1 and preserves 64-bit integer precision.
  Upstream `_meta` and nonstandard top-level fields use collision-safe
  MacRemote result-meta namespaces. `LocalMCPServer` spills oversized
  assistant-visible content, user-only content, and hidden metadata into
  separate artifacts. Both content links retain their audience; the hidden
  metadata pointer is available only under outer `_meta`. The configured tool output limit
  remains a hard cap: context over that cap is omitted atomically with
  `reason: "output_limit"` and an explicit stderr diagnostic. Upstream `isError` maps
  to exit 1 while retaining the payload and context; the same outer MacRemote
  envelope and `reason` schema still applies to every backend.
- Large-output spill (D27): `ProcessRunner.collectStdout` retains an inline head
  and starts a mode-`0600` spool once retained stdout exceeds 100,000 bytes. The
  MCP envelope keeps at most 48,000 UTF-8 bytes of stdout and is capped at
  120,000 bytes overall; `registerStdoutArtifact` registers the complete bounded
  spool and appends a `resource_link`, size, and SHA-256. A fully preserved
  stream keeps `reason: "ok"` even when `truncatedStdout` says the inline field is
  only a head. `output_limit` means the configured hard cap lost bytes;
  preservation failure is `internal_error` without changing the authoritative
  process exit status. Download-tool payloads still get a `download_url` via
  `augmentStructuredContentWithArtifactDownloadURL` and a matching
  `resource_link` whose `mimeType` follows the declared filename.
- Tunnel watchdog (`Services/TunnelWatchdog.swift`, D28): health-checks the
  local origin (`/health`) and the tunnel process; `handleUnexpectedFailure` /
  the health monitor drive `runRecoveryLoop` with
  `TunnelWatchdogBackoff.delay` (initial 1 s, ×2, cap 32 s, ceiling 5). Wired in
  `AppModel.makeTunnelWatchdog` — `onReconnecting` sets
  `TunnelStatus.reconnecting(attempt:)` (`Models/RuntimeState.swift`, title
  "Reconnecting", `isRecovering == true`), `onRecoveryFailed` surfaces the
  failure; `shouldIgnoreStoppedEvent()` suppresses the controlled-stop event so
  Stop Sharing is never mistaken for a crash. The hero renders reconnecting as
  `.publicPending`; the readiness card shows "Reconnecting public link
  (attempt N)."
- Filesystem preset dedupe: `preset.filesystem.file_info` and
  `preset.filesystem.read_head` were removed from
  `Models/DefaultToolPresetCatalog.swift` (superseded by the native
  `filesystem_*` tools, D22). No `tools.json` migration — presets are templates,
  so already-added user tools are untouched.
- Stress harness: `Tests/MacRemoteTests/StressHarnessServer.swift` — one inert
  `@Test` (returns immediately unless `MR_STRESS_HARNESS=1`) that stands up a
  loopback `LocalMCPServer` with Single-Header auth and five stress tools
  (`stress_echo`, `stress_cat_stdin`, `stress_bigout`, `stress_sleep`,
  `stress_typed`), writing its endpoint JSON for an
  external driver. Python driver in `Tools/stress/` (`mcp_client.py`,
  `run_category.py`).
- Tests: `ToolExecutionLimiterTests`, `TunnelWatchdogTests`,
  `ProcessRunnerTests`, `ArtifactStoreTests`, plus error-model/`reason`-code and
  spill coverage in `LocalMCPServerTests`. The stress harness contributes one
  inert test during an ordinary run.

## Reminder cards and quiet helper calls (2026-10-01)

`ToolWidgetPresentation.automatic` is an optional catalog opt-out from automatic
MCP UI linkage. `FirstPartyMCPProviderCatalog` suppresses
RemCTL intermediate lookups, diagnostics, and the flexible command; typed
reminder reads and writes retain the shared v7 widget. The provider resolves
row actions against the imported family, including disambiguated IDs.
`LocalMCPServer` supplies reminder date, section, partial and batch-change hints.
The HTML accepts standard results, text-fallback envelopes, and additive
ChatGPT compatibility data, and restricts Run again to read-only tools.
See `MCP-UI-SPEC.md` for the revised linkage decision and rendering boundaries.
