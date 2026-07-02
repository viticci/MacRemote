# MacRemote — Implementation Map (as built)

> Companion to `DESIGN-SPEC.md` (what each screen does) and `DESIGN-GUIDELINES.md`
> (tokens, components, glass, copy). This file is the **as-built architecture**:
> where things live and how the pieces connect, so an agent can navigate the code
> without re-deriving it. Produced alongside the 2026-07-01 redesign
> implementation. When code and this file disagree, fix whichever is wrong in the
> same change.

## Build & run

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift test   # Swift Testing, 195 tests
script/build_and_run.sh              # builds (auto-pins SDK), signs, relaunches dist/MacRemote.app
script/build_and_run.sh --build-only # build without killing a running instance / its tunnel
```

See `AGENTS.md` for why the SDK pin is mandatory (CLT 6.4, no Xcode: broken 27
SDK `@State` macro + no XCTest). `Package.swift` targets `.macOS(.v26)` and
carries path-guarded CLT test-linking workarounds.

## Scenes (`App/MacRemoteApp.swift`)

Window IDs are centralized in `MacRemoteWindowID` (`Models/NavigationSection.swift`).

| Scene | ID | Notes |
|---|---|---|
| Main window | `MacRemoteWindowID.main` | `NavigationSplitView`; system glass sidebar + detail. Min 1040×680. Installs `AppSkeletonInstaller` (wires `appModel.windowOpener`, the AppDelegate quit bridge, and first-run Welcome). |
| Approval window | `MacRemoteWindowID.approval` | Floating, `.windowLevel(.floating)`, hidden title bar, `.contentSize`. **Non-activating** — presented via `AppModel.presentApprovalWindow()` (decision D4). `ApprovalWindowConfigurator` (NSViewRepresentable) adds all-Spaces + full-screen-auxiliary collection behavior and `hidesOnDeactivate = false`. |
| Welcome window | `MacRemoteWindowID.welcome` | Fixed 760×560, first run only (gated on `hasCompletedWelcome`), reopenable from Help. |
| Settings | `Settings` scene (⌘,) | The **only** settings surface (no sidebar Settings section). Toolbar-tab `TabView`: General / Notifications / Security. |
| MenuBarExtra | — | `.menuBarExtraStyle(.menu)`, toggled by `appModel.isMenuBarExtraEnabled`. Status line + Copy URL + server verbs + "N requests waiting…" (opens the Approval window, never resolves inline — D3). Glyph rendered by `MenuBarIconRenderer` as a template `NSImage` so the badge dot survives menu-bar tinting. |

Menu commands live in `MacRemoteCommands` (same file): Server (⌘R/⌘./⇧⌘R/⇧⌘./⇧⌘C,
test runners ⌘T/⌥⌘T/⌃⌘T), File (⌘N/⇧⌘N/⇧⌘L), Edit ▸ Find (⌘F), View ▸ sections
(⌘1–⌘5) + Inspector (⌥⌘I), Requests (⌘⏎/⌥⌘⏎/⌘⌫ acting on the frontmost pending
interrupt), Help (Welcome, Connection Testing Guide).

## Navigation (`Models/NavigationSection.swift`, `Views/ContentView.swift`, `Views/SidebarView.swift`)

Five sections, single-line sidebar labels, one numeric badge (Requests) + one
failure dot (Connection):

| Section | Symbol | ⌘ | Detail view |
|---|---|---|---|
| Connection | `dot.radiowaves.left.and.right` | ⌘1 | `ConnectionView` |
| Tools | `wrench.and.screwdriver` | ⌘2 | `ToolsView` |
| Apps | `app.badge.checkmark` | ⌘3 | `AppsView` |
| Requests | `hand.raised` | ⌘4 | `RequestsView` |
| Activity | `waveform.path.ecg` | ⌘5 | `ActivityView` |

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
| `ConnectionReadinessCard.swift` | Real `SmokeReadiness` 6-check card; rows expandable in every state (D1) | §4.2 |
| `ConnectionAddressCard.swift` | Instant Link / Your Domain, `DeployStageList`, token field | §4.3 |
| `ConnectionVerifyCard.swift` | Quick/Full test, Test a Tool…, Copy Test Commands, Testing Guide | §4.4 |
| `ToolsView.swift` | Unified tool List: filter chips, Group By, category + MCP-server groups, Scan, Add ▾ | §5.1 |
| `ToolInspector.swift` | `.inspector` — Overview/Definition/Permissions/Activity tabs + Test/Duplicate/Remove | §5.1 |
| `ToolLibrarySheet.swift` | Bundles / Found on This Mac / Presets / Custom | §5.1 |
| `AppsView.swift` | `AppCard` per connected app + per-category policy groups | §5.2 |
| `RequestsView.swift` | Pending (`ApprovalCard` inline) + session history + Deny-All bar | §5.3 |
| `ApprovalCard.swift` | The approval anatomy (actor/capability/scope/countdown); window + inline + onboarding variants | §5.4 |
| `ApprovalWindowView.swift` | Floating-window host; "1 of N" paging over `pendingInterrupts` | §5.4 |
| `ActivityView.swift` | Log list, level + Events/Everything filters, Export/Copy/Clear | §5.5 |
| `SettingsView.swift` | General / Notifications / Security panes | §5.6 |
| `WelcomeView.swift` | Five-screen onboarding; reuses ConnectionHero + ApprovalCard + AccessFixer | §3 |

## Design system (`Views/DesignSystem/`) — replaces the old `SharedViews.swift`

- `Tokens.swift` — `Space` (spacing scale), `TypeRamp` (text-style helpers,
  e.g. `heroStatus`, `rowDetail`, `truthNote`), semantic color roles, concentric
  radii. **The only source of spacing/type/color.**
- `Components.swift` — `StatusOrb`, `StatChip`, `StateChip`, `Card` (collapsed-
  summary variant), `KeyValueGrid`/`KeyValueRow`, `CopyButton` (writes pasteboard
  + calls injected audit closure), `MonoValue`, `CountdownRing`, `ActivityLogRow`,
  `EmptyState` (ContentUnavailableView wrapper), `DetailsDisclosure` (+ ⌥-click
  expand-all via `DetailsExpandAll`).
- `Checklists.swift` — `DeployStageList` (five named Cloudflare deploy stages),
  `SetupChecklist` (self-retiring, D16).
- `AccessFixer.swift` — `TargetRow`, `AccessFixerActions` (all six troubleshoot
  actions injected as closures), `AccessFixer`. One component, three hosts: the
  app-global FDA sheet, the Connection Readiness FDA expansion, onboarding S3.

All design-system components are **pure** (data injected via init; no
`@Environment(AppModel.self)`) so they work in the main window, the floating
Approval window, and onboarding alike.

## AppModel (`Stores/AppModel.swift`) — key API the views bind to

`@MainActor @Observable`. Selected surface added/changed by the redesign:

- Navigation/scenes: `selection`, `windowOpener`, `presentApprovalWindow()`,
  `openMainWindow()`, `hasCompletedWelcome`, `readinessRowToExpand` +
  `revealReadinessRow(_:)` / `clearReadinessRowToExpand()`, `openTestingGuide()`,
  `focusSearchField()`.
- Approvals (frontmost-interrupt model, D4): `frontmostPendingInterrupt`,
  `pendingRequestCount`, `canAlwaysAllowFrontmostPendingRequest`,
  `approve/deny/alwaysAllowFrontmostPendingRequest()`.
- Quit gate (D2.6): `shouldConfirmQuit`, `prepareForConfirmedQuit()` (called from
  `AppDelegate.applicationShouldTerminate`).
- Menu bar: `isMenuBarExtraEnabled`, `menuBarStatusLine`.
- Tools: `updateUserTool(id:draft:)` (**transactional**, D8 — preserves tool ID,
  rewrites Always Allow grants, rolls back on failure; covered by
  `AppModelToolUpdateTests`), `runToolTest(toolID:parameters:)`, `requestNewTool()`,
  `requestAddFromLibrary()`, `isToolInspectorPresented`.
- Notifications: `refreshNotificationPermissionStatus()`,
  `requestNotificationPermission()`, `notificationPermissionStatus`. Guarded
  behind a bundle check — no-ops under `swift run`/`swift test` (UNUserNotification
  crashes unbundled).
- Credentials: `oauthClientCredentials`, `lockedOAuthClientIDs` /
  `hasLockedOAuthCredentials`, `unlockOAuthCredentials()` — see next section.

`NSApp` is nil in test processes; the window/dock/notification helpers guard it.
Do not remove those guards.

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

## Connector icon (`Services/LocalMCPServer.swift`, `Resources/`)

Goal: MacRemote's icon in Claude.ai when its URL is added as a custom connector.
Research (`scratchpad/design/research-mcp-icon.md`, `claude-ai-mcp#152`): **as of
mid-2026 Claude.ai ignores MCP `serverInfo.icons` for remote connectors** and
renders the **Google favicon-service result for the connector URL's registrable
domain**. App-side is fully wired regardless:

- Routes: `GET /` (branded landing page whose `<head>` carries the favicon link
  tags Google's fetcher parses), `/favicon.ico` (lean multi-size ≈7.7 KB),
  `/favicon.png` (32px), `/macremote-icon.png` (512px), `/macremote-icon-128.png`.
- `serverInfo` (in the `initialize` result) carries `description`, `websiteUrl`,
  and a 3-entry `icons` array (128px + 512px URLs + a 64px `data:` URI hedge that
  needs no fetch) — spec-correct for the day Claude honors SEP-973.
- Resources: `AppIconSource.png` (1024, source of truth), `MacRemoteConnectorIcon
  {,128,64}.png`, `Favicon.{ico,png}`. Regenerate lean assets from the source with
  Pillow if the icon changes.

**Not yet done (infrastructure, needs the domain owner):** for
`macremote.viticci.net` connectors the icon only appears once `viticci.net`'s apex
serves the MacRemote favicon (the apex currently returns 530). Oracle to re-test:
`curl "https://www.google.com/s2/favicons?domain=viticci.net&sz=32"` — a 726-byte
globe means still-broken. Re-adding the connector in Claude.ai re-resolves the icon.

## Testing

Swift Testing (`import Testing`), 195 tests / 21 suites. Two suites are
`.serialized` (`CloudflareServiceTests`, `LocalMCPServerTests`) because they share
mock statics / bind ports and race under Swift Testing's default parallelism.
New suites from the redesign: `AppModelToolUpdateTests` (transactional tool edit),
`ApprovalCardArgumentParsingTests` (argument/`stdin` rendering).

## CLI discovery (added 2026-07-02)

Spec: `docs/design/CLI-DISCOVERY-SPEC.md` (binding decision log DL-1…DL-18 + security
rules). Spine: **FOUND ≠ ADDED ≠ SHARED ≠ TRUSTED.**

- Scanner: `Services/LocalCLIScanner.swift` + helpers (`HomebrewCatalogIndex`,
  `ManPageNameParser`, `CodeSignatureReader`, `CLIHarvestedTextSanitizer`,
  `CLIRecommendationBlocklist`, `CLIBinaryInspector`, `CLICategoryInference`).
  **Zero-execution is falsifiable**: no `Process`/`URLSession`/`NSTask` in any of
  these files — grep before review. Sources: Homebrew receipts + JWS catalog
  caches, npm `package.json`, uv/pipx/pip dist-info, cargo/go records, man-page
  NAME sections, static code signatures, quarantine xattrs.
- Models: `DiscoveredCLICandidate`, `CLIScanState` (persisted seen-set drives
  "New since last scan"); `ToolProvenance` on `ToolDefinition` (Codable
  back-compat with pre-provenance tools.json).
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
- Catalog: 136 presets (new AI & Agents category, Readwise replaced Matter,
  ~17 new detection-gated presets, 20 safety/copy fixes); `script/macremotectl`
  mirrors the catalog and the blocklist (`BLOCKED_EXECUTABLES`).
- Tests: 300 in 29 suites (fixtures under `Tests/MacRemoteTests/Fixtures/CLIDiscovery/`).
