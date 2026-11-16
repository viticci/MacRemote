# MacRemote MCP UI Spec — the Shared Widget

MacRemote implements the **MCP Apps extension (SEP-1865, spec 2026-01-26)**
with one shared widget for each eligible tool command. Linkage remains
capability-scoped: modern clients receive it only when they negotiate Apps, and
legacy clients keep the compatibility behavior below. Plain text and structured
results remain complete for clients that do not render the widget.

**The owner decides (2026-11-16, DESIGN-SPEC D77).** Linkage is off by default.
Settings › General ▸ Result Cards has one **Show result cards** switch and one
switch per tool family (`ToolFamily`: bridged server, File Transfer, catalog
provider, or executable). A tool links the widget only when the catalog allows
a card (`LocalMCPServer.widgetEligible`, which honors `automatic: false`) **and**
`ResultCardPreferences.allowsCard(for:)` says the owner wants one. Otherwise
`tools/list` carries no `_meta.ui`, `ui/resourceUri`, `openai/outputTemplate`,
or `openai/widgetAccessible` for that tool, and its results carry no
`net.viticci.macremote/ui` hints or link aliases. `content` and
`structuredContent` are identical either way, and the resource stays listed and
readable so old conversations still load their cards. The server receives the
choice as a `@Sendable` provider that reads the saved value on every request,
so the next tool list and the next result follow a change. MacRemote advertises
`tools.listChanged: false` and sends no change notification; apps pick up a
change when they reload the tool list. The choice is presentation only: it
never enters `tools.json`, a security fingerprint, a permission epoch, or an
approval.

**Default linkage (2026-10-01 amendment to the 2026-08-30 universal rule):** the renderer now has a defensive semantic-summary boundary that omits
raw JSON, terminal commands, executable details, local paths, credentials, and
hidden result metadata. A tool without catalog curation therefore uses the safe
`semanticResult` profile instead of falling back to a host's developer display.
An explicit `ToolWidgetPresentation` keeps the richer `reminderRows`,
`episodeRows`, `habitRows`, or `noteRows` profile plus optional accent and nested
`rootPath`. Semantic IDs, executable names, provider labels, source apps, and
product payload schemas never select a profile. Flexible Commands, custom and
imported tools, and native File Transfer tools all receive `semanticResult`.

This lets PocketCTL and OverCTL share `episodeRows` while keeping Pocket Casts
red and Overcast orange, and lets the first-party provider table give bridged
NotesCTL reads `noteRows` and bridged RemCTL reads `reminderRows` while the
rest use `semanticResult`. Presentation metadata never changes a
security fingerprint, permission, approval, or action target.

**RemCTL workflow policy (2026-10-01):** `lists`, `get_list`,
`resolve_location`, `doctor`, and the flexible `run` return their complete MCP
results without launching a card (`ToolWidgetPresentation.automatic: false`).
Reminder reads and typed writes keep useful cards. This deliberately changes
the universal-linkage policy: intermediate lookup and diagnostic cards added
no useful UI while creating a wall of success blocks. Missing `automatic`
means true, so existing custom catalogs retain their behavior.

The reminder presentation is based on the RemCTL 2.0.2 widget's data contracts:
`displayDate` before `dueDate`, section context, compact change receipts,
partial-write warnings, and separate succeeded/uncertain/unchanged batch items.
Deleted rows expose no edit controls. Generic rendering remains driven by
catalog hints; no installed CLI or upstream HTML is modified. Actions bind to
the actual imported sibling tool IDs, including collision suffixes. They always
re-enter normal authenticated tool calls and Mac-side approvals.

The renderer unwraps a complete execution envelope from assistant-visible text
when `structuredContent` is absent. ChatGPT's `toolOutput` and
`toolResponseMetadata` are additive compatibility inputs; a standard MCP Apps
result takes precedence. User-only content is never a fallback source. Only
read-only tools offer Run again; writes and unknown capabilities never do.
Native RemCTL creation remains one reminder per call. MacRemote neither batches
unrelated approvals nor promises to merge separate host-owned cards. The server
instructions encourage supported batches, reusing resolved identifiers, and
using complete write receipts without redundant reads.

**Correction (2026-07-30):** an earlier version of this document said
habitctl's check-off "sat dormant until `.habits` was curated the same
evening". That was wrong on the facts. The habits *presentation* hints
(accent + columns) shipped that evening, but neither
`HabitCTLToolPresetCatalog` nor `PocketCTLToolPresetCatalog` declared any
`uiActions` at all; the buttons in the widget harness were fixtures. Habit
check-off and the podcast row buttons ship in this round — see "Shipped
action packs" below.

One widget covers every tool because process adapters, Fixed and Flexible
Commands, both MCP bridge flavors, and native tools return the same outer
eleven-field envelope through `LocalMCPServer.structuredContent(for:)`, including
the machine-readable `reason`. Bridge `stdout` unwraps assistant-visible bare
sole-text results and directly carries upstream `structuredContent` when
present. User-only blocks retain their annotations but never enter unannotated
stdout. A structurally
equivalent JSON fallback is omitted; other distinct, annotated, or multimodal
blocks remain real outer MCP content. Upstream metadata is preserved under
collision-safe result-meta namespaces. When that complete context would exceed
the result cap, assistant-visible content, user-only content, and hidden
metadata spill to separate JSON artifacts. The two content artifacts use
audience-annotated links; all descriptors are namespaced under outer `_meta`,
where the hidden metadata URL remains invisible to the model. The configured tool output limit is a hard cap
and reports any atomic context omission through `output_limit` plus stderr
guidance.

Decision log for this feature lives here.

## Server surface (Services/LocalMCPServer.swift)

- **Resource**: `ui://macremote/output-v8.html`, MIME
  `text/html;profile=mcp-app`, served via standard `resources/list` /
  `resources/read`. The versioned URI is a host cache key: change the version
  when the widget artifact changes materially. `resources/read` still accepts
  `ui://macremote/output-v7.html`, `ui://macremote/output-v6.html`, `ui://macremote/output-v5.html`, `ui://macremote/output-v4.html`, `ui://macremote/output-v3.html`,
  `ui://macremote/output-v2.html`, and the
  legacy `ui://macremote/output` URI for existing hosts, but Apps-negotiated
  requests advertise v8 alongside
  the always-present compact catalog resource `macremote://catalog/v1`. Every read result carries
  `_meta.ui` sandbox hints: `prefersBorder`, CSP allowlists
  (`connectDomains` empty — no fetch/XHR; `resourceDomains` allows exactly
  `https://static.pocketcasts.com` for podcast artwork), and a
  `clipboardWrite` permission request. The `resources/list` descriptor
  declares the same `_meta.ui` policy, because hosts are told to look in both
  places (the read result wins); `MCPAppsMetadata.uiPolicy` is the single
  source both build from. Additive ChatGPT aliases mirror the
  same policy as `openai/widgetDescription`, `openai/widgetPrefersBorder`,
  and `openai/widgetCSP`; no custom widget domain is requested.
- **The sandbox policy is never capability-gated** (fix 2026-07-30). Tool
  linkage and the resource listing are: a client that did not declare the Apps
  capability is not offered the widget. The policy is not. `_meta` is ignorable
  by contract, so a client that does not understand `ui` drops it and nothing
  breaks; withholding it drops `ui.csp`, and a host with no CSP applies its own
  default (`img-src 'self' data:`) — which blocks every piece of podcast
  artwork. That is exactly what happened to claude.ai on the web, which
  negotiates as a legacy client whose cached capability is lost on every
  relaunch: it rendered the widget with the artwork column silently empty.
- **Tool linkage**: tool descriptors are linkage-eligible unless catalog presentation explicitly sets `automatic: false`, and an eligible tool links only while the owner's result-card choice allows it (D77, above). When standard
  Apps linkage is allowed, its `tools/list` entry carries
  `"_meta": {"ui": {"resourceUri": "ui://macremote/output-v8.html",
  "visibility": ["model", "app"]}}` (SEP-1865 nested form). The deprecated
  flat `ui/resourceUri` and ChatGPT's `openai/outputTemplate` are additive
  aliases pointing at the same resource; `openai/widgetAccessible: true`
  mirrors the standard `"app"` visibility. Every tool also carries mirrored
  OAuth `securitySchemes`. Modern capability gating can still withhold the whole
  optional UI surface; explicit `automatic: false` also withholds linkage without changing the tool contract or approval policy.
- **Capability eras**: modern MCP 2026-07-28 requests carry client capabilities
  on every request. MacRemote emits standard Apps linkage, result hints,
  resource-list entries, and nested resource policy only when that request
  includes
  `params._meta["io.modelcontextprotocol/clientCapabilities"].extensions`
  with `["io.modelcontextprotocol/ui"].mimeTypes` containing the exact Apps
  MIME type. Empty modern capabilities mean no optional UI.
  **Media types are compared after normalization, not byte-for-byte**
  (`MCPAppsMetadata.normalizedMediaType` / `isHTMLAppMediaType`): RFC 9110
  allows optional whitespace around parameters, a quoted parameter value, and
  additional unrelated parameters, so `text/html; profile="mcp-app"` and
  `text/html;profile=mcp-app;charset=utf-8` are the same capability as
  `text/html;profile=mcp-app`. Extra parameters are forgiven; a bare
  `text/html`, a different `profile`, or another type/subtype still fails.
  What this fixes is the **legacy negotiation path**: a legacy client that
  spelled the media type legally but differently was recorded as not supporting
  Apps, so it kept receiving the deprecated URI aliases while `resources/read`
  withheld the standard `_meta.ui` sandbox block — pointed at a resource it
  could not instantiate. That is a genuine correctness bug on that path, and
  that is all this change fixes.
  It does **not** explain the 2026-07-30 "Failed to load the MCP app" error in
  claude.ai. A modern client whose spelling we fail to recognize is never
  offered the widget at all — no tool linkage, no resource entry — so there is
  nothing for it to fail to load. The `resources/read` path was audited for that
  incident and came back clean: no reachable 5xx or JSON-RPC error past
  authentication. That failure remains unexplained and is consistent with a
  transient transport or tunnel failure.
  Legacy clients negotiate once in `initialize`; MacRemote caches that exact
  Apps capability for the authenticated client — in memory, so a relaunch
  forgets it. A legacy client that never negotiated Apps still receives the
  flat URI, `openai/outputTemplate`, and `openai/widgetAccessible` tool aliases
  plus the OpenAI resource aliases; since 2026-07-30 it also receives the
  nested standard `_meta.ui` sandbox policy, which is not capability-gated (see
  above). Direct reads of both current and legacy URIs remain available and
  always include the complete HTML text fallback.
- **Fallback is sacred**: `content[0].text` serializes the same outer MacRemote
  envelope carried by `structuredContent`. Claude Code, Raycast, and every
  non-rendering client receive meaningful output without needing the widget.
  Bridge payload normalization happens inside `stdout`; it never removes this
  cross-host fallback.
- **Result hints**: every linked tool result, including early execution errors,
  carries
  `CallToolResult._meta["net.viticci.macremote/ui"]` with `{version,
  toolTitle, toolName, capability, category, actions?}`. The stable semantic
  tool ID is already the public MCP name and widget action target; there is no
  internal/public translation layer. The result also mirrors the standard
  resource link and visibility, its deprecated flat alias,
  `openai/outputTemplate`, and `openai/widgetAccessible` for host paths that
  resolve the widget from the result. Standard MCP Apps fields are
  authoritative; every `openai/*` field
  is an additive ChatGPT compatibility alias, never a replacement. A result
  from a tool whose card the owner turned off carries none of these fields.
- **Payload cap**: the inline envelope keeps at most 48,000 UTF-8 bytes of
  `stdout` and 16,000 characters of `stderr`; the complete bounded stdout is
  linked as an artifact when needed. The full serialized result is capped at
  120,000 bytes, keeping it below the ~150k cliff where Claude's code-execution
  sandbox diverts results to a file and the widget never hydrates.

## UI actions — interactivity as data, never code

`ToolUIAction` (Models/ToolDefinition.swift) declares widget affordances on a
tool. It is **pure data** (catalog presets, built-in catalogs, or
user-defined tools.json) — no tool-specific code paths, per AGENTS.md's
"no special product modes" rule:

```swift
ToolUIAction(
    id: "complete", title: "Mark Done", kind: .checkOff,
    toolID: "remctl_set_completion",
    arguments: .object(["reminder_id": .string("{id}"), "completed": .bool(true)]),
    requiredRowFields: ["id"],
    completedWhenField: "completed"
)
```

An object property that is exactly one row placeholder keeps the row value's
type, so a numeric `id` reaches a typed upstream schema as a number; items in
an argv-style array always stay strings. Bridge clients also coerce string
arguments to the scalar type the upstream schema declares, which covers hosts
that cached an older widget.

- `kind`: `.checkOff` (leading Reminders-style circle on table rows) or
  `.rowButton` (trailing button).
- Targeting: `toolID` for stable semantic catalog entries (including preset
  tools), or `targetExecutableBasename` to address "the shared flexible adapter
  for this executable" when an action intentionally targets a user-created
  adapter. Unresolvable actions are dropped server-side; every resolved action
  calls the same semantic name the client discovered.
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
  The widget calls the target tool by public name through the host, which sends
  the request over the same authenticated MCP connection. MacRemote resolves
  it through the ordinary execution path; `ToolCallApprovalCoordinator` gates
  every non-read-only call and fails closed when approval is unavailable.
  "If allowed" is enforced by the server, never by the UI. (`remctl_delete_reminder`
  is destructive → Always Allow or the Approval window decides, exactly as if
  the model had called it.)

Shipped action packs:
- **RemCTL** (bridged, 2026-09-16) read results: Mark Done targets
  `remctl_set_completion`; Reschedule and Edit Title target
  `remctl_update_reminder`; Delete targets the every-call
  `remctl_delete_reminder`. The actions come from
  `FirstPartyMCPProviderCatalog`, not from a Swift catalog.
- **HabitCTL** (2026-07-30) journal and habit results: one leading Check Off
  circle targeting `habitctl_record_result` with `{habit: "{id}", result:
  "completed"}`, filled when the row's `status` equals `completed`. Journal
  rows carry that status; definition rows (`search`/`show`) don't, so the
  circle reads empty there and checking off still records today — the useful
  behavior on a search hit.
- **PocketCTL** (2026-07-30) episode results, in render order: Play Next and
  Play Last target `pocketctl_change_up_next` (`placement: next|last`), Star
  and Archive target `pocketctl_update_state` (`state: starred|archived`),
  all keyed on `{uuid}`. None is styled destructive — archive is reversible.
  `pocketctl_search_online` deliberately carries no actions: its rows mix
  podcast records (which also carry a `uuid`) with episodes from the whole
  catalogue, so a queue or state change fired from there is a guaranteed
  error wearing a friendly button.
- **NotesCTL** (bridged, 2026-09-16) search and recently-modified rows:
  **View Note** targets the read-only `notesctl_show` tool with `{note_id:
  "{identifier}"}`. Mutation buttons stay absent because NotesCTL's guarded
  writes require separate preview and revision-bound apply calls.
- **OverCTL** (2026-08-10) Up Next and episode results: Play Next and Play Last
  target `overctl_change_queue`; Star targets
  `overctl_update_episode_state`; Archive targets the dedicated
  `overctl_archive_episode` and uses the widget's destructive two-step
  confirmation. Up Next rows substitute `{episodeID}`; episode rows substitute
  `{id}`. Search results deliberately carry no actions.

First-party widget actions target dedicated semantic tools and typed arguments,
never a provider’s Flexible Command. This keeps widget calls inside the same
validated recipe, preflight, and approval contract advertised to agents.

A tool added before a preset gained actions picks them up through **Update
from Catalog**. Nothing is rewritten at launch.

**Write-back requires a shared write tool.** An action resolves through
`resolveActionTarget` against the *exposed* tool set. Reminder check-off /
reschedule / edit / delete target `remctl_set_completion`,
`remctl_update_reminder`, and `remctl_delete_reminder`. Each required dedicated tool must be shared for its matching
affordance to appear. If only the read-only reminder tools are shared, the
widget renders a plain table with no action buttons — truthful (you can't write
without a shared write tool), not a bug. The affordances also stay behind
normal capability gating and host approval at execution; delete asks every
time.

## The widget (Widget/MacRemoteWidget.html)

Design: **Instrument Panel** (winner of a three-direction judged
competition). One card; the whole status story is a single 2px accent line
(green/red/amber); `light-dark()` theming honoring
both `prefers-color-scheme` and a host-forced `hostContext.theme` (via
`data-mrw-theme`).

**Theme and legibility (v8, 2026-11-16).** `color-scheme` lives on the
document root, not only on the card. A browser paints a frame's backdrop
opaque, in the frame root's own scheme, whenever that scheme differs from the
embedding page's; v7 set no root scheme, so in Claude's dark theme the frame
got a white backdrop while the host's dark-theme text variables colored the
title and "Completed" at 1.1:1. Now:

1. The root scheme follows `hostContext.theme`. A host that sends style
   variables but no theme gets the theme its `--color-text-primary` implies
   (relative luminance above 0.179 reads as light text, so a dark theme).
2. Host color variables are used only when they fit that theme: primary,
   secondary, and tertiary text light on dark (dark on light), the primary
   and secondary backgrounds the reverse, and each of those text colors at
   least 4.5:1 on each background as rendered (a color the host leaves out is
   the widget's own fallback). A checked color the host sends but the canvas
   can't measure (unsupported syntax, mostly transparent) fails. Otherwise
   the root gets `data-mrw-host-colors="ignored"`, which resets the consumed
   `--color-*` properties to `initial` inside the widget so every token falls
   back to its own `light-dark()` value. Fonts and other variables still apply.
3. The root paints `--color-background-primary` when the host supplies a
   fitting one, so host text always sits on the host's own background;
   otherwise it stays transparent.
4. The fallback secondary gray is solid (`#6e6e73` light, `#a1a1a6` dark),
   and so is the tertiary gray (`#6e6e73` light, the same as secondary,
   because no lighter gray reaches 4.5:1 on the panel; `#8e8e93` dark), all
   at least 4.5:1 on the card and panel colors in both schemes.

The document is self-contained and loads no external
scripts or styles and makes no fetch/XHR/WebSocket requests. The only declared
external resource is static podcast artwork from
`https://static.pocketcasts.com`.

Adaptive states from the envelope:

Before state detection, `table.rootPath` may select one nested presentation
value. If the path is absent at runtime, detection falls back to the complete
value. Context hints may read the complete upstream semantic envelope. The
model-facing fallback retains that envelope; the pretty UI and its clipboard
action expose only the safe, visible result.

| stdout looks like | state |
|---|---|
| JSON object with a non-empty string at `document.bodyKey` | safe document: optional title plus whitespace-preserving text body; Markdown and HTML-looking input stay inert text |
| JSON object whose `change.actionKey` value is one of the curated `change.titles` | change confirmation: accent-tinted check + mapped headline; **Preview** when `dryRunKey` is true or the action is in `previewActions`; optional outcome override, record card, numbered queue, and warnings. A submitted write without positive `verifiedKey` read-back becomes amber **Completed with warnings** |
| JSON object where at least one `groups[].key` holds an array of objects | grouped sections in curated order: `style: "card"` renders its first row as the episode card, `style: "documentList"` renders safe titled text documents with status, and `numbered: true` adds a leading position column; everything else is the curated table |
| JSON object where the `groups[].key`s are all present and all empty | still the grouped state, as the friendly empty state: the accent-tinted check plus one line naming the empty sections ("Nothing to show — Now Playing, Up Next, In Progress and New Releases are empty."), leftover safe scalars still as chips |
| bare JSON array of objects | sortable table, curated column order (id/title/name/list/due… first, all-null columns dropped, cap 8), check-off circles and row buttons per declared actions |
| single JSON object whose primary curated field is present (e.g. `pocketctl now`, `remctl info`, `habitctl show`) | card: 56px artwork, title + subtitle, meta line (duration · progress · link), action buttons |
| object with exactly one array-of-objects value (`{"items": [...]}`) | the same table |
| JSON array with no elements, or object whose only values are empty arrays (`[]`, `{"items": []}`, an all-empty report) | friendly empty state |
| other JSON object/array | semantic summary: safe scalar facts in titled groups; execution keys, wire metadata, paths, credentials, URLs, and nested developer data stay hidden |
| stdout that fails `JSON.parse` **and** the envelope says it was truncated | oversized state: "Output too large to display inline" plus the received size — never a raw clipped-JSON fragment |
| anything else | safe text document after control codes, command lines, paths, credentials, and serialized JSON are removed; if nothing safe remains, a neutral Completed state |
| empty + succeeded | friendly empty state |
| failed/timed out | friendly reason-specific error panel; stdout, stderr, paths, and command details remain off the pretty surface |

**Detection order matters twice.** An explicit document runs before change, so
a safe export carrying a generic `status: "ok"` cannot be mistaken for a write
confirmation. Change then runs before groups, because a confirmation that
carries its resulting queue also looks like a grouped payload. Then a **bare array** is
unambiguously a table, but an **object** is not: a single record that happens
to carry one sub-collection (a reminder with its subtasks, a habit with its
goals) used to render as a table of its CHILDREN with the record itself gone.
So the card claims an object before the wrapped-table shape does, and
`{"items": […]}` — which has no primary field of its own — still lands on the
table. Uncovered sub-collections remain in the model-facing fallback but never
become raw JSON in the pretty UI. Card and table cells show only safe scalar
values. The empty check runs after all of them, so an empty result is only ever
"nothing came back", never a hidden populated value.

Footer: Copy Result, plus Run Again when the host advertises `serverTools`.
Copy Result copies only the text visible in the pretty UI. Run Again replays the exact
`ui/notifications/tool-input` arguments. The widget does not embed MacRemote
brand chrome; the host owns the surrounding card.

**Per-result presentation hints** in `CallToolResult._meta` are derived from the
tool's catalog-authored `ToolWidgetPresentation` profile. The renderer consumes
only generic columns, groups, documents, context, change, and actions; it never
dispatches on provider or tool IDs:

- `accent` (hex) recolors the accent line, success chip, check circle, and
  action buttons via `color-mix` tints. RemCTL reminders read purple
  (`#8b5cf6`); PocketCTL podcasts read Pocket Casts red (`#f43e37`);
  HabitCTL habits read Habitify blue (`#2a9df4`); NotesCTL reads yellow
  (`light-dark(#7a5900, #ffd60a)`); OverCTL reads orange
  (`light-dark(#9a4300, #ff9f0a)`). The paired values keep readable contrast in
  both host themes, and every state still carries text or a symbol.
- `table.rootPath` selects a nested value for presentation without changing the
  full model-facing fallback or context source. Copy Result remains limited to
  visible safe text. OverCTL uses `data` for
  its stable `{schemaVersion, ok, command, data, meta}` envelope.
- `table.document` names `bodyKey`, optional `titleKey`, first-heading title
  extraction, and a fallback title. Documents use text nodes only: the widget
  never evaluates HTML, creates links from Markdown, or inserts result text with
  `innerHTML`.
- `table.context` is an ordered list of `{path, title}` chips resolved against
  the complete value, including paths outside `rootPath` such as OverCTL source,
  read-back, conclusive verification, and receipt state.
- `table.columns` supplies a curated, ordered column set. Each entry is
  `{key, title, primary?}` or a derived column with `derive:`
  - `"datetime"` (`sourceKey`, `allDayKey` *or* `allDay: true`) — ISO date
    (+ all-day flag) into a friendly **When** ("Jul 9, 2:00 PM", all-day →
    "Jul 9", missing → "—"). All-day-ness has two spellings because sources
    do: `allDayKey` names a per-row boolean (a reminder is all-day or it
    isn't), while the literal `allDay: true` marks a column whose value is
    always a calendar DAY even when it serializes with a time — habitctl's
    `startDate`, which is why the habits **Started** column carries it and
    reads "Jun 29" rather than a meaningless "Jun 29, 12:00 AM". A bare
    `YYYY-MM-DD` is additionally parsed at *local* midnight and treated as
    all-day regardless of hints: `new Date("2026-06-29")` is UTC midnight,
    i.e. the previous day everywhere west of Greenwich, and a start date
    must not shift by a day depending on where the widget is rendered.
  - `"duration"` (`sourceKey`, seconds) — compact human duration ("1h 43m").
  - `"quantity"` (`sourceKey` count, `unitKey`) — a pluralized count
    ("4 days", "1 rep") — habit streaks.
  - `"recurrence"` (`sourceKey`) — a structured recurrence rule into friendly,
    unambiguous copy. Intervals read "every 2 weeks"; monthly ordinal weekdays
    prefer `daysOfWeekDetailed[].weekNumber` and fall back to parallel
    `daysOfWeek` + `weekNumbers`; an occurrence count is appended as
    ", 5 times" (never `x5`, which is now an interval token), and an end date
    as "until 2026-07-30". Reminders use this for the **Repeats** column.
  - `"booleanLabel"` (`sourceKey`, `trueLabel`, optional `falseLabel`) — shows
    a compact semantic label only for the configured boolean value. Reminders
    use `trueLabel: "Flagged"` so a real flag is visible without printing raw
    `true`/`false`; unflagged rows leave the cell empty.
  - `"progress"` (`sourceKey`, `totalKey`, optional `format` + `unitKey`) —
    accent-colored conic-gradient pie. `format: "seconds"` labels with a
    percent and a played-time tooltip ("1h 08m of 1h 43m played" —
    podcasts); the default treats values as counts and labels with the
    fraction ("3/8", tooltip "3 of 8 glasses" — habit goals).
  - `"artwork"` (`sourceKey`, `urlTemplate` with `{value}`, `altKey`) — 28px
    rounded thumbnail; the value is URL-encoded into the template (podcast
    artwork off the Pocket Casts CDN, hence the CSP resource domain). An image
    the host refuses or the network drops is replaced by the same tile carrying
    the show's initial, keeping the requested URL on `data-mrw-art-src`. It
    used to hide itself, which is how a host that blocked every image looked
    like a widget that simply doesn't show artwork.
  - `"link"` (`sourceKey`) — compact "Open ↗" pill instead of the raw URL;
    only http(s) values render. When the host advertises `openLinks`, the widget
    requests `ui/open-link`; otherwise it falls back to a safe
    `target="_blank" rel="noopener noreferrer"` browser anchor.
  Every `sourceKey` may be a string or an array of fallback keys — commands
  of the same CLI can spell the same fact differently (pocketctl up-next
  calls the podcast uuid `podcast`, in-progress `podcastUuid`) — and every
  field key may be a dot-path into nested objects (habitctl's
  `currentStreak.length`, `progress.target`). A plain column may carry
  `subtitleKey`: its value renders as a dim second line in the cell
  (episode title over podcast name) and in the card, sorting stays on the
  main value.
  A curated set keeps the trailing action buttons on-screen instead of
  scrolled off past raw columns. Curated specs whose source fields never
  appear in the rows are dropped, and if fewer than two survive the widget
  falls back to auto columns — so the podcasts curation (episode-shaped
  rows) doesn't distort subscriptions/playlists output.
  **That drop rule is also how one curation covers two shapes.** habitctl
  returns journal rows (`today`) *and* habit definitions (`search`, `show`)
  from the same category: a journal row has `currentStreak`/`progress` but no
  goals array or start date, a definition has the reverse. The habits curation
  lists all four columns — Streak, Goal, Target (`goals.0.value`, a dot-path
  that indexes the array), Started (`startDate`) — plus `subtitleKey:
  "description"` on the name, and each shape keeps the two that apply. Before
  this, a definition fell to auto columns and printed raw `occurrence` JSON.
- `table.hiddenColumns` drops raw keys when columns aren't fully curated
  (reminders hide `id`, `completed`, and the raw fields already represented by
  the recurrence/flag derives; podcasts hide `uuid`, `published`, `fileType`,
  `size` and other transport fields; habits hide the journal-row noise plus the
  definition's nested `occurrence`, `goals`, `timeOfDays`, `reminders`, and the
  fields a curated column already shows).
- `table.groups` turns **one payload carrying several row arrays** into ordered
  sections. Each entry is `{key, title, style?, numbered?}`. A CLI report like
  `pocketctl triage --json` answers with four arrays at once (`now`, `up_next`,
  `in_progress`, `new_releases`); the single-array table detection can't see
  that shape, so before this hint the whole result fell to the key/value tree.
  `pocketctl search-online --type combined` is the second shape: two groups
  (`podcasts`, `episodes`) of genuinely different rows in one payload. A
  payload only ever carries one family of keys, so both families live in the
  one ordered list. The two groups render differently, and that is worth being
  precise about: an **episode** row fills the curated columns (artwork,
  Episode + show subtitle, Duration, Link — search results carry no playback
  position, so Played drops out). A **podcast** row has none of the curated
  episode fields — not even `podcastUuid`, since a show's own uuid is spelled
  `uuid` — so fewer than two curated columns survive and the group falls back
  to auto columns: **Title** and **Author**. That means no artwork on podcast
  rows today. `type`, `explicit`, `hasVideoEpisodes`, `slug` and
  `publishedDate` are in `hiddenColumns` precisely because that fallback
  otherwise printed them as an API dump ("Explicit: false", "Type: podcast").
  NotesCTL stored transcripts use `style: "documentList"` plus `bodyKey`,
  optional `titleKey`, `statusKey`/`statusTitles`, `pendingKey`/`pendingTitle`,
  and a fallback row title. Available transcripts and pending/error explanations
  render as safe text blocks; no returned string becomes HTML.
  Rules: sections render in hint order; `style: "card"` renders the group's
  first row as the episode card; `style: "documentList"` renders safe documents;
  `numbered: true` adds a leading tabular
  position column (1…N); an empty group is skipped as long as another group has
  rows; keys the hint doesn't name still render — arrays of objects as a generic
  title-cased section, **scalars** as a dim meta chip after the last section
  (nested objects and lists of plain values are suppressed: "Episode · 8 keys"
  is the developer-facing shape this state replaces, and the model-facing text
  fallback still carries them) — so this state never degrades into a tree.
  When every named group is present and empty, the result stays a grouped
  result and renders the friendly empty state instead: the accent-tinted check
  plus one line built from the curated titles ("Nothing to show — Now Playing,
  Up Next, In Progress and New Releases are empty."), with any leftover scalar
  chips below it. A quiet triage is the most ordinary answer there is; dropping
  it to a raw key/value dump was the worst place to do it. Nothing is deduplicated:
  the same episode legitimately appears in `now` and `up_next`. **Sorting is
  disabled inside a section** (no column buttons, no mobile Sort control): a
  queue's order is data, and a sort control that silently reorders it lies.
- `table.change` renders the confirmation a write command answers with instead
  of rows: `{actionKey, titleKey?, episodeKey?, queueKey?, queueTitle?,
  dryRunKey?, previewActions?, countKey?, countNoun?, countNounPlural?,
  warningsKey?, outcomeKey?, outcomeTitles?, submittedKey?, verifiedKey?,
  unverifiedWarning?, titles}`.
  `titles` maps
  the command's own action name to the headline copy and **doubles as the
  recognition set** — a value outside it is not a change result and falls
  through to the other states. It is checked after an explicit document but
  before groups, because a confirmation that carries its resulting queue also
  looks like a grouped payload. A `dryRunKey` value of `true` — or the string `"true"`, since a
  preview misread as applied is the dangerous direction of that mistake — or an
  action named by `previewActions` adds the **Preview** chip (nothing applied
  yet). `outcomeKey` may replace a recognized action headline through
  `outcomeTitles`, such as an already-matched end state.
  The queue reuses the curated episode columns, numbered 1…N, and the acted-on
  row gets a `color-mix` accent tint when the episode's `uuid`/`id` matches a
  row. A minimal older payload (action + count only, no `episode`, no
  `queueKey`) still renders as the headline plus a plain "10 episodes in Up
  Next" line from `countKey` — a recognized action never falls to the tree.
  - `titleKey` (dot-path to a top-level scalar) names the thing that changed
    when the payload has no record to card — which is the normal case: most
    CLIs answer a write with a status, an id, and a name. It renders as a dim
    line under the headline, and is **suppressed when the record card is
    already showing that name**, so a payload carrying both never says it
    twice.
  - `countNoun` / `countNounPlural` supply the noun for the count line
    ("10 episodes in Up Next"). The widget's own default is the domain-free
    `item`/`items`: counting *episodes* is curation, and the widget knows
    nothing about episodes. The Python contract test bans the rendered
    `' episode'`/`' episodes'` copy from the HTML for exactly that reason.
  - `warningsKey` names a string or string-array payload field. A recognized
    successful change with warnings remains a successful tool call, but the
    card switches to an amber **Completed with warnings** state and renders
    every warning visibly. It must never claim an unqualified success or turn a
    successfully-created item into a failed execution. Reminders use
    `warningsKey: "warnings"` for `add --flag`: AppleScript flag failure leaves
    the reminder created and reports that the flag was not set.
  - `submittedKey` and `verifiedKey` distinguish a write request from positive
    read-back. When submitted is true, the result is not a preview, and verified
    is not true, `unverifiedWarning` is appended and the card becomes amber.
    OverCTL uses this to avoid claiming an unqualified success when Overcast did
    not confirm the final state.

Curated `change` payloads today:

| profile / source | actionKey | recognized actions |
|---|---|---|
| `reminderRows` | `status` | `created`, `updated`, `completed`, `uncompleted`, `deleted`, `unchanged` ("No changes"), `flagged`, `unflagged` |
| `habitRows` | `action` | `complete`, `failed`, `skipped`, `undo`, `log` |
| `episodeRows` / PocketCTL | `action` | four queue commands plus `episode-done`, `episode-unplayed`, `episode-star`, `episode-unstar`, `episode-archive`, `episode-unarchive`, `episode-progress`, `episode-mark-played` |
| `episodeRows` / OverCTL | `action` | `queue-add`, `queue-remove`, `queue-reorder`, `done`, `unplayed`, `star`, `unstar`, `save`, `progress`, `archive`, `restore`; `status: no_change` may override the headline and submitted-but-unverified writes warn |
| `noteRows` | `status` | `planned` (Preview), `created`, `updated`, `deleted`, `ok` |

`error` is deliberately **not** a key in any of them: a failed write must reach
the error panel, not be dressed as a success with a red-free headline.

All of these hints are consumed generically. The widget contains no CLI name,
payload key, or action literal (`up_next`, `play-next`, `dry_run`, `episode`, …
must not appear in the HTML).

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
   `hostCapabilities` and `hostContext` (theme, display mode, platform,
   container dimensions, safe-area insets, and host styles).
2. View → Host notification `ui/notifications/initialized`.
3. Host → View `ui/notifications/tool-input` (arguments), then
   `ui/notifications/tool-result` (a verbatim `CallToolResult`).
4. View → Host `ui/notifications/size-changed` with measured finite positive
   `{width, height}` values. A `ResizeObserver` handles steady-state changes,
   and the widget also reports synchronously after its initial render. Content
   grows naturally; there is no nested fixed-height scroll cap.
5. Actions/Run Again: standard host-proxied `tools/call`, exposed only when
   `hostCapabilities.serverTools` is present.
6. Links: `ui/open-link` when `hostCapabilities.openLinks` is present, otherwise
   the safe browser-anchor fallback above.
7. Also handled: `ui/notifications/tool-cancelled`,
   `ui/notifications/host-context-changed`, `ui/resource-teardown`, `ping`.

## Testing

- `MCPUISupportTests` (server, in-process HTTP + OAuth): capability
  advertisement and both negotiation eras, standard and alias tool `_meta`,
  widget and compact-catalog resource reads, sandbox meta, unknown-uri error,
  action encoding with semantic public names, ordinary authenticated
  `tools/call` re-entry through the Mac-side approval gate, and stdout caps.
  Episode profiles additionally assert the ordered `groups` payload (the triage four
  first, then the two search groups; card group, numbered queue group) and the
  full `change` payload including its `titles` recognition set. Notes assert a
  safe document hint and `documentList` transcript group. Every typed profile
  asserts its own `change` hint: reminders' remctl statuses (including `flagged`/`unflagged`,
  `warningsKey`, and that no `error` key exists), habits' five habitctl write
  actions plus `dryRunKey`, the habits columns in their definition shape,
  Notes preview actions, and OverCTL outcome/read-back fields.
  Reminders also pin the **Repeats** recurrence derive and **Flag** boolean-label
  derive. A separate test pins the cross-repo coupling: the
  PocketCTL-compatible `change.titles` keys must **cover** both of pocketctl's action maps,
  `QUEUE_ACTION_LABELS` and `EPISODE_ACTION_LABELS` (`pocketctl/cli.py`), so a
  rename or addition there fails here instead of silently dropping that command
  to a raw dump. Superset rather than equality: a title for an action pocketctl
  hasn't shipped is inert, a missing one is a broken result.
- `MCPAppsMetadataTests`: MIME capability matching including every legal
  spelling of the Apps media type (spacing, quoting, case, extra parameters like
  `charset`) and the rejections (bare `text/html`, `text/html;charset=utf-8`, a
  different or empty `profile`, another type), nested standard linkage, default and
  overridden visibility, OpenAI accessibility mirroring, CSP/permission policy,
  and versioned resource descriptors — including that the `resources/list`
  descriptor declares exactly the policy the read result does.
  `everyFirstPartyCatalogCommandIsWidgetEligible` also pins the complete 74/74
  process catalog to catalog-side eligibility, including every Flexible Command;
  bridged first-party tools are imported tools and are eligible like any other.
  Whether an eligible tool actually links is the owner's choice:
  `ResultCardPreferenceTests` proves that a fresh install (nothing saved) links
  nothing in `tools/list` or results, that turning cards on links every tool on
  the next request, that a family switched off loses only its own linkage, that
  `content` and `structuredContent` are byte-identical with and without a card,
  and that the widget resource stays readable while cards are off. It also pins
  the family rule (catalog provider by tool-ID prefix, File Transfer,
  executable name).
  `MCPUISupportTests` covers the same fix
  end to end: a client negotiating `text/html; profile="mcp-app"` must still get
  `_meta.ui` back from `resources/read`. Both suites assert the CSP allowlist on
  every negotiation path, capability or none — the 2026-07-30 artwork
  regression was a test that had codified the stripped shape as correct.
- `Widget/test/harness.html`: a host simulator (fixtures include table, dense,
  semantic object/text fallbacks (`visibilityfallback`, `safefallback`),
  attachments (`artifact`, `multimodal`), error, empty,
  truncated, habits, podcasts, nowcard, triage,
  emptygroups, artworkblocked, changeupnext, changeupnextdry, changeupnextlegacy,
  changedefaultnoun, episodestar, episodearchive, episodetitledupe,
  searchgroups, reminderinfo, remindercreated, reminderupdated,
  reminderdeleted, reminderrecurrence, remindercreatedwarning,
  reminderflagged, reminderunflagged, reminderflagerror, emptyreminders,
  emptywrapped, emptyhabits, habitshow, habitcheck, truncatedjson, actionfail,
  overrows, overdry, overunverified, notesdocument, notestranscripts;
  `?theme=dark`, which also hands the widget theme-appropriate host style
  variables — a light `--color-text-primary` under a dark theme made every dark
  render unreadable). Every run also checks that the widget root's computed
  `color-scheme` equals the theme in effect and that the tool title, the
  empty/semantic title and caption, and the error title reach 4.5:1 against
  the backdrop the browser paints (the root background, else the opaque canvas
  of the root's scheme), with dim cells, completed rows, and queue positions
  measured too wherever a fixture renders them (translucent text is
  composited over the backdrop first). `?host=mismatch` sends the other
  theme's colors and expects them set aside; `?host=lowsecondary` (secondary
  text 2.17:1 on a `#444444` background) and `?host=unmeasurable` (a mostly
  transparent secondary color) expect the same; `?host=themeless` sends colors with no theme and
  expects the theme to be inferred. Against the v7 widget the dark run measured
  1.1:1 for the title and "Completed" and 2.56:1 for the caption. `Tests/Python/test_mcp_apps_contract.py` drives it in headless
  Chrome and checks the handshake, capability gates, host context, finite
  positive width-and-height size payloads, cancellation and teardown, arbitrary
  JSON `structuredContent`, safe link behavior, and a recorded `tools/call` with
  exact substituted arguments. The harness also supports manual inspection of
  derived podcast columns, single-episode cards, action failures, and host theme
  forcing. The `triage` and `changeupnext*` fixtures are real captured
  PocketCTL output; the harness asserts section order, the card group, the
  sequential queue positions, the leftover-scalar chip (with an uncovered object
  and an uncovered list of plain values suppressed), the absence of any sort
  control inside a section, the change headline, the Preview chip, the single
  accent-highlighted row, the legacy count line, and that no key/value tree
  survives in either state. It also asserts that every episode keeps a visible
  artwork tile pointed at the Pocket Casts CDN, and the `artworkblocked`
  fixture — the same report with an artwork URL that can never decode — asserts
  the placeholder path a host CSP without `resourceDomains` puts every row
  through: the monogram tile, never a hidden one. The `emptygroups` fixture is
  the same report with nothing in any group: one friendly line naming the empty
  sections, no sections, no tree, checked in both themes. The round-2 fixtures cover the
  rest of the confirmation matrix — remctl create/update/delete, a habit
  checked off, an episode starred and archived, the `titleKey`-versus-record
  coexistence case (`episodetitledupe`, where the name must not appear twice),
  the default-noun fallback with no `countNoun` curated
  (`changedefaultnoun`) — plus the three empty answers (`emptyreminders`,
  `emptywrapped`, `emptyhabits`), the record-with-subtasks card
  (`reminderinfo`), the habit definition card (`habitshow`), and the clipped
  transcript (`truncatedjson`) that must render the oversized state instead of
  a raw JSON fragment. The RemCTL 1.6.1 fixtures additionally pin both
  recurrence JSON shapes, occurrence-count wording, visible flag state,
  flagged/unflagged confirmations, amber successful-with-warnings treatment,
  and `applescript_flag_failed` reaching the ordinary error panel.
  The v5 fixtures additionally prove nested OverCTL rows,
  dry-run and submitted-but-unverified warnings, safe Notes Markdown and
  available/pending transcript documents, inert hostile markup, and the computed
  yellow/orange accents in both host themes. The v6 contracts prove that generic
  objects and text become semantic summaries, rich content becomes safe related
  content or attachments, failures omit subprocess detail, and Copy Result never
  copies hidden wire data.

## Host compatibility

The standard MCP Apps bridge and `_meta.ui` contract remain primary for
claude.ai web / Claude Desktop / Claude iOS, VS Code, Goose, MCPJam, and other
compatible hosts that advertise the exact Apps MIME capability. ChatGPT
receives additive `openai/outputTemplate`, `openai/widgetAccessible`, and
resource-level `openai/widget*` aliases for its widget host; these never replace
or mutate the standard metadata. Modern clients without Apps receive no widget
linkage. Legacy no-cap clients receive aliases only. Every path retains the text
and structured fallback.

For ChatGPT developer-mode validation, open **Settings ▸ Plugins**, create a
developer-mode app, paste the Public URL into **MCP server URL**, choose OAuth
with Dynamic Client Registration, and approve the request in MacRemote. After
changing metadata or the widget URI, use ChatGPT's metadata refresh before
retesting. Verify the web widget first, then test the linked mobile experience;
mobile can retain the app's previous metadata until the web configuration is
refreshed. Use MacRemote's Local connection for on-Mac clients and its
Cloudflare public link for remote hosts.

MacRemote has not been submitted or published as an OpenAI plugin. All ChatGPT
claims here are scoped to developer-mode testing. Debug generic rendering with
MCPJam before blaming a host, and verify OpenAI-specific behavior in ChatGPT.
