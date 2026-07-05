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
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift test   # Swift Testing, 449 tests
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
| Settings | `Settings` scene (⌘,) | The **only** settings surface (no sidebar Settings section). Toolbar-tab `TabView`: General / Notifications / Security. Security also hosts the D24 token-lifetime pickers (access / refresh). |
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
  `requestAddFromLibrary()`, `isToolInspectorPresented`, `builtInCatalogTools`
  (native File Transfer group, never persisted), `allTools` (= built-in + user).
- Token lifetimes (D24): `oauthAccessTokenTTLSeconds` /
  `setOAuthAccessTokenTTLSeconds(_:)`, `oauthRefreshTokenTTLSeconds` /
  `setOAuthRefreshTokenTTLSeconds(_:)` — bound by the Settings › Security pickers.
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

Swift Testing (`import Testing`), 449 tests / 42 suites. Two suites are
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

## Automatic discovery (added 2026-07-04)

Spec: DESIGN-SPEC LM-19…LM-22, decision D21. **Surfacing only** — no auto-import,
no auto-share, no subprocess/network on the automatic path.

- Config paths: `Services/MCPConfigLocator.swift` (single source of truth for
  scanner paths + `configSnapshot(homeDirectory:)` freshness fingerprint).
- Scanner: `LocalMCPScanner.scan(..., includeRuntimeSources:)` — quiet refresh
  passes `includeRuntimeSources: false` and `probe: false`.
- Models: `DiscoveryFreshness`, `LocalMCPScanCache` (persisted at
  `~/Library/Application Support/MacRemote/mcp-scan-cache.json` — hashed
  seen-set + config snapshot only; raw URLs never hit disk).
- AppModel: `startAutomaticDiscovery()`, `refreshLocalMCPDiscovery(trigger:)`,
  `localMCPFreshness`, `cliFreshness`, `newUnimportedMCPCandidateCount`.
  Wired from `MacRemoteApp` `.task`. Activation observer debounces 5 s.
- UI: Tools MCP area (LM-19 stale line, LM-20 New chip, LM-3 summary), Tools
  sidebar badge (LM-21), CLI Found tab stale banner (`cliFreshness`).
- Tests: `Tests/MacRemoteTests/AutomaticDiscoveryTests.swift`.

## File Transfer & artifacts (added 2026-07-05)

Spec: DESIGN-SPEC decisions D22–D24, parity FT-1…FT-6. First native tool
backend (`ToolBackend.native`) — no subprocess.

- Catalog: `Services/FileTransferToolCatalog.swift` — six `builtin.fs.*` tools
  (`stat`, `list_tree`, `read_file`, `write_file`, `download_file`,
  `download_zip`), placeholder `executablePath` `/usr/bin/true`, empty argv,
  `origin .builtIn`, `category .filesystem`, `backend .native`. `write_file` is
  `capability .write`; the rest read-only.
- Executor: `Services/NativeToolExecutor.swift` — dispatches on
  `NativeToolIdentifier` (`Models/ToolDefinition.swift`), returns the same
  `ToolExecutionOutcome` envelope. Chunked base64 reads (≤64 KiB), list depth
  ≤5 / ≤2000 entries, `download_zip` uses `/usr/bin/ditto` argv (no shell).
- Path policy: `Services/FileTransferPathPolicy.swift` — tilde expansion,
  absolute-path-only, symlink-resolved denylist. `resolveRelativePath` guards
  the `download_zip` multi-path form against `..` traversal.
- Artifacts: `Services/ArtifactStore.swift` — staged copies under
  `<tmp>/MacRemoteArtifacts/<uuid>/`; 256-bit base64url token, streamed
  SHA-256, 600 s expiry, 3 downloads, 512 MiB cap; `resolve` (HEAD) vs
  `consume` (GET); `purgeAll()` on server stop. Route + `download_url`
  injection live in `LocalMCPServer` (`artifactResponse`, `.artifact`
  rate-limit group, `augmentStructuredContentWithArtifactDownloadURL`).
- MCP surface: `tools/list` gains cursor pagination only past
  `toolsListPageSize` (60) — base64 JSON `{offset,count}` cursor, `-32602`
  "Invalid cursor." on malformed. A present-but-rejected bearer now gets RFC
  6750 `error="invalid_token"` in the `WWW-Authenticate` challenge.
- AppModel: `builtInCatalogTools` (never persisted), `allTools`
  (= built-in + user), private `artifactStore` shared into the server and
  `ConfiguredToolExecutor`; purged on stop. Default-Not-Shared via the
  first-seen set `seenBuiltInFileTransferToolIDsKey` (+ legacy-flag migration),
  DL-2 pattern. Views bind to `allTools`; the "Built-in" source group in
  `ToolsView` shows them; `ToolInspector.BuiltInDefinitionView` renders them
  read-only and shows "Runs natively in MacRemote" for `backend == .native`.
- Tests: `Tests/MacRemoteTests/FileTransferToolTests.swift`,
  `ArtifactStoreTests.swift`, plus `tools/list` pagination and
  `invalid_token` coverage in `LocalMCPServerTests.swift`, token-lifetime
  coverage in `OAuthCoordinatorTests.swift`.

## Reliability & MCP conformance (added 2026-07-05)

Spec: DESIGN-SPEC decisions D25–D29. Reliability + spec-conformance hardening
that landed after three iOS-client stress runs crashed the server. Nothing here
is a new user-facing page — these are runtime/behavior changes to how the
in-process server survives hostile or heavy remote traffic.

- Process hardening (`Services/ProcessRunner.swift`): stdout/stderr drain on
  two detached `Task`s (fixes a single-pipe fill/deadlock); child is made its
  own process-group leader (`setpgid`) so timeout kills reach the whole tree via
  `kill(-pid, …)`, with a direct-pid signal as the race-free backstop; timeout
  path escalates SIGTERM → (2 s) → SIGKILL. Stdin is `/dev/null` unless a tool
  passes explicit `standardInput`. Tool environment
  (`Support/ExecutableLocator.toolEnvironment`) pins `PAGER`/`MANPAGER`/
  `GIT_PAGER=cat` and `TERM=dumb` so a child never blocks on a pager.
- Execution limiter (`Services/ToolExecutionLimiter.swift`, D25): `actor` with
  `maxConcurrentExecutions = 8`, `withSlot(timeout:)` (default 3 s). Acquired in
  `LocalMCPServer.callTool` **around `toolExecutor.execute` only**, *after* the
  approval await — so a pending approval never occupies a slot. Saturation →
  `toolExecutionErrorResult(reason: "unavailable", …)`.
- MCP error model (`Services/LocalMCPServer.swift`, D26): tool-execution
  failures are `isError:true` results carrying a `reason` on
  `structuredContent`; the `reason` enum is declared in `outputSchema()`
  (`ok / nonzero_exit / timeout / output_limit / killed / invalid_argument /
  not_approved / unavailable / internal_error` — `killed`/`internal_error` are
  reserved in the schema, not yet emitted). `executionReason(for:…)` maps a
  finished run; `toolExecutionErrorResult` maps pre-execution failures
  (`unavailable`, `not_approved`) and `ToolValidationError.callToolReason`
  (`invalid_argument`, or `unavailable` for
  unavailable/blocked/write-disabled/identity-changed). JSON-RPC errors are
  reserved for the envelope (`-32600/-32700/-32601/-32602/-32603`, in
  `handleMCPMessage`/`callTool`/`toolsList`); unknown notifications and
  `notifications/cancelled` return `202` with no body. Protocol versions
  supported: `2025-11-25` (latest) / `2025-06-18` / `2025-03-26`.
- Numeric parsing (D29): `ToolArgumentValue.integerString(from:)`
  (`Models/ToolDefinition.swift`) and `NativeToolExecutor` route every JSON
  number→Int through `Int(exactly:)` after an `isFinite` guard; out-of-range
  values surface `invalidInteger`/`invalid_argument` instead of trapping the
  in-process server.
- Large-output spill (D27): `spillStdoutContentItems` registers the full stdout
  with `ArtifactStore` and appends a `resource_link` (+ text note) when stdout
  exceeds `mcpStdoutCharacterLimit` (100 000); the inline envelope stays
  truncated. Download-tool payloads get a `download_url` via
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
  `builtin.fs.*` tools, D22). No `tools.json` migration — presets are templates,
  so already-added user tools are untouched. Remaining `.filesystem` group
  presets: `list_directory`, `find_by_name`.
- Stress harness: `Tests/MacRemoteTests/StressHarnessServer.swift` — one inert
  `@Test` (returns immediately unless `MR_STRESS_HARNESS=1`) that stands up a
  loopback `LocalMCPServer` with Single-Header auth and five stress tools
  (`stress.echo/cat_stdin/bigout/sleep/typed`), writing its endpoint JSON for an
  external driver. Python driver in `Tools/stress/` (`mcp_client.py`,
  `run_category.py`).
- Tests: `ToolExecutionLimiterTests`, `TunnelWatchdogTests`,
  `ProcessRunnerTests`, plus error-model/`reason`-code and spill coverage in
  `LocalMCPServerTests`. Suite/test totals: **449 tests / 42 suites** (the
  harness contributes its 1 inert test).
