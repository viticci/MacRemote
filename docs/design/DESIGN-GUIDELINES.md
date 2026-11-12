# MacRemote — Design Guidelines (Living Rulebook)

> **Provenance.** Produced by a judged design competition on **2026-07-01**. Five directions competed — `guided-operator`, `mission-control`, `system-utility`, `glass-expressive`, `dense-console` — scored by five judges; rank-point tally: **mission-control 21 · guided-operator 19 · system-utility 15 · dense-console 11 · glass-expressive 9**. The winning skeleton is Mission Control with judge-directed grafts; the binding decision log lives in `DESIGN-SPEC.md §1.2`. This file is the rulebook implementation and review must enforce. When this file and old code disagree, this file wins.

---

## 1. Design tokens (Swift-expressible)

### 1.1 Spacing (pt) — nothing else is allowed

| Token | Value | Use |
|---|---|---|
| `Space.s1` | 4 | intra-row, chip internals |
| `Space.s2` | 8 | control gaps, row internals |
| `Space.s3` | 12 | intra-card stacks |
| `Space.s4` | 16 | card padding |
| `Space.s5` | 20 | window content margins |
| `Space.s6` | 24 | section/card gaps |
| `Space.s8` | 32 | hero breathing room, hero container spacing |

List/Form row heights and insets are **system default** — never compressed (lowering `defaultMinListRowHeight` is banned; macOS 26 breathing room is the point). The current 0/1/2/3/5/6/10/14/18 zoo is retired.

The one allowed override **raises** it to the height a row is actually drawn at: the Tools list sets `defaultMinListRowHeight` to `ListMetrics.toolRowHeight` (32 — the 24 pt tool icon plus the system insets). AppKit sizes the rows it has not drawn yet from that value. With the system value (24) each row grew 8 pt as it scrolled into view, so the list jumped and a Share switch could move out from under the pointer. Section headers follow the same rule: a header control is `.controlSize(.small)` so the header draws at the height the list assumes for it.

### 1.2 Radii — concentric, never constant

- Pages publish `containerShape(.rect(cornerRadius: 16))` on detail content.
- Cards: `ConcentricRectangle(corners: .concentric(minimum: 12), isUniform: true)` (practical value 12).
- Code blocks / mono chips: concentric minimum 8. Nothing below 8.
- Chips, pills, the hero capsule: `Capsule()`.
- Sheets, popovers, menus, sidebar: system-owned (free). No hand-picked 6/8 mismatches; nested radii always derive from the container.

### 1.3 Type ramp (SwiftUI text styles only — macOS scale; zero `.font(.system(size:))`)

| Role | Style |
|---|---|
| Welcome window title | `.largeTitle` (26) — **the only `.largeTitle` in the app** |
| Hero status word; approval headline | `.title2` semibold (17) |
| Hero public URL; masthead machine text | `.title3` + `.monospaced` (15) |
| Card titles, section headers, row titles | `.headline` (13 semibold) |
| The selected source's name on a Tools page (one per page) | `.title3` semibold (15) — `TypeRamp.sourceTitle` |
| Controls, primary copy, row values | `.body` (13) |
| Row detail, readiness detail lines | `.callout` (12) secondary |
| Group footers, truth notes ("This session…") | `.footnote` (10) |
| Chips, badges, timestamps | `.caption` (10; semibold for chips) |
| Machine text (URLs, argv, IDs, paths, tokens, log payloads, markers) | `.callout`/`.caption` + `.monospaced()` |

**Mono rule:** monospaced is *reserved* for machine-produced/consumed text — it is the "this is machine truth" signal and never decorates prose. Counts use `.monospacedDigit()` + `.contentTransition(.numericText())`. No in-content large titles anywhere (titles are inline in the toolbar via `navigationTitle`/`navigationSubtitle`).

### 1.4 Color roles — 100 % semantic, zero hex in-app

Surfaces: `Color(nsColor: .windowBackgroundColor)`, `.controlBackgroundColor`, `.underPageBackgroundColor`, label hierarchy, `.separatorColor` (one hairline opacity app-wide). Accent: the **user's** accent (no brand override on controls; ship the asset-catalog accent for multicolor users only).

Status roles — always paired with a symbol or word, never color alone:

| Role | Color | Pairing |
|---|---|---|
| Off / idle | `.secondary` | `circle.dotted` |
| Local / working / info | `.blue` | `dot.radiowaves…`, spinner |
| Public / ready / passed | `.green` | `checkmark.circle.fill` |
| Attention / pending / warning / **Asks First** | `.orange` | `exclamationmark.triangle.fill`, `hand.raised` |
| Error / blocked / **Destructive** | `.red` | `xmark.octagon.fill` |

Capability chips — **one scale on every surface** (Tools, Apps, Requests, Approval window; fixes the always-orange approvals chip): Read-only `.green` · Write `.orange` · Destructive `.red`.

Brand azure (`#45A0FA…#89CAF9`, from the icon) appears **only** in onboarding artwork and the public web pages (`GET /`, `/authorize`) — never on in-app controls or surfaces. The Connection canvas wash uses semantic status colors at low opacity (SPEC D5), transitioning only on state change; it falls back to plain `windowBackgroundColor` under Reduce Transparency / Increase Contrast.

The zero-hex rule above governs the native macOS UI. Catalog-authored MCP Apps
widget accents are web presentation metadata governed by `MCP-UI-SPEC.md`.
They must supply contrast-safe light/dark values and pair color with text or a
symbol; they never change authorization or become a status by color alone.

---

## 2. Component library (replaces `SharedViews.swift`)

Every component names what it replaces. `StatusPanel` (dead code), `HeaderView` (in-content titles), `FlowStep`/`FlowStepState`, `MetricPill`, `StatusBadge`, and `panelStyle()` are deleted.

| Component | Anatomy | Variants / states | Replaces |
|---|---|---|---|
| `ConnectionHero` | One `GlassEffectContainer(spacing: Space.s8)` (32 pt): state chip + status word (`.title2` semibold) + URL capsule (`.title3` mono) + fused Copy (`glassEffectUnion`) + verb buttons beneath. `glassEffectID` morphs between states; `.interactive()` on clickables only. | Off / Starting / Local / Public-pending / Public / Partial-failure ("Server running · link stopped") / Failed / Unavailable / Zero-tools. Compact variant reused in onboarding S4–S5. | DashboardView flow-step cards 2–3; TunnelView status rows |
| `StatusOrb` | Animated state circle: symbol + tint + `symbolEffect` per state | off/starting/local/public/failed | ad-hoc dots |
| `StatChip` | count + label capsule, quaternary fill; **tappable = filter/navigate**. Always one line at its full width; it is never squeezed | static · filter (selected/unselected) | `MetricPill` |
| `StateChip` | severity-tinted capsule w/ symbol; one severity scale. Always one line at its full width; `symbolOnly()` shows the symbol alone, with the words in the tooltip, where a row is too narrow | status · capability (Read-only/Asks First/Write/Destructive) · state words · symbol only | `StatusBadge` |
| `FlowLayout` | a row of chips or small controls that wraps whole items onto new lines, like words in a paragraph | — | squeezed `HStack` chip rows |
| `Card` | content-layer card: 16 pt padding, `.background(.quaternary.opacity(0.4))`, concentric 12 radius, **no stroke**, optional collapsed-summary header (Rule 24: collapsed cards must summarize non-default state) | expanded · collapsed-summary | `panelStyle()` (the twenty gray boxes) |
| `KeyValueGrid` | aligned label + mono value rows, selectable, per-row hover `CopyButton`; lives inside a `▸ Details` disclosure | plain · privacy-sensitive rows | ad-hoc metadata grids (Clients, Approvals, proofs, credentials) |
| `CopyButton` | one copy affordance app-wide: `doc.on.doc` → checkmark (`contentTransition(.symbolEffect(.replace))`, 1.2 s), writes pasteboard **and** the audit-log line | inline · hover-reveal (on `MonoValue`) | 10+ divergent copy buttons |
| `MonoValue` | machine text: `.monospaced`, middle truncation, `.textSelection(.enabled)`, hover-reveal `CopyButton` | — | scattered mono Text |
| `ApprovalCard` | actor header (app glyph + name) → capability sentence (severity-tinted) → `ApprovalArgumentList`: every argument in full, standard input included, each value in its own box with Copy, invisible characters written out, scrolling inside a bounded box, never shortened → `▸ Details` grid → caption ("…you can undo it in Apps") → verb row; countdown ring = `Gauge` drawn **around the app icon**, `TimelineView`-driven, green→amber last 30 s | window (glass verb row) · inline queue row (content) · onboarding demo; tool-call · OAuth-connect (matching code + return destination, then consequence copy); pending/approved/denied/expired/server-stopped | ApprovalsView rows |
| `CountdownRing` | `Gauge`/trimmed-circle progress around a 64 pt icon, real 90 s (tool call) / 300 s (sign-in) fuse | normal · amber (<30 s) | (new) |
| `ReadinessRow` | state glyph + title + live detail + **expansion (available in every state — SPEC D1)** + contextual fix button | ready/checking/warning/blocked; FDA row expands `AccessFixer`; Privacy row expands its remedy | Security Gates rows; TunnelView readiness rows |
| `AccessFixer` | status row → default detail **“Add MacRemote to Full Disk Access — then relaunch and check again.”** → `TargetRow` list (MacRemote.app only) → numbered ①②③ strip → primary row (Check Again prominent · Open System Settings · Later) → `Troubleshoot ⌄` menu; **Re-add MacRemote in System Settings** appears only when the current target list contains `MacRemote.app` | hosts: app-global sheet · Readiness expansion · onboarding S3; states: checking/required/confirmSetup (prominent Confirm Setup verb)/ready(auto-dismiss)/failed; extended to macOS-privacy failures | the three duplicate FDA button farms |
| `ConduitLightLayer` | "Aurora Exchange" — the hero URL capsule holds a living iridescent aurora while the tunnel is public: two hue bands drifting in opposite directions (outbound/inbound), edge glints running the top rim L→R and bottom rim R→L, and a white-cored packet comet crossing every ~5 s, alternating direction. A `.colorEffect` color layer between the glass and the text — **never a second glass surface** (the §3 glassEffect map is unchanged). Shader: `Shaders/ConduitLight.metal` (core in `auroraUnion()`, shared with the `previewGrid` offscreen kernel — `script/render_shader_preview.swift` renders PNG frames for review without launching the app), precompiled to the committed `Shaders/default.metallib` via `script/compile_shaders.sh` (CLT host has no Metal compiler; missing metallib = silent no-op). 30 fps TimelineView, paused on occlusion; Reduce Motion = static aurora; removed under Reduce Transparency; 0.72-alpha highlight ceiling with a calmed midline band so the URL keeps contrast; full-size hero only | `.publicRunning` only; gain fades in 0.45 s after the glass morph settles | new 2026-07-02, redesigned for visibility same day |
| `TargetRow` | NSWorkspace icon + role capsule `This app` (the only row is `MacRemote.app`) + **probed access chip** (Access works · No access yet · Checked when it runs — truthful probe results, never a guess at System Settings rows) + mono path + Copy (path & fileURL types) + Reveal + `.onDrag { NSItemProvider(object: NSURL) }` + `.help` | access chip: ready/attention/quiet by probe outcome | FullDiskAccessTargetRow (+ per-target access state, 2026-07-02). **Drag rule (falsifiable):** target rows must drag a file-url *reference* via `NSItemProvider(object: NSURL)`. SwiftUI `.draggable(URL)` stages a bundle COPY under `~/Library/Caches/com.apple.SwiftUI.Drag-*`, so System Settings grants Full Disk Access to a throwaway copy — `grep -rn '\.draggable(' Views` must return no fixer target rows. |
| `ToolsSourceColumn` / `ToolsPageHeader` | the Tools page's left column (`.sidebar` list style, content layer — never glass): All Tools · Command Line groups · MCP Servers, counts that follow search and filter, an attention glyph per server (sign-in, failed check, signing in, importing), **New** on unimported candidates · the right pane's header: 36 pt tinted icon, `sourceTitle` name, "9 of 12 shared" line, chips, mono endpoint, verbs, then progress/error lines (`ImportedServerHeader`, `CandidateServerHeader`) | column rows: plain · attention · new; server page: Signed In / Sign-in Required / Signing In / Importing / Check Failed; candidate page: Ready to Import / View Only | the unified list's bottom-of-page MCP groups and their crowded group rows (D63) |
| `ToolRowView` / `ImportedServerHeader` + `CandidateServerHeader` / `ToolInspector` | list row (icon/name/chips/Share toggle) · MCP server header (source badge, endpoint, Ready to Import/View Only, Import/Refresh-with-warning, Share All, progress, probe errors) · tabbed inspector (**Overview / Definition / Permissions / Activity**; Definition owns the 1 s–24 h timeout; Test Tool/Duplicate/Remove footer) | shared/not-shared (0.62 dim) · per-row error · built-in (read-only Definition) | ToolsView cards; LocalMCPToolsView panels; the Add Tool sheet's edit duty |
| `AppCard` | identity header (`ConnectedAppIconView`, received name, session chip, sign-in-method chip, allowance count) + meta line (token counts · First connected · Last connected) + Details grid + bulk verbs (**Sign Out…**) + policy-list header with the per-card **Filter tools** field (only past 8 tools) + grouped policy list with per-category `Allow ▾` | active · waiting to finish signing in · expired (0.85 dim) | ClientsView cards |
| `ConnectedAppIconView` | a connected app's mark, resolved through `ConnectedAppArtworkResolver` across four tiers in order — bundled PNG, the vendor's own installed app, a `data:` icon from the app's MCP handshake, then a `Circle` + the brand's SF Symbol (SPEC D48). **`AppIconSize` is the complete set of app-icon sizes: `.compact` 24 · `.card` 28 · `.hero` 64** — no other size may be introduced, and each carries a `minimumPixelWidth` the installed-app tier must meet. Brand resolution is `ConnectedAppIdentity` (exact matching, presentation only — see SPEC D46); which tier answered is never shown. Missing or unreadable artwork falls back silently; it is never an error state, never asserts, and never fetches anything | compact (Requests rows, inline approval header) · card (Apps) · hero (Approval window countdown ring); `isDimmed` for non-active sessions (0.55, recognition preserved) | the `ConnectorProviderProfile.inferred(fromClientName:)` substring glyph helper (deleted) |
| `CloudflaredHelperSetup` | the one Cloudflare-helper offer (SPEC D44): state line (a failure shows its fixed headline plus the technical reason as a selectable `MonoValue`) → the single prominent verb (**Install Helper** / **Try Again**) → **"What gets installed"** `DetailsDisclosure` holding the consent sentence, the download URL and SHA-256 as `MonoValue`s, license/source/release links, and — below a divider — the Homebrew alternative with `CopyButton`; a small **Check Again** renders in every state that is not mid-install, so no state of the row ends without a pressable verb. Hosted by the Address card banner and onboarding S4, keyed by a `disclosureID` so the two hosts keep separate disclosure state | checking · notInstalled · downloading (determinate + Cancel) · verifying · ready · failed | the two divergent `brew install cloudflared` rows in `WelcomeView` and `ConnectionAddressCard` |
| `LogRow` | mono time + level chip + message (2-line, selectable) + optional `lock.shield` prefix glyph | info/warning/error | LogsView row (promoted into the system) |
| `SetupChecklist` | live-stated numbered steps card with jump links; collapses to "All set ✓" capsule on first completion; regression re-expands only the failing row (30 s debounce, one-shot notification escalation, never above a live hero) | leading · collapsed capsule · regression | ConnectionFlowPanel |
| `DeployStageList` | four named stages (Check Cloudflare access → Create tunnel → Configure DNS → Start); failure lands on its stage: human line first, raw API text in copyable mono disclosure | pending/active/done/failed per stage | the single deploy spinner |
| `EmptyState` | `ContentUnavailableView` wrapper enforcing the pattern: "No X yet." + plain-language trigger + CTA | list-empty · `.search` | bare empty panes |
| `StatusTile` | the collapsed face of a Connection card, sized for an adaptive `LazyVGrid` (min 240 / max 420, `Space.s4` gaps — D19): icon + `cardTitle` + chevron header over the card's Rule-24 summary; same Card material recipe (quaternary 0.4 fill, concentric 12, **never glass**); the whole tile is one open button; hover = fill shift to 0.55, no lift | resting · hover | the three stacked full-width collapsed cards on Connection |

**Disclosure behavior (app-wide):** `▸ Details` disclosures persist their state per section; **⌥-click expands every disclosure on the current page**. Collapsed summaries must state non-default values ("Your Domain · Deployed ✓"). `DetailsDisclosure` takes an optional **`initiallyExpanded`** flag, which is only the `SceneStorage` *default* — it opens a section until the user has expressed a preference for that `id`, and never overrides a preference they already set. Use it where a hidden non-default setting would otherwise be invisible (Settings ▸ General ▸ Advanced sign-in methods opens itself whenever the saved sign-in method is not the product default). It is not a way to make a section open every time.

---

## 3. Liquid Glass usage map — hard rules

**The falsifiable rule: the only `glassEffect(` call sites in app code live inside `ConnectionHero`. If code review finds `glassEffect(` anywhere else, the design is violated.** (One component, one `GlassEffectContainer`, reused by the main window and onboarding S4–S5.)

### Gets glass

1. **`ConnectionHero`** — the app's single custom `GlassEffectContainer(spacing: Space.s8)` (32 pt); children carry `glassEffect(.regular.tint(stateColor))` + `glassEffectID(_, in:)`; the copy affordance joins via `glassEffectUnion`; transitions are the default matched-geometry morph that `glassEffectID` drives; `.interactive()` only on clickable elements. Tint = semantic status (blue/green/red), never theme.
2. **System button styles** (not custom glass): exactly one `.buttonStyle(.glassProminent)` per view region — hero primary verb, Approval window's Approve Run, onboarding primaries, Library sheet's Install, Access Fixer's Check Again. Paired secondaries `.glass`. `ToolbarItemPlacement.confirmationAction` auto-styles — prefer it.
3. **`safeAreaBar(edge: .bottom)`** in Requests (Deny All Waiting) — glass buttons over scrolling content, appears only with 2+ pending.
4. **System chrome, free, untouched:** window toolbar (`ToolbarItemGroup` + `ToolbarSpacer` grouping; status items detach via `.sharedBackgroundVisibility(.hidden)`), sidebar, sheets, popovers, menus, dialogs, MenuBarExtra, search fields, standard controls.

### Never glass (content layer — enumerated)

Every `Card`; tool/app/request/log lists and all rows; **`AppCard`s and the `ConnectedAppIconView` mark inside them**; `KeyValueGrid`s; readiness rows; the Address form; **the `CloudflaredHelperSetup` row and the Settings ▸ Cloudflare Helper section (in both hosts — banner and onboarding)**; Settings forms; inspectors; `AccessFixer` bodies; onboarding body content; the Connection canvas wash (it is a color, not a material); the web pages. The Approval **window body** is standard window material — only its verb row uses glass button styles.

### Hard rules (binding review checklist — cite by number in review)

1. Never glass-on-glass (no custom glass inside the toolbar or another glass surface).
2. `.regular` only under text — `.clear` is banned app-wide (transparency-slider safety).
3. ≥2 custom glass elements on a screen ⇒ one shared `GlassEffectContainer` (we have exactly one).
4. Tint is semantic (status, primary action) — never a theme.
5. `.interactive()` only on clickable elements.
6. No `ultraThinMaterial` imitation blurs — real API only, or it won't track the macOS 27 slider/Reduce Transparency.
7. Do not override automatic toolbar/sidebar treatments (no opaque `toolbarBackground`, no hidden toolbar background — every section keeps the standard toolbar).
8. Total custom glass elements per window: single digits (target ≤5, all inside the hero container).

**Scroll edges:** `.scrollEdgeEffectStyle(.soft, for: .top)` on Connection/Tools/Apps/Requests; `.hard` on Activity (streaming text performance). **`backgroundExtensionEffect()` appears exactly once** — the Connection canvas extending under the sidebar. **Morphing pattern:** state changes morph via `glassEffectID` within the one container; distant appearance (Approval window arrival) uses fade/`materialize`-class transitions, not cross-window morphs.

---

## 4. Copy style guide

### 4.1 Voice rules

1. **Outcome first, mechanism second.** The primary line says what happens in the user's world; protocol facts demote to `▸ Details` grids, footers, and ⓘ popovers. **Demote, never delete.**
2. **Talk to *you* about *your Mac*.** The approving side is you; the machine is this Mac.
3. **Contractions welcome; passive voice banned.** "will appear here" → "shows up here"; never "cannot" in body copy.
4. **Buttons are verb-first and complete "Click to …".** Navigation buttons say "Open …". Title Case for buttons/nav/section headers/dialog titles; sentence case for sentences.
5. **One term per concept** (glossary below). One destructive verb per object class: **Delete** (things that vanish) · **Revoke** (permissions) · **Replace** (credentials) · **Reset** (identifiers) · **Remove** (tools) · **Sign Out** (sessions).
6. **Calm urgency for security moments:** state the actor, the action, the consequence — no adjectives, no sound, no flashing.
7. **State honesty markers:** session-only surfaces say so ("This session — cleared when MacRemote quits"); secrets say where they live; Instant Links say they change.
8. **Status details are noun phrases without periods** ("Waiting for Cloudflare").
9. **Errors = what happened + what to do next**, human sentence first, raw detail selectable in mono below. Raw strings never render in a value slot (a failure message is not a URL).
10. **Empty states:** "No X yet." + plain-language trigger + CTA.
11. **Typography details:** numerals stay numerals; "…" never "..."; no literal backticks rendered in copy; never abbreviate Full Disk Access; counts in prose read "9 of 12 shared" (chips may use "9/12").
12. **Notifications:** title = short human headline ("Setup needs attention"); body = one sentence + one action ("Open MacRemote to fix it."). An approval notification offers **Deny** only, never Approve (SPEC D68).
13. **Consequence at the verb:** every approval, Always Allow, and destructive dialog states what changes ("Claude can now run Convert To PNG without asking — you can undo it in Apps").
14. Keep Apple-established terms verbatim: **Always Allow, Full Disk Access, System Settings, Read-only**.
15. **OpenAI lifecycle terms:** call the developer-mode object an **app**. Use **plugin** only for submission or publishing, and never imply that MacRemote has been submitted or published.

### 4.2 FINAL glossary — one term per concept (banned terms in the last column)

| Concept | The one term | Bans |
|---|---|---|
| Making a tool visible / its state | **Share** (toggle) / **Shared · Not Shared · Partially Shared** | Expose, Exposed, Enabled, Partially Enabled, Allowed commands |
| The set of visible tools | **Shared Tools** | Tool Surface, Exposed Surface, Exposed Tool Surface |
| A runnable command | **Tool** (catalog entries: **presets**; groups: **Bundles**, **Found on This Mac**) | detected CLI, command preset (as UI labels) |
| Refresh an installed catalog definition | **Update from Catalog** | rescan commands, reinstall preset, sync adapter |
| Curated reusable first-party workflow | **Dedicated tool** in prose; implemented as a **Fixed Command** | special mode, endpoint, adapter |
| Tool authoring modes | **Fixed Command / Flexible Command** | CLI Adapter, Command Template, Template, Adapter, Full Access, Generic adapters |
| The remote party | **App** (headlines/prose); "Client ID" survives **only** inside Details grids | client, remote client, OAuth client, MCP client, connector, provider, remote app |
| The approving side | **you / this Mac** | host, host Mac, host app, host approval, process context |
| Per-call gating | **Asks First** (chip) / "asks you before running" (prose) | host-gated, write-capable, per-call host approval |
| Standing permission | **Always Allow** (kept) | allowances, trust policies, Tool Trust |
| All sign-ins reset | **Sign Out All Apps** | Revoke OAuth Grants |
| Ending one app's session | **Sign Out** (verb) / **Sign out "‹App›"?** (dialog title) | Delete App, Delete Client, Remove App, Disconnect |
| When an app first and most recently connected | **First connected** / **Last connected** | Last Auth (visible copy), last seen, last active |
| A connected app's session state | **Active** · **Waiting to finish signing in** · **Sign-in expired** | online, offline, connected device, Verified, Unverified |
| The default sign-in method | **Dynamic OAuth**, labeled **Default**; the Advanced picker writes it **Dynamic OAuth (Default)** | recommended mode (as a product term), auto mode |
| Non-default sign-in territory | **Advanced** (chip + the "Advanced sign-in methods" disclosure) | Expert, Power user, Manual mode |
| Cloudflare's tunnel binary | **Cloudflare's helper** in prose; **Cloudflare Helper** as the Settings section title; the source reads **Managed by MacRemote** / **Installed by you** | cloudflared (visible copy), the tunnel binary, the daemon |
| Approval surface | **Requests** (section) · **request** (item) · verbs **Approve / Deny** | Approvals/Host gates split |
| Server + tunnel lifecycle | **Connection**; states **Off / Local / Public** | tunnel (as a section name), endpoint |
| Product connection paths | **Local** (apps on this Mac) / **Public** (remote devices through the app-managed Cloudflare link) | third transport mode, private transport mode |
| The URL | **Public URL** (field label) / "your public link" (prose) | public endpoint, public HTTPS route, public MCP URL (visible copy) |
| Tunnel modes | **Instant Link / Your Domain** | quick tunnel, named tunnel |
| Going public | **Go Public** / **Stop Sharing** | Open Public Tunnel, Start Tunnel (visible copy) |
| Auth transport mode | **Sign-in method** | the "Privacy" picker, bare "Access" picker |
| ChatGPT public-link auth | **Dynamic OAuth with Dynamic Client Registration** (spell out the registration method in setup copy) | DCR abbreviation in visible copy, manual OAuth |
| Verification | **Test Tool… / Check Readiness** | Proof, Markers (visible UI) |
| Readiness | **Readiness** ("Check Readiness") | Requirements/Readiness drift, Check Access vs Check Again vs Check Readiness salad (Check Again = re-run inside a remedy; Check Readiness = the five-check sweep) |
| Local MCP import | **Local MCP Servers**; verb **Import**; states **Ready to Import / View Only / Imported** | bridge, Bridgeable, Scan-only, probe (verb → "check") |
| MacRemote's own sign-in to an MCP server (D62) | verb **Sign In…**; states **Signed In / Sign-in Required / Signing In**; verb **Sign Out**; the reply page says "MacRemote is signed in to ‹server›." | authorize, authenticate, OAuth (as a visible label), token (primary copy), log in |
| Instance identifier | **Private address ID**; action **Reset Private Address…** | Rotate Instance ID (visible copy) |
| Local binding | **"Only on this Mac"** (primary) + `127.0.0.1` mono detail | Bind address (primary), loopback, Bound to 127.0.0.1 |
| Event list | **Activity** — "This session" | Logs, Audit trail, Recent Activity (as a distinct term) |
| macOS grants | **Full Disk Access** (always spelled out); **Privacy Permissions**; FDA rows are **items** | FDA, targets, app-service privacy access |
| Reset-app-row action | **Re-add MacRemote in System Settings** | Reset App Row (visible copy) |
| Pings | **notifications** | alerts |
| Kept verbatim | **Scan This Mac**, **Always Allow**, **Read-only**, status words Stopped/Starting/Running | — |
| Public-link auto-recovery | **Reconnecting** (status word) / "Reconnecting public link (attempt N)" (prose) — shown while the watchdog is restoring a dropped public link (D28) | Recovering tunnel, Restarting tunnel, Reconnecting tunnel (visible copy) |
| MCP freshness | **Scan results may be out of date** (when configs changed since last refresh) | — |
| Automatic discovery | Config-only MCP surfacing at launch/activation — **not** automatic import or share; the Tools count means unimported candidates marked **New**, never approvals | auto-import, auto-share, background probing |
| Built-in native tools | **Built-in** (source group) / "runs natively in MacRemote" | native backend, `filesystem_*`, subprocess (visible copy) |
| Downloadable result | **download link** (prose) / **Public URL**-family for the link | artifact, artifact token, `/artifact` (primary copy — allowed in Details/mono) |

> **Model-facing exemption.** Built-in tool *summaries* (the MCP `description` text composed in `LocalMCPServer.toolDescription(for:)`, echoed in the Inspector Overview) are metadata authored for the model, not primary UI copy. They may use technical terms (`argv`, `base64`, `host approval`, etc.) and are **exempt from this glossary**.
>
> **Narrow technical-name exemption.** **RemCTL Capability Host**, **NotesCTL Capability Host**, and **MusicCTL Capability Host** are signed apps' official names. Those exact names may appear in readiness diagnostics and selectable technical details. This exception does not permit `host` as a generic visible term or product concept.

### 4.3 Banned words & patterns (visible copy)

`host` (any compound; except the exact technical names **RemCTL Capability Host**, **NotesCTL Capability Host**, and **MusicCTL Capability Host** in the narrow contexts above) · `expose/exposure/exposed` · `surface` (as tool-set noun) · `client` in headlines · `connector`/`provider` in headlines · `FDA` · `DCR` (abbreviation in visible copy) · `rotate` (visible labels) · `Adapter`/`Template` as mode names · `bridge/bridgeable/scan-only/probe` · `proof/markers` (visible UI) · `audit trail` · `alerts` · `loopback`/`bind address` (primary copy) · third-party transport as a product connection path · `argv/stdin/stderr/tools/list/PKCE/bearer` (primary copy — allowed inside Details/mono/technical exports) · `artifact/artifact_token/download_url/base64/sha256/native backend` (primary copy — allowed inside Details/mono/technical exports) · `Privacy` as an auth-mode label · **`Verified`** (any verification claim beside a brand mark — the mark is a hint, not proof) · **`device`** / **`connected device`** (a connected app is an app, not a device) · **`online`** / **`offline`** (MacRemote knows token liveness, not presence) · **`last seen`** (use *Last connected*) · **`Delete App`** (use *Sign Out*) · "MacRemote will [enumerate artifacts]" dialog frame · passive "will appear here" · `...` three-dot ellipsis · literal backticks · **"Approve All"** (any phrasing).

### 4.4 Canonical rewrites (the load-bearing strings — final)

1. Go-public confirmation: **"This creates a public link to your shared tools — not to your whole Mac. 166 tools will be reachable: 68 read-only, 98 that ask you before running. New apps must use the sign-in method you chose."**
2. OAuth consequence: **"If you approve, Claude can run your 68 read-only tools without asking. The 98 tools marked Asks First will ask before they run."** Above it, the code row **Code 123 456** and the caption **"Approve only if your sign-in page shows this code. Anyone with your public link can ask to connect under any name. After approval the sign-in returns to ‹destination›."**
3. Always Allow caption: **"Allowing once runs it now. 'Always Allow' lets Claude run this tool without asking again — you can undo it in Apps."**
4. Reset Private Address: **"Gives your Mac a new private address. Sharing stops and every app is signed out."**
5. Sign Out All Apps: **"Signs out every connected app. Your public link stays the same — each app just asks for your approval again."**
6. Full Disk Access copy: default detail **“Add MacRemote to Full Disk Access — then relaunch and check again.”** · explainer **“MacRemote starts the tools you share, and macOS gives them MacRemote's access, so MacRemote is the only item to add. After changing System Settings, run Check Again — MacRemote relaunches itself once if macOS still reports the old answer.”** (explainer → ⓘ popover, verbatim)
7. Requests empty state: **"When an app wants to connect or run a tool that needs your OK, it shows up here — and in a window you can't miss."**
8. Cloudflare helper install consent (replaces the retired Homebrew instruction, SPEC D44) — offer line: **"One-time setup: MacRemote can install Cloudflare's helper for you."** · disclosure label **"What gets installed"** · consent sentence: **"Cloudflare's tunnel helper ‹version›, published by ‹publisher› — about ‹size›. MacRemote checks the download against Cloudflare's published checksum and signature, and stores it only for its own use — your shared tools can't touch it. You can remove it any time in Settings ▸ General."** · Homebrew alternative, kept inside the same disclosure: **"Prefer to install it yourself? MacRemote uses your own copy when it finds one."** + the `brew install cloudflared` mono chip and Copy Command. Progress states: **"Downloading Cloudflare's helper…"** → **"Checking the download."** → **"Cloudflare's helper is ready."** (the ready line lingers ~2 s in onboarding S4 so the work has a visible ending). **Failure headlines are fixed per kind, and the technical reason is never one of them** — it renders separately as a selectable mono detail (and as Settings' **Reason** row): download or install failure → **"MacRemote couldn't install Cloudflare's helper."** · checksum or signature mismatch → **"The download didn't match what Cloudflare published, so MacRemote discarded it."** · attempted while the link is live → **"Turn the public link off before replacing Cloudflare's helper."** · cancelled → **"The install was cancelled. Nothing was kept."** · no pinned build for this processor → **"MacRemote doesn't have a Cloudflare helper for this Mac's processor. Install it yourself and MacRemote will use your copy."**
9. Supervision warning in Activity: **"MacRemote restarted while your link was live. Open MacRemote to check or restart it."** (previous URL as second mono line)
10. Local MCP intro: **"Find the MCP servers your Mac's AI apps already use, and share their tools through MacRemote."**
11. MCP Refresh warning: **"Refreshing updates this server's tools. Unchanged tools keep Always Allow; changed tools ask again."**
12. Loopback row: **"Only on this Mac"** + `127.0.0.1:51891` mono detail.
13. Welcome: **"MacRemote lets ChatGPT, Claude, and other MCP apps use tools on this Mac."** — one sentence, because the three value rows underneath already say the rest and repeating them in prose is noise. Canonical value rows: `wrench.and.screwdriver` / **"Share only the tools you choose"** · `person.badge.key` / **"Choose how apps sign in"** · the security row `lock.shield` / **"Keep risky tools behind an approval"**.
14. ChatGPT public setup: **"In ChatGPT, open Settings ▸ Plugins, create a developer-mode app, paste the Public URL into MCP server URL, choose OAuth with Dynamic Client Registration, then approve the request in MacRemote."**
15. Remote reachability — the onboarding S4 truth note, which replaced the retired S2 sentence (that one used the banned "cannot" and sat one screen too early): **"Apps on this Mac can connect over the local server. Your other devices need your public link."**
16. File Transfer Folders footer (SPEC D67/D72): **"The built-in File Transfer tools reach only these folders, and so does any other tool that runs without asking. Reading needs no approval, so add a folder only if an app may read everything in it. Keys, keychains, and MacRemote's own data are never reachable."** With **Whole Mac** listed: **"File Transfer, and any other tool that runs without asking, can read every file your account can open. Allow this only if you trust every connected app. Writing still asks first. SSH and cloud keys, keychains, and MacRemote's own data are never reachable."**
17. Sign out one app (SPEC D45) — title **"Sign out "Claude"?"** · body **"Claude's sign-in, tokens, waiting requests, and Always Allow settings are removed. It can ask to connect again anytime."** · confirm **Sign Out**. The result row states what was actually removed and omits every zero: **"Signed out Claude — removed 1 registration, 2 access tokens, and 3 Always Allow rules."** With nothing left to remove: **"Signed out Claude — there was nothing left to remove."**
18. Sign out every app (dialog body) — **"Every app's sign-in, tokens, waiting requests, and Always Allow settings are removed. Each app can ask to connect again anytime, and your public link doesn't change."** (The Security caption stays rewrite #5.)
19. Advanced sign-in tradeoffs (SPEC D42) — disclosure caption **"Most apps need nothing here. Change this only when an app asks you for a client ID and secret, or can only send one header."** Then, per method:
    - Dynamic OAuth (Default): **"The app signs itself up and asks for your approval. Nothing to copy or paste. Works with ChatGPT, Claude, Raycast, and Notion."**
    - OAuth Client Secret: **"You paste a client ID and secret into the app. Use it only when the app asks for those two fields. While this is on, apps that sign themselves up can't connect — including ChatGPT and Claude over your public link."**
    - Single Header: **"MacRemote makes one secret token the app sends with every request. For apps that can send a custom header but can't finish a sign-in. ChatGPT, Claude, and Notion can't send it."**
    A blocked pairing has to say *which* wall it hit: **"‹App› signs itself up over your public link, and this method turns that off. Use Dynamic OAuth for ‹App›."** vs **"‹App› can't send a fixed sign-in header. Use Dynamic OAuth for ‹App›."**
    Changing the method signs out every app the new method does not admit. The result is stated under the picker in the form of rewrite #17, naming the apps by how they signed in: **"Signed out 2 apps that signed themselves up — removed 2 registrations, 2 access tokens, and 2 refresh tokens."** · **"Signed out 1 app that used a client ID and secret — removed …"** · moving to Single Header: **"Signed out 3 apps — removed …"**. Leaving Single Header adds **"The Single Header token no longer works."** Nothing is shown when the change stopped nothing.
20. Single Header token, not in use — **"Not in use — ‹method› is your sign-in method."** The OAuth Client Credentials section shows the same line whenever the method is not OAuth Client Secret, because those credentials sign in under that method only. Delete confirmation body: **"Any app still sending it is signed out. You can generate a new one here at any time."**
21. Remove the Cloudflare helper — title **"Remove MacRemote's copy of Cloudflare's helper?"** · body **"This removes only the copy MacRemote downloaded. A helper you installed yourself is left alone, and MacRemote will use it instead."** · refusal while the link is live: **"Turn the public link off before removing Cloudflare's helper."**
22. Welcome public-address choices — **Instant Link:** **"Fastest. No Cloudflare account or domain. MacRemote creates a random temporary address that changes each time."** · **Your Domain:** **"A stable address you choose, such as macremote.example.com. You need a Cloudflare account, a domain added to it, and an API token."** The Your Domain checklist must also say that MacRemote shows the token permissions, never saves the token, and follows this order: paste the token → load domains → choose the domain and subdomain → deploy.
23. Welcome install location — only outside `/Applications`: **"Move MacRemote to Applications, then reopen it there. This keeps macOS permissions attached to one copy."** + **Open Applications**. Do not show a made-up download link.

---

**Counts agree with their nouns.** The examples above quote plural counts, but the app fills in live ones, and a new owner often shares a single tool. Write counted nouns with `counted(_:_:)` (`Models/CountedNoun.swift`), so one tool reads "1 tool", and match the verb ("1 that asks"). Rewrite #1 lives in `ToolExposureSummary.publicLinkSentence`. Rewrite #2 leaves out its second sentence when no shared tool asks first.

**Narrow columns.** A chip never wraps or shrinks: a squeezed chip breaks its
label letter by letter. The container adapts instead. A row of chips wraps
(`FlowLayout`, as in the Tools filter row). A list row gives up its chips before
its title, with `ViewThatFits`: every chip, then the one that matters, then
that chip as a symbol, and only then a shortened title (`ToolRowView`). Check
any new row with the inspector open at the window's minimum width.

## 5. Accessibility

1. **Contrast on glass:** all text-bearing glass is `.regular` (never `.clear`); the hero keeps a luminance-safe tint opacity (≤0.35); QA at both extremes of the macOS 27 transparency slider.
2. **Reduce Transparency / Increase Contrast:** system glass adapts automatically (real APIs only — rule 3.6); the Connection canvas wash falls back to plain `windowBackgroundColor`; verify chips/hairlines at increased contrast.
3. **Reduce Motion:** `glassEffectID` morphs and the canvas transition become crossfades; symbol effects (`.variableColor`, `.bounce`, `.pulse`) are suppressed; the countdown ring still updates (it is information, not decoration) but without pulse.
4. **Color never alone:** every status/capability color pairs with a glyph or word (token table §1.4); state words are written out on approval cards and history rows.
5. **VoiceOver:** the hero exposes one combined element — "Connection: Public. macremote.example.com. Stop Sharing, Stop Server, Copy available." Approval window announces on appearance: "Approval request. Claude wants to run Convert To PNG. Write — this can change files on your Mac. Expires in 1 minute 47 seconds." Countdown announces at 60 s and 15 s remaining. `CopyButton` confirms "Copied". Badges name their scope: "2 requests waiting" versus "2 new MCP servers found. Open Tools to review them; nothing was imported automatically."
6. **Keyboard:** full command map (SPEC §2.3); approval verbs are menu commands (never require the floating window to be key); inspector persists across arrow-key selection; `.searchable` fields focus via ⌘F; every control reachable by Tab/Full Keyboard Access.
7. **Text selection everywhere:** every identifier/URL/path/argument stays `.textSelection(.enabled)` (parity rule CC-1) — accessibility and operator ergonomics are the same requirement here.
8. **Sidebar metrics are user-configurable** — never hardcode sidebar row heights/icon sizes (HIG Rule 5); respect the user accent color (Rule 35).
9. **Dock badge** only for pending requests, cleared when reviewed (Rule 42); the Tools discovery count never propagates to the Dock, menu bar, notifications, or Approval window. Notifications remain limited to decisions and failures, never routine telemetry (Rule 43).
10. **App marks are decoration to VoiceOver.** `ConnectedAppIconView` is `.accessibilityHidden(true)` by default in every host — the Apps card, the Requests row, and the Approval window all state the app's name in adjacent text, and `CountdownRing` already ignores its children and announces "Expires in…". A mark must never become the only way to tell two apps apart. Visually the reverse rule applies: an expired or waiting session **dims** its mark (0.55) rather than replacing it with a generic glyph, because recognition is what makes the row scannable, and losing it would punish the exact state the user most needs to act on. Increased contrast keeps bundled artwork (it carries its own contrast) rather than dropping to a symbol.

---

## 6. Third-party brand marks

1. **A mark is a hint, never an identity claim.** It is chosen from strings the app supplied about itself, so it may be wrong or hostile. Never place a checkmark, a "Verified" word, or any other trust affordance next to one, and never let it sit in a position that reads as authentication.
2. **Reproduce marks unaltered.** Downscale only. No recolor, no crop, no re-drawing, no adding MacRemote's tint, no forcing a shape the owner did not publish. Record every transformation in the manifest.
3. **Licensing gates bundling, not code.** Artwork ships only when published terms permit redistribution. Every bundled file needs a row in `Resources/ConnectedAppIcons/MANIFEST.json` carrying owner, source URL (pinned to a commit when the source is a git host), source hash, retrieval date, license and license URL, the redistribution evidence quoted, transformations, and the committed file's own SHA-256 — plus the verbatim notice in `THIRD-PARTY-NOTICES.md`. Where a vendor requires its logo "exactly as provided", the row records **no** transformation and the source and committed hashes must match.
4. **Four tiers, in order, and the tier is never shown** (D48): a curated bundled asset, then the mark read out of a copy of the vendor's own app installed on this Mac, then a `data:` icon the app attached to its MCP handshake, then the per-brand SF Symbol. A brand with no bundling permission is not a second-class citizen — it just resolves lower down. Reaching the symbol is never an error state, and no tier may be rendered as a badge, a rank, or a trust affordance.
5. **Still no network request to draw an icon.** The installed-app tier reads the filesystem; the handshake tier accepts inline bytes only. An `http(s)` icon source is refused, favicons and community re-drawings are refused, and OAuth `logo_uri` is dropped because it arrives before anyone has approved anything.
6. **Recognition has a resolution floor.** A vendor's named variant is only used when its raster is at least twice the point size it will be drawn at; below that the app icon wins. A blurry authentic mark is worse than a sharp one from the same bundle.
7. **Brand names appear only to identify the app that connected.** All trademarks belong to their owners; the notices file says so, and no vendor sponsors or endorses MacRemote.
