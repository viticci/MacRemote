# MacRemote Repository Threat Model

## Overview

MacRemote is a macOS app that exposes a small, user-approved set of local Mac
tools to remote MCP clients. Its primary surfaces are a native SwiftUI
configuration app, a loopback-only MCP HTTP server, a command runner, an OAuth
authorization flow, and a Cloudflare Tunnel integration.

The most sensitive asset is the local Mac user session. A successful compromise
could run local commands, read local data, manipulate local apps through exposed
CLIs, or mint remote tokens that let a chatbot keep calling tools after initial
authorization. Command execution, token issuance, tunnel exposure, client
policies, and audit logging are security-critical runtime code.

## Trust Boundaries

Trusted actors:

- the local Mac user operating the app;
- the app code and bundled helper code after local installation;
- Cloudflare Tunnel as a transport provider, when configured by the user;
- the selected remote MCP client only after successful OAuth and host approval.

Untrusted or attacker-controlled actors:

- anyone who learns or guesses the public MCP URL;
- malicious or compromised remote MCP clients;
- prompt-injected model behavior that attempts unexpected tool calls;
- attacker-controlled MCP request fields, JSON-RPC inputs, OAuth client names,
  redirect URIs, tool parameters, and HTTP headers;
- local malware or another local user process.

Core boundaries:

- public internet to Cloudflare Tunnel;
- Cloudflare Tunnel to `127.0.0.1:<port>`;
- HTTP server to auth/session state;
- MCP tool call to command runner;
- command runner to local CLIs such as `remctl`, `codex`, or `pocketctl`;
- public `/artifact/<token>` route to staged artifact files;
- native File Transfer tools to the local filesystem (read/write) under the path denylist;
- app UI to persistent configuration and secrets.

## Core Assumptions

- The local MCP server binds only to loopback.
- The tunnel forwards only to the MCP server port.
- A leaked URL alone must not authorize a client.
- User-defined tools are exact executable paths plus argv templates, not shell
  strings.
- Secrets are stored in Keychain or protected app support files and never
  committed.

## Attack Surface

Remote HTTP/MCP inputs are the largest attack surface. The server must validate
all JSON-RPC shapes, reject unknown methods, cap body size, cap output size, and
avoid reflecting attacker-controlled strings into HTML without escaping.

OAuth and client registration are critical. A malicious client may try open
redirects, PKCE bypass, authorization code replay, refresh token reuse, or client
impersonation. Mitigations include strict redirect URI validation, PKCE required
for code flow, one-time authorization codes, short token lifetimes, refresh token
rotation, token hashing or encryption at rest, and host-side approval before
code issuance.

Tool execution is critical. A malicious model may try command injection through
tool parameters or ask for a broader tool than approved. Mitigations include no
shell execution, exact executable allow-lists, per-tool parameter schemas, argv
construction from typed values, fixed timeouts, environment allow-lists, and
separate capability classes for read-only, write, and destructive tools.
Generic CLI adapters intentionally expose one executable plus model-supplied
argv and optional stdin. That is universal but not a sandbox. Each generic
adapter must be treated as delegation of the whole executable's reachable
capability surface. Shell interpreters and `/usr/bin/env` are blocked because
they erase the executable boundary.

Resource exhaustion is a remote-reachable denial-of-service surface: a client
can send bursts, hang commands, stream oversized output, or pass malformed
arguments to starve the host or crash the server. Mitigations: a global
execution concurrency limiter caps simultaneous tool runs (acquired after the
approval gate) and sheds excess load with a structured `reason: "unavailable"`
result instead of spawning unbounded processes; timed-out tools are killed by
both their process group and direct pid (SIGTERM then SIGKILL) so pagers and
spawned subprocesses are reaped; child stdout/stderr are drained concurrently
to avoid a pipe-buffer deadlock, with per-tool output byte caps; stdin defaults
to `/dev/null` and pagers are disabled; and numeric arguments are parsed with a
checked conversion so an out-of-range integer returns `invalid_argument`
instead of trapping the process. Argument and validation failures return a tool
result with `isError: true` and a machine-readable `reason`; JSON-RPC errors are
reserved for malformed envelopes and unknown methods/tools.

The built-in File Transfer tools reach the filesystem directly rather than
through a delegated CLI. Mitigations: absolute-path-only inputs (relative paths
and `..` traversal rejected), a sensitive-path denylist (`~/.ssh`, `~/.gnupg`,
`~/.aws`, `~/Library/Keychains`, `~/.cloudflared`, MacRemote's
application-support folder) enforced after symlink resolution so a symlink into
a denied tree is blocked, bounded read chunks (≤64 KiB/call) and list depth
(≤5) and entry counts (≤2000), and `write_file` carrying the `write` capability
so each call needs host approval. These tools are Not Shared by default and
never enter `tools.json`.

The `/artifact/<token>` download route is unauthenticated and reachable over the
public tunnel. It trades the bearer for a 256-bit capability token with tight
bounds: 10-minute expiry, 3 downloads max, 512 MiB size cap, per-route rate
limiting, `no-store`, and purge-on-server-stop. A leaked artifact URL exposes at
most that one already-approved file, and only until the token's downloads or
expiry run out. The token is generated with `SecRandomCopyBytes`; path traversal
in the token is rejected (`/` disallowed in the token component).

Default command categories are only preset drafts. They must not be auto-enabled
or silently added to the exposed MCP surface. Filesystem presets are constrained
to read-only commands and must not include delete, unlink, or trash operations;
write-capable presets such as image conversion must be labeled as write tools.

Tunnel setup is high risk. A bug that binds the local server to `0.0.0.0` or
forwards a broad local service would expose more than the intended MCP process.
Mitigations include loopback-only listeners, health checks before tunnel start,
single-origin tunnel routing, and explicit stop, revoke, OAuth credential
rotation, and instance rotation controls in the UI. OAuth credential rotation invalidates connected clients and tokens.
Instance rotation remains a private local compatibility control, not the public
URL authority.

Logs and diagnostics can leak secrets. Audit logs must redact tokens,
authorization codes, refresh tokens, Cloudflare credentials, request headers,
and full command output by default.

Local MCP discovery reads local agent config files. At launch and on activation
the app passively re-reads those configs with no subprocess and no network, and
persists a discovery cache at `~/Library/Application
Support/MacRemote/mcp-scan-cache.json`. That cache must store only hashed
seen-identities and a config fingerprint; it must never persist raw endpoint
URLs, request headers, or tokens, so a leaked cache file cannot reveal upstream
MCP endpoints or secrets. Passive discovery must not probe, import, or expose any
server — only the explicit manual scan-and-import flow may reach upstream servers
or add bridge tools.

## Severity Calibration

Critical:

- arbitrary shell command execution through a remote MCP call;
- token issuance without host-side approval;
- public tunnel exposing anything beyond the MacRemote MCP server;
- auth bypass allowing leaked URL holders to call exposed tools.

High:

- redirect URI validation flaw that leaks authorization codes;
- refresh token replay or non-rotating refresh tokens;
- broad CLI adapters exposed without host-approved OAuth, destructive tool
  annotation, or per-call host approval for writes;
- tools exposed before required Full Disk Access or macOS privacy gates pass
  from MacRemote's process context;
- native `write_file` writing outside the intended location, or any File
  Transfer tool reading a denylisted path (path-policy bypass);
- persistent client tool policies applied to the wrong OAuth client or resource;
- logs storing bearer tokens or Cloudflare credentials.

Medium:

- missing request or output size limits causing local denial of service.
  Remote-triggerable process exhaustion (unbounded concurrent executions or
  unreaped child process trees) and the integer-overflow crash from a malformed
  numeric argument are mitigated: executions are bounded by the concurrency
  limiter with structured load-shedding, timed-out children are killed by
  process group and direct pid, and numeric parsing is checked so a bad argument
  returns `invalid_argument` rather than trapping the server;
- artifact tokens not expiring, exceeding the download count, or surviving
  server stop; artifact route missing its rate limit or size cap;
- weak or predictable instance identifiers;
- incomplete audit records that prevent the user from understanding which client
  called which tool;
- UI state desynchronization that shows the tunnel stopped while it is still
  running.

Low:

- cosmetic UI mistakes that do not affect auth or execution;
- non-sensitive log wording issues;
- failure to detect optional tunnel providers when the local server remains
  stopped and no exposure occurs.
