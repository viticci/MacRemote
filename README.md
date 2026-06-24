# MacRemote

MacRemote is a native macOS app for exposing a deliberately small, user-approved
set of local tools to remote MCP clients.

The design goal is not "remote shell for your Mac." The server can only run
the active tool surface selected in the app. The default surface is the full
RemCTL CLI plus narrow read helper tools, and the user can disable that profile
to expose only custom CLI adapters such as PocketCTL.

## Product Shape

- Native SwiftUI macOS app.
- Local MCP server process bound to `127.0.0.1`.
- Tool registry controlled from the app UI.
- Selective exposure: registered tools can exist without being part of the
  currently served MCP surface.
- No shell execution for tool calls. Commands run as exact executable paths plus
  validated argv arrays.
- Host-side approval before a remote client receives OAuth tokens.
- Host approval shows the token-bound issuer and MCP resource URL before a
  client can receive tokens.
- OAuth grant revocation for cutting off approved clients without changing the
  public MCP path.
- Per-call host approval before write or destructive tools execute.
- App-wide Full Disk Access prompt flow for tools that declare protected-data
  requirements. The full RemCTL profile requires FDA; generic CLIs such as
  PocketCTL do not inherit that requirement unless marked by the user.
- Cloudflare Tunnel for public reachability. The tunnel forwards only to the
  local MCP server port, not to the Mac as a whole.
- Instance ID rotation that stops public exposure, clears in-memory OAuth grants,
  and changes the public MCP URL path.
- Tunnel view summarizes the exposed tool surface before public access: total
  tools, custom tools, generic adapters, and host-gated write/destructive tools.
- Starting the public tunnel requires explicit confirmation of the exposed tool
  surface.

## CLI Adapter Model

Custom tools use a generic CLI adapter instead of one hand-written MCP wrapper
per command. The user picks an executable, and MacRemote exposes it as one MCP
tool with:

- `args`: optional `array<string>` expanded directly into argv;
- `stdin`: optional string written to standard input;
- timeout and output byte caps;
- explicit read-only/write/destructive risk label;
- direct `Process` execution with no shell.

For tighter surfaces, users can replace the generic `{args}` template with fixed
argv templates such as `["--format", "json", "search", "{query}"]`; placeholders
become typed MCP parameters. This gives both modes: universal CLI wrapping when
the whole executable is the intended capability, and narrow command templates
when only one subcommand should be exposed.

The Add Tool flow includes opt-in default command categories that prefill safe
templates:

- Filesystem: list, stat, head, and find-by-name. No delete/unlink presets.
- Utilities: date, disk usage, uptime, and network interfaces.
- Image Processing: image info plus write-to-output conversion and resize
  templates via `sips`.
- Text: word count, line count, and single-file grep.
- Developer: read-only git status and recent log templates.
- Podcasts: PocketCTL presets are shown when `pocketctl` is installed in a
  standard user or Homebrew location. These include read-only `now`/`triage`
  style templates and a host-gated full CLI adapter.

These presets are not exposed automatically. They only become MCP tools after
the user selects one, reviews the executable/argv template, and saves it.
The full RemCTL profile can be toggled off so a saved custom CLI can be tested
or served without inheriting RemCTL's Full Disk Access requirement.

## MCP Baseline

MacRemote targets the latest stable MCP specification, `2025-11-25`, while
keeping compatibility with `2025-06-18` and `2025-03-26` clients.

- Streamable HTTP endpoint at `/mcp/<instance-id>`. `/mcp` is retained only as
  a loopback compatibility route; public forwarded requests must use the
  instance-specific path.
- OAuth 2.1-style authorization code flow with PKCE and host approval.
- RFC 9728 protected-resource metadata at the root and MCP endpoint well-known
  paths, plus authorization-server discovery.
- OAuth Resource Indicators bind authorization codes, access tokens, and
  refresh tokens to the exact MCP resource URL.
- `MCP-Protocol-Version` validation on MCP requests.
- `Origin` validation to reduce DNS rebinding and browser CSRF risk.
- Tool `inputSchema`, `outputSchema`, structured results, and risk annotations.

The May 2026 MCP release-candidate blog points toward a stateless protocol core
and harder OAuth/OIDC alignment for the `2026-07-28` release. This app keeps the
current server intentionally stateless at the application layer, but does not
claim support for that future protocol version until it is final and client
support catches up.

The June 2026 Enterprise-Managed Authorization extension is not enabled in this
single-user Mac build. The OAuth coordinator is kept separate from tool
execution so an IdP-backed authorization extension can be added later without
expanding the local command surface.

## First Target

The first end-to-end target is:

1. Start MacRemote.
2. Choose the exposed surface: default full RemCTL, or disable RemCTL and save
   a custom CLI preset such as PocketCTL.
3. Grant Full Disk Access with the guided RemCTL helper only when the exposed
   surface contains FDA-required tools.
4. Start the local MCP server after required permission checks pass from the app
   process.
5. Expose it through a Cloudflare Tunnel.
6. Connect a remote model client to the MCP URL.
7. Approve the auth request on the Mac.
8. Run the selected read-only smoke tool and verify the result.

## Repository Layout

```text
MacRemote/
├── App/                  SwiftUI app entrypoint
├── Models/               Domain models
├── Services/             Server, tunnel, process, auth services
├── Stores/               App state and persistence
├── Support/              Utilities and small glue types
├── Views/                SwiftUI views
├── docs/                 Architecture and security notes
└── script/               Build, run, and smoke-test entrypoints
```

## Security Bias

MacRemote should fail closed:

- no tunnel unless the local server is healthy;
- no tool execution without a valid access token;
- no token issuance without host approval;
- no write or destructive tool execution without per-call host approval;
- no arbitrary shell strings;
- no `sh`, `bash`, `zsh`, `fish`, `csh`, `tcsh`, or `env` executable wrappers;
- no inherited broad environment;
- no unbounded runtime or output;
- no default filesystem delete commands;
- no tool that declares Full Disk Access until the check passes from
  MacRemote's own process context.

## Current Local Gates

- `cloudflared` is supported when installed in `/opt/homebrew/bin` or
  `/usr/local/bin`. MacRemote starts accountless quick tunnels and extracts the
  temporary `trycloudflare.com` MCP URL from process output.
- The default RemCTL surface includes `remctl.run`, a full CLI adapter that
  passes validated argv arrays directly to `/Users/viticci/bin/remctl`, plus
  narrow read helper tools for common calls.
- Tools > Exposure can disable the full RemCTL profile. Custom CLI tools remain
  exposed, so PocketCTL-only or other non-FDA profiles can start the MCP server
  without running RemCTL's FDA check.
- `remctl.run` is marked destructive because the RemCTL CLI can create, edit,
  complete, or delete reminders and lists. It is still direct `Process`
  execution, never shell execution.
- Write and destructive tool calls are paused until they are approved in the
  Approvals view on the host Mac. Denied or expired calls do not reach the
  process runner.
- Settings includes a rotate action for the instance-specific MCP path. Rotation
  stops the local server and tunnel, clears pending approvals and OAuth grants,
  and forces remote clients to use a new URL path.
- Settings can revoke registered OAuth clients and bearer/refresh tokens while
  keeping the current MCP URL. Clients must reauthorize on the host Mac.
- Tunnel shows the currently exposed tool surface and can copy direct MCP
  preflight/API smoke commands for the selected smoke tool once a public URL
  exists.
- Starting Cloudflare Tunnel requires a confirmation that restates the tool
  surface and the remaining OAuth/per-call approval gates.
- Before starting the local MCP server, MacRemote runs
  `remctl doctor --for-agent --json` from its own process context whenever the
  exposed tool surface includes FDA-required tools. If macOS privacy blocks
  Reminders CoreData access, startup is blocked and MacRemote shows an app-wide
  permission sheet with the exact targets, copy/reveal actions, Settings
  routing, and RemCTL's guided Full Disk Access helper.
- PocketCTL is used as the first non-RemCTL CLI validation path. When installed,
  MacRemote can add PocketCTL presets and the test suite runs a real
  `pocketctl whoami --json` call through MCP after OAuth.
- After required permission checks pass, run the remote Anthropic MCP smoke test with
  [docs/END_TO_END_SMOKE_TEST.md](docs/END_TO_END_SMOKE_TEST.md).

## Research Notes

There are adjacent products and open-source projects, including
`remote-control-mcp` listings that expose shell commands, file access, and
AppleScript over MCP with OAuth/PKCE. MacRemote is deliberately narrower:
native app control, a user-defined allow-list, direct executable plus argv
execution, host-side approval, and no arbitrary shell surface in the first
profile.

The generic CLI direction is based on the same conclusion behind `cli2mcp` and
Peter Steinberger's CLI-first Peekaboo work: CLIs are the stable interface, and
the MCP layer should adapt selected executables rather than requiring one custom
server per CLI. MacRemote keeps that idea but puts it behind a native Mac UI,
OAuth, host approval, loopback binding, tunnel control, and local audit logs.

Useful source links:

- Claude custom connectors using remote MCP: https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp
- Claude Messages API MCP connector: https://platform.claude.com/docs/en/agents-and-tools/mcp-connector
- MCP 2025-11-25 specification: https://modelcontextprotocol.io/specification/2025-11-25
- MCP Streamable HTTP transport: https://modelcontextprotocol.io/specification/2025-11-25/basic/transports
- MCP authorization: https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization
- MCP tools and structured content: https://modelcontextprotocol.io/specification/2025-11-25/server/tools
- MCP Enterprise-Managed Authorization: https://blog.modelcontextprotocol.io/posts/enterprise-managed-auth/
- MCP 2026-07-28 release candidate: https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/
- cli2mcp: https://github.com/RonieNeubauer/cli2mcp
- Peekaboo CLI-first write-up: https://steipete.me/posts/2025/peekaboo-2-freeing-the-cli-from-its-mcp-shackles
- steipete Claude Code MCP wrapper: https://github.com/steipete/claude-code-mcp
- MCPorter: https://github.com/openclaw/mcporter
- Cloudflare Tunnel: https://developers.cloudflare.com/tunnel/
- Cloudflare MCP server portals: https://developers.cloudflare.com/cloudflare-one/access-controls/ai-controls/mcp-portals/
- Tailscale Funnel: https://tailscale.com/docs/features/tailscale-funnel
