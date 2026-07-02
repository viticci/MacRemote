# MacRemote — Polish Punchlist (SF Symbols + Residual Visual Polish)

> **Provenance.** Output of the CLI-discovery research run on **2026-07-02** (five briefs: `catalog-audit`, `discovery-mechanisms`, `security-model`, `ux-design`, `sf-symbols-audit`). Every current symbol and every proposed replacement below was verified to resolve via `NSImage(systemSymbolName:)` on this Mac (Darwin 27.0.0; harnesses `scratchpad/design/cli-discovery/symcheck*.swift`). This file is a **mechanical implementation checklist**: each row is file:line + exact change, no design judgment required at apply time. Companion feature spec: `CLI-DISCOVERY-SPEC.md`.

---

## 1. Bugs — symbols that do not exist (render blank today). Fix first.

| # | File:Line | Current | Replace with | Why |
|---|---|---|---|---|
| B1 | `Views/ToolsView.swift:10` | `"podcasts"` | `"music.microphone"` | `podcasts` is not an SF Symbol — the Podcasts category icon is blank in the shipping UI. Studio mic reads "podcast" and stays distinct from the `mic` permission glyph. |
| B2 | `Views/SettingsView.swift:392` | `"key.badge.plus"` | `"key.2.on.ring"` | `key.badge.plus` is not an SF Symbol — the Generate-credentials button icon is blank. A key ring = "mint another static client credential" (the app supports multiple static OAuth clients). |
| B3 | `Views/SettingsView.swift:397` | `"key.badge.plus"` | `"key.2.on.ring"` | Same fix, second call site. |

## 2. Semantic / redundancy replacements (all verified)

| # | File:Line | Current | Replace with | Rationale |
|---|---|---|---|---|
| S1 | `Views/DesignSystem/Tokens.swift:111` | `dot.radiowaves.left.and.right` (StatusRole.working) | `circle.dashed` | Radio waves = broadcasting; as generic "working" it collides with the Connection sidebar item and StatusOrb. `circle.dashed` already means in-progress (ConnectionReadinessCard:103) — unify. StatusOrb keeps its own radiowaves for starting/local, where it IS broadcast. |
| S2 | `Views/DesignSystem/Tokens.swift:131` | `checkmark.circle` (ToolCapability.readOnly chip) | `eye` | A checkmark means success, not read-only; collides with the ready role and the "Active" chip. The app already says view-only with `eye` (ToolsView:614) — one symbol per concept. |
| S3 | `Views/ToolsView.swift:327` | `dot.radiowaves.left.and.right` ("Scan This Mac") | `sparkle.magnifyingglass` | Scanning searches local disk files, not airwaves. Matches the Library's "Found on This Mac" tab — same concept, same symbol. This is also the glyph for the CLI-discovery scan menu (CLI-DISCOVERY-SPEC §5.1); apply here whether or not the menu conversion has landed. |
| S4 | `Views/ToolsView.swift:12` | `wrench.and.screwdriver` (Utilities category) | `wrench.adjustable` | Utilities shares its glyph with the Tools sidebar item, the "No tools yet" empty state, and the shared-tools readiness row. A single wrench keeps the meaning and gives the category its own identity. |
| S5 | `Models/ToolDefinition.swift:215` | `lock.shield` (fullDiskAccess permission) | `internaldrive` | Every other permission depicts its resource (calendar, camera, mic…) — FDA should depict the disk. Frees `lock.shield` to mean exactly one thing: Security. |
| S6 | `Views/ConnectionReadinessCard.swift:281` | `lock.shield` (FDA readiness row) | `internaldrive` | Same concept, same fix — FDA consistent across readiness row and permission chips. |
| S7 | `Models/ToolDefinition.swift:225` | `figure` (accessibility permission) | `accessibility` | `accessibility` is Apple's canonical Accessibility glyph — exact TCC-service match. |
| S8 | `Models/ToolDefinition.swift:224` | `rectangle.dashed` (screenRecording permission) | `rectangle.dashed.badge.record` | Plain dashed rectangle = selection/placeholder; the record badge makes it unambiguously Screen Recording. |
| S9 | `Models/ConnectorProfile.swift:32` | `lock.badge.clock` (.oauthClientSecret) | `key.fill` | The clock badge means auto-lock/timed and collides with SettingsView:360 where it correctly means "Keychain locked". `key.fill` matches the Copy Secret button (SettingsView:445): the secret IS the key. |
| S10 | `Models/ConnectorProfile.swift:35` | `key.viewfinder` (.serviceTokenAuthorizationHeader) | `key.card` | Viewfinder = scan-with-camera. A keycard is a single carried credential — one Access header presented on entry. |
| S11 | `Models/ConnectorProfile.swift:131` | `sparkles` (Raycast provider) | `rays` | `sparkles` is stretched across Raycast, the parameter-preview label, and echoes `sparkle.magnifyingglass`. `rays` is the literal match for **Ray**cast and frees `sparkles` to mean "computed magic" only. |
| S12 | `Models/ConnectorProfile.swift:133` | `square.grid.2x2` (Notion provider) | `doc.richtext` | 2×2 grid reads "app launcher"; Notion is a rich-document tool. *(Lower confidence — skip if the grid is meant to evoke Notion's block canvas.)* |
| S13 | `Views/ToolsView.swift:1098` | `exclamationmark.triangle` | `exclamationmark.triangle.fill` | Variant inconsistency: every other warning (incl. ToolsView:1105) uses the filled triangle. |
| S14 | `Views/ToolsView.swift:1165` | `exclamationmark.triangle` | `exclamationmark.triangle.fill` | Same fix, second call site. |
| S15 | `Views/ConnectionReadinessCard.swift:19` | `checklist` (Readiness card header) | `list.bullet.clipboard` | `checklist` is triple-booked with Reminders (category + permission + line 465, where it's right). Clipboard checklist = pre-flight; de-conflicts from Reminders. |
| S16 | `Views/ConnectionReadinessCard.swift:131` | `checklist` ("Check Readiness" button) | `list.bullet.clipboard` | Follows the header. |
| S17 | `Views/ToolLibrarySheet.swift:22` | `square.grid.3x3` (Bundles tab) | `shippingbox` | Bundles are curated packages — the box is the package metaphor, and the vocabulary Homebrew/npm users bring to the CLI-discovery feature. |
| S18 | `Views/ToolLibrarySheet.swift:129` | `square.grid.3x3` (Bundles empty state) | `shippingbox` | Follows the tab. |

## 3. New symbol assignments required by CLI-DISCOVERY-SPEC (all verified on this Mac)

| # | Where (new code) | Symbol | Use |
|---|---|---|---|
| N1 | `Models/ToolDefinition.swift` — new `ToolCategory.ai` case (SPEC F20) | `apple.intelligence` | Category icon for "AI & Agents". Verified via symcheck 2026-07-02. Does not collide with `sparkles` (parameter preview). |
| N2 | Found-tab signed rows (CLI-14) | `checkmark.seal` | Quiet seal glyph, secondary style, `.help` names the signer. Already in the app's verify vocabulary — no new meaning. |
| N3 | Quarantined chip (CLI-15) | `exclamationmark.triangle.fill` | Orange StateChip, existing warning vocabulary. |
| N4 | Source badges in the Found tab | `shippingbox` (Homebrew/npm packages) · `folder` (PATH folders) · `terminal` (loose executables) | Reuse, don't invent: `terminal` already means toolExecutable (RuntimeState FullDiskAccessTargetRole); `folder` is the filesystem category glyph. |
| N5 | Scan menu + Found tab affordances | `sparkle.magnifyingglass` | Same symbol as S3 and the existing Found tab — one concept, one symbol. |

## 4. Rendering-mode polish (residual items from the audit §3)

| # | File:Line | Change |
|---|---|---|
| R1 | `Views/DesignSystem/Components.swift:157` (StateChip glyph) | Add `.symbolRenderingMode(.hierarchical)` to filled status glyphs (`checkmark.circle.fill`, `exclamationmark.triangle.fill`, `xmark.octagon.fill`, `xmark.circle.fill`). At caption sizes a flat fill turns into a colored blob; hierarchical keeps the interior mark legible with the same tint. |
| R2 | `Views/RequestsView.swift:212` (the one `Image(systemName: stateSymbol)` render site; symbols defined at 293–300 and 368–374) | Same hierarchical treatment. |
| R3 | `Views/DesignSystem/Checklists.swift:92/100/104, 209/216, 271` | Same hierarchical treatment on the checklist state glyphs. |
| R4 | `Views/SettingsView.swift:301/308` (diagnostic rows) | Same hierarchical treatment. |
| R5 | `Views/SettingsView.swift:14` + `Views/ApprovalCard.swift:501` (`bell.badge`) | Add `.symbolRenderingMode(.hierarchical)` — the badge dot is drawn for it. |
| R6 | `Views/DesignSystem/Components.swift:26–29` (StatusOrb glyph) | Add `.symbolRenderingMode(.hierarchical)` under the existing variable-color effect (`dot.radiowaves.left.and.right` and `globe` have layered artwork). |
| R7 | `Views/ToolsView.swift:327` (scan control, after S3) | Add `.symbolEffect(.pulse, isActive: isScanning)` on `sparkle.magnifyingglass` (respecting Reduce Motion, as the codebase already does) in addition to the "Scanning…" label swap. Directly reusable by the CLI-discovery scan menu. |
| R8 | `Models/ToolDefinition.swift:224` (after S8) | `rectangle.dashed.badge.record` gets hierarchical rendering for free where permission chips draw it — include it in R1's treatment path. |

## 5. Explicit keeps (do not churn — judged and deliberately unchanged)

`waveform.path.ecg` (Activity — the sidebar's one moment of personality) · the `hand.raised` family (one symbol, one concept — the app's best symbol decision) · the octagon-vs-circle failure split (`xmark.octagon.fill` = broke, `xmark.circle.fill` = negative outcome) · the `circle.dotted` dormant family · the `checkmark.seal` verify family · `finder` for Reveal · `doc.on.doc` for every Copy · `point.3.connected.trianglepath.dotted` (what a bridge tool *is*) vs `app.connected.to.app.below.fill` (where it *came from*) · bare `xmark` vs `xmark.circle.fill` dismiss variants (both legitimate; unify only if touching those files anyway).

Sidebar/macOS-26 conventions: keep the five NavigationSection symbols outline-weight and monochrome; no `.symbolVariant(.fill)` on selection (iOS tab-bar convention, not macOS); no per-item rainbow `listItemTint`.

## 6. Sequencing note

Apply §1 (bugs) immediately — they are visible defects. §2 S1–S18 and §4 are safe in one mechanical pass; S3/R7 should land with or before the CLI-discovery toolbar-menu change so the scan vocabulary is already unified. §3 lands with the feature itself. After the pass, re-run the symbol existence check (`symcheck` pattern) over the diff as the review gate.
