# Federico Viticci tools

MacRemote gives ten of Federico Viticci's CLIs a place in the Library under
**Federico Viticci**. They reach remote apps through two mechanisms:

| Surface | Providers | How the tools are defined | Count |
|---|---|---|---|
| **MCP server bridge** | RemCTL, NotesCTL | The CLI ships its own MCP server. MacRemote launches it and bridges every tool it publishes. | whatever the installed CLI publishes (in November 2026, RemCTL 2.5: 21 tools, NotesCTL: 35 tools) |
| **Process catalog** | Alexandria, HabitCTL, PocketCTL, OverCTL, MusicCTL, GoodLinksCTL, Apple Frames, Iris | MacRemote defines typed Fixed Commands and one Flexible Command per CLI and runs the executable directly. | 74 tools: 66 Fixed Commands plus 8 Flexible Commands |

Every provider is optional. MacRemote offers a provider only when its
executable is installed. A missing CLI is not an error.

This document is the operator and agent reference for both surfaces. The Swift
sources of truth are `Services/FirstPartyMCPProviderCatalog.swift` for the MCP
surface and the per-provider `*ToolCatalog.swift` and `*ToolPresetCatalog.swift`
files for the process surface.

## Which surface a CLI uses

A CLI uses the MCP server bridge when it ships an MCP server. The CLI then owns
its tool names, input schemas, descriptions, result shapes, and its own
permission helper. MacRemote does not describe those tools a second time.
MacRemote owns transport, sign-in, Mac-side approval, output caps, the shared
widget, and a short policy table per provider (category, approval defaults,
widget hints).

A CLI uses the process catalog when it has no MCP server. MacRemote then
defines each tool in Swift: typed inputs, one exact argv recipe, permission
requirements, preflights, and approval defaults.

Adding an MCP server to a process-catalog CLI moves it to the first row: add
one entry to `FirstPartyMCPProviderCatalog.providers` and delete its Swift
catalog.

## MCP server bridge: RemCTL and NotesCTL

### Detection

MacRemote looks for the executable on the same search path it uses for every
CLI:

| Provider | Executable names | MCP server command |
|---|---|---|
| RemCTL | `remctl`, `rctl`, `reminders` | `remctl mcp` |
| NotesCTL | `notesctl` | `notesctl mcp serve --client macremote` |

When the executable exists, the MCP scanner synthesizes one candidate server
per provider with source `first_party`. That candidate is owned by the
executable, not by any app's config file, so it exists exactly as long as the
CLI is installed.

If Claude Code, Codex, or Claude Desktop already launch the same CLI's server
(for example after `remctl mcp install`), the scanner folds those config rows
into the first-party candidate as extra owners. One CLI never produces two tool
families. Direct launches, interpreter launches such as
`python3.13 /path/to/remctl mcp`, and symlinked aliases all resolve to the same
provider.

### Adding the tools

In the app: **Tools → Add → Add from Library → Presets → Federico Viticci**,
pick the Reminders or Notes category, and press **Add RemCTL** or
**Add NotesCTL**. MacRemote starts the server once, reads `tools/list`, and
imports every published tool. **Update** on the same row re-imports after a CLI
upgrade; ids, permission epochs, and sharing choices are preserved, and a
changed tool contract asks for approval again. **Update from Catalog** on the
Federico Viticci tab refreshes every installed MCP provider as well.

### Tool ids and names

Bridged ids are `<server>_<tool>`. A server that already prefixes its tool
names with its own name keeps them: RemCTL's `today` becomes `remctl_today`;
NotesCTL's `notesctl_search` stays `notesctl_search`. Tool titles, descriptions,
and input schemas are the CLI's own.

### Execution

Each call launches the CLI's server over stdio, forwards the exact JSON
arguments to `tools/call`, and returns the upstream result as the MacRemote
tool output. MacRemote keeps one idle server process warm per launch contract
for 60 seconds, so consecutive calls skip process startup and the MCP
handshake. A warm process is reused only while it is alive and its executable
is unchanged; a CLI upgrade, a probe, or a failed exchange discards it. No
warm process outlives MacRemote.

String arguments are converted to the scalar type the upstream schema declares
when the conversion is exact (`"32277"` becomes the integer `32277` for an
`integer` property). Anything else is forwarded unchanged.

### Permissions

Both CLIs route protected access through their own signed helper (RemCTL's
Capability Host for Reminders, NotesCTL's Capability Host for Notes). MacRemote
therefore declares no Full Disk Access or privacy requirement on bridged tools
and never lists MacRemote, Python, or a launcher as a permission target for
them. Run `remctl doctor` or `notesctl doctor --json` locally to diagnose the
helper.

### Approval policy

Bridged tools take their capability from the upstream annotations:
`readOnlyHint` is Read-only, `destructiveHint` is Destructive, anything else is
Write. Write and Destructive tools ask on the Mac unless the app has an Always
Allow grant. The provider policy adds the every-call default (asking on every
run, with the heavier consent step before a grant) to:

- RemCTL: `remctl_run`, `remctl_delete_reminder`;
- NotesCTL: `notesctl_run`, `notesctl_add_content`, `notesctl_apply_edit`,
  `notesctl_remove_tags`, `notesctl_trash`.

The mark is a default, not a lock. Federico can turn Always Allow on for any of
them, and turning it off restores per-call asking.

### Widget presentation

The shared MacRemote widget renders bridged results. The provider policy sets
the profile:

- RemCTL reads (`today`, `upcoming`, `overdue`, `flagged`, `search`,
  `show_list`, `get_reminder`) use `reminderRows` with Mark Done, Reschedule, Edit Title, and
  Delete row actions that call `remctl_set_completion`, `remctl_update_reminder`,
  and `remctl_delete_reminder` (resolved within the imported family if names
  collide). `lists`, `get_list`, `resolve_location`, `doctor`, and `run` keep
  their complete results but do not automatically open cards. Typed reminder
  writes show compact receipts with partial and batch outcomes. Only read-only
  tools offer Run again. Dates use `displayDate` before `dueDate`.
- NotesCTL tools use `noteRows` with the yellow accent and
  `rootPath: "result"` by default. Search and recent rows offer View Note,
  which calls `notesctl_show`. Diagnostics, accounts, folders, tags, links,
  attachments, tables, folder and pin changes, checklists, tag writes, and
  `notesctl_run` use `semanticResult` instead.

A row action only appears when its target tool is shared. The widget re-enters
authenticated `tools/call`, so approval still applies.

### What agents should know

- Prefer the dedicated tools; use `remctl_run` or `notesctl_run` only when no
  dedicated tool fits. Both take exact argv items in `args`; there is no shell.
- RemCTL ids are numeric. Read tools return them in `id`; pass that value to
  `get_reminder`, `update_reminder`, `set_completion`, `set_flagged`, and
  `delete_reminder`.
- NotesCTL guarded writes are two calls: the preview returns `revisionBefore`,
  and the apply call needs the same content plus that revision and the exact
  `folder_identifier` from `notesctl_folders`.
- The server's own instructions arrive with `initialize` and describe due-date
  formats, list selectors, and preview/apply rules in more detail.

## Process catalog: eight CLIs

The dedicated tools are catalog-backed Fixed Commands. They expose typed names,
booleans, numbers, enums, arrays, and JSON instead of asking an agent to build
CLI syntax. MacRemote validates those values and lowers them to one exact argv
array. It never invokes a shell.

Each CLI also has one Flexible Command. It accepts exact argv items, installs
Not Shared, and asks on every call until the owner marks it Always Allowed.
Agents should use it only when no dedicated tool fits.

### Catalog behavior

- **Update from Catalog** is authoritative for a complete provider scope. It
  refreshes retained tool ids, adds missing current tools, and removes obsolete
  persisted ids owned by that provider. Unrelated custom tools remain.
- A refreshed tool keeps its semantic id, permission epoch, and Shared or Not
  Shared state. An unchanged security contract keeps an existing Always Allow
  grant; a changed contract asks again.
- A complete provider refresh may adopt one scanner-created process tool when
  exactly one current preset and exactly one saved, provenance-bearing scan row
  have the same execution signature and the catalog's semantic id is absent.
  A hand-authored tool, an ambiguous match, or a partial provider refresh is
  never adopted. Adoption replaces the scan row with the catalog definition,
  preserves Shared or Not Shared, creates a new permission epoch, and clears
  Always Allow grants for both the old scan id and the new semantic id.
- There are no compatibility aliases for retired tool ids. MacRemote currently
  has one user, so a complete provider refresh removes obsolete provider-owned
  rows and their sharing state, invalid-state record, and Always Allow grants.
  Updating one catalog row does not retire its siblings.
- Matter and Readwise are not first-party catalog integrations. A scan may
  still find either as an ordinary third-party Flexible Command.

If a saved tool's executable later disappears, cannot be executed, or is no
longer a valid executable, the call returns an MCP tool error with
`reason: "unavailable"`. The message says to install or restore the command
and try again. It never reveals the configured executable path, working
directory, launch exception, or another local filesystem detail.

Install or reconcile all eight process providers from **Add from Library →
Presets → Federico Viticci** with **Add** or **Update from Catalog**.

### Approval and preflight rules

`Read-only` describes the command contract, not the sensitivity of its output.
The tool must still be Shared before an app can see it. Because a Read-only
Fixed Command runs without asking, any absolute path an app passes to it must
be inside a File Transfer folder (**Settings → Security → File Transfer
Folders**), and a value with a `..` component is refused. Tools that ask first
are not limited.

Write and Destructive tools ask on the Mac unless that app has a valid Always
Allow grant for the current security fingerprint. Exactly 13 process tools
ship marked **every-call**:

- all eight Flexible Commands: `alexandria_run`, `habitctl_run`,
  `pocketctl_run`, `overctl_run`, `musicctl_run`, `goodlinksctl_run`,
  `frames_run`, and `iris_run`;
- `alexandria_run_agent`;
- `overctl_archive_episode`;
- `goodlinksctl_delete`;
- `frames_frame_image` and `frames_frame_video`.

The mark is a default, not a lock. Federico can turn Always Allow on for any of
them, per tool in Apps, from a waiting request, or through Allow All Current
Tools, and the runtime then honors the grant like any other. Turning that
toggle back off restores per-call asking, and any edit that changes a tool's
security fingerprint invalidates the grant and asks again.

MacRemote runs a real CLI dry-run before these mutations and proceeds only when
the preflight succeeds:

- HabitCTL result and value writes;
- PocketCTL Up Next, episode-state, and playback-position writes;
- OverCTL Queue, episode-state, playback-position, and archive writes;
- MusicCTL playback control, seek, volume, shuffle, repeat, and output-route
  selection writes;
- GoodLinksCTL delete;
- Iris alarm, timer, URL-open, and message-compose writes (`--dry-run --offline`).

### Alexandria: 9 dedicated + 1 Flexible

Alexandria talks to its own loopback service, which owns Notes access and writer
coordination. Its MacRemote tools therefore require no Full Disk Access grant.

| Tool ID | Inputs | Exact command shape | Capability |
|---|---|---|---|
| `alexandria_health` | none | `--json health` | Read-only |
| `alexandria_list_resources` | `resource: rooms\|agents` | `--json views list` or `--json agents list` | Read-only |
| `alexandria_browse_room` | `view_id`; optional tab, search, tag, sort, limit, offset | `--json views items VIEW_ID [filters] --limit N --offset N` | Read-only |
| `alexandria_search_notes` | `query` | `--json notes search QUERY` | Read-only |
| `alexandria_show_note` | `note_uuid` | `--json notes show UUID` | Read-only |
| `alexandria_capture_clip` | required `stdin`; optional `title` | `--json notes capture - [--title TITLE]` | Write |
| `alexandria_capture_in_room` | `view_id`, required `stdin`; optional `title` | `--json views add VIEW_ID - [--title TITLE]` | Write |
| `alexandria_run_agent` | `agent`; optional `note_uuid` | `--json agents run AGENT [--note-uuid UUID]` | Write, every-call |
| `alexandria_wait_job` | positive `job_id` | `--json jobs wait JOB_ID` | Read-only |
| `alexandria_run` | optional `args[]`, optional `stdin` | exact argv supplied by the caller | Destructive Flexible Command, every-call |

Capture timeouts are indeterminate: search the library or room before retrying.
Agent runs enqueue work and return a `job_id`; retain it and call
`alexandria_wait_job` for terminal state. The Flexible Command blocks root
`deploy`, `check`, and `privileged` commands plus `--host` and `--port` endpoint
redirection, including argparse abbreviations and a root `--` option terminator,
even under an Always Allow grant.

### HabitCTL: 5 dedicated + 1 Flexible

HabitCTL talks to Habitify, so its tools carry an open-world hint.

| Tool ID | Inputs | Exact command shape | Capability |
|---|---|---|---|
| `habitctl_today` | optional `date = today` | `today --date DATE --json` | Read-only |
| `habitctl_search` | `query`, optional `limit = 50` | `search QUERY --limit N --json` | Read-only |
| `habitctl_show` | exact id or unambiguous `habit` | `show HABIT --json` | Read-only |
| `habitctl_record_result` | `habit`, `result`, optional `date` | `check\|fail\|skip\|undo HABIT --date DATE --json` | Write, dry-run first |
| `habitctl_log_value` | `habit`, finite `value`, exact `unit`, optional `date` | `log HABIT VALUE UNIT --date DATE --json` | Write, dry-run first |
| `habitctl_run` | optional `args[]` | exact argv supplied by the caller | Destructive Flexible Command, every-call |

The result enum is `completed`, `failed`, `skipped`, or `in_progress`. The
Flexible Command blocks login, logout, onboarding, and secret-key arguments.

### PocketCTL: 7 dedicated + 1 Flexible

Use full episode UUIDs from a fresh read for every episode-specific operation.

| Tool ID | Inputs | Exact command shape | Capability |
|---|---|---|---|
| `pocketctl_triage` | optional `limit = 8` | `triage --limit N --json` | Read-only |
| `pocketctl_search_online` | `query`, optional `result_type`, `limit` | `search-online QUERY --type TYPE --limit N --json` | Read-only |
| `pocketctl_show` | `episode_uuid`, optional `show_notes_characters` | `show UUID --notes-chars N --json` | Read-only |
| `pocketctl_transcript` | `episode_uuid` | `transcript UUID --json` | Read-only |
| `pocketctl_change_up_next` | `episode_uuid`, `placement` | `play-now\|play-next\|play-last\|remove-up-next UUID --json` | Write, dry-run first |
| `pocketctl_update_state` | `episode_uuid`, `state` | `done\|unplayed\|archive\|unarchive\|star\|unstar UUID --json` | Write, dry-run first |
| `pocketctl_set_playback_position` | `episode_uuid`, `position_seconds` | `progress UUID --position N --json` | Write, dry-run first |
| `pocketctl_run` | optional `args[]` | exact argv supplied by the caller | Destructive Flexible Command, every-call |

`placement` is `now`, `next`, `last`, or `remove`. `state` is `completed`,
`unplayed`, `archived`, `unarchived`, `starred`, or `unstarred`. All seven
dedicated tools carry the red `episodeRows` MCP Apps presentation; the Flexible
Command has no richer curated profile and uses `semanticResult`. The Flexible
Command blocks login, Gemini key management, and secret-file arguments across
the `pocketctl`, `pocketcasts`, and `pctl` entry points.

### OverCTL: 8 dedicated + 1 Flexible

OverCTL reads and changes an Overcast account. It keeps the stable outer
`{schemaVersion, ok, command, data, meta}` JSON envelope, and its MacRemote tools
require no Full Disk Access grant.

| Tool ID | Inputs | Exact command shape | Capability |
|---|---|---|---|
| `overctl_up_next` | optional minutes, podcast, exclude-played, limit, source | `up-next [options] --json` | Read-only |
| `overctl_search` | `query`; optional `scope: library\|directory` | `search\|discover QUERY --json` | Read-only |
| `overctl_episode` | positive `episode_id`; optional source | `episode ID [--source SOURCE] --json` | Read-only |
| `overctl_transcript` | positive `episode_id`; optional provider, time range, segments | `transcript ID [options] --json` | Read-only |
| `overctl_change_queue` | positive `episode_id`, `action: add_next\|add_last\|remove` | `queue-add\|queue-remove ID [--position …] --json` | Write, dry-run first |
| `overctl_update_episode_state` | positive `episode_id`, reversible state | `done\|unplayed\|save\|star\|unstar\|restore ID --json` | Write, dry-run first |
| `overctl_set_progress` | positive `episode_id`, non-negative seconds | `progress ID --position N --json` | Write, dry-run first |
| `overctl_archive_episode` | positive `episode_id` | dry-run `archive ID --json --dry-run`, then `archive ID --yes --json` | Destructive, every-call |
| `overctl_run` | optional `args[]` | exact argv supplied by the caller | Destructive Flexible Command, every-call |

The Flexible Command blocks sign-in and session removal, experimental upload,
credential-bearing audio URLs and exports, `cache export`, `protocol decode`,
`receipts clear`, `--show-secrets`, and `--force`. Dedicated episode and Up Next
results carry an orange typed presentation with Play Next, Play Last, Star, and
destructive Archive row actions. All actions re-enter normal `tools/call`; the
target write tool must be Shared and MacRemote still applies approval and
preflight. `overctl_run` has no richer curated profile and uses
`semanticResult`.

### MusicCTL: 15 dedicated + 1 Flexible

MusicCTL exposes Apple Music catalog and authorized cloud-library reads plus
bounded Music.app playback control. Detect it as `musicctl`, `mctl`, or
`applemusic`. Its tools declare no MacRemote macOS privacy requirements and have
no richer curated MCP Apps presentation or row actions, so they use
`semanticResult`.

| Tool ID | Inputs | Exact command shape | Capability |
|---|---|---|---|
| `musicctl_doctor` | optional `check_credentials: boolean = false`, `profile` | `doctor [--check-credentials] [--profile PROFILE] --json` | Read-only |
| `musicctl_search` | `query`; optional `types = albums,artists,songs,playlists`, `scope: catalog\|library = catalog`, `limit = 25`, `profile`, `storefront = us`, `language` | `search QUERY --types TYPES --scope SCOPE --limit N [--profile PROFILE] --storefront STOREFRONT [--language LANGUAGE] --json` | Read-only |
| `musicctl_list_library` | `resource`; optional `limit = 25`, `profile` | `library list RESOURCE --limit N [--profile PROFILE] --json` | Read-only |
| `musicctl_new_releases` | optional `min_songs = 5`, `since = 30d`, `types = albums,singles`, `include_owned = false`, `profile`, `storefront = us`, `language` | `library new-releases --min-songs N --since WINDOW --types TYPES [--include-owned] [--profile PROFILE] --storefront STOREFRONT [--language LANGUAGE] --json` | Read-only; 3,600-second timeout |
| `musicctl_list_playlists` | optional `limit = 25`, `profile` | `playlist list --limit N [--profile PROFILE] --json` | Read-only |
| `musicctl_playlist_tracks` | `identifier`; optional `limit = 25`, `profile` | `playlist tracks ID --limit N [--profile PROFILE] --json` | Read-only |
| `musicctl_listening_history` | `history: recently_played\|heavy_rotation\|recently_added`; optional `limit = 10`, `profile` | `history recently-played\|heavy-rotation\|recently-added --limit N [--profile PROFILE] --json` | Read-only |
| `musicctl_player_status` | none | `player status --json` | Read-only |
| `musicctl_list_output_routes` | none | `output-route list --json` | Read-only |
| `musicctl_player_control` | `action: play\|pause\|toggle\|stop\|next\|previous` | `player ACTION --apply --json` | Write, dry-run first |
| `musicctl_seek` | `seconds: 0–86400` | `player seek SECONDS --apply --json` | Write, dry-run first |
| `musicctl_set_volume` | `value: integer 0–100` | `player volume VALUE --apply --json` | Write, idempotent, dry-run first |
| `musicctl_set_shuffle` | `enabled: boolean`; optional `mode: songs\|albums\|groupings` | `player shuffle BOOLEAN [--mode MODE] --apply --json` | Write, idempotent, dry-run first |
| `musicctl_set_repeat` | `mode: off\|one\|all` | `player repeat MODE --apply --json` | Write, idempotent, dry-run first |
| `musicctl_select_output_routes` | one or more exact `output_ids[]` | `output-route select ID… --apply --json` | Write, idempotent, dry-run first |
| `musicctl_run` | optional `args[]`, optional `stdin` | exact argv supplied by the caller | Destructive Flexible Command, every-call |

Search limits are 1–25. Library and playlist limits are 1–100. The unified
history recipe accepts 1–10 results. `min_songs` is 1–100,000; `since` accepts
MusicCTL's bounded date/window syntax. `musicctl_doctor` stays offline: it may
check saved credentials and Capability Host readiness, but the catalog does not
offer its live network probe.

All six Music.app writes use the same safety boundary. MacRemote first runs the
resolved argv without `--apply` and with `--json`; only a successful non-applying
preview permits the real command with `--apply --json`. These writes use standard
approval, not every-call. `musicctl_new_releases` scans the complete cloud
library and has a 3,600-second timeout. It runs synchronously like every other
tool, so over the public link it must still finish within the
[time limit](GUIDE.md#reliability).

Use `musicctl_run` only when no dedicated tool fits. It accepts at most 64 exact
argv items plus optional UTF-8 stdin and never invokes a shell. Each argv item
and `stdin` is schema-capped at 65,536 characters, and MacRemote's combined
execution-input hard cap is 96 KiB. It blocks these authentication, credential,
configuration, and raw-request surfaces even under an Always Allow grant:

- root `onboard` and root `request`;
- `auth configure`, `auth setup`, `auth login`, and `auth logout`;
- `config set` and `config unset`;
- `--private-key-file`, `--private-key-stdin`, and `--reference` in any command.

### GoodLinksCTL: 6 dedicated + 1 Flexible

| Tool ID | Inputs | Exact command shape | Capability |
|---|---|---|---|
| `goodlinksctl_search` | optional query, tags, read/starred filters, sort, limit | `--json links list [filters] --all-pages --max-items N` | Read-only |
| `goodlinksctl_get` | `link_id` | `--json links get ID` | Read-only |
| `goodlinksctl_read` | `link_id` | `--json links content ID --format markdown --no-auto-download` | Read-only |
| `goodlinksctl_save` | absolute HTTP(S) `url`; optional metadata and states | `--json links add URL [options]` | Write |
| `goodlinksctl_update` | `link_id` plus at least one change | `--json links update ID [options]` | Write |
| `goodlinksctl_delete` | `link_id` | preflight `--json links delete ID --dry-run`, then confirmed delete | Destructive, every-call |
| `goodlinksctl_run` | optional `args[]` | exact argv supplied by the caller | Destructive Flexible Command, every-call |

Cached reads never trigger a missing-content download. Search tags use OR
semantics. `clear_tags` cannot be combined with additions or removals. The
Flexible Command blocks authentication, setup, token input, and endpoint
overrides.

### Apple Frames: 5 dedicated + 1 Flexible

Every input and output path must be absolute. Rendering asks every time because
deterministic output files may already exist. `frames_info` and
`frames_video_info` are Read-only, so their paths must be inside a File
Transfer folder.

| Tool ID | Inputs | Exact command shape | Capability |
|---|---|---|---|
| `frames_devices` | none | `list` | Read-only |
| `frames_info` | `paths[]` | `--json info PATH…` | Read-only |
| `frames_frame_image` | screenshot `paths[]`, `output_directory`; optional device, color, layout | `--json frame --output DIR [options] PATH…` | Destructive, every-call |
| `frames_video_info` | `paths[]`; optional device, color, rotation | `--json video-info [options] PATH…` | Read-only |
| `frames_frame_video` | video `paths[]`, `output`; optional preset, device, color, rotation, layout | `--json video --output PATH [options] PATH…` | Destructive, every-call |
| `frames_run` | optional `args[]` | exact argv supplied by the caller | Destructive Flexible Command, every-call |

Image layout is `individual` or `merged`. Video layout is `individual`,
`simultaneous`, or `sequential`; export preset is `compact`, `balanced`, or
`best`; rotation is `none`, `clockwise`, `counterclockwise`, or `180`.

Use `frames_run` for asset setup, interactive color defaults, clipboard output,
batching, codec tuning, alpha, backgrounds, and uncommon layouts.

### Iris: 11 dedicated + 1 Flexible

Iris talks to the approved iPhone through its own app and transport. Detect it
as `iris` or the `iphone` alias. MacRemote tools declare no macOS privacy
requirements. Dedicated tools use a 60-second timeout and an 8,192 KB output
cap; `iris_run` uses 600 seconds and 65,536 KB. Phone-reaching tools carry an
open-world hint; `iris_actions` and `iris_action_schema` are local manifest
reads and do not. Iris tools have no richer curated widget presentation and use
`semanticResult`.

| Tool ID | Inputs | Exact command shape | Capability |
|---|---|---|---|
| `iris_battery` | none | `device battery get --json` | Read-only |
| `iris_now_playing` | none | `music now-playing get --json` | Read-only |
| `iris_calendar_day` | `day: today\|tomorrow`; optional `limit: 1–100` | `calendar today\|tomorrow [--limit N] --json` | Read-only |
| `iris_alarms` | none | `alarm list --json` | Read-only |
| `iris_alarm_set` | `time`; optional `label` | `alarm set TIME [--label LABEL] --json` | Write, dry-run first |
| `iris_timer_start` | `duration` | `timer start DURATION --json` | Write, dry-run first |
| `iris_open_url` | `url` | `url open URL --json` | Write, dry-run first |
| `iris_message_compose` | `to`, `body` | `messages compose --to TO --body BODY --json` | Write, dry-run first |
| `iris_actions` | optional `application` | `actions list [--application APP] --json` | Read-only |
| `iris_action_schema` | `action_id` | `actions schema ACTION_ID --json` | Read-only |
| `iris_doctor` | none | `doctor --json` | Read-only |
| `iris_run` | optional `args[]` | exact argv supplied by the caller | Destructive Flexible Command, every-call |

Every dedicated recipe ends with `--json`. The four write tools preflight with
`--dry-run --offline` and use standard approval, not every-call.
`iris_message_compose` opens an unsent Messages draft and never sends.
`iris_open_url` is dispatch-only: a completed result proves the phone opened the
exact `http` or `https` URL, not what the user did next. `day` is `today` or
`tomorrow`. `limit` is 1–100 when present.

Use `iris_run` for screen read/capture, clipboard get, Iris's 13 `--confirm`
actions, and any command without a dedicated tool. Those stay on the Flexible
Command and ask every time. `iris_run` installs Not Shared. It blocks
`devices pair`, `devices authorize`, `devices revoke`, `devices use`,
`transport configure`, and root `migrate`, even under an Always Allow grant.

## Verification contract

Changes to either surface are complete only when all of these pass:

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

The Swift tests assert the exact 74-tool process surface, typed lowering,
constraints, preflights, approval policies, security fingerprints, installed
CLI help and option surfaces, provider
reconciliation, and, for the MCP surface, provider detection, config folding,
id minting, policy application, and warm-session reuse.
