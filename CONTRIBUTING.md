# Contributing

This is a private project. Keep changes small, testable, and aligned with the
generic tool model.

Changes to the first-party Alexandria, HabitCTL, PocketCTL, OverCTL, MusicCTL,
GoodLinksCTL, Apple Frames, or Iris catalog must keep
`docs/FEDERICO_CLI_TOOLS.md` and the Swift catalog aligned. Those
eight process providers expose 74 tools: 66 Fixed Commands and 8 Flexible
Commands. MusicCTL contributes 15 Fixed Commands plus one Flexible Command.
RemCTL and NotesCTL are not in that catalog: they ship their own MCP servers,
and `Services/FirstPartyMCPProviderCatalog.swift` holds only their detection,
launch, and policy rules. Run the installed-help, preflight, approval,
provider-reconciliation, and first-party MCP tests before submitting the
change.

## Before Editing

```bash
git status --short --branch
```

The working tree may contain local user changes. Do not revert changes you did
not make.

## Development Checks

Run these before submitting or pushing non-trivial changes:

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift test
python3 -m unittest discover -s Tests/Python -p 'test_*.py'
script/build_and_run.sh --verify
```

The 26.5 SDK pin is mandatory. The default macOS 27 SDK cannot compile this
package with Command Line Tools.

Protocol or MCP Apps changes must keep the focused Swift suites in
`LocalMCPProtocolConformanceTests.swift`, `MCPAppsMetadataTests.swift`,
`MCPHTTPBridgeClientTests.swift`, `MCPStdioBridgeClientTests.swift`,
`FirstPartyMCPProviderCatalogTests.swift`, `MusicCTLToolCatalogTests.swift`,
`OverCTLToolCatalogTests.swift`, `FullDiskAccessServiceTests.swift`,
`AppModelToolUpdateTests.swift`, `DefaultToolPresetInstallationIndexTests.swift`,
and `CLIAdapterParityTests.swift` green. Discovery or sidebar-count changes also
run
`LocalMCPScannerTests.swift`, `AutomaticDiscoveryTests.swift`, and
`SidebarViewTests.swift`. The Python discovery command above covers release
packaging, MCP Apps contract, and stress-driver tests.

Managed-helper, sign-in-default, connected-app identity, or sign-out changes
must keep `CloudflaredManagerTests.swift`, `ConnectorProfileTests.swift`,
`ConnectorSignInTests.swift`, `ConnectedAppIdentityTests.swift`, and
`ConnectedAppSignOutTests.swift` green.

Approval, sign-in, File Transfer, or sharing changes must keep
`ToolCallApprovalCoordinatorTests.swift`, `OAuthCoordinatorTests.swift`,
`FileTransferToolTests.swift`, `WholeMacFileAccessTests.swift`,
`AlwaysAllowPolicyTests.swift`, and `ToolRegistryTests.swift` green, and must
follow the security invariants in [AGENTS.md](AGENTS.md#security-invariants).

### Test Isolation

AppModel unit tests use `makeTestAppModel` from
`Tests/MacRemoteTests/Support/TestAppModel.swift`. It supplies in-memory
credential stores and an isolated Cloudflare helper manager. Pass the same
credential store explicitly when testing persistence across reconstructed
models. Credential-store tests inject write failures through
`InMemoryKeychainSecretStore`; these tests verify application behavior, not the
system Keychain.

## Design Constraints

- MacRemote is not a remote shell.
- Tools run as exact executable paths plus argv arrays.
- Built-in native tools (`ToolBackend.native`, the `filesystem_*` File Transfer
  group) are the only tools that run in-process instead of as an
  executable-plus-argv subprocess. Do not add new native backends without a
  documented decision; user-defined and preset tools stay process/bridge only.
- Shell wrappers such as `sh`, `bash`, `zsh`, `fish`, and `env` stay blocked.
- The runner's reliability invariants must not regress: the global execution
  concurrency limiter (`Services/ToolExecutionLimiter.swift`, acquired after the
  approval gate) with structured `reason:"unavailable"` load-shedding, timed-out
  children killed by process group, every descendant, and direct pid,
  concurrent stdout/stderr draining, and checked numeric-argument parsing. A remote argument must not be
  able to crash the server.
- RemCTL, PocketCTL, Codex, and other CLIs receive the same visual and runtime
  treatment. A bridged first-party MCP server is an imported server like any
  other; only its category, approval defaults, and widget hints come from the
  provider table.
- Optional CLIs must remain optional in docs and code.
- MacRemote's managed Cloudflare helper is app infrastructure, not a user tool.
  Its directory must never enter `ExecutableLocator.searchDirectories`, the CLI
  scanner, or preset resolution. Only `CloudflaredManager` knows the path.
- The managed helper's supply chain is fixed: HTTPS only, capped redirects
  confined to the pinned release hosts, a hard byte cap, and in-process
  gzip/USTAR handling that accepts exactly one regular file named `cloudflared`
  at the published size. The archive digest, the executable SHA-256 and byte
  count, and the Cloudflare Developer ID team are verified before the first
  launch and re-verified before every launch. No shell, no `curl | sh`, no
  package manager, no privilege escalation. A copy that fails verification is
  quarantined and never run. `cloudflared` stays optional; an external install
  is used but never modified; removal deletes only MacRemote's own files.
- The connected-app icon is presentation only. `ConnectedAppIdentity` matches
  attacker-controlled registration strings, so
  `grep -rn 'ConnectedAppIdentity' Services Stores` must stay empty and no icon
  may reach trust identities, token validity, approval policy, Always Allow
  keys, or revocation scope. Matching is exact-alias only. Bundled artwork
  requires a documented redistribution grant in
  `Resources/ConnectedAppIcons/MANIFEST.json` and `THIRD-PARTY-NOTICES.md`, and
  is never fetched at runtime.
- Dynamic OAuth is the product default (`ConnectorAuthMode.productDefault`). The
  app picker never changes the sign-in method, a saved choice survives launch,
  and credentials are generated only when a method is explicitly selected.
- Sign-out is exact and scoped by client ID plus OAuth trust identity, never by
  display name, and reports the counts it actually measured.
- Connected clients can refresh `tools/list`; adding tools should not require
  stopping the public link unless a specific client caches the tool list.
- macOS privacy requirements belong on tools through `permissionRequirements`.
- MacRemote.app is the only Full Disk Access item the app names
  (`FullDiskAccessService`). Never list a tool executable, a launcher, or an
  interpreter. Bridged RemCTL and NotesCTL tools declare no MacRemote
  permission requirement; each CLI's signed Capability Host owns its grants.
- A complete first-party provider refresh may adopt one uniquely matching
  scanner-created process tool into the stable semantic ID. Preserve exposure,
  create a new permission epoch, and clear grants for both identities. Never
  adopt custom or ambiguous equivalents.
- Cross-host MCP fields remain standard-first: `_meta.ui.resourceUri`, text and
  structured fallbacks, tool `securitySchemes`, and the normal approval path
  must keep working for Anthropic and generic clients. OpenAI `_meta` keys are
  additive aliases.
- The current widget URI is `ui://macremote/output-v8.html`; v7, v6, v5, v4, v3, v2, and
  the unversioned URI stay readable. Result cards are off until the owner turns
  them on in Settings › General ▸ Result Cards, globally or per tool family
  (decision D77). When they are on and the client negotiates MCP Apps, every
  shared tool links the widget unless its family is switched off or its catalog
  presentation sets `automatic: false`, as intermediate lookups and diagnostics
  do; unlinked tools keep complete text and structured results (see
  `docs/design/MCP-UI-SPEC.md`).
  Bridged NotesCTL reads use yellow `noteRows`, bridged RemCTL reads use purple `reminderRows`, dedicated OverCTL tools use
  orange `episodeRows`, and tools without a curated profile use
  `semanticResult`. The pretty UI must not expose raw JSON, terminal
  commands, executable paths, credentials, hidden metadata, or user-only
  content. A tool without a curated profile is not a tool without a widget.
- The Tools sidebar count is new detected, unimported MCP runtimes; Requests is
  the separate approval count. The help text must say nothing was imported.
- Exact duplicate runtimes in supported Codex and Claude direct configs merge
  while retaining every configuration owner. Different endpoint, argv, timeout,
  environment, header, or auth bindings stay separate. General plugin registries
  remain outside scanner scope.
- The current MCP protocol is `2026-07-28`: modern clients use stateless
  `server/discover`, per-request `_meta` with required `protocolVersion` and
  `clientCapabilities` plus optional `clientInfo`, `Mcp-Method`, conditional
  `Mcp-Name`, and schema-driven `Mcp-Param-*` mirrors. Preserve all three
  legacy `initialize`/session fallbacks: `2025-11-25`, `2025-06-18`, and
  `2025-03-26`.
- Era routing is exact-match: only a `2026-07-28` header, either modern `_meta`
  key, or `server/discover` selects modern validation, and parse-era
  classification follows the same rule. Any other header version — older or
  unknown-future — must be answered with `-32022` `Unsupported protocol
  version.` and `{supported, requested}` before any envelope demand, never with
  a modern-metadata complaint. The strict `-32602` for a `2026-07-28` client
  missing the envelope keeps its message and carries `supported` as a downgrade
  hint.
- On the bridge side, only a server's own version list may move a connection
  down. An upstream `-32022` whose `data.supported` names a legacy revision the
  initialize flow implements renegotiates to the newest mutual version, as does
  a discover result advertising only such versions; a bare or non-overlapping
  `-32022` and any `-32020`/`-32021` must keep failing closed. A renegotiated
  version is per connection — never write it back to the bridge's persisted
  `protocolVersion`, which is fingerprint material.
- Every tool call runs synchronously inside its request. Do not add background
  execution without a recorded design decision.
- MacRemote has two supported connection paths: loopback on this Mac and an
  app-managed Cloudflare public link. That link is served by MacRemote's managed
  helper when it installed one, otherwise by the user's own `cloudflared`; the
  helper is a dependency, not a third path. Public apps sign in with Dynamic
  OAuth/DCR by default, ChatGPT developer-mode drafts included. Client Secret
  and Single Header stay available behind Advanced; no other tunnel product
  belongs in the app lifecycle.
- Do not call a local/unit-test result live ChatGPT proof. MacRemote is a
  hand-written Swift MCP server with standard fields first and additive OpenAI
  aliases; never describe it as an Apps SDK implementation or as
  submitted/published.

## Release Packaging

`script/package_release.sh` is the only supported release packager. Its default
mode is the strict distribution path: it requires a clean checkout, a Developer
ID Application identity and notary profile, produces a universal arm64+x86_64
app, notarizes and staples it, and verifies Gatekeeper. Do not claim a public or
notarized release unless that mode completes successfully.

Club releases use that notarized mode too; see "Release packaging" in AGENTS.md for the
command. Then run `script/package_club.sh`: it wraps the notarized app, the
Club guide, the release notes, and the source into `MacRemote-<version>.zip`,
the one file members download. On a Mac without Developer ID, the fallback is:

```bash
script/package_release.sh --private-beta
```

This mode still requires a clean checkout and produces the explicitly named
`MacRemote-<version>-macos-universal2-private-beta.zip`, checksum, and release-info
sidecar. It uses Apple Development signing and is not notarized; tester docs
must direct a blocked first launch to **System Settings → Privacy & Security →
Open Anyway** and must not claim Gatekeeper acceptance on a clean Mac.

For local packaging validation only, use:

```bash
script/package_release.sh --local-signing --allow-dirty
```

Artifacts named `local` or `local-dirty` are not releases. Never give them to
testers or upload them as release assets. Use `script/verify_release.sh` for an
existing package, and keep its distribution checks distinct from private-beta
or local validation.

## App Icon

The icon source is the Icon Composer document `Resources/AppIcon.icon`.
`Tools/icon/draw_icon.py` regenerates it and overwrites hand edits. After any
change, run `Tools/icon/build_assets.py` and commit what it writes: the
`Resources/` icon files and `docs/images/banner.png`. It needs Xcode 26 or later
and Pillow. Builds only copy these files, so the Command Line Tools build above
does not need Xcode.

## Commit Style

Use short imperative commit messages. Include docs and tests with the code change
when behavior changes.
