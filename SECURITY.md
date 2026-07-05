# Security

MacRemote exposes local Mac tools to remote MCP clients. Treat every change to
auth, tunnel handling, tool serialization, process execution, approval policy,
or logging as security-sensitive.

## Reporting

For private security reports, contact the repository owner directly. Do not file
public issues with secrets, tunnel URLs, OAuth tokens, or local command output.

## Security Model

- The local MCP server binds to `127.0.0.1`.
- Public access goes through a Cloudflare Tunnel URL ending in `/mcp`; the
  hostname can be temporary or a user-owned Cloudflare custom domain.
- OAuth client-secret mode disables dynamic client registration and requires
  `client_secret_basic` or `client_secret_post` before token issuance.
- Cloudflare Access service-token headers can be added as an outer transport
  gate for clients that support static headers.
- A leaked URL alone must not authorize tool calls.
- OAuth + PKCE and host-side approval are required before token issuance.
- Tool calls require a valid bearer token bound to the approved resource.
- Write, destructive, and broad CLI tools require per-call approval unless the
  host grants a persistent client policy.
- Tools run through direct process execution, never `/bin/sh -c`.
- Built-in File Transfer tools run natively in the app and enforce a
  sensitive-path denylist (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/Library/Keychains`,
  `~/.cloudflared`, and MacRemote's application-support folder) after resolving
  symlinks; they reject relative paths.
- File download tools return a one-time capability token, not file bytes. The
  `GET/HEAD /artifact/<token>` route is unauthenticated by design but requires a
  256-bit token, expires in 10 minutes, allows at most 3 downloads, caps size at
  512 MiB, is rate-limited, sends `Cache-Control: no-store`, and is purged when
  the server stops.
- The public tunnel forwards the artifact route along with `/mcp`; a leaked
  artifact URL grants at most the 3 downloads of that single staged file before
  expiry.
- Logs must redact tokens, authorization codes, refresh tokens, Cloudflare
  credentials, and other secrets.
- Automatic MCP discovery only re-reads local configs; its cache at
  `~/Library/Application Support/MacRemote/mcp-scan-cache.json` stores hashed
  identities and a config fingerprint, never raw URLs, headers, or tokens.

See [docs/ARCHITECTURE_SECURITY.md](docs/ARCHITECTURE_SECURITY.md) and
[docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) for details.
