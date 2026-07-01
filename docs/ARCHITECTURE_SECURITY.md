# MacRemote Architecture and Security Design

## Decision

Use Cloudflare Tunnel as the default remote transport.

Claude custom connectors connect from Anthropic cloud infrastructure, so a
private tailnet-only endpoint is not enough. Tailscale Funnel can expose a local
service to the public internet, but Cloudflare Tunnel is the better default for
MacRemote because it is outbound-only, maps a public hostname to
`http://127.0.0.1:<port>`, and can layer Access, WAF, DDoS protection, and
Managed OAuth features in front of the app when needed.

Tailscale remains a future optional mode for personal testing, but not the
default chatbot integration path.

## Product Landscape

This category exists, but most current options are closer to "give the model a
remote shell on my Mac" than a native, host-governed Mac app. The closest match
found during research is `remote-control-mcp`, which is listed as exposing a Mac
over MCP through a secure tunnel with OAuth 2.0 + PKCE, shell execution, file
management, and AppleScript. Other projects expose AppleScript/JXA, zsh, browser
automation, or VNC-style Mac control.

MacRemote should not compete on breadth first. Its initial differentiator is the
opposite: a narrow tool registry, native user control, no arbitrary shell string,
and a remote auth flow that must be approved on the host Mac before any token is
issued.

## Runtime Components

### macOS App

The SwiftUI app owns configuration and user intent:

- tool definitions;
- server lifecycle;
- tunnel lifecycle;
- pending authorization requests;
- audit log;
- settings for Cloudflare and local server preferences.

Client authorization approvals must show the token-bound issuer and exact MCP
resource URL. A friendly client name is not enough because leaked or replayed
URLs are part of the threat model.

The app must let the host revoke all registered OAuth clients, authorization
codes, access tokens, and refresh tokens without requiring an instance path
rotation. Rotation is still available when the public MCP URL itself should be
invalidated.

The tunnel UI must show the tool surface that will be reachable through the
public URL: total tools, custom tools, generic CLI adapters, and write or
destructive tools that require per-call host approval.

Starting a public tunnel must require explicit host confirmation that restates
the tool surface and that OAuth plus per-call approval gates still apply.

The main UI is a native `NavigationSplitView` with these sections:

- Dashboard: server, tunnel, and auth status.
- Tools: detected presets, preset sets, generic CLI adapters, and individual
  command templates.
- Clients: connected OAuth clients and persistent per-client tool policies.
- Approvals: pending and recent OAuth authorization requests.
- Tunnel: Cloudflare setup and current public MCP URL.
- Logs: execution and auth audit trail.
- Settings: provider paths, ports, and advanced security options.

### Local MCP Server

The MCP server binds only to `127.0.0.1` on a random high port or a user-selected
local port. It exposes HTTP MCP endpoints only through the app-controlled
listener. It must never bind to `0.0.0.0`.

Required endpoints:

- `GET /health`
- `GET /.well-known/oauth-protected-resource`
- `GET /.well-known/oauth-protected-resource/mcp/<instance-id>`
- `GET /.well-known/oauth-authorization-server`
- `POST /register`
- `GET /authorize`
- `POST /authorize/decision`
- `POST /token`
- `POST /mcp/<instance-id>`

Authenticated `POST /mcp` requests may be accepted as a compatibility alias for
clients that normalize an already-authorized MCP endpoint back to the
conventional MCP path. Public unauthenticated `/mcp` requests must not disclose
the instance path; initial discovery and the advertised public URL remain
`/mcp/<instance-id>`.

`/health` is diagnostic, not discovery. Loopback health may include instance and
tool-surface details for local verification, but public forwarded health must
only report generic service readiness and must not disclose the instance id,
tool profile, or tool count.

Public forwarded unauthenticated routes are rate limited in memory by route
group before they can create OAuth state or approval spam. Registration and
authorization creation have tighter windows; metadata, health, token exchange,
authorization polling, and unauthorized MCP attempts have separate buckets.
Loopback requests are not rate limited by this guard because they are local
diagnostics and tests, not the public attack surface.

Public origin detection must prefer a non-loopback `Host` header over forwarded
headers, and any non-loopback host is normalized to HTTPS. A spoofed
`X-Forwarded-Host` or `X-Forwarded-Proto` header must not downgrade a public
request into loopback mode or re-enable the legacy local `/mcp` path.

The app can implement the server natively in Swift or manage a helper process,
but the trust boundary is the same: the public tunnel may reach only this local
server, and the local server may run only approved tool definitions.

### Tool Runner

Tools are not shell snippets. A tool definition contains:

- stable tool id;
- display name and description;
- executable absolute path;
- argv template, defaulting to a generic `{args}` adapter;
- typed parameter schema;
- allowed parameter validators;
- timeout;
- stdout/stderr byte caps;
- working directory policy;
- environment allow-list;
- capability class: read-only, write, destructive.

Execution uses `Process`/`NSTask` style direct spawning with an executable and
argv array. No `/bin/sh -c` is used for user-defined tools.

MacRemote supports two CLI exposure modes:

- Generic CLI adapter: one MCP tool wraps one executable. The tool schema
  exposes `args: array<string>` and optional `stdin: string`. This is the
  universal mode for CLIs whose entire capability surface the user intends to
  grant.
- Fixed command template: one MCP tool wraps one exact argv template. Template
  placeholders such as `{query}` become typed MCP parameters. This is the
  safer mode for CLIs where only one subcommand or workflow should be exposed.

MacRemote also supports local MCP bridge backends for MCP servers running on
the Mac. A bridge tool is persisted as ordinary user tool data, but its backend
is `mcpHTTPBridge` or `mcpStdioBridge` instead of `process`. HTTP bridge tools
contain the upstream MCP endpoint URL, upstream server and tool names, optional
call-time header sources, upstream JSON input schema, and upstream annotations.
Stdio bridge tools contain the resolved executable path, exact argv array,
call-time environment value sources, upstream server and tool names, upstream
JSON input schema, and upstream annotations. Bridge tools must not be converted
into shell invocations.

The bridge client behaves like a normal MCP client on the host Mac: it sends
`initialize`, sends `notifications/initialized`, and then forwards remote
`tools/call` arguments to the selected upstream tool. HTTP bridges also store
any returned `Mcp-Session-Id` and accept JSON or SSE responses. Stdio bridges
launch the configured executable directly with its argv array, speak JSON-RPC
over stdin/stdout, capture stderr for diagnostics, and terminate the upstream
process after the probe or call. The remote client never receives direct access
to the upstream local MCP endpoint, executable command surface, or bearer
tokens; it sees only the MacRemote OAuth-protected tool surface and approval
gates.

`script/macremotectl scan-mcp` discovers MCP definitions from common local
agent configs and extension manifests, including Codex, Claude Desktop, Claude
Code, Claude extension bundles, Cursor, LM Studio, Xcode Coding Assistant,
Grok, and OpenCode. The app GUI and repo-local CLI can probe and import
bridgeable HTTP and stdio servers. Literal headers that look like secrets are
not imported. Header and stdio environment sources should point to environment
variables, config TOML key paths, or manifest JSON key paths so secrets are
resolved at call time and not copied into the tool registry. If a local client
splits one hosted service into multiple MCP auth profiles, MacRemote preserves
those as separate bridged servers and relies on each wrapper's exposed tool
list rather than hardcoding service-specific routing.

Tool serialization follows the current MCP tool schema shape:

- `name`: stable programmatic id;
- `title`: human-readable display name;
- `description`: behavior, argv, approval, and permission guidance;
- `inputSchema`: JSON Schema object for model-supplied arguments;
- `outputSchema`: JSON Schema object for structured command results;
- `annotations`: `title`, `readOnlyHint`, `destructiveHint`,
  `idempotentHint`, and `openWorldHint`.

The app ships opt-in preset categories that prefill fixed command templates and
generic CLI adapters for common operations: Reminders, Podcasts, Filesystem,
Utilities, Image Processing, Text, and Developer. Presets are convenience drafts,
not an expanded default tool surface. Filesystem presets must remain read-only
and must not include delete, unlink, or trash commands. Write-capable image
presets must write to explicit output paths and be labeled as write tools.
Registered tools are distinct from the active exposed surface: the user chooses
which saved tools are exposed, regardless of whether the executable is RemCTL,
PocketCTL, Codex, or another command.

This follows the practical direction of projects such as `cli2mcp`, which wraps
arbitrary CLI binaries as MCP tools, while avoiding shell wrappers and keeping
the Mac app as the approval and audit boundary. Future versions can improve
generic adapter ergonomics by parsing `--help` output into richer flag schemas;
the security model must still treat every exposed executable as a delegated
capability rather than a sandbox.

One common optional preset set is the RemCTL CLI, with read helpers for common
queries:

- executable: the detected `remctl` path from `PATH` or common user/Homebrew bin
  directories;
- full adapter tool: `remctl.run`, which passes validated argv arrays directly
  to RemCTL;
- read helper tools: `today`, `upcoming`, `overdue`, `flagged`, `urgent`,
  `lists`, `groups`, `smart-lists`, `templates`, `sections`, `tags`,
  `list-symbols`, `stats`, `search`, `show`, `group-info`, `template-info`,
  `sharees`, `subtasks`, and `info`;
- helper tools force machine-readable output with global `--format json`;
- `remctl.run` is annotated as destructive because the full RemCTL CLI includes
  write and delete operations.

Read-only helper tools can execute after OAuth token validation. Write and
destructive tools require a second host approval for each call unless the host
has granted that connected client persistent access to the tool. The MCP request
waits while the call is shown in the Approvals view with the tool name,
capability, and argument preview. Denied or expired calls return a JSON-RPC
error and never reach the process runner.

Tool definitions can declare permission requirements. Full Disk Access is one
requirement; macOS privacy services such as Reminders, Screen Recording,
Accessibility, Automation, and Local Network are separate requirements. When
launched from a GUI app bundle, macOS privacy controls can attribute protected
access to MacRemote as the host app, to the executable, or to the interpreter
behind a script-based CLI. MacRemote blocks local server startup when the exposed
surface contains missing required access. The app shows the exact targets to
grant, copy/reveal actions, Settings routing, relaunch guidance, and a fresh
check path.

No generic CLI inherits another CLI's permission requirement. RemCTL presets
declare Full Disk Access and Reminders. Peekaboo declares Screen Recording and
Accessibility. AppleScript-style tools declare Automation and Accessibility.
Custom tools can declare the same requirements through the app or
`script/macremotectl --require`.

When tools are added, removed, or toggled while the local server is running, the
server updates its `tools/list` surface. Connected clients can refresh the tool
list; clients that cache aggressively may need to reconnect, but the tunnel does
not need to stop solely because the tool registry changed.

### Tunnel Manager

The app starts the local server first, verifies `/health`, then starts or
configures Cloudflare Tunnel to forward a single public hostname to the local
server port.

The public URL should include an instance-specific high-entropy component:

- current quick-tunnel shape: `https://<trycloudflare-host>/mcp/<instance-id>`;
- future named-domain shape: `https://<random-instance>.<configured-domain>/mcp`.

The random instance id must be generated with at least 128 bits of entropy.
Public forwarded requests must use `/mcp/<instance-id>`; the legacy `/mcp`
compatibility route is accepted only on loopback. The URL is not a secret by
itself; it is a routing hardening layer. OAuth and host-side approval remain
mandatory.

## Authorization Design

MacRemote acts as both MCP resource server and OAuth authorization server.

Flow:

1. Remote client calls `/mcp/<instance-id>` without a token.
2. Server returns `401` with `WWW-Authenticate` pointing to protected resource
   metadata.
3. Client discovers authorization metadata.
4. Client uses dynamic client registration or an allowed redirect URI.
5. Client opens `/authorize` with PKCE and the MCP `resource` parameter.
6. MacRemote creates a pending authorization request and shows it in the Mac app.
7. The browser page waits. It cannot approve itself.
8. User approves or denies on the host Mac.
9. On approval, the server issues a short-lived authorization code.
10. Client exchanges code plus PKCE verifier plus the MCP `resource` parameter
    for access and refresh tokens.
11. Tool calls require a valid bearer token scoped to the instance and tool set.

Security requirements:

- PKCE required for authorization code flow.
- Authorization codes are one-time use and expire within 2 minutes.
- Access tokens expire quickly, target 15 minutes.
- Refresh tokens rotate on every use.
- Stored tokens are hashed or encrypted.
- Tokens are bound to client id, redirect URI, resource URI, instance id, and
  approved tool profile.
- Dynamic OAuth client registration is capped in memory; the host can revoke
  grants when the cap is reached.
- Pending host authorization requests are capped, and resolved authorization
  history is pruned, so a leaked URL cannot create unbounded approval spam or
  memory growth.
- Public forwarded OAuth and metadata routes have bounded request windows and
  return `429 Too Many Requests` with `Retry-After` when exceeded.
- The `WWW-Authenticate` challenge includes path-specific protected-resource
  metadata and an `mcp:tools` scope hint.
- A leaked public URL is insufficient. The host Mac must approve each new client.
- Pending authorization requests expire automatically.
- Denials are logged.

Cloudflare Access can be added as an outer protection layer, but app-level OAuth
and host approval are still required because Access is not the product's only
security boundary.

## Audit and User Control

Every sensitive event is logged locally:

- server started/stopped;
- tunnel started/stopped;
- auth request created/approved/denied/expired;
- token refresh;
- tool call requested;
- tool call accepted/rejected;
- process exit code, duration, and truncated output metadata.

The audit log must not store bearer tokens, authorization codes, refresh tokens,
or full command output by default.

The app provides:

- disable tunnel;
- stop server;
- revoke clients and OAuth grants;
- rotate instance id;

Future controls should add:

- rotate local signing keys;
- export redacted logs.

## First Build Scope

The first useful build should include:

- SwiftUI shell with Dashboard, Tools, Approvals, Tunnel, Logs, Settings;
- local server lifecycle state;
- user-defined tool registry with selectable exposure;
- generic CLI adapter for user-defined executable paths;
- opt-in preset sets and command categories for common CLI templates;
- optional RemCTL, PocketCTL, Codex, and detected CLI presets with tests;
- security design and threat model artifacts;
- build/run script and Codex Run action.

The first public tunnel and Anthropic/OpenAI MCP smoke test happen only after
the selected exposed profile passes process-runner tests and the auth gate is
present.

## Sources

- Claude custom connectors using remote MCP: https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp
- Claude Messages API MCP connector: https://platform.claude.com/docs/en/agents-and-tools/mcp-connector
- Cloudflare Tunnel: https://developers.cloudflare.com/tunnel/
- Cloudflare MCP server portals: https://developers.cloudflare.com/cloudflare-one/access-controls/ai-controls/mcp-portals/
- Tailscale Funnel: https://tailscale.com/docs/features/tailscale-funnel
- Remote Control MCP listing: https://conare.ai/marketplace/mcp/remote-control-mcp
- cli2mcp: https://github.com/RonieNeubauer/cli2mcp
- Peekaboo CLI-first write-up: https://steipete.me/posts/2025/peekaboo-2-freeing-the-cli-from-its-mcp-shackles
- steipete Claude Code MCP wrapper: https://github.com/steipete/claude-code-mcp
- MCPorter: https://github.com/openclaw/mcporter
