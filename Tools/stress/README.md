# MacRemote Stress Harness

A local, tunnel-free way to hammer a real `LocalMCPServer` and confirm the
reliability posture holds under adverse load: concurrency bursts, oversized
output, hangs/timeouts, malformed arguments, modern protocol metadata, MCP
Tasks, questions from a bridged server (elicitation), and protocol edge cases. It exists to reproduce — and keep regression-guarding —
the scenarios from the iOS-client stress reports that once crashed the server.

The harness serves on loopback (`127.0.0.1`) only, behind a static bearer token.
It never opens a public link and never touches your saved `tools.json`: it runs
its own curated set of stress tools.

## Pieces

- **`StressHarnessServer.swift`** (`Tests/MacRemoteTests/`) — a `swift test`
  case (`stressHarnessServer`) that boots a real `LocalMCPServer` with a static
  header token and the curated stress tools, writes an endpoint file, and blocks
  until stopped. It is **inert unless `MR_STRESS_HARNESS=1`**, so a normal
  `swift test` returns immediately.
- **`mcp_client.py`** — a dependency-free MCP-over-HTTP client (stdlib only).
  Loads the endpoint file and supports both the legacy `initialize`/session
  flow and modern `server/discover` flow. It constructs modern `params._meta`
  and mirrored MCP headers, and retains concurrent fan-out,
  `notifications/cancelled`, and raw JSON-RPC.
- **`run_category.py`** — runs one stress category end-to-end and prints a JSON
  summary; exit code `0` means the category passed.

## Test the drivers

The Python request builder, modern/legacy envelope rules, and category
registry have unit tests that do not start the blocking server:

```bash
python3 -m unittest discover -s Tests/Python -p 'test_stress_*.py'
```

## Launch the server

Run from the repo root, in its own terminal. The SDK pin matches `AGENTS.md`:

```bash
MR_STRESS_HARNESS=1 MR_STRESS_TOKEN="$(openssl rand -hex 16)" \
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swift test --filter stressHarnessServer
```

The case blocks (serving requests) until it is stopped or its TTL elapses.

Environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `MR_STRESS_HARNESS` | _unset_ | Must be `1`, or the case is a no-op. |
| `MR_STRESS_TOKEN` | random hex | Static bearer token; written into the endpoint file. |
| `MR_STRESS_ENDPOINT_FILE` | `/tmp/mr_stress_harness/endpoint.json` | Where the server publishes connection details. |
| `MR_STRESS_STOP_FILE` | `/tmp/mr_stress_harness/stop` | Create this file to stop the server. |
| `MR_STRESS_TTL_SECONDS` | `900` | Max lifetime before the case returns on its own. |
| `MR_STRESS_BRIDGED_SKILL` | _unset_ | `1` also shares a skill from a fake bridged server, next to MacRemote's own skill. |
| `MR_STRESS_FOUND_SKILL` | _unset_ | `1` also shares a skill that the skills scanner reads from `~/.claude/skills` in a temporary home, for the stress tools' `echo`, with three reference files (`usage.md`, `UPPER.MD`, `Search Options.md`). |

## Auth and endpoint shape

On startup the server writes the endpoint file (atomically). The Python client
reads it automatically, or you can point at a custom path with
`MR_STRESS_ENDPOINT_FILE`:

```json
{
  "baseURL": "http://127.0.0.1:<port>",
  "port": <port>,
  "token": "<bearer token>",
  "instanceID": "stress",
  "mcpPath": "/mcp/stress",
  "healthPath": "/health",
  "tools": [{ "id": "stress_echo", "mcpName": "stress_echo" }, ...]
}
```

Every MCP request carries `Authorization: Bearer <token>`. The five original
categories use the legacy `2025-11-25` initialize/session flow. The `modern`,
`tasks`, and `elicitation` categories use `2026-07-28`, including
`params._meta`, `Mcp-Method`, and the conditional `Mcp-Name` mirror.
`GET <baseURL>/health` needs no token.

The curated stress tools use one semantic identifier for the test definition,
runtime lookup, endpoint metadata, and public MCP name. `mcpName` remains in the
endpoint file for driver compatibility, but it is identical to `id`:

| Semantic tool ID | What it exercises |
| --- | --- |
| `stress_echo` | Small argv round-trip; concurrency smoke. |
| `stress_cat_stdin` | stdin round-trip through `/bin/cat`. |
| `stress_bigout` | ~500 KB stdout → inline-cap spill to a `resource_link` artifact. |
| `stress_sleep` | Long child with a short (2s) tool timeout → process-tree kill. |
| `stress_task_sleep` | Sleeps 5s, past the harness's 2-second task grace → becomes a task. |
| `stress_typed` | Integer parameter (range `1...100`) for bad-argument validation. |
| `stress_ask` | Bridged stdio server (`fixture`) that asks questions with `elicitation/create`, then reports the answers it got back in `structuredContent.stdout` → `{"answers": [...]}`. Arguments: `kind` `"form"` (default; one `color` text field) or `"url"`; `rounds` (default 1). |

## Run a category

From another terminal:

```bash
python3 Tools/stress/run_category.py <category>
```

Run all eight categories against the same live endpoint:

```bash
for category in concurrency largeoutput hang badargs protocol modern tasks elicitation; do
  python3 Tools/stress/run_category.py "$category" || break
done
```

Categories and their assertions:

- **`concurrency`** — 50 concurrent `stress_echo` calls (16 workers): no
  connection failures, every response well-structured (including a graceful
  `reason:"unavailable"` if the concurrency limiter sheds load), and `/health`
  still `ok` after the burst.
- **`largeoutput`** — `stress_bigout` returns `reason:"ok"` with a
  `resource_link` content item because the complete output was preserved
  externally (never empty output), and a large `stdin` payload round-trips
  through `stress_cat_stdin`.
- **`hang`** — `stress_sleep` times out with `reason:"timeout"` and
  `timedOut:true`, and the server still answers a follow-up `stress_echo` with
  `reason:"ok"`.
- **`badargs`** — `stress_typed` with a non-integer (`"banana"`) and an
  out-of-range value (`-1`) each return `isError:true` and
  `reason:"invalid_argument"` — no server crash.
- **`protocol`** — `notifications/cancelled` is acknowledged with HTTP `202`, an
  unknown request method returns JSON-RPC `-32601`, and an unknown tool returns
  `-32602`.
- **`modern`** — `server/discover` negotiates `2026-07-28`, `tools/list`
  returns modern completion/cache metadata, and a direct `stress_echo` call
  returns `resultType:"complete"` with `reason:"ok"`.
- **`tasks`** — with the Tasks extension declared (DESIGN-SPEC D81; the
  harness server uses a 2-second grace instead of the app's 20):
  `server/discover` advertises `io.modelcontextprotocol/tasks`;
  `stress_task_sleep` answers with `resultType:"task"` and polls to
  `completed` with `reason:"ok"`; `stress_echo` with `run_in_background:true`
  is a task at once and completes with its echo; a second `stress_task_sleep`
  task is cancelled and reads back `cancelled`; an unknown task id is
  `-32602`; `tasks/get` without the extension is `-32021`; `/health` stays
  `ok`.
- **`elicitation`** — questions from a bridged server (DESIGN-SPEC D82), one
  `stress_ask` call per kind of app: with the Tasks extension and
  elicitation declared, the call answers at once with a task in
  `input_required` whose one question reads `[fixture] Pick a color.`, and
  `tasks/update` delivers the answer to the upstream; with elicitation only,
  it answers `resultType:"input_required"` with a `requestState`, sending the
  call again with that state and the answer finishes it, and the same state
  a second time is `-32602`; with neither, the upstream gets `decline` and
  the call finishes; `/health` stays `ok`.

## Testing another client against the harness

A second MCP client can use the harness as a real 2026-07-28 server. Start it
as above, read `baseURL` and `token` from the endpoint file, and send
`POST <baseURL>/mcp/stress` with `Authorization: Bearer <token>`. Which tool
gives which case (declare the capabilities in each request's
`params._meta["io.modelcontextprotocol/clientCapabilities"]`):

| Case | Tool and arguments | Capabilities to declare |
| --- | --- | --- |
| A task that finishes | `stress_echo` with `{"args": ["x"], "run_in_background": true}` (a task at once), or `stress_task_sleep` with `{}` (a task after 2 s, done after 5 s) | the Tasks extension |
| A task that is cancelled | `stress_task_sleep`, then `tasks/cancel` | the Tasks extension |
| A task that needs input | `stress_ask` with `{}` (form) or `{"kind": "url"}` (link): a task at once, `status:"input_required"`; answer with `tasks/update` | the Tasks extension and `elicitation` |
| An `input_required` answer | `stress_ask` with `{}`, `{"kind": "url"}`, or `{"rounds": 2}` (two rounds, two keys); send the call again with `requestState` and `inputResponses` | `elicitation` only |
| A question nobody can answer | `stress_ask` with `{}`: the upstream gets `decline`, the call completes | neither |

A link question goes only to an app that declared `elicitation.url`; one that
declared forms only never sees it (the upstream gets `cancel`). Legacy
sessions never get questions: MacRemote sends no requests of its own to an
app, so a legacy app's questions are declined.

[`conformance-profile.json`](conformance-profile.json) names these tools by
role for a runner that takes a `--profile` file (Cobots'
`Tools/mcp/conformance.py`):

```bash
python3 -I conformance.py --http "<baseURL>/mcp/stress" \
  --header "Authorization: Bearer <token>" \
  --profile Tools/stress/conformance-profile.json
```

Roles it leaves out are skipped: `legacy_form` (see above), `form_kinds`,
`task_fail`, `task_error_result`, `task_expire`, and the file roles have no
harness tool.

## Shut down

Create the stop file (the server consumes it and the test case returns), or let
the TTL elapse:

```bash
touch /tmp/mr_stress_harness/stop
```
