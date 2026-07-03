# MacRemote — Design Guidelines (Living Rulebook)

> **Provenance.** Produced by a judged design competition on **2026-07-01**. Five directions competed — `guided-operator`, `mission-control`, `system-utility`, `glass-expressive`, `dense-console` — scored by five judges; rank-point tally: **mission-control 21 · guided-operator 19 · system-utility 15 · dense-console 11 · glass-expressive 9**. The winning skeleton is Mission Control with judge-directed grafts; the binding decision log lives in `DESIGN-SPEC.md §1.2`. This file is the rulebook implementation and review must enforce. When this file and old code disagree, this file wins.

---

## 1. Design tokens (Swift-expressible)

### 1.1 Spacing (pt) — nothing else is allowed

| Token | Value | Use |
|---|---|---|
| `space1` | 4 | intra-row, chip internals |
| `space2` | 8 | control gaps, row internals |
| `space3` | 12 | intra-card stacks |
| `space4` | 16 | card padding |
| `space5` | 20 | window content margins |
| `space6` | 24 | section/card gaps, hero container spacing |
| `space8` | 32 | hero breathing room |

List/Form row heights and insets are **system default** — never compressed (`defaultMinListRowHeight` overrides are banned; macOS 26 breathing room is the point). The current 0/1/2/3/5/6/10/14/18 zoo is retired.

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

---

## 2. Component library (replaces `SharedViews.swift`)

Every component names what it replaces. `StatusPanel` (dead code), `HeaderView` (in-content titles), `FlowStep`/`FlowStepState`, `MetricPill`, `StatusBadge`, and `panelStyle()` are deleted.

| Component | Anatomy | Variants / states | Replaces |
|---|---|---|---|
| `ConnectionHero` | One `GlassEffectContainer(spacing: 24)`: state chip + status word (`.title2` semibold) + URL capsule (`.title3` mono) + fused Copy (`glassEffectUnion`) + verb buttons beneath. `glassEffectID` morphs between states; `.interactive()` on clickables only. | Off / Starting / Local / Public-pending / Public / Partial-failure ("Server running · link stopped") / Failed / Unavailable / Zero-tools. Compact variant reused in onboarding S4–S5. | DashboardView flow-step cards 2–3; TunnelView status rows |
| `StatusOrb` | Animated state circle: symbol + tint + `symbolEffect` per state | off/starting/local/public/failed | ad-hoc dots |
| `StatChip` | count + label capsule, quaternary fill; **tappable = filter/navigate** | static · filter (selected/unselected) | `MetricPill` |
| `StateChip` | severity-tinted capsule w/ symbol; one severity scale | status · capability (Read-only/Asks First/Write/Destructive) · state words | `StatusBadge` |
| `Card` | content-layer card: 16 pt padding, `.background(.quaternary.opacity(0.4))`, concentric 12 radius, **no stroke**, optional collapsed-summary header (Rule 24: collapsed cards must summarize non-default state) | expanded · collapsed-summary | `panelStyle()` (the twenty gray boxes) |
| `KeyValueGrid` | aligned label + mono value rows, selectable, per-row hover `CopyButton`; lives inside a `▸ Details` disclosure | plain · privacy-sensitive rows | ad-hoc metadata grids (Clients, Approvals, proofs, credentials) |
| `CopyButton` | one copy affordance app-wide: `doc.on.doc` → checkmark (`contentTransition(.symbolEffect(.replace))`, 1.2 s), writes pasteboard **and** the audit-log line | inline · hover-reveal (on `MonoValue`) | 10+ divergent copy buttons |
| `MonoValue` | machine text: `.monospaced`, middle truncation, `.textSelection(.enabled)`, hover-reveal `CopyButton` | — | scattered mono Text |
| `ApprovalCard` | actor header (app glyph + name) → capability sentence (severity-tinted) → structured argument rows (`stdin` summarized) → `▸ Details` grid → caption ("…you can undo it in Apps") → verb row; countdown ring = `Gauge` drawn **around the app icon**, `TimelineView`-driven, green→amber last 30 s | window (glass verb row) · inline queue row (content) · onboarding demo; tool-call · OAuth-connect (consequence copy); pending/approved/denied/expired/server-stopped | ApprovalsView rows |
| `CountdownRing` | `Gauge`/trimmed-circle progress around a 64 pt icon, real 120 s/300 s fuse | normal · amber (<30 s) | (new) |
| `ReadinessRow` | state glyph + title + live detail + **expansion (available in every state — SPEC D1)** + contextual fix button | ready/checking/warning/blocked; FDA row expands `AccessFixer`; Privacy row expands its remedy | Security Gates rows; TunnelView readiness rows |
| `AccessFixer` | status row → `TargetRow` list → numbered ①②③ strip → primary row (Check Again prominent · Open System Settings · Later) → `Troubleshoot ⌄` menu | hosts: app-global sheet · Readiness expansion · onboarding S3; states: checking/required/confirmSetup (prominent Confirm Setup verb)/ready(auto-dismiss)/failed; extended to macOS-privacy failures | the three duplicate FDA button farms |
| `ConduitLightLayer` | "Aurora Exchange" — the hero URL capsule holds a living iridescent aurora while the tunnel is public: two hue bands drifting in opposite directions (outbound/inbound), edge glints running the top rim L→R and bottom rim R→L, and a white-cored packet comet crossing every ~5 s, alternating direction. A `.colorEffect` color layer between the glass and the text — **never a second glass surface** (the §3 glassEffect map is unchanged). Shader: `Shaders/ConduitLight.metal` (core in `auroraExchange()`, shared with the `previewGrid` offscreen kernel — `script/render_shader_preview.swift` renders PNG frames for review without launching the app), precompiled to the committed `Shaders/default.metallib` via `script/compile_shaders.sh` (CLT host has no Metal compiler; missing metallib = silent no-op). 30 fps TimelineView, paused on occlusion; Reduce Motion = static aurora; removed under Reduce Transparency; 0.72-alpha highlight ceiling with a calmed midline band so the URL keeps contrast; full-size hero only | `.publicRunning` only; gain fades in 0.45 s after the glass morph settles | new 2026-07-02, redesigned for visibility same day |
| `TargetRow` | NSWorkspace icon + role capsule + **probed access chip** (Access works · No access yet · Checked when it runs — truthful probe results, never a guess at System Settings rows) + mono path + Copy (path & fileURL types) + Reveal + `.onDrag { NSItemProvider(object: NSURL) }` + `.help` | access chip: ready/attention/quiet by probe outcome | FullDiskAccessTargetRow (+ per-target access state, 2026-07-02). **Drag rule (falsifiable):** target rows must drag a file-url *reference* via `NSItemProvider(object: NSURL)`. SwiftUI `.draggable(URL)` stages a bundle COPY under `~/Library/Caches/com.apple.SwiftUI.Drag-*`, so System Settings grants Full Disk Access to a throwaway copy — `grep -rn '\.draggable(' Views` must return no fixer target rows. |
| `ToolRow` / `ServerGroupHeader` / `ToolInspector` | list row (icon/name/chips/Share toggle) · MCP server header (source badge, endpoint, Ready to Import/View Only, Import/Refresh-with-warning, Share All, progress, probe errors) · tabbed inspector (**Overview / Definition / Permissions / Activity** + Test Tool/Duplicate/Remove footer) | shared/not-shared (0.62 dim) · per-row error · built-in (read-only Definition) | ToolsView cards; LocalMCPToolsView panels; the Add Tool sheet's edit duty |
| `AppCard` | identity header (provider glyph, state, token counts) + Details grid + bulk verbs + grouped policy list with per-category `Allow ▾` | active · expired (gray) | ClientsView cards |
| `LogRow` | mono time + level chip + message (2-line, selectable) + optional `lock.shield` prefix glyph | info/warning/error | LogsView row (promoted into the system) |
| `SetupChecklist` | live-stated numbered steps card with jump links; collapses to "All set ✓" capsule on first completion; regression re-expands only the failing row (30 s debounce, one-shot notification escalation, never above a live hero) | leading · collapsed capsule · regression | ConnectionFlowPanel |
| `DeployStageList` | four named stages (Check Cloudflare access → Create tunnel → Configure DNS → Start); failure lands on its stage: human line first, raw API text in copyable mono disclosure | pending/active/done/failed per stage | the single deploy spinner |
| `EmptyState` | `ContentUnavailableView` wrapper enforcing the pattern: "No X yet." + plain-language trigger + CTA | list-empty · `.search` | bare empty panes |
| `StatusTile` | the collapsed face of a Connection card, sized for an adaptive `LazyVGrid` (min 240 / max 420, `Space.s4` gaps — D19): icon + `cardTitle` + chevron header over the card's Rule-24 summary; same Card material recipe (quaternary 0.4 fill, concentric 12, **never glass**); the whole tile is one open button; hover = fill shift to 0.55, no lift | resting · hover | the three stacked full-width collapsed cards on Connection |

**Disclosure behavior (app-wide):** `▸ Details` disclosures persist their state per section; **⌥-click expands every disclosure on the current page**. Collapsed summaries must state non-default values ("Your Domain · Deployed ✓").

---

## 3. Liquid Glass usage map — hard rules

**The falsifiable rule: the only `glassEffect(` call sites in app code live inside `ConnectionHero`. If code review finds `glassEffect(` anywhere else, the design is violated.** (One component, one `GlassEffectContainer`, reused by the main window and onboarding S4–S5.)

### Gets glass

1. **`ConnectionHero`** — the app's single custom `GlassEffectContainer(spacing: 24)`; children carry `glassEffect(.regular.tint(stateColor))` + `glassEffectID(_, in:)`; the copy affordance joins via `glassEffectUnion`; transitions `.glassEffectTransition(.matchedGeometry)`; `.interactive()` only on clickable elements. Tint = semantic status (blue/green/red), never theme.
2. **System button styles** (not custom glass): exactly one `.buttonStyle(.glassProminent)` per view region — hero primary verb, Approval window's Approve Run, onboarding primaries, Library sheet's Install, Access Fixer's Check Again. Paired secondaries `.glass`. `ToolbarItemPlacement.confirmationAction` auto-styles — prefer it.
3. **`safeAreaBar(edge: .bottom)`** in Requests (Deny All Waiting) — glass buttons over scrolling content, appears only with 2+ pending.
4. **System chrome, free, untouched:** window toolbar (`ToolbarItemGroup` + `ToolbarSpacer` grouping; status items detach via `.sharedBackgroundVisibility(.hidden)`), sidebar, sheets, popovers, menus, dialogs, MenuBarExtra, search fields, standard controls.

### Never glass (content layer — enumerated)

Every `Card`; tool/app/request/log lists and all rows; `KeyValueGrid`s; readiness rows; the Address form; Settings forms; inspectors; `AccessFixer` bodies; onboarding body content; the Connection canvas wash (it is a color, not a material); the web pages. The Approval **window body** is standard window material — only its verb row uses glass button styles.

### Hard rules (from `research-liquid-glass.md` §8 — cite by number in review)

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
12. **Notifications:** title = short human headline ("Public link needs attention"); body = one sentence + one action ("Open MacRemote to check or restart it.").
13. **Consequence at the verb:** every approval, Always Allow, and destructive dialog states what changes ("Claude can now run Convert To PNG without asking — you can undo it in Apps").
14. Keep Apple-established terms verbatim: **Always Allow, Full Disk Access, System Settings, Read-only**.

### 4.2 FINAL glossary — one term per concept (banned terms in the last column)

| Concept | The one term | Bans |
|---|---|---|
| Making a tool visible / its state | **Share** (toggle) / **Shared · Not Shared · Partially Shared** | Expose, Exposed, Enabled, Partially Enabled, Allowed commands |
| The set of visible tools | **Shared Tools** | Tool Surface, Exposed Surface, Exposed Tool Surface |
| A runnable command | **Tool** (catalog entries: **presets**; groups: **Bundles**, **Found on This Mac**) | detected CLI, command preset (as UI labels) |
| Tool authoring modes | **Fixed Command / Flexible Command** | CLI Adapter, Command Template, Template, Adapter, Full Access, Generic adapters |
| The remote party | **App** (headlines/prose); "Client ID" survives **only** inside Details grids | client, remote client, OAuth client, MCP client, connector, provider, remote app |
| The approving side | **you / this Mac** | host, host Mac, host app, host approval, process context |
| Per-call gating | **Asks First** (chip) / "asks you before running" (prose) | host-gated, write-capable, per-call host approval |
| Standing permission | **Always Allow** (kept) | allowances, trust policies, Tool Trust |
| All sign-ins reset | **Sign Out All Apps** | Revoke OAuth Grants |
| Approval surface | **Requests** (section) · **request** (item) · verbs **Approve / Deny** | Approvals/Host gates split |
| Server + tunnel lifecycle | **Connection**; states **Off / Local / Public** | tunnel (as a section name), endpoint |
| The URL | **Public URL** (field label) / "your public link" (prose) | public endpoint, public HTTPS route, public MCP URL (visible copy) |
| Tunnel modes | **Instant Link / Your Domain** | quick tunnel, named tunnel |
| Going public | **Go Public** / **Stop Sharing** | Open Public Tunnel, Start Tunnel (visible copy) |
| Auth transport mode | **Sign-in method** | the "Privacy" picker, bare "Access" picker |
| Verification | **Quick Test / Full Test / Test a Tool… / Check Readiness / Last result / Testing Guide** | Smoke, Preflight, API Smoke, Proof, Markers (visible UI; kept verbatim inside copied technical output) |
| Readiness | **Readiness** ("Check Readiness") | Requirements/Readiness drift, Check Access vs Check Again vs Check Readiness salad (Check Again = re-run inside a remedy; Check Readiness = the six-check sweep) |
| Local MCP import | **Local MCP Servers**; verb **Import**; states **Ready to Import / View Only / Imported** | bridge, Bridgeable, Scan-only, probe (verb → "check") |
| Instance identifier | **Private address ID**; action **Reset Private Address…** | Rotate Instance ID (visible copy) |
| Local binding | **"Only on this Mac"** (primary) + `127.0.0.1` mono detail | Bind address (primary), loopback, Bound to 127.0.0.1 |
| Event list | **Activity** — "This session" | Logs, Audit trail, Recent Activity (as a distinct term) |
| macOS grants | **Full Disk Access** (always spelled out); **Privacy Permissions**; FDA rows are **items** | FDA, targets, app-service privacy access |
| Reset-app-row action | **Re-add MacRemote in System Settings** | Reset App Row (visible copy) |
| Pings | **notifications** | alerts |
| Kept verbatim | **Scan This Mac**, **Always Allow**, **Read-only**, status words Stopped/Starting/Running | — |

### 4.3 Banned words & patterns (visible copy)

`host` (any compound) · `expose/exposure/exposed` · `surface` (as tool-set noun) · `client` in headlines · `connector`/`provider` in headlines · `FDA` · `rotate` (visible labels) · `Adapter`/`Template` as mode names · `bridge/bridgeable/scan-only/probe` · `smoke/preflight/proof/markers` (visible UI) · `audit trail` · `alerts` · `loopback`/`bind address` (primary copy) · `argv/stdin/stderr/tools/list/PKCE/bearer` (primary copy — allowed inside Details/mono/technical exports) · `Privacy` as an auth-mode label · "MacRemote will [enumerate artifacts]" dialog frame · passive "will appear here" · `...` three-dot ellipsis · literal backticks · **"Approve All"** (any phrasing).

### 4.4 Canonical rewrites (the load-bearing strings — final)

1. Go-public confirmation: **"This creates a public link to your shared tools — not to your whole Mac. 166 tools will be reachable: 68 read-only, 98 that ask you before running. New apps still need your approval to connect."**
2. OAuth consequence: **"If you approve, Claude can run your 68 read-only tools without asking. The 98 tools marked Asks First will still ask every time."**
3. Always Allow caption: **"Allowing once runs it now. 'Always Allow' lets Claude run this tool without asking again — you can undo it in Apps."**
4. Reset Private Address: **"Gives your Mac a new private address. Sharing stops and every app is signed out."**
5. Sign Out All Apps: **"Signs out every connected app. Your public link stays the same — each app just asks for your approval again."**
6. FDA explainer: **"MacRemote and some of its tools each need Full Disk Access. Add every item below — then relaunch and check again."** (layering lecture → ⓘ popover, verbatim)
7. Requests empty state: **"When an app wants to connect or run a tool that needs your OK, it shows up here — and in a window you can't miss."**
8. cloudflared missing: **"Cloudflare's helper isn't installed. Install it with `brew install cloudflared`, then check again."** (rendered as real code formatting + Copy Command)
9. Supervision push: title **"Public link needs attention"** · body **"MacRemote restarted while your link was live. Open MacRemote to check or restart it."** (previous URL as second mono line)
10. Local MCP intro: **"Find the MCP servers your Mac's AI apps already use, and share their tools through MacRemote."**
11. MCP Refresh warning: **"Refreshing replaces this server's 12 tools and clears their Always Allow settings."**
12. Loopback row: **"Only on this Mac"** + `127.0.0.1:51891` mono detail.

---

## 5. Accessibility

1. **Contrast on glass:** all text-bearing glass is `.regular` (never `.clear`); the hero keeps a luminance-safe tint opacity (≤0.35); QA at both extremes of the macOS 27 transparency slider.
2. **Reduce Transparency / Increase Contrast:** system glass adapts automatically (real APIs only — rule 3.6); the Connection canvas wash falls back to plain `windowBackgroundColor`; verify chips/hairlines at increased contrast.
3. **Reduce Motion:** `glassEffectID` morphs and the canvas transition become crossfades; symbol effects (`.variableColor`, `.bounce`, `.pulse`) are suppressed; the countdown ring still updates (it is information, not decoration) but without pulse.
4. **Color never alone:** every status/capability color pairs with a glyph or word (token table §1.4); state words are written out on approval cards and history rows.
5. **VoiceOver:** the hero exposes one combined element — "Connection: Public. macremote.viticci.net. Stop Sharing, Stop Server, Copy available." Approval window announces on appearance: "Approval request. Claude wants to run Convert To PNG. Write — this can change files on your Mac. Expires in 1 minute 47 seconds." Countdown announces at 60 s and 15 s remaining. `CopyButton` confirms "Copied". Badges have `accessibilityLabel`s ("2 requests waiting").
6. **Keyboard:** full command map (SPEC §2.3); approval verbs are menu commands (never require the floating window to be key); inspector persists across arrow-key selection; `.searchable` fields focus via ⌘F; every control reachable by Tab/Full Keyboard Access.
7. **Text selection everywhere:** every identifier/URL/path/argument stays `.textSelection(.enabled)` (parity rule CC-1) — accessibility and operator ergonomics are the same requirement here.
8. **Sidebar metrics are user-configurable** — never hardcode sidebar row heights/icon sizes (HIG Rule 5); respect the user accent color (Rule 35).
9. **Dock badge** only for pending requests, cleared when reviewed (Rule 42); notifications only for decisions and failures, never routine telemetry (Rule 43).
