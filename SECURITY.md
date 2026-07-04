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
- Logs must redact tokens, authorization codes, refresh tokens, Cloudflare
  credentials, and other secrets.
- Automatic MCP discovery only re-reads local configs; its cache at
  `~/Library/Application Support/MacRemote/mcp-scan-cache.json` stores hashed
  identities and a config fingerprint, never raw URLs, headers, or tokens.

See [docs/ARCHITECTURE_SECURITY.md](docs/ARCHITECTURE_SECURITY.md) and
[docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) for details.
