# MacRemote — Final Design Specification

> **Provenance.** This document is the synthesis output of a judged design competition run on **2026-07-01**. Five complete directions were produced and scored by five judges (commercial, platform purist, power operator, prosumer first-impression, parity auditor). Rank-point tally (higher = better): **mission-control 21 · guided-operator 19 · system-utility 15 · dense-console 11 · glass-expressive 9**. **Winner: `mission-control`.** This spec starts from Mission Control's skeleton, resolves every fatal flaw any judge raised, and deliberately grafts the judge-recommended ideas from the other four directions. Where judges conflicted, the decision and rationale are recorded in §1.2. The companion rulebook is `DESIGN-GUIDELINES.md`.
>
> Parity contract: all **200** items in `scratchpad/design/parity-inventory.md` are mapped in §7. Nothing may be silently dropped. Platform target: **macOS 26 SDK (26.5), Liquid Glass**, runtime macOS 26/27 — every API named here is verified compiling per `research-liquid-glass.md` (build with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`, `.macOS(.v26)`, tools-version 6.2).

---

## 1. Thesis and decision log

### 1.1 Thesis (from the winner)

MacRemote keeps exactly one precious object alive: **this Mac's remote connection** — the state machine Off → Local → Public that, when public, produces the URL you paste into Claude. The app is a cockpit around that object: one hero **Connection** surface where a single morphing glass object carries the state and the public URL; a calm five-item sidebar whose only number is "things waiting for your decision"; a floating, non-activating **Approval window** as the security interrupt; and Tailscale-grade depth discipline — all 200 capabilities survive, but admin machinery (custom domains, credentials, Full Disk Access forensics, verification) lives exactly one level below a quiet surface, reached from the status object it serves. The current app narrates its security model on every screen; this design *shows* the state and saves the narration for the moments a decision is actually being made.

### 1.2 Decision log — conflicts resolved (binding)

| # | Conflict | Decision | Rationale |
|---|---|---|---|
| D1 | **FDA reachability** — Mission Control contradicted itself (§4.1 "row click → detail" vs Risk 2 "expansion renders only when not green"); System Utility orphaned the FDA suite when green. | **Readiness rows are clickable/expandable in every state, including green.** The Full Disk Access row always expands into the Access Fixer; the Privacy row always expands into its remedy. No conditional rendering of remediation surfaces, ever. | Parity auditor fatal #2, purist fatal #1. Dense Console's "unconditional operational home" principle adopted; proactive FDA maintenance must work while healthy (macOS permission caching makes "ready" stale — the app's own footer says so). |
| D2 | **Approve All Waiting** (guided-operator batch bar) vs per-call approval contract. | **Banned.** The Requests batch bar ships **Deny All Waiting** only (confirmed, listing the count). No control anywhere approves more than one pending request. | Three judges called it fatal. A security product whose approval anatomy preaches per-decision scope cannot ship an approve-everything button. |
| D3 | **Menu bar inline Approve/Deny** (system-utility, when exactly one request pends) vs scope visibility. | **Rejected.** The MenuBarExtra's "N requests waiting…" item *opens the Approval window*; it never resolves a request itself. | Commercial fatal #2: approving a write-capable call with zero argument visibility breaks constraint 9. The 1Password Quick Access precedent is authentication, not command execution. |
| D4 | **Approval window activation** — System Utility activated the app (focus steal); Dense Console promised panel shortcuts on a non-activating window (contradiction). | The Approval window is **non-activating** on appearance (never steals key focus). It becomes key on first click. The approval shortcuts (⌘⏎ / ⌥⌘⏎ / ⌘⌫) are **app-level menu commands** (Requests menu) acting on the frontmost pending request whenever MacRemote is frontmost; they also work inside the window once it is key. Notification actions (Approve/Deny) cover the out-of-app case. | Power-operator fatals #1 and #2. A misdirected Return must never approve anything. |
| D5 | **Canvas weather** (glass-expressive) — most marketable visual vs purist violation (hardcoded hex + ambient motion). | Adopted **statically**: the Connection canvas is a state-tinted wash built from semantic status colors at low opacity (slate `.secondary` off · `.blue` local · `.green` public · `.red` top-edge on failure), with the app's one `backgroundExtensionEffect()`. The tint **changes only on state transitions** (single 0.6 s ease) — no ambient loop, no aurora. Reduce Motion → crossfade; Reduce Transparency/Increase Contrast → plain `windowBackgroundColor`. | Keeps "the window answers 'am I exposed?' from across the room" (commercial graft) while satisfying Rule 34 (motion = feedback) and Rule 36 (semantic color). Brand azure lives only in onboarding art and web pages. |
| D6 | **Approval interrupt surface** — glass-expressive's in-window overlay. | **Rejected.** The interrupt is a real floating `Window` scene above all apps and Spaces, per the winner. | Four judges called the in-window overlay fatal: the emotional core must reach the user in Xcode/Safari, not wait behind a Dock badge. |
| D7 | **Tool authoring mode names** — MC "Full Access" collided with "Full Disk Access" (prosumer fatal). GO "Full Command", GE "Flexible Command". | **Fixed Command / Flexible Command.** | Prosumer judge: GE's pair is "the clearest mode pair"; zero collision with permission vocabulary. |
| D8 | **Edit-a-tool mechanics** — MC's Edit sheet was delete+re-add under the hood (silent grant-loss hazard); DC's inspector edits in place. | **Inspector edit-in-place** (Definition tab, Save/Revert; no modal ever edits data). Implementation requirement: a true `updateUserTool(id:draft:)` path that preserves the tool ID and rewrites Always Allow allowances **transactionally** (snapshot → apply → roll back on failure). If delete+re-add remains under the hood, the same ID and allowance set must be provably preserved. | Power-operator fatal #5 + the strongest graft consensus in the judging (commercial, purist, prosumer all requested DC's inspector editing). |
| D9 | **Where Run Reminders Test lives** — MC buried it 3 deep (menu → picker). | **"Test a Tool…" is a visible button on the Verify card** (picker defaults to `remctl.today`, wired to `runToolTest`), plus menu command ⌃⌘T "Run Reminders Round-Trip". | Parity auditor flag; GO's visible placement grafted; DC's shortcut grafted. |
| D10 | **Tunnel mode names** — MC "Quick link", GO "Instant Link", GE "Quick Link". | **Instant Link / Your Domain.** | Prosumer judge rated GO's pair best; "Quick Link" would collide with "Quick Test" in the same card family. |
| D11 | **Access-mode picker surfaces** — MC dual-surfaced (shared binding), SU singleton. | **Singleton**: the one **Sign-in method** picker lives in Settings › General ("Connect an App" group, beside the App picker and compatibility matrix). The Address card's custom-domain form shows the chosen mode as a **read-only row** with "Change in Settings…". | Purist graft 2 — kills the Privacy/Access dual-surface drift structurally, not by convention. Picker renamed **Sign-in method** (GO/GE) — "Privacy" was a mislabel; bare "Access" collides with Full Disk Access. |
| D12 | **Approvals' named home** — Dense Console dissolved it into Activity. | **Requests keeps its own sidebar section** with the app's only numeric badge. | Prosumer + parity fatal on DC; the security product's headline feature needs a named home. |
| D13 | **Onboarding notification priming** — GO/SU spent a screen on it; MC had none. | **No dedicated screen.** Native notifications are requested **contextually**: a one-time inline row appears directly after the user resolves their *first* approval ("Want requests to reach you anywhere? **Allow Notifications**") — fired from that button. Permanently reachable in Settings › Notifications. | Moment-of-need priming (Rule 20): the ask lands seconds after the user has experienced the exact interrupt notifications amplify. Keeps onboarding at five screens with MC's superior staged-first-approval finale. |
| D14 | **Tools list technology** — Dense Console's `Table` (tri-state group checkboxes, self-admitted fallback risk) vs MC's `List`. | **`List`** with collapsible groups. Bulk share = **section-header Share All / Share None menus** (GO) + a **Group By** toolbar picker (Category / Source / Capability) grafted from DC. No `Table`, no tri-state checkbox. | Purist flagged DC's Table bet as load-bearing fragility; header menus deliver the same bulk ops on proven ergonomics. |
| D15 | **Coaching layer** (guided-operator CoachTips). | **Dropped.** Teaching lives in onboarding, empty states, and the self-retiring Setup checklist only. | The winner has no coaching layer; purist dinged hand-rolled TipKit; the checklist graft (D16) covers "what do I do next" structurally. |
| D16 | **Setup guidance after skip** — MC's dismissable checklist vs GO's self-retiring Guide. | MC's **Setup checklist card**, upgraded with GO's mechanics: it **collapses to an "All set ✓" capsule** the first time all steps pass (the graduation moment); a later readiness regression re-expands **only the failing row**, debounced 30 s, escalating once to a notification on repeat; regression expansion never displaces the hero while a public link is live. | Commercial + purist + power-operator all grafted the self-retiring mechanic; prosumer fatal #5 capped regression above the hero. |
| D17 | **Hero status typography** — MC's `.largeTitle` status word. | `.title2` semibold status word; URL in `.title3` monospaced. | Purist flagged `.largeTitle` as flirting with the in-content-title ban (Rule 8). |
| D18 | **Server-stop semantics for pending requests.** | Pending requests **resolve to Denied with reason "Server stopped"** (one grouped Activity line; history rows keep the reason). Any pending row whose verbs cannot act renders disabled with "Start the server to respond." No verb ever silently no-ops. | Merges MC's resolution semantics (parity graft) with DC's disabled-with-reason (purist graft). |

### 1.3 Grafts applied (source: idea)

glass-expressive: Beacon one-object hero discipline + compound-state honesty · state-tinted canvas (static, D5) · shared web shell for `GET /` and `/authorize` · "Which tools ask first?" capped name-list popover · ⌥-click expand-all-Details + per-section disclosure persistence · Activity "Events | Everything" scope.
guided-operator: self-retiring checklist mechanics (D16) · "you can undo it in Apps" approval caption · click-to-filter chips on Tools · per-category bulk menus (Tools headers, Apps "Allow ▾") · Deny-All-only batch bar shape · "Instant Link / Your Domain" · "Sign-in method".
dense-console: full keyboard command map · inspector edit-in-place with tabs (Overview/Definition/Permissions/Activity) + Test Tool result anatomy · Group By picker · dual-homed Copy Test Commands · URL `contentTransition(.numericText())` type-in · disabled-with-reason pending rows · hover-copy on every identifier.
system-utility: falsifiable glass rule · singleton Sign-in method picker · one canonical Access Fixer (3 hosts, extended to privacy failures) · countdown ring drawn around the requesting app's icon · deploy-stage naming (5 named stages, failure lands on its stage) · "Optional — for the full test" API-key row · provider-specific paste-here instructions in onboarding S5 · MCP Refresh side-effect warning + "Original config no longer found" humanization · one-time "Settings moved to the MacRemote menu (⌘,)" callout.

---

## 2. Information architecture and navigation

### 2.1 Scenes and windows

| Scene | Kind | Spec |
|---|---|---|
| **Main window** | `WindowGroup("MacRemote", id: "main")`, min 1040×680, restorable | `NavigationSplitView`: system Liquid Glass sidebar (single-line `Label`s; the 64 pt clear-spacer hack is deleted) + detail. Detail panes use the real toolbar: inline `navigationTitle` + `navigationSubtitle`, `ToolbarItemGroup` + `ToolbarSpacer`, `.searchable` on long lists. No in-content large titles anywhere. |
| **Approval window** | `Window("Approval", id: "approval")`, `.windowLevel(.floating)`, `.windowResizability(.contentSize)`, hidden title bar, joins all Spaces, ~440 pt | The security interrupt (§5.4). **Non-activating** on appearance (D4). Replaces the `selection = .approvals` navigation hijack with something strictly louder. |
| **Settings window** | `Settings` scene (⌘,), `TabView` toolbar panes | The **only** Settings surface. The sidebar Settings section is deleted (HIG Rule 14). §5.6. |
| **Welcome window** | Fixed 760×560, hidden title bar, first run only | Onboarding (§3). Reopenable: Help ▸ "Welcome to MacRemote…". |
| **MenuBarExtra** | `MenuBarExtra`, `.menuBarExtraStyle(.menu)` | §2.5. Companion, never the only path to anything (Rule 41). Settings › General toggle hides it. |

### 2.2 Sidebar — final sections

| # | Section | SF Symbol | ⌘ | Absorbs (current) | Badge |
|---|---|---|---|---|---|
| 1 | **Connection** | `dot.radiowaves.left.and.right` | ⌘1 | Dashboard + Tunnel (entirely) | red dot only while `serverStatus`/`tunnelStatus` is `.failed` |
| 2 | **Tools** | `wrench.and.screwdriver` | ⌘2 | Tools (CLIs) + Local MCPs | none |
| 3 | **Apps** | `app.badge.checkmark` | ⌘3 | Clients | none |
| 4 | **Requests** | `hand.raised` | ⌘4 | Approvals | numeric badge = pending count (the sidebar's **only** number) |
| 5 | **Activity** | `waveform.path.ecg` | ⌘5 | Logs | none |

Rows are single-line; the jargon captions ("Host gates", "Trust policies", "Audit trail") are deleted. Badge economy: one count + one failure dot, nothing else.

### 2.3 Menu commands (complete)

| Menu | Command | Key | Notes |
|---|---|---|---|
| MacRemote | Settings… | ⌘, | Settings scene |
| Server | Start Local Server / Stop Local Server | ⌘R / ⌘. | kept verbatim |
| Server | Go Public (Cloudflare Tunnel)… / Stop Sharing | ⇧⌘R / ⇧⌘. | Go Public runs the exposure confirmation |
| Server | Copy Public URL | ⇧⌘C | enabled while public |
| Server | Run Quick Test / Run Full Test / Run Reminders Round-Trip | ⌘T / ⌥⌘T / ⌃⌘T | gated exactly as the Verify card |
| Server | Copy Test Command ▸ Quick Test / Full Test | — | dual home for Copy Preflight / Copy API Smoke (with Verify ⌄ menu) |
| File | New Tool… / Add from Library… / Scan for MCP Servers | ⌘N / ⇧⌘N / ⇧⌘L | |
| Edit | Find | ⌘F | focuses the current page's search field |
| View | Connection … Activity | ⌘1–⌘5 | |
| View | Show/Hide Inspector | ⌥⌘I | Tools |
| Requests | Approve / Always Allow for App / Deny | ⌘⏎ / ⌥⌘⏎ / ⌘⌫ | act on the frontmost pending request while MacRemote is frontmost (D4); disabled otherwise |
| Help | Welcome to MacRemote… / Connection Testing Guide… | — | Testing Guide is the in-app help sheet replacing the dead `#filePath` doc-open |

Tool-row keys (Tools list focus): ⌃⌘S toggle Share, ⌘D Duplicate, ⌫ Remove (confirmed).

### 2.4 Re-routing the programmatic jumps (implementation checklist)

| Today (`AppModel`) | New behavior |
|---|---|
| Pending approval → `selection = .approvals` (lines 164, 1402) | **Never navigates.** Opens the Approval window + Dock badge (`NSApp.dockTile.badgeLabel` = pending count) + menu bar count + native notification (if allowed) + Pushover/Brrr. Requests badge increments. |
| FDA/privacy blocks → `selection = .settings` (458, 509, 512, 532, 1045, 1976) | FDA reasons: present the **Access Fixer sheet** (app-global, model-driven via `fullDiskAccessPrompt`, unchanged triggers). Privacy-only failures: `selection = .connection` with the Readiness **Privacy Permissions** row auto-expanded. |
| Instance rotation → `selection = .settings` (278) | Rotation is invoked *from* Settings › Security; on completion the pane shows the new ID in place plus an inline confirmation row ("New private address created"). No jump. |

### 2.5 MenuBarExtra spec

- **Glyph:** template `dot.radiowaves.left.and.right`; `circle.dotted` when everything is off; a badge dot when public or when requests pend; text label = pending count when > 0.
- **Menu contents (top to bottom):**
  1. Status line (disabled item): `● Public — macremote.viticci.net` / `● Local only` / `○ Off` / `⚠ Connection failed`.
  2. **Copy Public URL** (enabled while public; logs the copy).
  3. Start Local Server ⌘R / Stop Local Server ⌘. · Go Public… (opens the main window's confirmation — the blast-radius dialog never fires from a menu) / Stop Sharing.
  4. **"2 requests waiting…"** → opens the Approval window. **Never inline Approve/Deny** (D3).
  5. Open MacRemote · Quit MacRemote.
- Settings › General: "Show menu bar icon" (default on). Everything in the menu exists elsewhere — companion, not dependency.

### 2.6 Quit discipline (additive)

Quitting while a public link is live asks once: **"Stop sharing and quit?"** — "Your public link stops working the moment MacRemote quits." [Cancel] [**Quit**]. Toggle in Settings › General ("Warn before quitting while sharing", default on). The next-launch supervision warning remains the crash net.

---

## 3. Onboarding flow (greenfield; final copy)

Dedicated Welcome window (Rule 19), five screens, progress dots, every screen skippable, everything re-reachable. New persistence: `MacRemote.hasCompletedWelcome` only. Every privileged step is primed in-app before any system dialog fires (Rule 20).

### Screen 1 — Welcome
- **Title:** "Your Mac, on call."
- **Body:** "MacRemote lets apps like Claude use tools on this Mac — from anywhere. You choose the tools. You approve every app. Risky actions always ask you first."
- **Visual:** the app icon large over a soft azure gradient keyed to the icon palette (the one place brand color appears in-app); three value rows: `wrench.and.screwdriver` "Share only the tools you choose" · `hand.raised` "Approve every app that connects" · `lock.shield` "Everything runs on this Mac, behind your approval".
- **Actions:** **Get Started** (`.glassProminent`) · Skip for Now. Permissions primed: none.

### Screen 2 — Pick what this Mac can share
- **Body:** "MacRemote found tools already installed on this Mac. Start with a bundle — you can change everything later. Nothing is reachable until you go public."
- **Visual:** preset bundles (`DefaultToolPresetCatalog.presetSets`) as selectable cards ("Reminders · 21 tools", "Detected CLIs · 18 tools", …) with checkmark selection and a live footer: "34 tools selected · 12 will ask you before running". **Preview-then-confirm**: the primary button names the count and the list is visible before commit — no silent 40-tool install.
- **Actions:** **Add 34 Tools** · Skip — I'll add my own. Permissions primed: none.

### Screen 3 — Some tools need permission first *(conditional: only if a selected tool requires Full Disk Access or a privacy service)*
- **Body:** "Reminders tools need macOS's OK to read your reminders, and 2 tools need Full Disk Access. MacRemote never grants itself anything — you do it in System Settings, and macOS asks the first time a tool runs. **MacRemote can't read anything you don't approve.**"
- **Visual:** the embedded **Access Fixer** target list (real file icons, role capsules, draggable rows, Copy/Reveal) under the numbered steps; privacy services listed as informational chips ("macOS will ask when the first call happens — approve it once").
- **Actions:** **Open System Settings** (`openFullDiskAccessHelper()`) · Check Again · Do This Later (Readiness resurfaces it truthfully). Permissions primed: Full Disk Access (manual grant) + the per-service TCC dialogs the user now expects.

### Screen 4 — Start the connection
- **Body:** "First MacRemote starts a private server that only this Mac can see. Then Cloudflare gives it a public address — no ports opened, nothing else on your Mac exposed." If `cloudflared` is missing: "One-time setup: install Cloudflare's helper with `brew install cloudflared`, then click Check Again." (+ Copy Command).
- **Visual:** the real **ConnectionHero** component, live — the product demos itself: Off → pulse → Local → Public, the URL typing itself in. Beneath it the Readiness rows tick through the preflight sweep. Firewall pre-explanation: "If macOS asks about incoming connections, allow it — that's the local server."
- **Actions:** **Start & Go Public** (inline exposure summary with the real counts, replacing the dialog on this screen only) · Just Start Locally · Skip.

### Screen 5 — Connect your app
- **Body:** "This is your Mac's public MCP URL. Add it as a custom connector — when the app asks to connect, MacRemote shows you the request. Nothing runs until you approve."
- **Visual:** the URL as a hero capsule + **Copy URL**; a small provider picker (Raycast / Claude / Notion / Generic) swaps one line of paste-here instructions; **Copy Sign-In Credentials** appears only when the sign-in method requires it. Below: a live "Waiting for the first request…" row that **flips in place into the real approval card** — the user approves their first app inside onboarding (the sticky moment).
- **After the first approval resolves:** a one-time inline row — "Want requests to reach you anywhere? **Allow Notifications**" — whose button fires the `UNUserNotificationCenter` dialog (D13). Skippable; lives on in Settings › Notifications.
- **Actions:** **Done** (always enabled) · Copy URL.

### Skip behavior and re-surfacing
Skipping closes the Welcome window and opens Connection with the hero at Off and the **Setup checklist card**: "1 Add tools → 2 Start server → 3 Go public → 4 Connect an app", rows live-stated with jump links. Per D16 it collapses to an "All set ✓" capsule when complete (dismissable; regression re-expands only the failing row, debounced 30 s, one-shot notification escalation, never above a live hero). Empty states everywhere carry their own CTAs. Help ▸ "Welcome to MacRemote…" reopens the flow; Settings › General has "Show Welcome Window" and "Show setup checklist". First launch after the redesign shows a one-time callout: **"Settings moved to the MacRemote menu (⌘,)."**

---

## 4. Page specs — Connection (the cockpit)

Absorbs Dashboard (17) + Tunnel (36). Hard tier budget — above the fold: hero + sub-facts + Readiness only; Address and Verify are collapsed summary cards (Rule 24 honest summaries). The canvas is the state-tinted wash (D5) with the app's single `backgroundExtensionEffect()`.

```
┌ Sidebar ─────┬─ Toolbar: Connection — Public   [▷/■] [⧉ Copy URL] | [✓ Verify] ────────┐
│ ◉ Connection │   (canvas: state-tinted wash, extends under sidebar)                    │
│   Tools      │        ╭──────────────── GLASS (one container) ───────────────╮        │
│   Apps       │        │  ◉ Public                                            │        │
│   Requests ② │        │  https://macremote.viticci.net/mcp            [⧉]    │        │
│   Activity   │        │  Cloudflare Tunnel · Your Domain · stable address    │        │
│              │        ╰──────────────────────────────────────────────────────╯        │
│              │            [ Stop Sharing ]   [ Stop Server ]                           │
│              │   166 tools shared · 68 read-only · 98 ask first · 3 apps              │
│              │  ┌ Readiness ──────────────────────────────── All clear ✓ ▾ ┐          │
│              │  │ ✓ Full Disk Access   ✓ Privacy Permissions  ✓ Local Server│         │
│              │  │ ✓ Public URL         ✓ Shared Tools         ⚠ API Key     │         │
│              │  │   (every row clickable in every state — D1)  [Check Readiness]      │
│              │  └────────────────────────────────────────────────────────────┘        │
│              │  ┌ Address — Your Domain · macremote.viticci.net · Deployed ✓  ▸ ┐     │
│              │  ┌ Verify — Last test: Quick Test passed · Jul 1, 21:56         ▸ ┐     │
│              │  Recent Activity (5 rows) ······················ [Open Activity]        │
└──────────────┴─────────────────────────────────────────────────────────────────────────┘
```

### 4.1 The hero (`ConnectionHero`) — one glass object

One `GlassEffectContainer(spacing: 24)`; the state chip, status word, URL capsule, and copy affordance carry `glassEffect(.regular.tint(stateColor))` with `glassEffectID` morphs; the copy glyph fuses into the URL pill via `glassEffectUnion`. `.interactive()` on clickable elements only. **The Beacon discipline:** the Start button, the progress capsule, and the URL pill are the same piece of glass in three shapes. **Control is never fused:** Stop Sharing / Stop Server are separate, always-visible buttons beneath the capsule (never a ⏹ menu). Status word `.title2` semibold; URL `.title3` `.monospaced` (D17), materializing via `contentTransition(.numericText())`.

States (compound-state honesty — never average two states):

| State | Render | Verbs |
|---|---|---|
| Off | neutral chip "Off" | **Start Server** (`.glassProminent`) |
| Starting | chip + `.symbolEffect(.variableColor.iterative)` | — |
| Local | blue-tinted; "Local only"; local URL small mono (`http://127.0.0.1:51891`) | **Go Public…** (confirmed) · Stop Server |
| Public-pending | "Waiting for Cloudflare…" | Stop Server |
| Public | green-tinted wide capsule; public URL front and center + fused Copy | **Stop Sharing** · Stop Server |
| Partial failure | names the failing half: "Server running · link stopped" | Retry · Stop Server |
| Failed | error renders as a first-class row **below** the capsule (human line + raw detail mono selectable) + **Retry** — never inside the URL slot | Retry |
| `unavailable` (cloudflared missing) | Address-card banner: "Cloudflare's helper isn't installed — install it with `brew install cloudflared`" + **Copy Command** + **Check Again** | — |
| Zero tools | chip "Add a tool to start" + **Open Tools**; Start disabled (semantic gating kept) | — |

Sub-facts line (Tier 1): each count is a live control — tool counts open Tools filtered; the **ask-first count opens a popover** listing gated tool *names*, capped with "and 62 more…" expander (kills the comma-wall); the apps count opens Apps.

### 4.2 Readiness card

The real `SmokeReadiness` six-check machine replaces the fake Security Gates: Full Disk Access · Privacy Permissions · Local Server · Public URL · Shared Tools · **Anthropic API Key (labeled "Optional — for the full test")**. Each row: state glyph (`ready/checking/warning/blocked`), title, live detail string, **expandable in every state (D1)** — FDA expands the Access Fixer inline (all remediation actions); Privacy expands Check Access + Open Reminders Privacy deep link + requirement chips. **Check Readiness** runs the sequential preflight sweep (§8.3). A trailing ⓘ opens the **"How MacRemote protects this Mac"** popover carrying the eight former Security-Gates assurances, honestly framed as design guarantees ("By design: loopback-only server · no arbitrary shell commands · direct-argv adapters · one forwarded port · approval before tokens · per-call approval for writes · confirmed tunnel starts · Full Disk Access checked before start"). The card self-retires to "All clear ✓" per D16.

### 4.3 Address card (collapsed by default; summary states mode + hostname + deploy state)

Expanded: two radio rows — **Instant Link** ("a temporary trycloudflare.com address; changes every time you go public") and **Your Domain** ("a stable address on a domain you own"). The Your-Domain form: **Load Domains** · Status · Domain picker · Subdomain field · live Hostname preview · **Sign-in method as a read-only row → "Change in Settings…"** (D11) · API Token `SecureField` with caption "MacRemote never stores this token — you'll paste it again next launch" · the ordered deploy-hint line (`customDomainDeployHint`) · **Deploy Your Domain** (disabled until the token is present — button and hint finally agree) · deploy progress as **five named stages**: *Check Cloudflare access → Create tunnel → Configure DNS → Protect endpoint → Start* — a failure lands on its stage, human line first, raw API text in a copyable mono disclosure; token errors add a "What your API token needs" popover (structured checklist) · post-deploy proof grid (Hostname / Tunnel / Protection) · mode-titled **Copy Credentials**. A ⓘ popover holds the Why-Cloudflare explainer. Instant-link running state adds: "This address changes when you go public again."

### 4.4 Verify card (collapsed by default; summary = last result + time)

Expanded: status line + last-result summary; visible buttons **Run Quick Test** · **Run Full Test** · **Test a Tool…** (picker defaulting to `remctl.today`, wired to `runToolTest` — D9), gated by readiness exactly as today; a **More ⌄ menu**: Copy Quick Test Command, Copy Full Test Command, Copy Last Result (redacted `clipboardText` proof), Refresh Tunnel Status, **Testing Guide** (in-app help sheet). "Last result" grid (Status/Mode/URL/Tool count/Result/technical markers, mono) behind [Details]. Copy Test Commands are dual-homed (also Server menu, §2.3).

### 4.5 States
- **Empty/first-run:** hero at Off + Setup checklist card.
- **Loading:** hero pulse states; deploy stage list; readiness spinners.
- **Error:** inline error rows with Retry, mirrored to Activity; red dot on the sidebar row; the URL slot never carries an error string.

---

## 5. Page specs — remaining surfaces

### 5.1 Tools

```
┌ Toolbar: Tools — 166 shared of 172  [Group by ▾] [🔍 Search] [Scan] | [+ Add ▾] ┐
│  [All 172] [Shared 166] [Ask First 98] [Read-only 68] [Needs Access 11]  ← chips│
│ ┌──────────────────────────────────────────────┬──────────────────────────┐    │
│ │ ▾ Reminders (21)      21 shared [Share All ▾]│ INSPECTOR (selection)     │    │
│ │   ⊙ Today            Read-only          ◉━━ │ Git Status                │    │
│ │   ⊙ Add Reminder     Asks First         ◉━━ │ [Overview|Definition|     │    │
│ │ ▾ Developer (24)      24 shared [Share All ▾]│  Permissions|Activity]    │    │
│ │   ⊙ Claude Code  Flexible · Asks First  ◉━━ │ ⌘ /usr/bin/git -C {path}  │    │
│ │ ▾ ⧉ Hopper MCP (Claude Desktop)  12/12 shared│   status --short     [⧉]  │    │
│ │   server row: [Refresh] [Share All ◉━━]      │ Parameters: Path (path)   │    │
│ │   ⊙ List Names       Read-only          ◉━━ │ Limits 10 s · 512 KB      │    │
│ │ ▾ Utilities (18) …                           │ [Test Tool] [Duplicate]   │    │
│ │                                              │ [Remove…]                 │    │
│ └──────────────────────────────────────────────┴──────────────────────────┘    │
```

- **One unified lazy `List`** (built for hundreds of rows): collapsible groups = 8 categories for process tools + one group per imported MCP server. **Group By** toolbar picker: Category (default) / Source (Built-in · Added by You · per-server) / Capability (D14). Section headers carry counts + a **Share All / Share None** menu — on the Reminders category this menu is wired to `setRemCTLProfileEnabled` (its UI home). Count chips above the list are **click-to-filter** (All / Shared / Ask First / Read-only / Needs Access); a Filter menu holds the long tail (Not Shared, Flexible Command). Search matches name/summary/ID/path (⌘F focuses).
- **Rows:** category-tinted icon, name, quiet chips (Asks First / Flexible Command / permission dots), Share toggle. Not-shared rows dim to 0.62 with a "Not Shared" chip (kept). Per-row errors render on the offending row, never a distant shared banner. Bridge tools get **per-tool Share toggles** (model's `setToolEnabled` supports it — "Partially Shared" becomes actionable).
- **MCP server header rows:** source badge (Claude Desktop, Codex, Cursor…), redacted mono endpoint, **Ready to Import / View Only** state (+ reason), Import/**Refresh** — Refresh warns first: *"Refreshing replaces this server's 12 tools and clears their Always Allow settings."* — importing progress, probe errors inline; candidate-less imported servers read "Original config no longer found — tools still work" with the raw `bridgeIdentity` inside Details. Toolbar **Scan** (kept name "Scan This Mac" inside the button's label) + scanning progress "Scanning this Mac for MCP servers…" + last-scan caption + failure row with Retry.
- **Inspector** (`.inspector`, ⌥⌘I; persists across arrow-key selection). Tabs (D8):
  - **Overview** — identity, badges, mono command or bridge line (`serverURL → toolName`), parameter list ("Title (`name`)" with real code formatting), permission requirements, limits, per-app allowance summary ("Always allowed for Claude").
  - **Definition** — the **editor, in place** (user tools): Name/Summary/Executable (+ Browse…, inline per-field validation: absolute path, exists, shell blocklist), Mode (**Fixed Command / Flexible Command**, one-line consequence copy: "Flexible Command lets the app choose the arguments — every risky call still asks you"), argv editor with **live parameter preview** ("This creates parameters: Path, Query"), Category, Capability (consequence: "Write and Destructive tools ask you before every run"), Timeout/Output limit (text entry + steppers + presets), 13 macOS permission toggles with one-line footers. **Save / Revert**; no modal ever edits data. Built-ins: fields read-only with "Built-in tools can't be edited". Transactional-update requirement per D8.
  - **Permissions** — the `clientToolPermissionSnapshot` pivot: per-app Always Allow for this tool ("who can run this without asking?"), searchable, with stale-cleanup footer.
  - **Activity** — this tool's session calls.
  - Footer verbs: **Test Tool** (parameter form → `runToolTest` → exit code / stdout / stderr / duration in mono) · **Duplicate** · **Remove…** (user tools; confirmed: "Remove 'Git Status'? Apps that could use it lose access; its Always Allow settings are cleared.").
- **Add flow (+ ▾):** New Tool… (inserts a draft, inspector opens on Definition) · **Add from Library…** · Scan for MCP Servers. The **Library sheet** (720×560) has left tabs **Bundles / Found on This Mac / Presets / Custom**: Bundles preview-then-confirm ("Install 21 tools" with the list visible; dedupe messaging kept: "9 of 21 already installed — install the remaining 12?"); Found/Presets rows show "Added ✓" and prefill a draft ("Customize & Save" / "Just Add"); Custom hosts the full editor form (same fields as the Definition tab).
- **States:** empty ("No tools yet" + Add from Library / New Tool / Scan CTAs — `ContentUnavailableView`); scanning; import-in-flight per server row; search-empty (`ContentUnavailableView.search`).

### 5.2 Apps

```
┌ Toolbar: Apps — 2 connected                              [🔍 Search tools] ┐
│ ┌─────────────────────────────────────────────────────────────────────────┐│
│ │ [Claude glyph] Claude       Active · 2 tokens        166/166 Always ✓   ││
│ │   Signs in with client secret · Last connected Jul 1, 9:56 PM ▸ Details ││
│ │   [Allow All Current Tools] [Revoke All Always-Allows] [Delete App…]    ││
│ │   ▾ Reminders (21 of 21 allowed)                          [Allow ▾]     ││
│ │     Today            Read-only                    Always Allow ◉━━      ││
│ │     Add Reminder     Asks First                   Always Allow ◉━━      ││
│ │   ▸ Developer (24 of 24 allowed)                          [Allow ▾]     ││
│ ├─────────────────────────────────────────────────────────────────────────┤│
│ │ [◌] Remote MCP Client    Sign-in expired — reappears when it reconnects ││
│ └─────────────────────────────────────────────────────────────────────────┘│
```

- One `AppCard` per connected app: provider glyph (`ConnectorProviderProfile.systemImage`, finally used), name, connection state — Active (n access · n refresh tokens, live) / **Expired** (gray card, "Sign-in expired — reappears when it reconnects"; no more silent vanishing) — static-vs-dynamic chip ("Signs in with client secret" / "Registered itself"), "12 of 166 always allowed".
- **Details** disclosure: full mono `KeyValueGrid` (Client ID, Trust ID, Issuer, Resource, Scopes, Last Auth, token counts), selectable, per-row hover Copy.
- Bulk verbs: **Allow All Current Tools** (confirmed with count: "Claude will run all 166 shared tools without asking — including 98 that normally ask first.") · **Revoke All Always-Allows** · **Delete App…** (confirmed, §5.7). Post-action feedback is an inline summary row ("Signed out Claude — removed 1 registration, 2 tokens"), not logs-only.
- Per-tool policy list: grouped by category **with headers + per-category "Allow ▾" menus** (Allow all in category / Revoke category), searchable; rows = name, severity-tinted capability chip, "Not Shared" chip when applicable, mono tool ID (hover-copy), Always Allow switch. Stale allowances footer: "3 rules reference removed tools — Clean Up".
- Ordering kept (category → name). Empty state: "No apps yet. Go public, paste your link into an app like Claude, then approve its request here." + **Copy Public URL**.

### 5.3 Requests (queue + history)

```
┌ Toolbar: Requests — 1 waiting                          [Open Approval Window] ┐
│ WAITING                                                                        │
│ ┌ ◔ 0:47  Claude wants to run Convert To PNG   [Deny] [Approve Run] [⋯]     ┐ │
│ THIS SESSION                                                                   │
│  CONNECTION REQUESTS                                                           │
│   ✓ Approved   Claude · connect to this Mac                    9:56 PM  ▸    │
│  TOOL RUNS                                                                     │
│   ✕ Denied     Claude · Evaluate Script                        9:41 PM  ▸    │
│   ◌ Expired    Remote MCP Client · Convert To PNG              8:02 PM  ▸    │
└──── safeAreaBar (appears with 2+ pending): [Deny All Waiting]  ───────────────┘
```

- Pending list uses the same `ApprovalCard` component inline (content variant, live countdowns, inline verbs). History is session-only, labeled **"This session — cleared when MacRemote quits"**; the two kinds stay distinct sections (**Connection Requests** / **Tool Runs** — never merged in data or presentation); auth history capped at 64, tool-call history unbounded, both lazy. Row expansion → full `KeyValueGrid` (Request ID, Client ID, Trust ID, Resource, Issuer, Redirect / structured arguments + the raw `argumentsPreview` string preserved inside Details).
- **Batch bar:** `safeAreaBar(edge: .bottom)`, glass buttons, appears only with 2+ pending: **Deny All Waiting** (confirmed: "Deny 3 waiting requests?"). **No Approve All** (D2).
- Server-stop semantics per D18. Empty state: "Nothing waiting. When an app wants to connect or run a tool that needs your OK, it shows up here — and in a window you can't miss."

### 5.4 The Approval window (the live moment)

```
╭──────────────────────────────────────────────╮
│  [Claude icon with ◔ countdown ring]  1 of 2 │
│  “Claude” wants to run                       │
│  Convert To PNG                              │
│  Write — this can change files on your Mac   │
│                                              │
│   input    ~/Desktop/shot.heic               │
│   output   ~/Desktop/shot.png                │
│  ▸ Details (request · client · trust IDs)    │
│                                              │
│  Allowing once runs it now. “Always Allow”   │
│  lets Claude run this tool without asking    │
│  again — you can undo it in Apps.            │
│  [ Deny ]   [Always Allow ▾]  [ Approve Run ]│
╰──────────────────────────────────────────────╯
```

- **Anatomy (constraint 9):** clear actor (app glyph + name, first line) · clear capability (tool name + severity-tinted sentence: read-only green / **Write orange** / **Destructive red** — one scale everywhere; destructive calls tint the header red and demote Always Allow's prominence) · clear scope (structured key:value argument rows re-rendered from `argumentsPreview`; `stdin` summarized as "stdin · 4.2 KB ▸ view") · calm urgency (countdown ring drawn **around the requesting app's icon** via `Gauge`, fed by the real 120 s / 300 s fuses, drifting green→amber in the last 30 s; no sound, no flashing).
- **Verbs:** Deny (`.glass`) · **Approve Run** (`.glassProminent`) · **Always Allow for Claude…** as a menu item, deliberately one step heavier; on use, the verb row morphs for 1.2 s into the minted rule — "**Claude can now run Convert To PNG without asking**" — before dismissal; the caption above the verbs states the undo location ("you can undo it in Apps").
- **OAuth connect variant:** "'Claude' wants to connect to this Mac" + consequence line: "**If you approve, Claude can run your 68 read-only tools without asking. The 98 tools marked Asks First will still ask every time.**" + requested scopes + Details grid. Always Allow hidden when the request carries no clientID (kept rule).
- **Behavior:** non-activating (D4); joins all Spaces; floats above full-screen apps; multiple requests page as "1 of N" in one window; expiry flips the card to a quiet "Expired" state, then it recedes to Requests history; server stop per D18. Escalation stack fires together: window + Dock badge + menu bar count + sidebar badge + native notification with Approve/Deny actions (if allowed) + Pushover/Brrr. Dismissing the window loses nothing (Requests mirrors everything).
- **Keyboard:** per D4 — Requests menu commands ⌘⏎ / ⌥⌘⏎ / ⌘⌫ when MacRemote is frontmost; same keys in-window once it is key.

### 5.5 Activity

```
┌ Toolbar: Activity — This session  [All ▾] [Events|Everything] [🔍] [⧉ Copy All] [Export…] [Clear] ┐
│ 9:56:46 PM  Info     x-search: Search Posts All MCP call exited 0 in 2.46 s                      │
│ 9:56:43 PM  🛡 Info   x-search: Search Posts allowed by Claude's policy                           │
│ 9:56:32 PM  🛡 Info   OAuth token issued after your approval                                      │
│ 7:39:49 PM  Warning  Rejected MCP bearer token for /mcp                                          │
│ This session — up to 250 entries. Cleared when MacRemote quits.                                  │
```

- Level filter (All / Info / Warning / Error) + **Events | Everything** scope (Events foregrounds approvals, sign-ins, tool runs over cloudflared stdout — a filter, never a purge) + search (⌘F) + **Copy All** + **Export…** (.txt or .json) + **Clear**. Lazy list, `scrollEdgeEffectStyle(.hard, for: .top)`. Security-relevant lines get a leading `lock.shield` glyph (display affordance via prefix matching, not a fake taxonomy). Truth footer as shown. Empty: "No activity yet this session." Filtered-empty: `ContentUnavailableView.search`. No loading/error states (in-memory; the list *is* the error surface).

### 5.6 Settings window (⌘, — three panes)

```
┌──── MacRemote Settings ─────────────────────────────────────┐
│   [⚙ General]      [🔔 Notifications]      [🔐 Security]    │
└──────────────────────────────────────────────────────────────┘
```

- **General:** *Connect an App* group — App picker (Raycast/Claude/Notion/Generic, icons) · **Sign-in method** picker (**the singleton**, D11) · compatibility summary badges (Recommended/Works/Limited/Blocked) + setup line. *App behavior* group — Show menu bar icon · Warn before quitting while sharing · Show setup checklist · Show Welcome Window.
- **Notifications:** macOS Notifications status row ("Open Notification Settings" when denied) · Pushover (enable, User Key, API Key `SecureField`s, triggers footer re-voiced, Send Test) · Brrr (enable, Secret, footer, Send Test). One word everywhere: notifications. Storage honesty footer: "Notification keys are stored on this Mac."
- **Security:** *Local server* — "Only on this Mac" + `127.0.0.1` mono · **Private address ID** (mono, selectable, hover-copy) · **Reset Private Address…** (destructive, confirmed; caption: "Gives your Mac a new private address. Sharing stops and every app is signed out."; completes in place with "New private address created" row). *App access* — **Sign Out All Apps…** (confirmed). *OAuth Client Credentials* — explainer ("The secret lives in your Keychain."), per-credential panels (label, mono ID, masked secret `.privacySensitive()`, created date, Copy ID / Copy Secret / Copy JSON, **Replace…**, **Delete…** — each confirmed), **Generate ‹Provider› Credentials** (prominent when the list is empty).

### 5.7 Destructive confirmations (one system — outcome-first bodies, object-named titles, specific verbs)

| Dialog | Title | Body (final) | Confirm |
|---|---|---|---|
| Go public | "Go public?" | "This creates a public link to your shared tools — not to your whole Mac. 166 tools will be reachable: 68 read-only, 98 that ask you before running. New apps still need your approval to connect." (dynamic counts; **loses the `.destructive` role**) | Go Public |
| Delete app | "Delete 'Claude'?" | "Claude is signed out; its tokens, pending requests, and Always Allow settings are removed. It can ask to connect again anytime." | Delete App |
| Reset private address | "Reset your private address?" | "Sharing stops, every app is signed out, and your Mac gets a new private address. Your public link stays the same." | Reset |
| Sign out all apps | "Sign out every app?" | "All connected apps must ask for your approval again. Your public link doesn't change." | Sign Out All |
| Replace credentials | "Replace these credentials?" | "The old ID and secret stop working immediately; paste the new ones into Claude." | Replace |
| Delete credentials | "Delete these credentials?" | "The app using them is signed out and its Always Allow settings are cleared." | Delete |
| Remove tool *(new — closes the unconfirmed-delete gap)* | "Remove 'Git Status'?" | "Apps lose access immediately; its Always Allow settings are cleared." | Remove Tool |
| Quit gate *(new, additive)* | "Stop sharing and quit?" | "Your public link stops working the moment MacRemote quits." | Quit |
| Deny all waiting *(new, additive)* | "Deny 3 waiting requests?" | "Each app can ask again." | Deny All |

### 5.8 The Access Fixer (Full Disk Access — one component, three hosts)

Component `AccessFixer`; hosts: (1) the app-global sheet (`fullDiskAccessPrompt`, all four reasons keep bespoke re-voiced copy), (2) the Connection ▸ Readiness FDA expansion (**always available**, D1), (3) onboarding Screen 3. Extended per the graft to present for **macOS-privacy failures** too (one louder mechanism for all six privacy-triggered jumps).

```
╭─ Full Disk Access needed ──────────────────────────────╮
│ 🔒  Some shared tools read protected data. Add every   │
│     item below in System Settings, then relaunch.      │
│     Status: Required · (spinner while checking)        │
│  ┌ [icon] MacRemote    Host app   /Applications/… ⧉ ↗ ┐│  ← rows draggable
│  ├ [icon] remctl       Tool       ~/bin/remctl    ⧉ ↗ ┤│
│  ① Open System Settings ② Drag rows in ③ Relaunch,     │
│     then Check Again                                   │
│  [Troubleshoot ⌄]   [Later] [Open System Settings]     │
│                              [ Check Again ]           │
╰────────────────────────────────────────────────────────╯
```

Eight peer buttons become 3 + a menu — **every action survives**: primary row = **Check Again** (prominent) · Open System Settings (= Guided Setup) · Later; **Troubleshoot ⌄** = Relaunch MacRemote · Re-add MacRemote in System Settings (Reset App Row) · Confirm Setup Manually (conditional on `requiresManualConfirmation`) · Copy All Paths · Copy First Target · **Open Connection Readiness** (the re-mapped Settings jump — opens Connection with the FDA row expanded and dismisses the sheet). Target rows keep the full anatomy verbatim: NSWorkspace icon, role capsule, mono path, Copy (path + fileURL pasteboard types), Reveal, `.draggable(fileURL)`, `.help` tooltip. States: checking (spinner + disabled verbs), required (orange), ready (auto-dismisses, as today), failed (selectable error detail). Empty: "No items yet — Check Again finds exactly which items need access." The layered-FDA lecture lives in a ⓘ popover, verbatim.

### 5.9 Tunnel root landing page (`GET /`) and the OAuth waiting page

`GET /` returns 200 `text/html`, ≤10 KB, zero JavaScript: centered MacRemote mark at 96 px (served from the existing `/macremote-icon.png`), the word **MacRemote** (system font stack, semibold), one sentence — "This Mac shares approved tools with apps its owner authorizes. Connections require sign-in and the owner's approval." — and a muted footer "MCP endpoint: `/mcp`". `<head>` carries `<link rel="icon">` tags for `/favicon.ico` (re-exported multi-size ≤20 KB), `/favicon.png`, and `/macremote-icon.png` — matching the `/authorize` markup so Google's favicon fetcher (the mechanism Claude.ai uses for connector icons) resolves the mark. `prefers-color-scheme` aware; Cache-Control 1 h; **no instance ID, version, hostname, or tool data leaks**. The **`/authorize` waiting page adopts the same shell**: icon + name, "Waiting for approval on the owner's Mac…" with quiet polling dots, state lines for approved ("Approved — redirecting…") / denied / expired, and the request ID demoted to a footnote (kept for support).

---

## 6. Signature moments (all verified APIs)

1. **The State Change.** The hero is one `GlassEffectContainer`: Start pulses the symbol (`.symbolEffect(.variableColor.iterative)`); on `running` the chip tints blue and the local-URL capsule morphs out of it (`glassEffectID` + `withAnimation`, `.glassEffectTransition(.matchedGeometry)`); Go Public fuses orb and capsule into one wide green pill carrying the public URL, which types itself in via `contentTransition(.numericText())`. Stopping runs the film backward. The canvas wash eases to the new state color once (D5).
2. **The Descent.** A request arrives: the floating Approval window fades in with the countdown ring (`Gauge` around the app icon, `TimelineView`-driven, green→amber). On Approve/Always Allow, the verb row morphs into the minted consequence ("Claude can now run Convert To PNG") for 1.2 s, then dismisses. The scariest moment in the product becomes its most composed.
3. **The Preflight Sweep.** Check Readiness verifies the six rows sequentially — each symbol runs `.variableColor` while checking, then settles with a subtle `.bounce`; the hero dims slightly during the sweep and re-lights on "All clear". Truthful status staged as a launch-control ritual — the exact opposite of the eight fake checkmarks it replaces.

---

## 7. COMPLETE PARITY MAPPING TABLE — 200/200

This table is the implementation checklist. Column 3 is the exact new home. Nothing here may be omitted; the post-implementation audit verifies row by row. Cross-cutting rules (all preserved): every identifier `.textSelection(.enabled)` + hover-copy; every Copy writes an audit log line; every destructive action confirmed; disabled-state gating stays semantic.

### App Shell & Sidebar (6)

| ID | Current element | New home |
|---|---|---|
| SH-1 | Main window "MacRemote" (min 1040×680) | Kept: `WindowGroup("MacRemote", id:"main")`, min 1040×680, restorable |
| SH-2 | NavigationSplitView (balanced) | Kept: `NavigationSplitView`, system glass sidebar, detail toolbar populated |
| SH-3 | Sidebar 7-section list w/ caption lines | 5 sections (§2.2), single-line `Label`s; captions deleted (info → `navigationSubtitle` + empty states); Settings evicted (SH-6); Tunnel merged into Connection |
| SH-4 | Sidebar 64 pt top spacer | Deleted — system glass sidebar handles the title-bar region |
| SH-5 | FDA prompt sheet (auto-presented app-global) | Kept: same `fullDiskAccessPrompt`-driven sheet, redesigned as Access Fixer (§5.8); triggers unchanged; extended to privacy failures |
| SH-6 | Settings scene (⌘,) duplicated with sidebar section | Settings scene is the **only** Settings surface (§5.6); 7 programmatic jumps re-routed per §2.4; one-time "Settings moved to ⌘," callout |

### Menu Bar Commands (3)

| ID | Current | New home |
|---|---|---|
| MB-1 | Server ▸ Start Local Server ⌘R | Kept verbatim (+ menu grows per §2.3) |
| MB-2 | Server ▸ Stop Local Server ⌘. | Kept verbatim |
| MB-3 | MacRemote ▸ Settings… ⌘, | Kept (opens the Settings scene) |

### Dashboard (17) → Connection

| ID | Current element | New home |
|---|---|---|
| DA-1 | Header title + subtitle | Toolbar `navigationTitle` "Connection" + `navigationSubtitle` state summary; the security-model sentence retires to onboarding S1 |
| DA-2 | Run Reminders Test (conditional) | Verify card ▸ **Test a Tool…** (default `remctl.today`; same gating: server running + tool shared) + menu ⌃⌘T (D9) |
| DA-3 | Flow Step 1: Choose Tools card + Tools button | Hero zero-tools state ("Add a tool to start" + Open Tools) + Setup checklist row 1 + sub-facts counts |
| DA-4 | Step 2 Start Server (prominent) | Hero **Start Server** verb (+ toolbar ▷, ⌘R); disabled at 0 shared tools (kept) |
| DA-5 | Step 2 Stop Server | Hero **Stop Server** verb (+ toolbar ■, ⌘.) |
| DA-6 | Step 2 starting spinner | Hero Starting state (`.variableColor` pulse) |
| DA-7 | Step 2 server detail line | Hero Local state (local URL mono) / "Only on this Mac" caption |
| DA-8 | Step 3 Start Tunnel (confirmed) | Hero **Go Public…** verb + confirmation (§5.7 #1) + ⇧⌘R |
| DA-9 | Step 3 Stop Tunnel | Hero **Stop Sharing** verb + ⇧⌘. |
| DA-10 | Step 3 Copy URL (logs copy) | Hero fused Copy affordance + toolbar ⧉ + ⇧⌘C + menu bar item; all log the copy |
| DA-11 | Step 3 Refresh (stopped/failed/unavailable) | Hero failed state **Retry** + Address-card banner **Check Again** (unavailable) + plain stopped-state Refresh in the Verify card's More ⌄ ("Refresh Tunnel Status") |
| DA-12 | Step 3 tunnel detail line (state copy incl. cloudflared hint) | Hero states + Address banner (§4.1); errors in the error row, never the URL slot |
| DA-13 | Exposed Surface metric pills ×4 | Sub-facts line (Tier 1) — same numbers, clickable |
| DA-14 | Write-capable warning w/ tool-name wall | "98 ask first" count → capped name-list popover with "and 62 more…" expander |
| DA-15 | Runtime rows ×3 (server/tunnel/pending) | Hero (server+tunnel) + Requests badge & toolbar subtitle (pending, now with a jump the old row lacked) |
| DA-16 | Security Gates checklist ×8 (fake) | **Deleted as status**; real Readiness card replaces it; the 8 assurance strings survive verbatim in the "How MacRemote protects this Mac" ⓘ popover, framed as design guarantees |
| DA-17 | Recent Activity preview + empty state | Connection Tier 3 activity strip (5 rows) + **Open Activity** link (dead end fixed); empty "Nothing yet this session." |

### Tools (15)

| ID | Current element | New home |
|---|---|---|
| TO-1 | Header title + subtitle | Toolbar title "Tools" + subtitle count line |
| TO-2 | Tool Type tab picker (CLIs / Local MCPs) | Dissolved: one unified list; MCP servers are groups (Group By: Source isolates them); Scan lives in the toolbar |
| TO-3 | Add Tool button | Toolbar **+ Add ▾** menu (New Tool… ⌘N / Add from Library… ⇧⌘N / Scan for MCP Servers ⇧⌘L) |
| TO-4 | Tool Surface metric pills ×5 | Click-to-filter chip row (All/Shared/Ask First/Read-only/Needs Access) — same numbers, now filters |
| TO-5 | Zero-exposure warning | Chip row state + Connection hero blocked state + Setup checklist row |
| TO-6 | Surface-level error message (red) | Per-row / per-field inline errors (the shared floating string retires as a pattern, kept as data) |
| TO-7 | Empty state | `ContentUnavailableView` "No tools yet" + Add from Library / New Tool / Scan |
| TO-8 | Tool card identity (icon/tint/name/badge/summary) | List row (icon, name, chips) + Inspector Overview |
| TO-9 | Badge strip (category/mode/capability/permissions) | Row chips (capability, Flexible Command, permission dots) + Inspector Overview badges; mode names now Fixed/Flexible Command |
| TO-10 | Expose toggle per tool | Row **Share** toggle (`setToolEnabled`); errors inline on the row; ⌃⌘S |
| TO-11 | Remove (user tools, unconfirmed) | Inspector **Remove…** + row context menu — **now confirmed** (§5.7 #7) |
| TO-12 | Command line (copyable code block) | Inspector Overview mono command / bridge line + hover-copy (moved off the row — selection is the signpost) |
| TO-13 | Parameters list | Inspector Overview parameter list (real code formatting, no literal backticks) |
| TO-14 | Card dimming at 0.62 when not exposed | Kept: row dims to 0.62 + "Not Shared" chip |
| TO-15 | Ordering (category → name; bridge tools excluded) | Kept as default Group By: Category (server groups render separately); sort within groups by name |

### Local MCPs (18) → Tools (unified list, server groups)

| ID | Current element | New home |
|---|---|---|
| LM-1 | Section header + bridge subtitle | Server-group area intro voice; subtitle re-voiced ("Find the MCP servers your Mac's AI apps already use, and share their tools through MacRemote.") in the Add-from-Library/Scan context |
| LM-2 | Scan This Mac button (+ Scanning state) | Toolbar **Scan** button (label "Scan This Mac", disables + spins while scanning) + ⇧⌘L |
| LM-3 | Overview metric pills ×5 | Group-header counts + chip-row contributions (Detected / Ready to Import / Imported / Shared / Ask First appear on server headers and the scan status line) |
| LM-4 | Last scan timestamp | Scan status caption "Last scan: ‹time›" |
| LM-5 | Scan failure label | Inline error row under the scan caption + Retry |
| LM-6 | Error message (import/toggle) | Inline on the owning server group / row |
| LM-7 | Scanning progress panel | Scan progress row "Scanning this Mac for MCP servers…" |
| LM-8 | Empty state (names supported sources) | `ContentUnavailableView` naming the scanned sources verbatim + Scan CTA |
| LM-9 | Server identity (name/endpoint/description) | Server group header row (redacted mono endpoint, hover-copy; description in header detail) |
| LM-10 | Source badge | Server header source badge (Claude Desktop, Codex, Grok, OpenCode, Cursor, LM Studio, Xcode) |
| LM-11 | Bridgeable badge | **Ready to Import / View Only** state chip (renamed) |
| LM-12 | Exposure badges (Enabled/Partially/Disabled + X/Y) | "12/12 shared" / "Partially Shared" count on the header (glossary-aligned) |
| LM-13 | Import / Refresh button | Header **Import** / **Refresh** — Refresh warns first (side-effect dialog: replaces tools + clears Always Allow) |
| LM-14 | Expose toggle (per server, bulk) | Header **Share All** toggle (`setLocalMCPBridgeServerEnabled`) |
| LM-15 | Importing progress | Header spinner "Importing tools…" while `localMCPWorkingServerID` matches |
| LM-16 | Non-bridgeable reason | "View Only" chip + reason line on the header |
| LM-17 | Probe error label | Inline orange row on the server group |
| LM-18 | Tools Exposed by Server grid (+ fallback) | The server group's tool rows (now with **per-tool Share toggles**, additive) + Inspector; fallback "No tool list is available — scan again to check this server." kept |

### Clients (10) → Apps

| ID | Current element | New home |
|---|---|---|
| CL-1 | Header title + subtitle | Toolbar "Apps — n connected" |
| CL-2 | Empty state | Re-voiced empty state + Copy Public URL CTA |
| CL-3 | Client card identity (icon/name/ID/badge) | `AppCard` header: provider glyph, name, state, "n/m Always ✓"; client ID moves inside Details (mono, hover-copy) |
| CL-4 | Metadata grid ×6 (Client ID/Trust ID/Issuer/Resource/Scopes/Last Auth) | **Details** disclosure `KeyValueGrid` — all six + token counts (additive), mono, selectable, per-row copy |
| CL-5 | Allow All Current Tools | Card verb (confirmed with count) — kept, disabled when no tools |
| CL-6 | Clear Always Allow | **Revoke All Always-Allows** (renamed) — kept, disabled when no allowances |
| CL-7 | Delete Client + confirmation | **Delete App…** + rewritten confirmation (§5.7 #2) |
| CL-8 | Per-tool permission row (name/capability/Disabled badge/mono ID) | Policy list rows — severity-tinted capability chip (fixes always-orange), "Not Shared" chip, mono ID hover-copy |
| CL-9 | Always Allow toggle per tool per client | Kept (`setToolAlwaysAllowed`) |
| CL-10 | Tool ordering (category → name) | Kept, now with visible category headers + per-category Allow ▾ menus + search |

### Approvals (16) → Requests + Approval window

| ID | Current element | New home |
|---|---|---|
| AP-1 | Header title + subtitle | Toolbar "Requests — n waiting" |
| AP-2 | Empty state | Re-voiced (§5.3) |
| AP-3 | Client Authorization section | **Connection Requests** section (history) + pending cards; two kinds never merged |
| AP-4 | Auth row identity + colored state | ApprovalCard/history row: client name, selectable resource, state word tinted (pending orange/approved green/denied red/expired gray) |
| AP-5 | Auth detail grid ×6 | Row expansion `KeyValueGrid` (Request ID, Client ID, Trust ID, Resource, Issuer, Redirect) + window Details disclosure |
| AP-6 | Requested scopes text | Kept on the card (window + row) |
| AP-7 | Auth Deny | Card/window **Deny** (pending only) |
| AP-8 | Auth Approve (prominent) | Card/window **Approve** (`.glassProminent`) + consequence copy |
| AP-9 | Tool Calls section | **Tool Runs** section (history) + pending cards |
| AP-10 | Tool-call identity (tool name/ID, client name/ID, state) | Card header + Details grid |
| AP-11 | Capability pill + creation time | Severity-tinted capability sentence/chip (fixes always-orange) + time; live countdown added |
| AP-12 | Arguments preview (mono, selectable) | Structured key:value rows **plus** the raw preview string preserved inside Details (selectable) — nothing lost |
| AP-13 | Tool-call identity grid (Request/Client/Trust) | Details grid, mono, hover-copy |
| AP-14 | Tool-call Deny | Card/window **Deny** + ⌘⌫ |
| AP-15 | Approve Run (prominent) | Card/window **Approve Run** (`.glassProminent`) + ⌘⏎ |
| AP-16 | Always Allow (conditional on clientID) | Window/row **Always Allow for ‹App›…** menu (condition kept; `approveToolCallForever`) + minted-rule morph + undo caption + ⌥⌘⏎ |

### Tunnel (36) → Connection (Address + Verify + Readiness) — 1:1 against the inventory rows

| ID | Current element | New home |
|---|---|---|
| TU-1 | Header + subtitle | Toolbar subtitle; "Cloudflare Tunnel" survives as the named provider in the Address card and the Go-public confirmation |
| TU-2 | Status rows ×4 (Provider / Status / Local target / Public URL incl. placeholder states) | Hero (Tier 0): status + URL capsule; Provider named in the hero caption + Address summary; local target as the "Forwards only to MacRemote's local server (127.0.0.1:51891)" caption; "Waiting for Cloudflare" / "Not created yet" kept as noun-phrase states; failures render in the error row, never the URL slot |
| TU-3 | Copy public URL (logs) | Hero fused Copy + toolbar ⧉ + ⇧⌘C + menu bar item — all log the copy |
| TU-4 | Start Tunnel + confirmation | Hero **Go Public…** + confirmation (§5.7 #1) + ⇧⌘R |
| TU-5 | Stop Tunnel | Hero **Stop Sharing** + ⇧⌘. |
| TU-6 | Starting spinner | Hero Public-pending state |
| TU-7 | Refresh (stopped/failed/unavailable) | Retry (failed) / Check Again (unavailable) / "Refresh Tunnel Status" in Verify More ⌄ (plain stopped) — all three states mapped |
| TU-8 | Smoke Test Guide (dead `#filePath` open) | **Testing Guide** in-app help sheet (Verify More ⌄ + Help menu) — capability kept, mechanism fixed |
| TU-9 | Copy Preflight | **Copy Quick Test Command** — Verify More ⌄ + Server menu (dual-homed) |
| TU-10 | Copy API Smoke | **Copy Full Test Command** — same two homes |
| TU-11 | Load Domains | Address ▸ Your Domain **Load Domains** (disabled + spinner while working) |
| TU-12 | Custom Domain status | Your Domain status line + five-stage deploy list header |
| TU-13 | Domain picker | Your Domain form (zones; "Choose a domain" none option kept) |
| TU-14 | Subdomain field | Your Domain form (placeholder "macremote") |
| TU-15 | Hostname preview (selectable) | Your Domain live preview ("Enter a valid subdomain" fallback kept) |
| TU-16 | Access picker (shared state w/ Settings) | Read-only **Sign-in method** row → "Change in Settings…" (singleton per D11; same binding) |
| TU-17 | API Token secure field | Your Domain `SecureField` + session-only honesty caption ("MacRemote never stores this token — you'll paste it again next launch") |
| TU-18 | Deploy hint (`customDomainDeployHint`) | Kept as the caption above Deploy |
| TU-19 | Deploy Custom Domain button | **Deploy Your Domain** — now also gated on token presence (hint/gate agreement fixed) |
| TU-20 | Copy Access credentials (dynamic title) | Post-deploy **Copy Credentials** (mode-titled, kept) |
| TU-21 | Last deployment proof grid | Post-deploy proof grid (Hostname / Tunnel / Protection + access-mode detail) |
| TU-22 | Verification status row (+ blocked copy) | Verify card status line (blocked copy re-voiced, gating kept) |
| TU-23 | Readiness check rows | Readiness card (`ReadinessRow`, same 6-check machine) — one component, also used in onboarding S4 |
| TU-24 | Check Readiness | Readiness card **Check Readiness** (disabled while a test runs) |
| TU-25 | Run Preflight | Verify **Run Quick Test** (gating kept: `readiness.canRunPreflight`) |
| TU-26 | Run API Smoke | Verify **Run Full Test** (gating kept) |
| TU-27 | FDA targets sub-panel (readiness) | Readiness ▸ FDA row expansion = embedded Access Fixer (same `TargetRow`s) — **always reachable** (D1) |
| TU-28 | FDA sub-panel Settings jump | Re-pointed: the FDA row expansion is the canonical surface (the sidebar Settings destination no longer exists); from the sheet, Troubleshoot ⌄ ▸ **Open Connection Readiness** |
| TU-29 | FDA Copy All Paths | Access Fixer (step area + Troubleshoot ⌄; logs) |
| TU-30 | FDA Open Guided Setup | Access Fixer **Open System Settings** (`openFullDiskAccessHelper()`) |
| TU-31 | FDA Relaunch MacRemote | Access Fixer Troubleshoot ⌄ ▸ Relaunch MacRemote |
| TU-32 | FDA Reset App Row | Access Fixer Troubleshoot ⌄ ▸ Re-add MacRemote in System Settings |
| TU-33 | FDA Confirm Setup (conditional) | Access Fixer Troubleshoot ⌄ ▸ Confirm Setup Manually (conditional on `requiresManualConfirmation`) |
| TU-34 | Last Proof panel + Copy Proof | Verify ▸ [Details] grid (Status/Mode/URL/Tool count/Result + mono markers) + **Copy Last Result** (redacted `clipboardText`, kept technical) |
| TU-35 | Exposed Tool Surface panel (counts + gated-name list) | Sub-facts line (same numbers) + the ask-first popover (full name list, capped with "and 62 more…" expander) |
| TU-36 | Why Cloudflare explainer | Address card ⓘ popover (facts kept, re-voiced) |

### Logs (2) → Activity

| ID | Current element | New home |
|---|---|---|
| LO-1 | Header ("Audit trail" lie) | Toolbar "Activity — This session" + truth footer; additive filter/scope/search/export/clear |
| LO-2 | Log list (time/level/message, newest first, 250 cap) | Kept exactly (mono time, level chip colors, 2-line messages, selectable), lazy, `.hard` top edge |

### Settings (39) — numbered against the inventory

| ID | Current element | New home |
|---|---|---|
| SE-1 | Connectors: Provider picker (icons) | Settings › General ▸ Connect an App ▸ **App** picker |
| SE-2 | Connectors: "Privacy" access-mode picker | Settings › General ▸ **Sign-in method** picker (**the singleton**, D11; mislabel dead) |
| SE-3 | Connector profile summary (4 badges + setup line) | Settings › General ▸ compatibility badges + setup line |
| SE-4 | Local Server: Bind address | Settings › Security ▸ "Only on this Mac" + `127.0.0.1` mono |
| SE-5 | Local Server: Instance ID (copyable) | Settings › Security ▸ **Private address ID** (mono, selectable, hover-copy) |
| SE-6 | Rotate Instance ID + dialog | Settings › Security ▸ **Reset Private Address…** + confirmation (§5.7 #3); completes in place (§2.4) |
| SE-7 | Revoke OAuth Grants + dialog | Settings › Security ▸ **Sign Out All Apps…** + confirmation (§5.7 #4) |
| SE-8 | OAuth Credentials: Generate | Settings › Security ▸ **Generate ‹Provider› Credentials** (prominent when empty) |
| SE-9 | Per-entry panel (label/ID/masked secret/created) | Settings › Security credential panels (`.privacySensitive()` mask kept) |
| SE-10 | Copy ID | Kept (logs copy) |
| SE-11 | Copy Secret | Kept (logs copy) |
| SE-12 | Copy JSON (conditional) | Kept (`oauthClientCredentialsJSON`) |
| SE-13 | Rotate credentials + dialog | **Replace…** + confirmation (§5.7 #5) |
| SE-14 | Delete credentials + dialog | **Delete…** + confirmation (§5.7 #6) |
| SE-15 | Pushover enable | Settings › Notifications ▸ Pushover toggle |
| SE-16 | Pushover User ID (secure) | Kept (`SecureField`, disabled while off) |
| SE-17 | Pushover API Key (secure) | Kept |
| SE-18 | Pushover triggers explainer | Re-voiced footer ("Get notified when an app asks to connect, when your public link stops unexpectedly, or when MacRemote restarts while it was sharing.") |
| SE-19 | Pushover Send Test | Kept (disabled unless configured) |
| SE-20 | Brrr enable | Settings › Notifications ▸ Brrr toggle |
| SE-21 | Brrr Secret (secure) | Kept (footer re-voiced, no literal backticks) |
| SE-22 | Brrr Send Test | Kept |
| SE-23 | FDA status row (7 states) | Connection ▸ Readiness ▸ Full Disk Access row (icon+color per state) — **always visible** |
| SE-24 | FDA Check Access / Check Again + spinner | Readiness FDA expansion + Access Fixer **Check Again** (title flips while checking; spinner row kept) |
| SE-25 | FDA Open Guided Setup | Access Fixer **Open System Settings** |
| SE-26 | FDA Relaunch MacRemote | Access Fixer Troubleshoot ⌄ |
| SE-27 | FDA Reset App Row | Access Fixer Troubleshoot ⌄ ("Re-add MacRemote in System Settings") |
| SE-28 | FDA Confirm Setup (conditional) | Access Fixer Troubleshoot ⌄ (conditional on `requiresManualConfirmation`) |
| SE-29 | FDA Copy First Target | Access Fixer Troubleshoot ⌄ (copies path + fileURL type; logs) |
| SE-30 | FDA report detail (selectable) | Access Fixer status/detail line (selectable) |
| SE-31 | FDA Grant Access To target rows | Access Fixer `TargetRow`s (full anatomy verbatim: icon, role capsule, mono path, Copy, Reveal, drag, `.help`) |
| SE-32 | FDA Copy All Paths (+ drag hint) | Access Fixer (step area + Troubleshoot ⌄); the ⌘⇧G hint lives in the row `.help` tooltip |
| SE-33 | FDA numbered setup steps (5–6) | Access Fixer numbered 3-step strip (① Open System Settings ② Drag rows in ③ Relaunch, then Check Again) + Troubleshoot ⌄ for the long-tail steps — every instruction survives |
| SE-34 | FDA contextual footers (no-targets / caching caveat) | Access Fixer empty state + caching-caveat footer under step ③ ("macOS often keeps the old permission cached until MacRemote relaunches.") |
| SE-35 | macOS Privacy status row | Connection ▸ Readiness ▸ Privacy Permissions row — always visible |
| SE-36 | Privacy Check Access | Privacy row expansion **Check Access** |
| SE-37 | Open Reminders Privacy deep link | Privacy row expansion **Open Reminders Privacy** (`x-apple.systempreferences:…Privacy_Reminders`) |
| SE-38 | Privacy report detail | Privacy row detail (selectable) |
| SE-39 | Privacy requirement badges | Privacy row expansion requirement chips (one per checked `ToolPermissionRequirement`) |

### Sheets & Dialogs (28)

| ID | Current element | New home |
|---|---|---|
| SD-1 | Add Tool sheet (600×720, Cancel/Save, inline error) | **Library sheet** (720×560, tabs Bundles/Found on This Mac/Presets/Custom) + inspector **Definition** tab for edits (D8); Save validates with per-field errors, model-level error string kept as fallback |
| SD-2 | Tool Sets one-click import | Bundles tab — **preview-then-confirm** ("Install 21 tools" with the list visible; dedupe messaging intact; `addUserTools(from:)`) |
| SD-3 | Detected CLIs rows (prefill draft) | Found on This Mac tab — rows prefill a draft ("Customize & Save" / "Just Add"); "Added ✓" markers |
| SD-4 | Command Presets + category picker | Presets tab with category filter (featured excluded, as today) |
| SD-5 | Mode picker (CLI Adapter / Command Template) | **Fixed Command / Flexible Command** segmented control (Custom tab + Definition tab) with consequence one-liners (D7) |
| SD-6 | Name / Summary / Executable Path fields | Kept (executable mono + **Browse…** file picker added; inline validation) |
| SD-7 | Arguments editor (argv lines, `{name}` placeholders) | Kept (mono TextEditor) + **live parameter preview** (inference made visible) |
| SD-8 | Adapter info (args/stdin explanation) | Flexible Command info block, re-voiced ("The app chooses the arguments. Every risky call still asks you first."); `args`/`stdin` facts kept |
| SD-9 | Category picker (8 categories) | Kept |
| SD-10 | Capability picker (Read-only/Write/Destructive) | Kept + consequence footer ("Write and Destructive tools ask you before every run") |
| SD-11 | Timeout stepper (1–60 s) | Kept — text entry + stepper + presets |
| SD-12 | Output limit stepper (1–5120 KB) | Kept — text entry + stepper + presets (512 KB / 2 MB / 5 MB) |
| SD-13 | macOS Permissions toggles (13, incl. FDA) | Kept — each with a one-line consequence; footer explains they gate Readiness |
| SD-14 | Cancel / Save | Sheet Cancel/Save; inspector Definition **Save/Revert** |
| SD-15 | Start Public Tunnel confirmation (dynamic counts) | "Go public?" (§5.7 #1) — counts kept, `.destructive` role removed, reused by Dashboard-equivalent + menu + MenuBarExtra routes |
| SD-16 | Delete Client confirmation | "Delete 'Claude'?" (§5.7 #2) |
| SD-17 | Rotate Instance ID confirmation | "Reset your private address?" (§5.7 #3) |
| SD-18 | Revoke OAuth Grants confirmation | "Sign out every app?" (§5.7 #4) |
| SD-19 | Rotate OAuth Credentials confirmation | "Replace these credentials?" (§5.7 #5; pending-ID clearing on either choice kept) |
| SD-20 | Delete OAuth Credentials confirmation | "Delete these credentials?" (§5.7 #6; same) |
| SD-21 | FDA permission sheet (680 pt, reason-adaptive) | Access Fixer sheet (§5.8) — all four `FullDiskAccessPrompt` reasons keep bespoke re-voiced title/detail; status row + spinner + selectable detail kept |
| SD-22 | FDA sheet targets / "No Targets Yet" empty state | Access Fixer `TargetRow` list / empty state ("No items yet — Check Again finds exactly which items need access.") |
| SD-23 | FDA sheet Settings button (navigates + dismisses) | Troubleshoot ⌄ ▸ **Open Connection Readiness** (opens Connection with the FDA row expanded, dismisses the sheet) — the inventory's navigation intent, re-pointed at the new home |
| SD-24 | FDA sheet Copy All Paths | Kept (Troubleshoot ⌄ + step area; logs) |
| SD-25 | FDA sheet Later | Kept (`dismissFullDiskAccessPrompt()`) |
| SD-26 | FDA sheet Guided Setup / Relaunch / Reset App Row / Confirm Setup | Open System Settings (primary row) + Troubleshoot ⌄ (Relaunch · Re-add MacRemote · Confirm Setup conditional) |
| SD-27 | FDA sheet Check Again (prominent) | Kept prominent (`.glassProminent`) |
| SD-28 | FDA target row (icon/role/path/Copy/Reveal/drag/help) | `TargetRow` component — anatomy unchanged, shared across all three hosts |

### Cross-Cutting Behaviors (6)

| ID | Behavior | New home |
|---|---|---|
| CC-1 | Every identifier `.textSelection(.enabled)` | Kept app-wide via `MonoValue` (+ hover-reveal CopyButton added) |
| CC-2 | Every Copy writes an audit log entry | Kept via the single `CopyButton` component (pasteboard write + `appendLog` + checkmark morph) |
| CC-3 | Secret masking (28-asterisk `.privacySensitive`, SecureFields) | Kept: credential secrets `.privacySensitive()`; Pushover/Brrr/Cloudflare tokens `SecureField` |
| CC-4 | FDA rows draggable (file URLs into System Settings) | Kept in `TargetRow` (`.draggable(fileURL)`) |
| CC-5 | FDA row `.help` tooltip (drag or ⌘⇧G) | Kept in `TargetRow` |
| CC-6 | `panelStyle()` / MetricPill / StatusBadge shared vocabulary | Replaced by the component system: `Card`, `StatChip`, `StateChip` (see DESIGN-GUIDELINES §2) — one severity scale, one card treatment |

### Model-Only APIs (4) — all gain UI

| ID | API | New home |
|---|---|---|
| MO-1 | `runToolTest(toolID:parameters:)` | Inspector **Test Tool** (result: exit code/stdout/stderr/duration, mono) + Verify **Test a Tool…** (default `remctl.today`) + ⌘⏎ on tool rows |
| MO-2 | `setRemCTLProfileEnabled` / `isRemCTLProfileEnabled` | Tools ▸ Reminders section-header **Share All / Share None** menu (wired to the profile API) + the Bundles tab's Reminders toggle |
| MO-3 | `clientToolPermissionSnapshot` | Inspector **Permissions** tab (per-tool pivot) + Apps "n of m always allowed" counts |
| MO-4 | `anthropicCredentialState` | Readiness ▸ **Anthropic API Key** row, labeled "Optional — for the full test" |

**Count check:** 6+3+17+15+18+10+16+36+2+39+28+6+4 = **200. ✓**

---

## 8. Implementation requirements (non-visual, binding)

1. **Toolchain:** build with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`; `Package.swift` → `// swift-tools-version: 6.2`, `platforms: [.macOS(.v26)]`; zero `#available` checks; no 27-SDK-only APIs (`visibilityPriority`, `ToolbarOverflowMenu`).
2. **Tool editing** must preserve tool identity and Always Allow allowances transactionally (D8).
3. **Approval window** is non-activating; verbs are click targets + menu commands (D4). Pending-request resolution on server stop per D18. The 16-pending cap surfaces as a queue-footer note when hit.
4. **Readiness rows render their expansions in every state** (D1) — a code review finding a `state != .ready` guard around the FDA/Privacy expansion is a spec violation.
5. **No control approves more than one request** (D2).
6. **The MenuBarExtra never resolves a request** (D3).
7. **Glass budget is falsifiable** (see DESIGN-GUIDELINES §3): any `glassEffect(` outside `ConnectionHero` fails review.
8. QA states: both extremes of the macOS 27 transparency slider, Reduce Transparency, Reduce Motion, Increase Contrast, inactive window; Activity streaming under `.hard` edges; the 166-tool dataset at 1040×680 minimum.
