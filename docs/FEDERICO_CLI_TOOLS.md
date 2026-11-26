# Federico Viticci tools

MacRemote gives six of Federico Viticci's CLIs a place under **Federico
Viticci**, in the Library and in the Tools sidebar. They reach remote apps
through two mechanisms:

| Surface | Providers | How the tools are defined | Count |
|---|---|---|---|
| **MCP server bridge** | RemCTL, NotesCTL, MailCTL, PhotoCTL, MusicCTL | The CLI ships its own MCP server. MacRemote launches it and bridges every tool it publishes. | whatever the installed CLI publishes (in November 2026: RemCTL 21 tools, NotesCTL 35, MailCTL 40, PhotoCTL 17, MusicCTL 34) |
| **Process catalog** | Apple Frames | MacRemote defines typed Fixed Commands and one Flexible Command and runs the executable directly. | 6 tools: 5 Fixed Commands plus 1 Flexible Command |

Every provider is optional. MacRemote offers a provider only when its
executable is installed. A missing CLI is not an error.

This document is the operator and agent reference for both surfaces. The Swift
sources of truth are `Services/FirstPartyMCPProviderCatalog.swift` for the MCP
surface and `Services/AppleFramesToolPresetCatalog.swift` for the process
surface.

## Which surface a CLI uses

A CLI uses the MCP server bridge when it ships an MCP server. The CLI then owns
its tool names, input schemas, descriptions, result shapes, and its own
permission helper. MacRemote does not describe those tools a second time.
MacRemote owns transport, sign-in, Mac-side approval, output caps, the shared
widget, and a short policy table per provider (category, approval defaults,
widget hints).

A CLI uses the process catalog when it has no MCP server. MacRemote then
defines each tool in Swift: typed inputs, one exact argv recipe, permission
requirements, preflights, and approval defaults. Apple Frames is the only one
left.

Adding an MCP server to a process-catalog CLI moves it to the first row: add
one entry to `FirstPartyMCPProviderCatalog.providers` and delete its Swift
catalog. If the old catalog's tool ids are what the server's tools get, list
each id with the fingerprint of the command the old catalog gave it in the
entry's `legacyInvocationFingerprints`, and the executable names it ran in
`legacyExecutableNames`, so installed tools carry over (see "Keeping tools
current"). RemCTL and NotesCTL moved this way in September 2026 and got their
lists in November 2026 (DESIGN-SPEC D87); MusicCTL moved in November 2026.

## MCP server bridge: RemCTL, NotesCTL, MailCTL, PhotoCTL, and MusicCTL

### Detection

MacRemote looks for the executable on the same search path it uses for every
CLI:

| Provider | Executable names | MCP server command |
|---|---|---|
| RemCTL | `remctl`, `rctl`, `reminders` | `remctl mcp` |
| NotesCTL | `notesctl` | `notesctl mcp serve --client macremote` |
| MailCTL | `mailctl` | `mailctl mcp serve` |
| PhotoCTL | `photoctl` | `photoctl mcp serve` |
| MusicCTL | `musicctl` | `musicctl mcp serve` |

When the executable exists, the MCP scanner synthesizes one candidate server
per provider with source `first_party`. That candidate is owned by the
provider, not by any app's config file or by the folder the CLI is in, so it
exists exactly as long as the CLI is installed. A CLI that moves (from
`~/bin/remctl` to `~/.local/bin/remctl`, say) keeps its tools, ids, and
sharing; the next import points them at the new path, and because they now run
another file, Always Allow for them stops applying. That import happens on its
own at the next launch, and at the next activation once the old path is gone,
even when the new path leads to the same file. While the old path still works,
the tools keep running it until MacRemote next rescans, at the latest at its
next launch. An **Update** pressed before then already lists the new path.

MailCTL also installs `mail` and `mctl` aliases, and MusicCTL installs an `mctl`
of its own. MacRemote looks for none of them: `/usr/bin/mail` is the system
mail command, and `mctl` does not say which CLI answers (on Federico's Mac,
`~/bin/mctl` runs MailCTL and `~/.local/bin/mctl` runs MusicCTL). MailCTL's
Claude Code plugin is not a config file the scanner reads, so the synthesized
candidate is how MacRemote finds MailCTL.

If Claude Code, Codex, or Claude Desktop already launch the same CLI's server
(for example after `remctl mcp install`), the scanner folds those config rows
into the first-party candidate as extra owners, so the same server never
produces two tool families. Direct launches, interpreter launches such as
`python3.14 /path/to/remctl mcp`, and symlinks to the same file all resolve to
the same provider. A different file is never matched by its name alone. Only a
row that launches the same server folds: it sets no `env`, and its arguments
are the provider's serve arguments, give or take one `--client <label>` pair
(`notesctl mcp serve --client claude-desktop`). A row with environment
variables or other arguments may point the server at other data, so it stays a
server of its own and is never adopted. MacRemote checks the launch it saved
for such a family too: if the row later drops its environment variables or
extra arguments, the family imported from it still keeps its ids and sharing
and is not adopted, and the provider's own tools start Not Shared with ids of
their own.

### Adding the tools

Every installed provider has an **Add** row (or **Update**, once added)
wherever MacRemote groups Federico's tools:

- **Tools**, the **Federico Viticci** source: a provider not added yet is
  listed under **Not Yet Added**. Once added, its tools sit there grouped by
  category with the rest of his tools, and also on the provider's own page
  under **MCP Servers**.
- **Add from Library → Presets → Federico Viticci**, in the provider's
  category: Reminders, Notes, Mail, Media (PhotoCTL), or Music (MusicCTL).
- **Add from Library → Bundles → Federico Viticci CLIs**, which exists whenever
  one of his CLIs is installed.
- **Add from Library → Found on This Mac**, under **Federico Viticci**. A scan
  never lists these CLIs as plain command-line hits.

Adding starts the server once, reads `tools/list`, and imports every published
tool, shared as the owner chose. **Update** starts the server again, from
wherever the CLI is installed right now, and reads a fresh list, never one kept
from earlier; ids, permission epochs, and sharing choices are preserved, a tool
new to the family starts Not Shared, and a changed tool contract asks for
approval again. A refresh gives an existing id back only to the server tool
that held it: when a release drops one tool and adds another whose name maps to
the same id, the newcomer gets an id of its own and starts Not Shared. Only Add
shares a family the owner does not have: if the owner removes a provider's
tools while its Update waits or lists, the Update brings nothing back and says
so in one Activity line. **Update from Catalog** on the Federico Viticci tab
also refreshes every provider already added. An Add or Update pressed while a
scan or another import runs waits its turn, and these buttons stay off until it
is done; the provider's **Import** and **Refresh** on its MCP Servers page take
the same turn and stay off the same way. A failed Add or Update shows why under
that provider's row, wherever the row appears.

The Library re-checks which of these CLIs are installed each time it opens, so
a CLI installed or removed while MacRemote runs shows correctly without a
relaunch.

### Keeping tools current

Once a provider is added, its tools follow the installed CLI without the owner
pressing anything (DESIGN-SPEC D86). At launch, and when MacRemote becomes
active, MacRemote compares each added provider's import stamp with the one it
saved after that provider's last successful import. The stamp is the
provider's policy revision (a number in MacRemote, raised by hand whenever
MacRemote changes how it treats that CLI's tools) and the executable's size
and modification time, symlinks followed. When the stamp differs, or the
provider's tools still name an executable path the CLI has moved from (a
path that is gone also changes the stamp), MacRemote imports the provider
again: it starts the server once to read
`tools/list` and runs no tool. The rules are Update's, with one more: an
import the owner did not start never shares a tool the owner did not already
share, so every tool it adds starts Not Shared. Tools the CLI dropped go away,
and a tool whose contract changed loses Always Allow. A shared tool that asked
first and that the CLI now marks read-only goes Not Shared until the owner
reviews it, as on every refresh. If the owner removed the provider's tools in
the meantime, the import brings nothing back. The Activity log gets at most
one line per provider, only when something changed ("MusicCTL updated: 2 tools
added, 1 removed"; a new title or description counts, and so does a change to
the skills the server offers, in the same line), and nothing when the tools
and skills are the same. A failed import changes nothing and saves nothing, so
the next launch or activation tries again, even when nothing on disk changed:
MacRemote skips a rescan for five seconds after one, but never that retry, and
an activation during a manual scan runs it when the scan ends. Each launch or
activation tries each provider once. A CLI that was never added is never
imported on its own. A wrapper script that does not change when the CLI it
starts updates does not count as a change; press Update then. D86 raised
every provider's policy revision, so it imports each added provider once more
at its first launch, and D87 raised RemCTL's to 2 so a RemCTL added beside its
legacy tools is imported once more and they carry over.

Two one-time moves happen the same way, at the first refresh that can do them,
and on the same stamp: once one has run for an executable, removing its result
does not make it run again until the stamp changes.

- **Carry-over of retired process tools.** Tools installed from MacRemote's
  retired process catalogs become the bridged tools with the same ids, in one
  transaction: RemCTL's 9 (`remctl_today`, `remctl_search`, `remctl_info`,
  `remctl_create`, `remctl_update`, `remctl_set_completion`,
  `remctl_set_flagged`, `remctl_delete`, `remctl_run`), NotesCTL's 19 (from
  `notesctl_doctor` to `notesctl_run`), and MusicCTL's 16 (from
  `musicctl_doctor` to `musicctl_run`). Each keeps its Shared or Not Shared
  choice (with the read-only exception above); its Always Allow stops applying,
  because the tool's definition changed. The provider's other tools start Not
  Shared. If two of the server's tools would take one retired id (`search` and
  `musicctl_search`), the one named exactly that takes it and the other gets an
  id of its own. Until the import succeeds, the old process tools keep working
  with the same guards, including the blocked commands of `musicctl_run`;
  RemCTL and NotesCTL have no such blocks left, so their `run` tools only ask
  on every call. Only a tool still as that catalog installed it carries over:
  an executable the catalog ran (`remctl`, `rctl`, or `reminders`; `notesctl`;
  `musicctl` or `mctl`), in any folder, running the same command for its id. A
  tool the owner pointed at another executable or whose command they edited
  stays as it is, with its id and sharing, and the server's tool of that name
  gets an id of its own and starts Not Shared. A new name, summary, or
  category does not count as an edit.
- **A tool on a suffixed id moves to the plain one** (D87). An earlier build
  imported RemCTL beside its legacy tools, so a bridged tool whose plain id a
  legacy tool held got a suffixed id (`remctl_today_629d6422cb`). The import
  moves that bridged tool to the plain id and replaces the legacy tool. It
  keeps the bridged tool's Shared or Not Shared choice and permission epoch,
  not the legacy tool's; the suffixed id goes, and Always Allow for the tool
  stops applying because its id is part of what a grant covers. No other tool
  changes id.
- **Leftovers** (D87). A legacy tool still as the catalog installed it whose id
  no bridged tool takes (`remctl_info`, `remctl_create`, `remctl_update`,
  `remctl_delete`: the server calls those `get_reminder`, `create_reminder`,
  and so on), or whose server tool is skipped, is removed with a successful
  import if it is Not Shared. A shared one stays the process tool it was. A
  failed import removes nothing. The Activity line counts them ("RemCTL
  updated: 5 tools changed; 4 old tools removed.").
- **Adoption.** A server imported earlier under a plain name from another
  app's config, such as a `photoctl` family from Claude Desktop, becomes the
  provider's family in place: same tool ids and sharing (with the same
  read-only exception), with the provider's policy applied. Only a family
  whose config row folds into the provider and whose saved launch passes the
  same test, as described above, is adopted.

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

Each CLI routes protected access through its own signed helper (RemCTL's
Capability Host for Reminders, NotesCTL's for Notes, MailCTL's for Mail,
PhotoCTL's for Photos, MusicCTL's for Music.app). MacRemote therefore declares
no Full Disk Access or privacy requirement on bridged tools and never lists
MacRemote, Python, or a launcher as a permission target for them. Run
`remctl doctor`, `notesctl doctor --json`, `mailctl doctor`, `photoctl doctor`,
or `musicctl doctor` locally to diagnose the helper.

### Approval policy

Bridged tools take their capability from the upstream annotations:
`readOnlyHint` is Read-only, `destructiveHint` is Destructive, anything else is
Write. Write and Destructive tools ask on the Mac unless the app has an Always
Allow grant. The provider policy adds the every-call default (asking on every
run, with the heavier consent step before a grant) to:

- RemCTL: `remctl_run`, `remctl_delete_reminder`;
- NotesCTL: `notesctl_run`, `notesctl_add_content`, `notesctl_apply_edit`,
  `notesctl_remove_tags`, `notesctl_trash`;
- MailCTL: `mailctl_run`, `mailctl_archive`, `mailctl_move` (up to 100
  messages per call), `mailctl_rule_set_enabled` (a rule acts on every message
  that arrives);
- PhotoCTL: `photoctl_run`;
- MusicCTL: `musicctl_run`, `musicctl_rating_clear` (the one tool MusicCTL
  marks destructive).

Any other tool a first-party server marks destructive asks on every call too,
for all five providers, so a destructive tool a new CLI version adds is
guarded the day it appears. On the versions installed on 2026-11-25 (read from
each CLI's tool catalog, not by launching it) that adds one tool, NotesCTL's
`notesctl_apply_batch`; RemCTL and MusicCTL mark destructive only tools listed
above, and MailCTL and PhotoCTL mark none.

MailCTL's other writes (flag, mark read, the three draft tools, template save,
mailbox create) ask first. No MailCTL tool sends mail: a draft waits in Drafts.
PhotoCTL reads only, except `photoctl_export`, which copies files into a folder
and asks first. PhotoCTL marks `photoctl_run` read-only because its server
refuses library writes; MacRemote still makes it ask every time, since a
Flexible Command passes any arguments through, and serves it as a write. The
MusicCTL playback, volume, route, playlist, library, favorite, and rating
writes ask first.

`musicctl_new_releases` scans the whole cloud library, so it keeps the
3,600-second timeout it had as a process tool. Every other bridged tool has a
60-second timeout. In an app that supports MCP Tasks a long call becomes a task
after 20 seconds (DESIGN-SPEC D81).

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
- MailCTL tools use `semanticResult` with the Mail blue accent
  (`light-dark(#0064d1, #0a84ff)`) and no row actions: the widget has no
  mail-row shape. `doctor`, `capabilities`, `accounts`, `mailboxes`, and `run`
  do not automatically open cards.
- PhotoCTL tools use `semanticResult` with a pink accent
  (`light-dark(#b8326b, #ff6fa8)`) and no row actions: the widget has no
  photo-row shape. `doctor`, `capabilities`, and `run` do not automatically
  open cards.
- MusicCTL tools use `semanticResult` with the Music red accent
  (`light-dark(#c4002b, #ff375f)`) and no row actions. The retired process
  catalog had no row presentation to keep. `doctor`, `capabilities`, and `run`
  do not automatically open cards.

A row action only appears when its target tool is shared. The widget re-enters
authenticated `tools/call`, so approval still applies.

### What agents should know

- Prefer the dedicated tools; use `remctl_run`, `notesctl_run`,
  `mailctl_run`, `photoctl_run`, or `musicctl_run` only when no dedicated tool
  fits. Each takes exact argv items in `args`; there is no shell.
- RemCTL ids are numeric. Read tools return them in `id`; pass that value to
  `get_reminder`, `update_reminder`, `set_completion`, `set_flagged`, and
  `delete_reminder`.
- NotesCTL guarded writes are two calls: the preview returns `revisionBefore`,
  and the apply call needs the same content plus that revision and the exact
  `folder_identifier` from `notesctl_folders`.
- MailCTL message ids are numeric (`id`); `mid:<Message-ID>` is the durable
  form. `mailctl_run` takes reads only; every write has its own tool.
- The server's own instructions arrive with `initialize` and describe due-date
  formats, list selectors, and preview/apply rules in more detail.

## Process catalog: Apple Frames

The dedicated tools are catalog-backed Fixed Commands. They expose typed paths,
names, and enums instead of asking an agent to build CLI syntax. MacRemote
validates those values and lowers them to one exact argv array. It never
invokes a shell.

`frames_run` is the one Flexible Command. It accepts exact argv items, installs
Not Shared, and asks on every call. Agents should use it only when no dedicated
tool fits.

Earlier private builds also shipped process catalogs for six other CLIs.
DESIGN-SPEC D88 removed them and says what happens to tools saved from them:
they stay, as the owner's own process tools, under **Everything Else**.

### Catalog behavior

- **Update from Catalog** is authoritative for the complete Apple Frames scope.
  It refreshes retained tool ids, adds missing current tools, and removes
  obsolete persisted `frames_` ids. Unrelated custom tools remain. Updating one
  catalog row does not retire its siblings.
- A refreshed tool keeps its semantic id, permission epoch, and Shared or Not
  Shared state. An unchanged security contract keeps an existing Always Allow
  grant; a changed contract asks again.
- A complete refresh may adopt one scanner-created process tool when exactly
  one current preset and exactly one saved, provenance-bearing scan row have
  the same execution signature and the catalog's semantic id is absent. A
  hand-authored tool, an ambiguous match, or a partial refresh is never
  adopted. Adoption replaces the scan row with the catalog definition,
  preserves Shared or Not Shared, creates a new permission epoch, and clears
  Always Allow grants for both the old scan id and the new semantic id.
- There are no compatibility aliases for retired tool ids. A complete refresh
  removes obsolete `frames_` rows and their sharing state, invalid-state
  record, and Always Allow grants.
- Matter and Readwise are not first-party catalog integrations. A scan may
  still find either as an ordinary third-party Flexible Command.

If a saved tool's executable later disappears, cannot be executed, or is no
longer a valid executable, the call returns an MCP tool error with
`reason: "unavailable"`. The message says to install or restore the command
and try again. It never reveals the configured executable path, working
directory, launch exception, or another local filesystem detail.

Install or reconcile Apple Frames from **Add from Library → Presets → Federico
Viticci** with **Add** or **Update from Catalog**, or add the **Apple Frames**
bundle.

### Approval rules

`Read-only` describes the command contract, not the sensitivity of its output.
The tool must still be Shared before an app can see it. Because a Read-only
Fixed Command runs without asking, any absolute path an app passes to it must
be inside a File Transfer folder (**Settings → Security → File Transfer
Folders**), and a value with a `..` component is refused. Tools that ask first
are not limited.

Write and Destructive tools ask on the Mac unless that app has a valid Always
Allow grant for the current security fingerprint. Three Apple Frames tools ship
marked **every-call**: `frames_frame_image`, `frames_frame_video`, and
`frames_run`.

The mark is a default, not a lock. Federico can turn Always Allow on for any of
them, per tool in Apps, from a waiting request, or through **Allow All Current
Tools**, and the runtime then honors the grant like any other. Turning that
toggle back off restores per-call asking, and any edit that changes a tool's
security fingerprint invalidates the grant and asks again.

### Apple Frames: 5 dedicated + 1 Flexible

MacRemote detects the `frames` executable. Every input and output path must be
absolute. Rendering asks every time because deterministic output files may
already exist. `frames_info` and `frames_video_info` are Read-only, so their
paths must be inside a File Transfer folder. Every tool declares no open-world
access.

| Tool ID | Inputs | Exact command shape | Capability | Timeout |
|---|---|---|---|---|
| `frames_devices` | none | `list` | Read-only | 60 s |
| `frames_info` | `paths[]` | `--json info PATH…` | Read-only | 60 s |
| `frames_frame_image` | screenshot `paths[]`, `output_directory`; optional device, color, layout | `--json frame --output DIR [options] PATH…` | Destructive, every-call | 180 s |
| `frames_video_info` | `paths[]`; optional device, color, rotation | `--json video-info [options] PATH…` | Read-only | 120 s |
| `frames_frame_video` | video `paths[]`, `output`; optional preset, device, color, rotation, layout | `--json video --output PATH [options] PATH…` | Destructive, every-call | 600 s |
| `frames_run` | optional `args[]` | exact argv supplied by the caller | Destructive Flexible Command, every-call | 600 s |

Image layout is `individual` or `merged`. Video layout is `individual`,
`simultaneous`, or `sequential`; export preset is `compact`, `balanced`, or
`best` (the default); rotation is `none`, `clockwise`, `counterclockwise`, or
`180`.

Use `frames_run` for asset setup, interactive color defaults, clipboard output,
batching, codec tuning, alpha, backgrounds, and uncommon layouts.

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

The Swift tests assert the Apple Frames process surface, typed lowering,
constraints, approval policies, security fingerprints, and provider
reconciliation, and, for the MCP surface, provider detection, config folding,
id minting, policy application, warm-session reuse, the RemCTL, NotesCTL, and
MusicCTL carry-over (moves and leftovers included), adoption of a plain
family, and the quiet re-import after a CLI change.
