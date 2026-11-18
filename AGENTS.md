# Agent Instructions

This repo builds a macOS app that exposes user-approved local CLI tools over
remote MCP. Keep the implementation generic: RemCTL, PocketCTL, Codex, and every
other command are optional tools, not special product modes. A first-party CLI
that ships its own MCP server (RemCTL, NotesCTL) is bridged through the generic
MCP bridge; MacRemote does not describe its tools a second time.

## Read this before touching the UI

The UI was fully redesigned for macOS 26/27 Liquid Glass on 2026-07-01. The
design is **authoritative and documented** — do not invent UI, and do not revert
to pre-redesign patterns:

- `docs/design/DESIGN-SPEC.md` — information architecture, every page's layout,
  onboarding flow, the parity mapping (§7), and the binding decision log (§1.2,
  decisions D1–D77). When in doubt about *what* a screen does, this wins.
  Removing a feature is allowed when the decision log records it.
- `docs/design/DESIGN-GUIDELINES.md` — the living rulebook: design tokens,
  component library, the Liquid Glass usage map, and the copy glossary. When in
  doubt about *how* something should look or read, this wins.
- `docs/design/IMPLEMENTATION.md` — the as-built map: scenes, file layout,
  component locations, and the AppModel API surface the views bind to. Start here
  to navigate the code.

If a change contradicts these docs, either follow the docs or update the docs in
the same change and say why. Silent drift from the spec is a defect.

## Toolchain (Command Line Tools, macOS 26.5 SDK)

**Always build and test with the commands below.** They pin the build to Command
Line Tools and the macOS 26.5 SDK. Full Xcode may also be installed; these
commands do not use it. Under Command Line Tools (Swift 6.4), the default macOS
27 SDK is unusable because its SwiftUI `@State` macro plugin ships only with
full Xcode, and Command Line Tools no longer include XCTest.

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swift build
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swift test
```

`script/build_and_run.sh` sets `DEVELOPER_DIR` to Command Line Tools and, when
the 26.5 SDK exists, sets `SDKROOT` to it, so it works with no environment
setup. It replaces any `SDKROOT` the caller set. `script/package_release.sh`
sets the same pin and stops if the 26.5 SDK is missing.

`Package.swift` targets `.macOS(.v26)` / tools-version 6.2 and carries
path-guarded CLT test-linking workarounds (harmless under Xcode). Tests use
**Swift Testing** (`import Testing`, `@Test`, `#expect`), not XCTest. Write zero `#available` checks and no macOS-27-SDK-only APIs
(`visibilityPriority`, `ToolbarOverflowMenu`).

`script/build_and_run.sh` (run/verify modes) `pkill`s the running app before
relaunching — which also kills any child `cloudflared` tunnel. If a live tunnel
is serving a session, prefer `--build-only`.
MacRemote's only connection paths are its loopback URL on this Mac and an
app-managed Cloudflare public link. Do not add another tunnel product or
connection state without an explicit design decision.

MacRemote can install its own pinned copy of Cloudflare's helper
(`CloudflaredManager`, decision D44) under
`~/Library/Application Support/MacRemote/CloudflaredHelper/`. That copy is **app
infrastructure, not a user tool**: it must never enter
`ExecutableLocator.searchDirectories`, never be offered through
`preset.cloudflared.*` or the CLI scanner, and never appear in `tools.json`.
Only `CloudflaredManager` resolves it, and only `TunnelService`/`CloudflareService`
launch it. Launch precedence is live-session pin > managed copy > external
(Homebrew/PATH) copy; MacRemote removes only its own copy and never touches one
the user installed.

While a helper runs, a second `MacRemote` process runs beside it: the tether
(`Services/HelperTether.swift`), the app's own executable started with
`--tether-helper`. It stops the helper if the app crashes or is killed. Keep
`MacRemoteMain.main()` checking for that flag before any app code, and never
pass a tether executable from tests.

When you change the pinned helper version in `Models/CloudflaredManifest.swift`,
add the outgoing release's executable digests to
`CloudflaredManifest.earlierExecutableSHA256`. Without them, the helper already
installed on a user's Mac fails verification after the app update and the
public link stays unavailable until a manual reinstall.

## UI rules (enforced — a violation fails review)

- **Liquid Glass is falsifiable.** The only `glassEffect(` call sites live inside
  `Views/ConnectionHero.swift`. Everything else uses system button styles
  (`.glass` / `.glassProminent`), `safeAreaBar`, and standard materials. `grep -rn
  'glassEffect(' Views` must return only ConnectionHero hits. No glass on the
  content layer (lists, forms, cards), no glass-on-glass, no `.clear` glass, no
  `ultraThinMaterial` blur imitations.
- **Design tokens only.** Spacing/radii/type/color come from
  `Views/DesignSystem/Tokens.swift` (`Space`, `TypeRamp`, semantic colors). No
  `.font(.system(size:))`, no hardcoded hex in-app (brand azure appears only in
  onboarding art and the served web pages).
- **Copy follows the glossary** (GUIDELINES §4.2/§4.3). One term per concept:
  it's an **app** (not "client"), tools **ask first** (not "host-gated"), the
  **public link/URL** (not "tunnel URL" in body copy), **sign-in method** (not
  "privacy"/"access mode"). Never surface `argv`, `PKCE`, `tools/list`,
  `loopback`, or `FDA` in visible UI copy. Buttons are verb-first.
- **Truthful status only.** No fake "all green" checklists. Server/tunnel/
  readiness state must reflect the real state machines
  (`AppModel.connectionReadiness`, etc.).
- **An icon is not an identity.** `Models/ConnectedAppIdentity.swift` picks a
  picture from strings the app supplied about itself (`client_name`, redirect
  URIs) — attacker-controlled input. Matching a brand grants zero privilege and
  changes no security decision; authentication, Always Allow, token validity,
  and revocation stay keyed on the client ID and the OAuth trust ID.
  `grep -rn 'ConnectedAppIdentity' Services Stores` must stay empty. Never draw
  a verification claim ("Verified", a checkmark badge) next to a brand mark, and
  never bundle artwork without a license entry in
  `Resources/ConnectedAppIcons/MANIFEST.json`.
- **Approvals never get quieter.** Pending OAuth / tool-call approvals surface in
  the floating, non-activating Approval window plus Dock/menu-bar/notification
  escalation (never a navigation hijack, never an inline menu-bar approve, never
  an Approve in a notification, never an "approve all"). See decisions D2–D4
  and D68.

## Core rules (unchanged)

- Do not edit installed user CLIs. Fix MacRemote, docs, or presets instead.
- Do not introduce shell execution for tools. Use exact executable paths and argv
  arrays. Native built-in tools (`ToolBackend.native`) are the sole exception to
  the "exact executable path + argv" rule: they implement behavior directly in
  Swift. The `download_zip` tool shells out to `/usr/bin/tar` via an argv array
  only (still no `/bin/sh`).
- Do not hardcode user-specific absolute home paths in code or docs except in
  test fixtures that explicitly require a fake path.
- Do not make any first-party CLI required. Each appears only when its
  executable is detected.
- Preserve user-defined tool data. Avoid deleting
  `~/Library/Application Support/MacRemote/tools.json` unless the user asks to
  start fresh.
- Treat macOS privacy as per-tool metadata. Use `permissionRequirements` instead
  of CLI-specific checks where possible.

## Cross-host MCP invariants

- The current protocol is `2026-07-28`. Modern requests use stateless
  `server/discover`, `MCP-Protocol-Version`, required per-request
  `params._meta` with `protocolVersion` and `clientCapabilities`; `clientInfo`
  is optional. Modern requests also carry `Mcp-Method`, conditional `Mcp-Name`,
  and schema-driven `Mcp-Param-*` mirrors. Preserve legacy
  `initialize`/session compatibility for all three supported versions:
  `2025-11-25`, `2025-06-18`, and `2025-03-26`. Do not silently downgrade after
  a recognized modern-protocol response or error.
- Keep standard MCP and MCP Apps fields primary. ChatGPT-specific `_meta` keys
  are additive compatibility aliases; never replace the standard field with an
  OpenAI-only field.
- Result cards are the owner's choice and **off by default** (decision D77):
  Settings › General ▸ Result Cards holds one global switch plus one switch
  per tool family (`Models/ToolFamily.swift`). The server gets the choice
  through its `resultCardPreferences` provider, read on every request. A
  shared tool links the widget only when the client negotiates MCP Apps, the
  catalog allows a card (`widgetPresentation.automatic: false` suppresses it
  for intermediate lookups and diagnostics), and the owner's choice allows it.
  Linked tools use standard `_meta.ui.resourceUri` with the versioned
  `ui://macremote/output-v9.html` cache key. A tool without a curated profile
  uses the safe `semanticResult` profile; that is not the same as having no
  widget. A result without `net.viticci.macremote/ui` means the card is off: the
  widget draws nothing and reports a height of 0, because a host can keep
  linking the card from a tool list it cached earlier (D78). An unlinked tool and its results carry no UI metadata or aliases,
  while text `content` and `structuredContent` stay identical. The choice is
  presentation only: never put it in `tools.json`, a security fingerprint, a
  permission epoch, or an approval decision. Keep `ui://macremote/output-v8.html`, `ui://macremote/output-v7.html`, `ui://macremote/output-v6.html`, `ui://macremote/output-v5.html`,
  `ui://macremote/output-v4.html`, `ui://macremote/output-v3.html`,
  `ui://macremote/output-v2.html`, and `ui://macremote/output` readable for
  existing clients. The pretty UI and its clipboard action must not expose raw
  JSON, terminal commands, executable paths, local paths, credentials, hidden
  metadata, or user-only content. Use a new URI for a future breaking widget
  change.
- Preserve meaningful text `content` and `structuredContent` for Claude, generic
  MCP clients, and hosts that do not render widgets. Widget actions must re-enter
  normal authenticated `tools/call` and the existing Mac-side approval gate.
- Bridge-backed tools keep MacRemote's uniform outer result envelope, but their
  `stdout` is the assistant-visible upstream semantic payload: prefer upstream
  `structuredContent`, otherwise unwrap one assistant-visible text content
  block, otherwise use the assistant-visible content-block array. Content with
  `annotations.audience` containing `user` but not `assistant` stays out of
  unannotated `stdout`. Omit a bare JSON text fallback only when it is
  structurally equal to `structuredContent`; append every other distinct,
  annotated, or multimodal block as real outer MCP content. Preserve upstream
  `_meta` and nonstandard top-level fields under collision-safe MacRemote
  result-meta namespaces. At the transport cap, spill assistant-visible,
  user-only, and hidden metadata into separate artifacts. Keep audience hints
  on both content links and expose the hidden metadata pointer only in outer
  `_meta`; never expose user-only content or upstream `_meta` through
  assistant-visible `content`. The configured tool output limit remains a hard cap: omit excess
  preservation context atomically, return `reason:"output_limit"`, and explain
  the loss in stderr. Map upstream `isError` to a failed execution. Do not
  product-special-case payload schemas.
- Every tool carries top-level `securitySchemes` and the `_meta.securitySchemes`
  back-compat mirror. Server instructions stay concise and host-neutral in both
  modern discovery and legacy initialization.
- CORS uses exact origin reflection with `Vary: Origin`, never `*`. The trusted
  ChatGPT origins are allowed only for a canonical public request base, never to
  turn direct loopback into a browser-accessible endpoint.
- Authenticate a valid MCP path before method dispatch. Unauthenticated
  GET/DELETE receives `401` discovery; authenticated GET/DELETE receives `405`.
- **Dynamic OAuth is the product default sign-in method**
  (`ConnectorAuthMode.productDefault`, decision D42). A fresh install starts
  there regardless of the selected app, and an unreadable persisted value falls
  back there. OAuth Client Secret and Single Header live under the Advanced
  disclosure in Settings › General, which holds the one D11 picker
  (`grep -rn 'setConnectorAuthMode' Views` must return only `SettingsView.swift`).
  The app picker is **advisory** (D43): it swaps setup instructions and never
  changes the sign-in method or mints a credential. The persisted key stays
  `MacRemote.connector.accessMode`; every existing raw value keeps working.
  For a public ChatGPT developer-mode draft, use MacRemote's app-managed
  Cloudflare URL with Dynamic OAuth/DCR. Single Header remains a generic
  interoperability option for MCP apps that can send one static
  `Authorization` header. Do not put the generated bearer value in source,
  checked-in profiles, logs, or test output.
- Do not describe MacRemote as embedding the OpenAI Apps SDK, or claim live
  ChatGPT proof, submission, publication, or publication readiness without that
  separate evidence. The implementation is hand-written Swift MCP with additive
  host compatibility.
- Do not claim complete MCP or OAuth conformance. Client Identifier Metadata
  Document (CIMD) support is not advertised and remains deferred. MacRemote
  never fetches a client document. `Services/PublishedOAuthClient.swift` lists
  the few published client IDs it accepts from a built-in copy (Claude's hosted
  apps); do not turn that list into a fetch.

## Modern protocol and MCP Apps

- `Services/MCPUpstreamProtocol.swift` owns modern request metadata, mirrored
  header construction, modern discovery validation, and the recognized
  legacy-fallback boundary shared by HTTP and stdio bridge clients.
- Local MCP discovery deduplicates only an exact canonical runtime contract:
  HTTP uses the complete URL plus credential-safe header bindings; stdio uses
  the exact command, full argv, startup timeout, and credential-safe environment
  bindings. Exact duplicates declared in several configs merge every discovery
  owner. Reconciliation removes an imported family only after every readable,
  non-manual owner disappears; an unreadable owner fails closed and preserves
  it. The scanner reads the explicit config paths in `MCPConfigLocator` and
  Claude Extension `manifest.json` files, not general Codex or Claude plugin
  registries.
- `Services/MCPAppsMetadata.swift` owns the standard MCP Apps extension,
  tool/resource metadata, the versioned `ui://macremote/output-v9.html` URI, the
  catalog eligibility/default `semanticResult` policy, and additive legacy/OpenAI
  aliases. Do not duplicate those constants in the server, scanners, or views.

## Tool Definitions

User tools are persisted as JSON dictionaries with:

- `name`, `summary`
- `executablePath`
- `argumentPattern`
- `parameters`
- `capability`: `readOnly`, `write`, or `destructive`
- `category`
- `permissionRequirements`
- `backend`: `process` (default), `mcpHTTPBridge`, `mcpStdioBridge`, or `native`.
  Native tools are the built-in File Transfer group (`filesystem_*`); they run
  in-process (no subprocess, no `argv`), carry a placeholder `executablePath`,
  and are defined in `Services/FileTransferToolCatalog.swift`. They are never
  written to `tools.json`, are always present, and default to Not Shared (DL-2
  first-seen pattern).

Two authoring modes (UI names, per decision D7 — do not call these "Full Access"):

- **Flexible Command** — broad command delegation:
  ```text
  argumentPattern: ["{args}"]
  ```
- **Fixed Command** — narrow, schema-driven tools:
  ```text
  argumentPattern: ["--json", "search", "{query}"]
  ```

Federico Viticci's ten CLIs use two surfaces. RemCTL and NotesCTL ship their
own MCP servers, so `Services/FirstPartyMCPProviderCatalog.swift` declares only
how to detect and launch each server plus a short per-tool policy (category,
every-call defaults, widget profile, row actions); the scanner synthesizes one
`first_party` candidate per installed CLI, folds any Claude Code, Codex, or
Claude Desktop config row that launches the same server into it, and
`bridgeTools` applies the policy. Bridged ids are `<server>_<tool>` without a
doubled prefix, tool contracts are the CLI's own, and permissions belong to the
CLI's signed helper, so bridged tools declare none. Consecutive stdio calls
reuse one warm server process per launch contract for 60 seconds
(`MCPStdioSessionPool`); a probe, a changed executable, a failed exchange, or
app quit discards it.

The other eight CLIs (Alexandria, HabitCTL, PocketCTL, OverCTL, MusicCTL,
GoodLinksCTL, Apple Frames, Iris) are a process catalog over the generic tool
model: 66 Fixed Commands plus 8 Destructive, every-call Flexible Commands, one
per provider: 74 tools. MusicCTL contributes 15 Fixed Commands plus one
Flexible Command. `everyCall` sets the default (asking on every run) and adds a
heavier consent step; it is not a lock, so an explicit Always Allow grant from
the owner overrides it and revoking restores the asking. The complete ids,
typed inputs, exact argv recipes, preflights, and approval rules for both
surfaces are in `docs/FEDERICO_CLI_TOOLS.md`.
Matter and Readwise are ordinary third-party discoveries. A complete first-party
provider Update from Catalog is authoritative and retires obsolete provider IDs;
do not add legacy aliases while MacRemote remains a single-user product.

A complete first-party provider refresh may adopt one scanner-created process
tool only when its provenance-backed execution signature uniquely matches one
current preset and the stable semantic ID is absent. Preserve exposure, create a
new permission epoch, and clear Always Allow grants for both identities. Never
adopt hand-authored or ambiguous equivalents, and never adopt during an ordinary
Add operation.

MusicCTL owns `provider.musicctl`, category `music`, and `set.music`.
`musicctl_new_releases` has a 3,600-second timeout. Music.app writes must run
MusicCTL's non-applying preview before the identical `--apply` command. Its
broad adapter blocks onboarding, raw requests, auth
configure/setup/login/logout, config set/unset, and private-key
file/stdin/reference inputs.

Every tool call runs synchronously inside its request. There is no background
execution.

Remote clients do not get shell expansion. Tell clients to pass exact argv items
and absolute paths. Edit tools through `AppModel.updateUserTool(id:draft:)`, which
preserves the tool ID and permission epoch transactionally. An unchanged security
fingerprint remains allowed; a changed contract asks again. Never delete and
re-add: recreation gets a new permission epoch and cannot inherit old allowances.

## Security invariants

- Decide approval and "Asks First" with `ToolDefinition.asksBeforeRunning`,
  never `capability != .readOnly`.
- File Transfer path decisions belong to `FileTransferPathPolicy` and compare
  file identity, not spelling; directory walks, searches, and archives must
  skip protected locations (`isProtected(path:)`, `isProtectedEntry`,
  `containsProtectedFolder`). The owner may allow any folder, up to the whole
  Mac (`reachesWholeMac`); the protected locations are then the only limit, so
  never shorten that list, and never add a second way to widen reach.
- Anything Spotlight or another index returns is checked against the policy
  path by path before it is shown (`FileNameSearch.spotlight`).
- An approval shows every argument in full (`ApprovalArgumentList`); never
  shorten, summarize, or re-parse what the owner approves.
- No surface may approve without showing the arguments or the sign-in code
  (`ApprovalRequest.verificationCode`): no Approve in notifications, no
  "approve all".
- Validate a call (`ToolExecuting.validate`) before requesting approval.
- A tool that runs without asking may only be pointed at files inside the
  allowed folders (`requireReachablePaths`), and every tool process starts in
  an empty, read-only folder (`ProcessRunner.emptyWorkingDirectory`). Do not
  give a tool process the app's own working directory.
- Serialize JSON with `JSONSerialization.checkedData`; `data(withJSONObject:)`
  raises an uncatchable exception on non-finite numbers.
- Read pipes and files with calls that return errors (`read(2)`/`poll(2)`,
  `FileHandle.read(upToCount:)`), never `availableData` or
  `readData(ofLength:)`; set `F_SETNOSIGPIPE` on pipes the app writes to.
- No runtime path derived from `#filePath` in a release build.
- Text a client supplies about itself (name, redirect) is untrusted: sanitize it
  (`sanitizeClientName`, `parseRedirectURIs`) and never let it change a security
  decision.
- Sharing is fail-closed: a tool the app did not save itself starts Not Shared
  (`knownToolFingerprintsKey`).
- Unauthenticated endpoints must check their caps before storing anything
  (`requirePendingCapacityLocked`, `PublicRequestRateLimiter`).

## MCP Description Expectations

The server exposes tool metadata aligned with the `2026-07-28` schema while
preserving the three 2025 legacy shapes:

- `name`: stable programmatic id.
- `title`: human-readable display name.
- `description`: concise behavior, argument, permission, and approval guidance.
- `inputSchema`: JSON Schema object for accepted arguments.
- `outputSchema`: JSON Schema object for structured results.
- `annotations`: `readOnlyHint`, `destructiveHint`, `idempotentHint`,
  `openWorldHint`, and `title`.
- `securitySchemes`: OAuth at the top level plus an identical `_meta` mirror for
  compatibility.

Modern `server/discover` returns `supportedVersions`, capabilities, concise
cross-tool `instructions`, `resultType:"complete"`, cache metadata, and
`io.modelcontextprotocol/serverInfo` under `_meta`. Legacy `initialize` returns
the negotiated 2025 `protocolVersion`, capabilities, top-level `serverInfo`, and
the same concise instructions without modern completion/cache fields. Every
shared tool whose result card is on (D77) uses standard `_meta.ui.resourceUri`
when Apps is negotiated; legacy MCP and OpenAI aliases may mirror the same URI
but never replace it.

For broad CLI adapters, descriptions must explicitly say there is no shell and
that `args` is an argv array.

Tool results carry a machine-readable `reason` code
(`ok|nonzero_exit|timeout|output_limit|killed|invalid_argument|not_approved|unavailable|internal_error`)
in `structuredContent` and `outputSchema`. Tool argument/execution failures
return a `CallToolResult` with `isError:true` + `reason`, not a JSON-RPC error.
JSON-RPC errors remain reserved for malformed envelope (`-32700`), unknown tool
or missing name (`-32602`), unknown request method (`-32601`), and internal
failure (`-32603`). Modern request validation additionally uses `-32020` for
header/body mismatch, `-32021` for a missing negotiated capability, and
`-32022` for an unsupported current protocol version, with appropriate non-2xx
HTTP status. Legacy compatibility retains its 2025 response shapes.
Notifications are acknowledged with HTTP 202. Tool executions are additionally
bounded by a global concurrency limiter
(`Services/ToolExecutionLimiter.swift`, acquired after the approval gate) that
sheds excess load with `reason:"unavailable"` — do not remove or bypass it.

Catalog policy (CLI-DISCOVERY-SPEC §6.4): the scanner's Ring-1 table (§4.3) is
catalog policy too — **no preset may wrap credential/secret managers, shells,
privilege tools, or package managers.** The scanner and the catalog share one
denylist source of truth (`Services/CLIRecommendationBlocklist.swift`); a new
preset whose executable matches `neverSuggestNames`/`neverSuggestPrefixes`
fails review.

Server info carries SEP-973 `icons` + `websiteUrl`: top-level in legacy
`initialize`, and under `io.modelcontextprotocol/serverInfo` in modern result
`_meta`. The server also serves `/`, `/favicon.ico`, `/favicon.png`,
`/macremote-icon.png`, `/macremote-icon-128.png`, and
`/macremote-icon-256.png`. See
`docs/design/IMPLEMENTATION.md` §"Connector icon" before touching any of that —
the icon that Claude.ai actually renders depends on the connector domain's
favicon, not on `serverInfo.icons`.

## Release packaging

`script/package_release.sh` is the release entry point. Its default strict mode
requires a clean checkout, Developer ID Application signing, a notary profile,
a universal arm64+x86_64 app, notarization, stapling, and Gatekeeper verification.
Do not claim a notarized or public release until that path succeeds.

Releases are notarized. The notary profile is named `MacRemote` and lives in
the login Keychain of the Mac that packages the release:

```bash
MACREMOTE_CODESIGN_IDENTITY='Developer ID Application: Federico Viticci (4W35M4UN6R)' \
MACREMOTE_NOTARY_PROFILE='MacRemote' script/package_release.sh
```

It produces `MacRemote-<version>-macos-universal2.zip` plus `.sha256` and
`.release-info.txt` sidecars. Club members do not get those files. They
download one ZIP, built next by `script/package_club.sh`:
`MacRemote-<version>.zip`, which unpacks to a **MacRemote <version>** folder
holding `MacRemote.app`, `Club Guide.md` (`docs/CLUB_BETA.md`),
`Release Notes.md`, and `Source/` (this repository at the commit the app was
built from). `docs/CLUB_BETA.md` describes that folder to members, so change
the script and the guide together. `--private-beta` remains as an Apple
Development-signed fallback for a Mac without Developer ID; a build made that
way is not notarized, and its guide must direct a blocked first launch to
**System Settings → Privacy & Security → Open Anyway**.

## Docs describe the latest release

README.md, docs/GUIDE.md, docs/CLUB_BETA.md, and INSTALL.md's install section
describe the latest release, the build people can download. A change that is
not released yet goes only in `docs/releases/UNRELEASED.md`. When a release
ships, fold those notes into the user docs, move them to
`docs/releases/<version>.md`, and empty `UNRELEASED.md`. Design, security, and
contributor docs describe the source on `main`.

`script/package_release.sh --local-signing --allow-dirty` exists only for local
packaging validation. Artifacts whose names contain `local` or `local-dirty`
must never be shipped, uploaded, or described as beta releases. Use
`script/verify_release.sh` to inspect an existing package, and do not treat its
non-distribution mode as Gatekeeper/notarization proof.

## Verification

For any non-trivial change:

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swift build
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swift test
python3 -m unittest discover -s Tests/Python -p 'test_*.py'
script/build_and_run.sh --verify
```

The local MCP stress harness reproduces concurrency, large-output, hang,
bad-argument, legacy protocol, and modern protocol scenarios against a
real `LocalMCPServer` on loopback, without a public link. It is gated by
`MR_STRESS_HARNESS=1` so a normal `swift test` skips it. See
`Tools/stress/README.md`:

```bash
MR_STRESS_HARNESS=1 MR_STRESS_TOKEN=<hex> \
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swift test --filter stressHarnessServer
# then, against the endpoint file it writes:
python3 Tools/stress/run_category.py \
  <concurrency|largeoutput|hang|badargs|protocol|modern>
# driver-only tests; no live server required:
python3 -m unittest discover -s Tests/Python -p 'test_stress_*.py'
```

After UI changes, also re-check the falsifiable rules:

```bash
grep -rn 'glassEffect(' Views        # only ConnectionHero.swift
grep -rn '#available' Views Stores App   # ~none
```
