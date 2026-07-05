# Agent Instructions

This repo builds a macOS app that exposes user-approved local CLI tools over
remote MCP. Keep the implementation generic: RemCTL, PocketCTL, Codex, and every
other command are optional tools, not special product modes.

## Read this before touching the UI

The UI was fully redesigned for macOS 26/27 Liquid Glass on 2026-07-01. The
design is **authoritative and documented** — do not invent UI, and do not revert
to pre-redesign patterns:

- `docs/design/DESIGN-SPEC.md` — information architecture, every page's layout,
  onboarding flow, the 200-item parity mapping (§7), and the binding decision
  log (§1.2, decisions D1–D18). When in doubt about *what* a screen does, this wins.
- `docs/design/DESIGN-GUIDELINES.md` — the living rulebook: design tokens,
  component library, the Liquid Glass usage map, and the copy glossary. When in
  doubt about *how* something should look or read, this wins.
- `docs/design/IMPLEMENTATION.md` — the as-built map: scenes, file layout,
  component locations, and the AppModel API surface the views bind to. Start here
  to navigate the code.

If a change contradicts these docs, either follow the docs or update the docs in
the same change and say why. Silent drift from the spec is a defect.

## Toolchain (this machine — CLT only, no Xcode)

**Always build and test with the SDK pinned to macOS 26.5.** The default macOS 27
SDK is unusable under Command Line Tools 6.4 (its SwiftUI `@State` macro plugin
ships only with full Xcode), and CLT 6.4 no longer includes XCTest.

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift test
```

`script/build_and_run.sh` and `script/macremotectl` export this pin automatically
when the 26.5 SDK exists and `SDKROOT` is unset, so `script/build_and_run.sh`
works with no environment setup. `Package.swift` targets `.macOS(.v26)` /
tools-version 6.2 and carries path-guarded CLT test-linking workarounds (harmless
under Xcode). Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`),
not XCTest. Write zero `#available` checks and no macOS-27-SDK-only APIs
(`visibilityPriority`, `ToolbarOverflowMenu`).

`script/build_and_run.sh` (run/verify modes) `pkill`s the running app before
relaunching — which also kills any child `cloudflared` tunnel. If a live tunnel
is serving a session, prefer `--build-only`.

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
  readiness state must reflect the real state machines (`SmokeReadiness`, etc.).
- **Feature parity is sacred.** The redesign preserved all 200 capabilities in
  `docs/design/DESIGN-SPEC.md §7`. Do not remove, orphan, or bury options in the
  name of minimalism; use progressive disclosure instead.
- **Approvals never get quieter.** Pending OAuth / tool-call approvals surface in
  the floating, non-activating Approval window plus Dock/menu-bar/notification
  escalation (never a navigation hijack, never an inline menu-bar approve, never
  an "approve all"). See decisions D2–D4.

## Core rules (unchanged)

- Do not edit installed user CLIs. Fix MacRemote, docs, or presets instead.
- Do not introduce shell execution for tools. Use exact executable paths and argv
  arrays. Native built-in tools (`ToolBackend.native`) are the sole exception to
  the "exact executable path + argv" rule: they implement behavior directly in
  Swift. The `download_zip` tool shells out to `/usr/bin/ditto` via an argv array
  only (still no `/bin/sh`).
- Do not hardcode user-specific absolute home paths in code or docs except in
  test fixtures that explicitly require a fake path.
- Do not make RemCTL required. It is optional and should appear only when
  detected or explicitly configured.
- Preserve user-defined tool data. Avoid deleting
  `~/Library/Application Support/MacRemote/tools.json` unless the user asks to
  start fresh.
- Treat macOS privacy as per-tool metadata. Use `permissionRequirements` instead
  of CLI-specific checks where possible.

## Common Commands

```bash
script/macremotectl doctor --json
script/macremotectl list-presets --json
script/macremotectl list-preset-sets --json
script/macremotectl add-preset-set set.detected_clis --replace
script/macremotectl clear-tools --yes
```

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
  Native tools are the built-in File Transfer group (`builtin.fs.*`); they run
  in-process (no subprocess, no `argv`), carry a placeholder `executablePath`,
  and are defined in `Services/FileTransferToolCatalog.swift`. They are never
  written to `tools.json`, are always present, and default to Not Shared (DL-2
  first-seen pattern), so `clear-tools` does not remove them.

Two authoring modes (UI names, per decision D7 — do not call these "Full Access"):

- **Flexible Command** — broad command delegation:
  ```text
  argumentPattern: ["{args}"]
  ```
- **Fixed Command** — narrow, schema-driven tools:
  ```text
  argumentPattern: ["--json", "search", "{query}"]
  ```

Remote clients do not get shell expansion. Tell clients to pass exact argv items
and absolute paths. Edit tools through `AppModel.updateUserTool(id:draft:)`, which
preserves the tool ID and rewrites Always Allow grants transactionally — never
delete-and-re-add (it silently drops per-app allowances).

## MCP Description Expectations

The server exposes tool metadata aligned with the current MCP schema:

- `name`: stable programmatic id.
- `title`: human-readable display name.
- `description`: concise behavior, argument, permission, and approval guidance.
- `inputSchema`: JSON Schema object for accepted arguments.
- `outputSchema`: JSON Schema object for structured results.
- `annotations`: `readOnlyHint`, `destructiveHint`, `idempotentHint`,
  `openWorldHint`, and `title`.

For broad CLI adapters, descriptions must explicitly say there is no shell and
that `args` is an argv array.

Catalog policy (CLI-DISCOVERY-SPEC §6.4): the scanner's Ring-1 table (§4.3) is
catalog policy too — **no preset may wrap credential/secret managers, shells,
privilege tools, or package managers.** The scanner and the catalog share one
denylist source of truth (`Services/CLIRecommendationBlocklist.swift`); a new
preset whose executable matches `neverSuggestNames`/`neverSuggestPrefixes`
fails review. `script/macremotectl` mirrors the same rule via
`BLOCKED_EXECUTABLES`.

The `initialize` result also carries SEP-973 `serverInfo.icons` + `websiteUrl`
and the server serves `/`, `/favicon.ico`, `/favicon.png`, `/macremote-icon.png`,
and `/macremote-icon-128.png`. See `docs/design/IMPLEMENTATION.md` §"Connector
icon" before touching any of that — the icon that Claude.ai actually renders
depends on the connector domain's favicon, not on `serverInfo.icons`.

## Verification

For any non-trivial change:

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift test
script/build_and_run.sh --verify
```

For docs-only changes, at least run:

```bash
script/macremotectl doctor --json
python3 -m py_compile script/macremotectl
```

After UI changes, also re-check the falsifiable rules:

```bash
grep -rn 'glassEffect(' Views        # only ConnectionHero.swift
grep -rn '#available' Views Stores App   # ~none
```
