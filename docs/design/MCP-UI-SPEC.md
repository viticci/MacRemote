# MacRemote MCP UI Spec — the Selective Widget

MacRemote implements the **MCP Apps extension (SEP-1865, spec 2026-01-26)**
with one shared widget that attaches **selectively**: only tools whose
category has curated presentation hints link it — RemCTL reminders and
PocketCTL podcasts today. Every other tool returns the plain
text/structured result and the host renders its own native display.

**Why selective (decision 2026-07-02, supersedes the original
render-everything design):** for uncurated output the widget degrades to a
raw JSON/terminal dump, which is strictly worse than claude.ai's native
tool rendering (observed with the X/Twitter search tools). The widget only
earns its place where MacRemote curates the presentation — columns, cards,
artwork, actions. Eligibility is derived, not listed:
`LocalMCPServer.widgetEligible(category:)` returns true exactly when the
category has an accent or table hints, so adding a curated category
automatically opts it in. Declared `uiActions` on ineligible tools stay
inert data until their category earns hints (habitctl's check-off is
currently dormant for this reason).

One widget still covers every eligible tool because all tools — process
adapters, Fixed Commands, and both MCP bridge flavors — return the same
ten-field envelope through `LocalMCPServer.structuredContent(for:)`.

Decision log for this feature lives here; the adversarially-verified research
that led to it is `docs/research/MCP-UI-REPORT.md`.

## Server surface (Services/LocalMCPServer.swift)

- **Resource**: `ui://macremote/output`, MIME `text/html;profile=mcp-app`,
  served via standard `resources/list` / `resources/read`. The read result
  carries `_meta.ui` sandbox hints: `prefersBorder`, CSP allowlists
  (`connectDomains` empty — no fetch/XHR; `resourceDomains` allows exactly
  `https://static.pocketcasts.com` for podcast artwork), and a
  `clipboardWrite` permission request.
- **Tool linkage**: `tools/list` entries for widget-eligible tools (see
  above — reminders + podcasts categories) carry
  `"_meta": {"ui": {"resourceUri": "ui://macremote/output"}}` (SEP-1865
  nested form). All other tools carry no `_meta` at all. Hosts without the
  extension ignore `_meta` entirely.
- **Fallback is sacred**: `content[0].text` (the serialized envelope) and
  `structuredContent` are unchanged. Claude Code, Raycast, and every
  non-rendering client see exactly what they saw before this feature.
- **Result hints**: for widget-eligible tools only,
  `CallToolResult._meta["net.viticci.macremote/ui"]` carries `{version,
  toolTitle, toolName (public), capability, category, actions?}`. Internal
  tool ids never leave the server — action targets are translated to public
  MCP names. Ineligible tools return results with no `_meta`.
- **Payload cap**: envelope `stdout` is capped at 100k characters and
  `stderr` at 16k (`mcpStdoutCharacterLimit` / `mcpStderrCharacterLimit`)
  with truncation flags set, keeping every result far below the ~150k cliff
  where Claude's code-execution sandbox diverts results to a file and the
  widget never hydrates.

## UI actions — interactivity as data, never code

`ToolUIAction` (Models/ToolDefinition.swift) declares widget affordances on a
tool. It is **pure data** (catalog presets, built-in catalogs, or
user-defined tools.json) — no tool-specific code paths, per AGENTS.md's
"no special product modes" rule:

```swift
ToolUIAction(
    id: "complete", title: "Mark Done", kind: .checkOff,
    toolID: "remctl.run",
    arguments: .object(["args": .array([.string("done"), .string("{id}"), .string("--json")])]),
    requiredRowFields: ["id"],
    completedWhenField: "completed"
)
```

Mind the target CLI's flag grammar: remctl's `--json` is a **per-subcommand**
flag — placed before the subcommand, argparse exits 2 with "unrecognized
arguments" and the affordance no-ops. This shipped broken once (v2 catalog);
the `catalogUIActions.v3` migration repairs persisted remctl actions by
moving a leading `--json` to the end of the args array
(`AppModel.remCTLActionsWithRepairedJSONFlag`, remctl-targeted actions only).

- `kind`: `.checkOff` (leading Reminders-style circle on table rows) or
  `.rowButton` (trailing button).
- Targeting: `toolID` for stable built-in catalogs (remctl), or
  `targetExecutableBasename` to address "the shared flexible adapter for
  this executable" — preset-derived tools carry random ids, so catalog
  actions can't reference them by id. Unresolvable actions are dropped
  server-side; internal addressing never reaches clients.
- `arguments` string leaves may contain `{field}` (row) and `{input.<name>}`
  (collected input) placeholders.
- `inputs` collects values before firing: the widget expands an inline form
  under the row, prefilled via `prefillField` (reschedule/edit-title use
  this).
- `style: .destructive` arms a two-step Confirm? in the widget before firing
  (delete uses this — on top of, never instead of, the approval flow).
- `requiredRowFields` gates the affordance per row; `completedWhenField`
  renders already-done rows checked and struck through — truthiness by
  default, string equality with `completedWhenEquals` (habitctl reports
  `status: "completed"`).
- **Security invariant**: an action is a shortcut to a normal `tools/call`.
  The widget calls the target tool by public name through the host, over the
  same authenticated connection; MacRemote's capability gating and the host
  approval flow apply unchanged. "If allowed" is enforced by the server,
  never by the UI. (`remctl.run` is destructive → Always Allow or the
  Approval window decides, exactly as if the model had called it.)

Shipped action packs:
- **RemCTL** (today/upcoming/overdue/flagged/urgent/search/show): check-off,
  Reschedule (input: due date), Edit Title (input prefilled from the row),
  Delete (destructive, `--force` because the CLI's interactive confirm would
  hang a headless call — widget confirm + approval flow carry the safety).
- **HabitCTL** (today/journal presets): check-off via `habitctl check <id>`,
  equals-matched completion on `status`.
- **PocketCTL** (up-next: Play Next / Play Last / Remove; in-progress:
  Play Next / Play Last / Star), plus four new queue-management presets
  (`play_now`, `play_next`, `play_last`, `remove_up_next`) so queue verbs
  are also directly callable by the model.

Preset-carried actions reach existing installations through a one-time
migration (`migrateCatalogUIActionsIfNeeded`, matching on **name + full
executable path** — a same-basename impostor at a different path never
inherits another tool's category or destructive actions — and never
overwriting tools that already have actions). The marker is set only after a
durable save, so a failed write retries next launch.

**Write-back requires a shared write tool.** An action resolves through
`resolveActionTarget` against the *exposed* tool set. Reminder check-off /
reschedule / edit / delete target the flexible RemCTL adapter by basename, so
that adapter ("Run RemCTL") must be shared for the affordances to appear. If
only the read-only reminder tools are shared, the widget renders a plain
table with no action buttons — truthful (you can't write without a shared
write tool), not a bug. This is deliberate: the alternative (showing buttons
that fail on click) is worse. The affordances also stay behind normal
capability gating and host approval at execution.

## The widget (Widget/MacRemoteWidget.html)

Design: **Instrument Panel** (winner of a three-direction judged
competition). One card; the whole status story is a single 2px accent line
(green/red/amber); tabular-numeric metrics; `light-dark()` theming honoring
both `prefers-color-scheme` and a host-forced `hostContext.theme` (via
`data-mrw-theme`). Self-contained, zero network.

Adaptive states from the envelope:

| stdout looks like | state |
|---|---|
| JSON array of objects, or object with exactly one array-of-objects value (`{"items": [...]}`) | sortable table, curated column order (id/title/name/list/due… first, all-null columns dropped, cap 8), check-off circles and row buttons per declared actions |
| single JSON object whose primary curated field is present (e.g. `pocketctl now`) | episode card: 56px artwork, title + subtitle, meta line (duration · progress · link), action buttons |
| other JSON object/array | collapsible key/value tree |
| anything else | terminal panel with curated ANSI palette (SGR colors/bold/dim/italic; everything else stripped) |
| empty + succeeded | friendly empty state |
| failed/timed out | error panel: friendly headline, stderr inlay, stdout-before-failure disclosure |

Footer: MacRemote brand, Copy Output, Run Again (replays the exact
`ui/notifications/tool-input` arguments).

**Per-result presentation hints** in `CallToolResult._meta` (derived from the
tool's category server-side, `LocalMCPServer.widgetAccent`/`widgetTableHints`):

- `accent` (hex) recolors the accent line, success chip, check circle, and
  action buttons via `color-mix` tints. RemCTL reminders read purple
  (`#8b5cf6`); PocketCTL podcasts read Pocket Casts red (`#f43e37`).
- `table.columns` supplies a curated, ordered column set. Each entry is
  `{key, title, primary?}` or a derived column with `derive:`
  - `"datetime"` (`sourceKey`, `allDayKey`) — ISO date (+ all-day flag) into
    a friendly **When** ("Jul 9, 2:00 PM", all-day → "Jul 9", missing → "—").
  - `"duration"` (`sourceKey`, seconds) — compact human duration ("1h 43m").
  - `"progress"` (`sourceKey` played seconds, `totalKey` total seconds) —
    accent-colored conic-gradient pie + percent label, tooltip "1h 08m of
    1h 43m played".
  - `"artwork"` (`sourceKey`, `urlTemplate` with `{value}`, `altKey`) — 28px
    rounded thumbnail; the value is URL-encoded into the template (podcast
    artwork off the Pocket Casts CDN, hence the CSP resource domain).
  - `"link"` (`sourceKey`) — compact "Open ↗" pill (`target="_blank"
    rel="noopener"`) instead of the raw URL; only http(s) values render.
  Every `sourceKey` may be a string or an array of fallback keys — commands
  of the same CLI can spell the same fact differently (pocketctl up-next
  calls the podcast uuid `podcast`, in-progress `podcastUuid`). A plain
  column may carry `subtitleKey`: its value renders as a dim second line in
  the cell (episode title over podcast name) and in the card, sorting stays
  on the main value.
  A curated set keeps the trailing action buttons on-screen instead of
  scrolled off past raw columns. Curated specs whose source fields never
  appear in the rows are dropped, and if fewer than two survive the widget
  falls back to auto columns — so the podcasts curation (episode-shaped
  rows) doesn't distort subscriptions/playlists output.
- `table.hiddenColumns` drops raw keys when columns aren't fully curated
  (reminders hide `id` + `completed`; podcasts hide `uuid`, `published`,
  `fileType`, `size` and other transport fields).

Row action buttons render their label immediately and stay visible (not
hover-gated), so Reschedule/Delete are discoverable on every surface. A
failed action shows a red **Failed** state for a few seconds with the CLI's
stderr tail in the tooltip — never a silent reset (a silent reset reads as
"the button does nothing").

### Wire protocol (verified against spec.types.ts + apps.mdx)

Raw JSON-RPC 2.0 objects over `postMessage` with `window.parent`; the View
initiates:

1. View → Host request `ui/initialize` (id 0; `appInfo`, `appCapabilities`,
   `protocolVersion: "2026-01-26"`), host result carries
   `hostContext.theme` etc.
2. View → Host notification `ui/notifications/initialized`.
3. Host → View `ui/notifications/tool-input` (arguments), then
   `ui/notifications/tool-result` (a verbatim `CallToolResult`).
4. View → Host `ui/notifications/size-changed` (`{height}` via
   ResizeObserver — the scroll cap is a fixed 400px because vh units are
   circular inside a self-sizing iframe).
5. Actions/Run Again: standard `tools/call` request, host-proxied.
6. Also handled: `ui/notifications/tool-cancelled`,
   `ui/notifications/host-context-changed`, `ui/resource-teardown`, `ping`.

## Testing

- `MCPUISupportTests` (server, in-process HTTP + OAuth): capability
  advertisement, tool `_meta`, resource read + sandbox meta, unknown-uri
  error, action encoding with public names, stdout cap.
- `Widget/test/harness.html`: a host simulator (fixtures: table, tree,
  terminal, error, empty, truncated, habits, podcasts, nowcard, actionfail;
  `?theme=dark`). Drive with Playwright: handshake, all states, check-off →
  recorded `tools/call` with substituted args → row completion, the podcasts
  derived columns (artwork/duration/progress/link) with subtitles, the
  nowcard single-episode card with its action button, the actionfail
  fixture's visible Failed state, and host theme forcing.

## Host compatibility

Eligible tools render on claude.ai web / Claude Desktop / Claude iOS
(custom remote connectors), ChatGPT, VS Code, Goose, MCPJam et al. Claude
Code ignores `_meta.ui` by design and keeps the text fallback. Ineligible
tools render with each host's native tool display everywhere. Debug flaky
rendering with MCPJam before blaming a host.
