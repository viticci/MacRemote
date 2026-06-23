# MacRemote

MacRemote is a native macOS app for exposing a deliberately small, user-approved
set of local tools to remote MCP clients.

The design goal is not "remote shell for your Mac." The server can only run
tools that the user explicitly defines in the app, and the first live profile is
limited to RemCTL read-only commands.

## Product Shape

- Native SwiftUI macOS app.
- Local MCP server process bound to `127.0.0.1`.
- Tool registry controlled from the app UI.
- No shell execution for tool calls. Commands run as exact executable paths plus
  validated argv arrays.
- Host-side approval before a remote client receives OAuth tokens.
- Cloudflare Tunnel for public reachability. The tunnel forwards only to the
  local MCP server port, not to the Mac as a whole.

## MCP Baseline

MacRemote targets the latest stable MCP specification, `2025-11-25`, while
keeping compatibility with `2025-06-18` and `2025-03-26` clients.

- Streamable HTTP endpoint at `/mcp`.
- OAuth 2.1-style authorization code flow with PKCE and host approval.
- RFC 9728 protected-resource metadata and authorization-server discovery.
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
2. Enable the RemCTL-only tool profile.
3. Start the local MCP server.
4. Expose it through a Cloudflare Tunnel.
5. Connect a remote model client to the MCP URL.
6. Approve the auth request on the Mac.
7. Run a RemCTL read-only tool call and verify the result.

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
└── script/               Build and run entrypoints
```

## Security Bias

MacRemote should fail closed:

- no tunnel unless the local server is healthy;
- no tool execution without a valid access token;
- no token issuance without host approval;
- no arbitrary shell strings;
- no inherited broad environment;
- no unbounded runtime or output;
- no write-capable RemCTL commands in the first profile.

## Current Local Gates

- `cloudflared` is supported when installed in `/opt/homebrew/bin` or
  `/usr/local/bin`. MacRemote starts accountless quick tunnels and extracts the
  temporary `trycloudflare.com` MCP URL from process output.
- Direct RemCTL reads from the GUI app require Full Disk Access for
  `dist/MacRemote.app`; without it, macOS blocks reads of the local Reminders
  CoreData store. Terminal runs can still pass because Terminal already has the
  required permission.

## Research Notes

There are adjacent products and open-source projects, including
`remote-control-mcp` listings that expose shell commands, file access, and
AppleScript over MCP with OAuth/PKCE. MacRemote is deliberately narrower:
native app control, a user-defined allow-list, direct executable plus argv
execution, host-side approval, and no arbitrary shell surface in the first
profile.

Useful source links:

- Claude custom connectors using remote MCP: https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp
- Claude Messages API MCP connector: https://platform.claude.com/docs/en/agents-and-tools/mcp-connector
- MCP 2025-11-25 specification: https://modelcontextprotocol.io/specification/2025-11-25
- MCP Streamable HTTP transport: https://modelcontextprotocol.io/specification/2025-11-25/basic/transports
- MCP authorization: https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization
- MCP tools and structured content: https://modelcontextprotocol.io/specification/2025-11-25/server/tools
- MCP Enterprise-Managed Authorization: https://blog.modelcontextprotocol.io/posts/enterprise-managed-auth/
- MCP 2026-07-28 release candidate: https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/
- Cloudflare Tunnel: https://developers.cloudflare.com/tunnel/
- Cloudflare MCP server portals: https://developers.cloudflare.com/cloudflare-one/access-controls/ai-controls/mcp-portals/
- Tailscale Funnel: https://tailscale.com/docs/features/tailscale-funnel
