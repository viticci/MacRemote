# MacRemote

MacRemote is a native macOS app that exposes user-approved local CLI tools to
remote MCP clients. It is not a remote shell. Every exposed tool is an exact
executable path plus argv behavior, every remote client must complete OAuth with
host approval, and write-capable or broad CLI calls require host approval before
execution unless the user explicitly grants that client a persistent policy.

RemCTL, PocketCTL, Codex, Peekaboo, and other CLIs are all treated the same way:
they are optional tools the user can add from detected presets or define by hand.

## What You Get

- Native SwiftUI app for managing the exposed MCP tool surface.
- Local MCP server bound to `127.0.0.1`.
- Cloudflare Tunnel for a temporary public HTTPS MCP URL.
- OAuth + PKCE with host-side approval before token issuance.
- Per-client tool policies for pre-approving selected tools.
- Direct process execution with no shell interpolation.
- Generic CLI adapters for whole-command delegation.
- Command templates for narrow, schema-driven MCP tools.
- System presets and bulk preset sets for detected CLIs.
- Full Disk Access and macOS privacy checks before protected tools are served.
- `script/macremotectl` for agent-friendly install and configuration.

## Requirements

- macOS 14 or later.
- Swift toolchain available at `/usr/bin/swift`.
- `cloudflared` on `PATH` or in a standard Homebrew location.
- Optional CLIs such as RemCTL, PocketCTL, Codex, Peekaboo, Spogo, Summarize,
  Gog, GitHub CLI, and other commands on `PATH` or in common user/Homebrew bin
  directories.

Check the local machine:

```bash
script/macremotectl doctor --json
```

`doctor` requires Swift and Cloudflare Tunnel. All user CLIs are optional; missing
CLIs simply mean their presets will not appear.

## Quick Start

Build and open the app:

```bash
script/macremotectl install --launch
```

Then in the app:

1. Open **Tools**.
2. Add one tool, several detected CLI adapters, or a full preset set.
3. Use the per-tool toggles to decide what is exposed.
4. Open **Dashboard** and start the local server.
5. Open **Tunnel** and start the Cloudflare tunnel.
6. Copy the public MCP URL.
7. Approve the remote client in **Approvals**.
8. Approve individual write/destructive calls, or open **Clients** and grant that
   client persistent access to selected tools.

The public URL has this shape:

```text
https://<trycloudflare-host>/mcp/<instance-id>
```

Share that URL only with the remote MCP client you are testing.

## Tool Model

MacRemote supports two tool modes:

- **CLI Adapter**: one MCP tool wraps one executable. The client supplies
  `args: string[]` and optional `stdin`. This delegates the executable's broad
  capability surface, so it should normally be `destructive`.
- **Command Template**: one MCP tool wraps a fixed argv template. Placeholders
  such as `{query}` become typed MCP parameters. This is the safer mode for
  exposing one workflow from a larger CLI.

Tools are never shell snippets. MacRemote blocks shell wrappers such as `sh`,
`bash`, `zsh`, `fish`, and `env`, then runs commands through direct `Process`
execution with a bounded environment, timeout, and output cap. Remote clients
must pass exact argv items; there is no `~`, `$HOME`, glob, pipe, redirection, or
command substitution expansion.

Current MCP tool descriptions include `title`, `description`, `inputSchema`,
`outputSchema`, and tool `annotations` such as `readOnlyHint`,
`destructiveHint`, `idempotentHint`, and `openWorldHint`.

## Presets

The app detects installed commands and offers:

- **Tool Sets**: bulk-add groups such as All System Presets, Detected CLIs,
  Reminders, Podcasts, Developer, Text and Data, Media, Utilities, and
  Steipete / OpenClaw.
- **Detected CLIs**: direct adapters for installed commands.
- **Command Presets**: narrower read-only or write templates for common tasks.

From the command line:

```bash
script/macremotectl list-presets --json
script/macremotectl list-preset-sets --json
script/macremotectl add-preset preset.developer.codex --replace
script/macremotectl add-preset-set set.detected_clis --replace
```

To start fresh:

```bash
script/macremotectl clear-tools --yes
```

## Permissions

Each tool can declare macOS permission requirements:

- Full Disk Access
- Reminders, Calendars, Contacts, Photos, Camera, Microphone, Speech Recognition,
  Location
- Screen Recording, Accessibility, Automation, Local Network

MacRemote checks requirements from the same app-launched process context used for
remote tool calls. If protected access is missing, the app blocks server/tunnel
readiness and shows the exact targets to grant in System Settings. After changing
System Settings, use **Relaunch MacRemote** in the app or quit and reopen it
manually, then run **Check Access** again.

Full Disk Access is layered. Some CLIs need access on the host app, some need it
on the executable, and script-based CLIs may need it on their interpreter. Grant
every target MacRemote lists.

## Connected Clients

When a client connects for the first time, MacRemote records it under
**Clients**. From there, the user can pre-approve tools for that client so future
calls do not stop on per-call approval.

Tools can be added while the local server is running. MacRemote updates the
running tool surface immediately; connected clients need to refresh `tools/list`
or reconnect if their UI caches the list.

## Remote MCP Smoke Test

After the tunnel is running, copy the public MCP URL from **Tunnel**.

Direct MCP preflight:

```bash
MACREMOTE_MCP_URL="https://<host>.trycloudflare.com/mcp/<instance-id>" \
./script/anthropic_mcp_smoke.py --mcp-preflight-only
```

Full Anthropic API smoke:

```bash
ANTHROPIC_API_KEY="<key>" \
MACREMOTE_MCP_URL="https://<host>.trycloudflare.com/mcp/<instance-id>" \
./script/anthropic_mcp_smoke.py
```

Expected success markers:

```text
mcp_preflight=passed
mcp_tool_use_count=1
mcp_tool_result_count=1
smoke_test=passed
```

For a broad CLI adapter, use a harmless command and approve the call in
**Approvals**:

```bash
ANTHROPIC_API_KEY="<key>" \
MACREMOTE_MCP_URL="https://<host>.trycloudflare.com/mcp/<instance-id>" \
./script/anthropic_mcp_smoke.py \
  --tool preset-or-custom-tool-id \
  --prompt 'Call the selected MacRemote MCP tool once with harmless read-only arguments.'
```

## Agent CLI

`script/macremotectl` configures MacRemote without clicking through the UI. It
does not approve OAuth clients, approve tool calls, or start public tunnels.

Install the CLI into `~/.local/bin`:

```bash
script/macremotectl install-cli
```

Build and launch:

```bash
macremotectl install --launch
```

Add a generic CLI adapter:

```bash
macremotectl add-tool \
  --name "GitHub CLI" \
  --summary "Run GitHub CLI by passing argv directly." \
  --executable "$(command -v gh)" \
  --mode cli \
  --category developer \
  --capability destructive \
  --replace
```

Add a fixed command template:

```bash
macremotectl add-tool \
  --name "Git Status" \
  --summary "Return short git status for this repository." \
  --executable /usr/bin/git \
  --mode template \
  --arg=-C \
  --arg="$PWD" \
  --arg=status \
  --arg=--short \
  --category developer \
  --capability readOnly \
  --replace
```

Use `--arg=value` for argv entries that start with a dash. Use `--require
fullDiskAccess`, `--require screenRecording`, and similar flags when a custom
tool needs macOS privacy access.

For tests or dry runs, write to a temporary registry:

```bash
MACREMOTE_TOOLS_FILE="$(mktemp -t macremote-tools.XXXXXX.json)" \
script/macremotectl add-preset preset.utilities.current_date
```

## Development

Build:

```bash
swift build
```

Test:

```bash
swift test
```

Build app bundle without launching:

```bash
script/build_and_run.sh --build-only
```

The development script signs the app with `MACREMOTE_CODESIGN_IDENTITY` when
set, otherwise it uses the first local Apple code-signing identity it can find.
If no usable identity is available, it falls back to local ad-hoc signing with a
stable designated requirement for `com.macstories.MacRemote`. That keeps macOS
privacy grants from being tied to a rebuild-specific code hash during local
development. Release builds should be Developer ID signed and notarized before
sharing broadly.

Build and verify launch:

```bash
script/build_and_run.sh --verify
```

Repository layout:

```text
App/       SwiftUI app entrypoint
Models/    Domain models
Services/  Server, tunnel, auth, process, and tool services
Stores/    App state and persistence
Support/   Formatting and small helpers
Views/     SwiftUI views
docs/      Architecture, threat model, and smoke-test notes
script/    Build, CLI, and smoke-test entrypoints
```

More docs:

- [INSTALL.md](INSTALL.md)
- [AGENTS.md](AGENTS.md)
- [CONTRIBUTING.md](CONTRIBUTING.md)
- [SECURITY.md](SECURITY.md)
- [docs/ARCHITECTURE_SECURITY.md](docs/ARCHITECTURE_SECURITY.md)
- [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md)
- [docs/END_TO_END_SMOKE_TEST.md](docs/END_TO_END_SMOKE_TEST.md)
