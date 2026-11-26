# MacRemote Architecture and Security Design

## Product Decision

MacRemote has two connection paths:

- **Local server:** the app exposes one MCP Streamable HTTP endpoint on
  `127.0.0.1`. Local clients on the Mac can connect directly.
- **App-managed public link:** Cloudflare Tunnel forwards one public HTTPS
  hostname to that loopback server for ChatGPT, Anthropic, and other remote MCP
  clients.

Those are the product. There is no third transport mode and no separate
transport helper for the user to install or operate.

Authentication is independent of transport. One method is the product default;
the other two are advanced options a user selects explicitly:

- **Dynamic OAuth — the default.** Protected-resource discovery, DCR,
  authorization code, S256 PKCE, and resource binding. It is the only method that
  reaches a Mac-side approval before a token exists and requires no secret to be
  copied by hand, and it is what ChatGPT's custom MCP server connection depends
  on. A
  fresh install starts here regardless of which app the user has selected.
- **OAuth Client Secret — advanced.** Preconfigured confidential clients. Turning
  it on disables self-registration server-wide, so clients that sign themselves
  up — including ChatGPT's custom MCP server and Claude's custom connector over
  the public link — cannot connect while it is active.
- **Single Header — advanced.** The generic bearer mode for a client that can
  attach a fixed `Authorization` header but cannot complete a sign-in.

Choosing which app to connect never chooses a method. The app picker only
switches the setup instructions shown; it does not write the sign-in
configuration and does not mint a credential.

The tunnel carries requests; it never replaces MacRemote authentication,
approval, or tool policy.

MacRemote implements MCP and MCP Apps directly in Swift. Standard fields are
primary. Compatibility aliases are additive, and their presence does not mean
the app embeds the OpenAI Apps SDK.

## Security Objectives and Trust Boundaries

The protected asset is the signed-in macOS user session. An exposed tool can
read local data, mutate apps, create files, or delegate a broad executable
surface. The design therefore requires:

- a loopback-only listener;
- authentication before MCP method dispatch;
- an explicit shared-tool registry rather than arbitrary command execution;
- exact executable paths and argv arrays, with no shell;
- host approval for new OAuth apps and sensitive tool calls;
- permissions bound to the exact tool security contract;
- bounded execution and artifact storage;
- fail-closed parsing and persistence;
- local audit records that exclude credentials and full outputs.

The principal boundaries are:

- public internet → Cloudflare edge → loopback MCP server;
- local or remote MCP client → MacRemote authentication and authorization;
- authenticated `tools/call` → Mac-side approval policy;
- approved call → process, native, or imported MCP backend;
- public capability URL → artifact storage;
- app UI → persisted tools, grants, and secrets.

Cloudflare is a transport provider, not an authorization authority. A local
process is also untrusted until it presents a valid MacRemote credential.

## Runtime Components

### macOS App

The SwiftUI app owns:

- the saved and currently shared tool catalog;
- local server and Cloudflare public-link lifecycle;
- sign-in configuration and credentials;
- pending OAuth and tool-call decisions;
- per-app persistent tool permissions;
- the folders File Transfer may reach;
- local audit history.

The primary UI surfaces are Connection, Tools, Apps, Requests, and Activity.
Settings contains the sign-in method, the Cloudflare helper, notification
status, File Transfer folders, token lifetimes, and credentials.

Starting a public link requires an explicit confirmation of the exposed tool
surface. The UI reports real local-server and Cloudflare state. It never treats
a public URL as a credential.

The UI also draws a name and a mark for each connected app. Both come from
strings the app supplied at registration, so both are untrusted presentation. The
brand table that selects a mark is a deterministic exact-match lookup that no
service or store reads; it cannot influence authentication, Always Allow
resolution, token validity, or which client a revocation targets. No mark carries
a verification claim, and no artwork is fetched at runtime.

### Local MCP Server

`LocalMCPServer` binds only to `127.0.0.1` on a random high port or a selected
local port. It never binds to `0.0.0.0`.

The server routes include:

- `GET /health`;
- `GET /.well-known/oauth-protected-resource`;
- `GET /.well-known/oauth-protected-resource/mcp`;
- `GET /.well-known/oauth-authorization-server`;
- `GET /.well-known/oauth-authorization-server/mcp`;
- `POST /register`;
- `GET /authorize`;
- `GET /authorize/status`;
- `POST /token`;
- `POST /mcp`;
- `PUT <MCP path>/uploads/<token>` for an approved upload's bytes
  (DESIGN-SPEC D83; see [Native File Transfer](#native-file-transfer));
- `GET` and `HEAD /artifact/<token>` for short-lived result downloads;
- connector icons, favicon assets, and the small landing page.

The private instance path may remain a loopback compatibility endpoint. Public
requests advertise and use `/mcp`; the private instance identifier is a
revocation boundary, not a public URL secret.

`/health` is diagnostic rather than protocol discovery. Loopback health can
include instance and tool-surface details. Public health returns only generic
readiness and never discloses the private instance ID or catalog.

Authentication happens before MCP method dispatch. Unauthenticated `POST`,
`GET`, or `DELETE` requests to a valid MCP path receive the same `401`
protected-resource challenge. Authenticated `GET` and `DELETE` then receive
`405 Method Not Allowed` because MacRemote's Streamable HTTP implementation
uses request-scoped JSON responses over `POST`.

Public unauthenticated requests are rate limited in memory
(`PublicRequestRateLimiter`) before they can create registrations, sign-in
requests, or approval prompts. Each kind of request (health, metadata,
registration, authorization, authorization status, token, unauthorized MCP,
artifact, upload) has a limit per minute for one caller. The caller is the address
Cloudflare reports in `CF-Connecting-IP`. All callers together share a ceiling
eight times the per-caller limit, so one stranger cannot use up the allowance of
every legitimate app. Loopback requests are outside this limiter.

The server holds at most 96 open connections. A client has 30 seconds to send
one complete request, and a request larger than 128 KiB is refused. The one
exception is an upload's body (D83): once its headers are in, checked, and
matched to an upload waiting for bytes, the body is written to staging as it
arrives, up to the approved size, within its own time limit. Each
connection carries one request. When the client closes the connection before
the answer, the server cancels the work, which withdraws a call still waiting
for approval.

The server answers only for hosts it serves. A request's `Host` must be this
Mac's loopback address with the server's port (`127.0.0.1`, `localhost`, or
`[::1]`), or the public link's host while the link is up. `TunnelService`
reports that host; `LocalMCPServer` asks for it on every request. Any other
`Host`, or none, gets `421 Misdirected Request` before routing. This stops a
web page that points its own host name at `127.0.0.1` (DNS rebinding) from
talking to the server under that name. The request base, and with it the OAuth
issuer and resource, is built from the known host, never from a header.
Cloudflare's helper passes the caller's `Host` through unchanged, so
`X-Forwarded-Host` is not read at all.

Browser CORS reflects only exact allowed origins and always adds `Vary: Origin`.
The allowed set is the canonical request base, active local origins, and the
trusted ChatGPT origins when the canonical base is public. It never uses `*`
and never allows a ChatGPT origin to call direct loopback. Preflight permits the
standard modern headers, including `MCP-Protocol-Version`, `Mcp-Method`,
`Mcp-Name`, and `Mcp-Param-*`. Responses expose `WWW-Authenticate`,
`MCP-Session-Id`, and `MCP-Protocol-Version`.

### Managed Cloudflare helper

MacRemote can install its own copy of the Cloudflare tunnel client rather than
requiring the user to obtain one. That copy is app infrastructure: it lives under
`~/Library/Application Support/MacRemote/CloudflaredHelper/`, is never added to
the shared tool catalog, and is not reachable by the CLI scanner, executable
search path, or tool presets.

The release is pinned at build time — version, download URL, exact archive and
executable sizes, exact SHA-256 for both, expected Developer ID team, and the
exact uncompressed archive length are compiled constants. Nothing is fetched at
runtime to decide what is correct. The download is HTTPS-only against a small
host allowlist enforced on the initial request and on every redirect, with a
bounded redirect chain and a byte cap; the transfer must match the published size
exactly. Extraction is in-process, with no subprocess, shell, package manager, or
external archiver: a length-capped inflate checked against the archive's own
CRC-32 and length trailer, then a reader that accepts exactly one regular file of
the expected name and size and rejects symlinks, links, directories, prefixed or
traversing paths, archive extensions, and any second entry. The unpacked file is
re-read from disk and re-verified for size, digest, and signing team before
publication.

Installation is atomic into an owner-only directory (0700) with the binary at
0500 and its install record at 0600, and rolls back rather than leaving a binary
with no record. Before every launch the same file is re-verified — ownership,
permissions, regular-file type, size, SHA-256, Developer ID team — and any
failure quarantines the copy instead of running it. The digest check is
two-fold: the computed SHA-256 must match the install record *and* be a member
of the compile-time digest set, so a rewritten `install.json` beside an
unpublished binary never authorizes a launch. That set holds the current pinned
release and the releases earlier MacRemote versions installed
(`CloudflaredManifest.earlierExecutableSHA256`). A helper from an earlier
release therefore keeps working after an app update, and Settings offers the
update. The record file itself is
validated in the same pass — regular file, not a symlink, owner-only mode.
Status displays use a separate no-hashing path (`stat`-class checks and the
verification cache keyed on inode, modification time, and size); only the full
verification authorizes a launch, and a supervised watchdog relaunch re-proves
the session's pinned path off the main actor and fails the tunnel rather than
substituting a different binary. Resolution order is the
running process's pinned path, then the current supervised session's path, then
MacRemote's verified copy, then a copy the user installed. Pinning the session
path means an update or removal can never swap the executable underneath a live
tunnel. The UI reports the real source; MacRemote never claims to manage a copy
the user installed, and removal deletes only its own folder.

### App-managed Cloudflare Public Link

The app starts and health-checks the local server before launching the resolved
Cloudflare helper — its own verified copy when one exists, otherwise the copy the
user installed — with an exact executable path and an argv array, never a shell.
The public URL is:

- `https://<quick-tunnel-host>/mcp`; or
- `https://<configured-hostname>/mcp`.

A watchdog distinguishes deliberate stop from an unexpected exit, probes the
origin, and retries unexpected failures with bounded exponential backoff.
Recovery is shown as reconnecting; exhausting retries becomes a failure rather
than a false running state.

A running helper is not proof of a working link. The helper is started with
`--metrics 127.0.0.1:0`, and the app reads the number of ready connections from
its `/ready` page on this Mac (`TunnelService.refreshEdgeConnection`): on every
watchdog check, and one second after the helper prints anything. The link is
shown as running only while that number is above zero. At start it also waits
for the helper's "Registered tunnel connection" line, for an Instant Link as
well as Your Domain. A link that lost its connections is shown as reconnecting
and comes back by itself; the helper is not restarted for it, because that
would change an Instant Link's address.

The helper never outlives the app's intent. Every quit path stops it
(`applicationWillTerminate`). A crash, Force Quit, or kill signal never reaches
that method, and macOS cannot make a child process die with its parent. So
each time the app starts the helper, it also starts a second copy of its own
executable as a tether (`Services/HelperTether.swift`). The tether watches both
processes. When the app exits, it stops the helper; when the helper exits
first, it exits. It signals only the process it was told about, after matching
its executable path, and it ignores polite kill signals so that a signal sent
to the app by name cannot remove it first.

As a second line, the app records the helper's process ID, start time, and
executable path when it starts one. At the next launch, a helper that still
matches that record is stopped (`TunnelService.stopHelperLeftByPreviousLaunch`).
That covers a tether that was killed together with the app.

Go Public uses the address the owner chose. With Your Domain chosen, it never
starts an Instant Link. A domain that is already deployed goes public again
from its saved run token; any other opens the Address card to deploy. An
Instant Link's address is read from the helper's output; only a
`trycloudflare.com` host other than Cloudflare's own API host is accepted
(`TunnelService.firstPublicURL`).

The Cloudflare API token is never saved. A deploy saves one secret, the
tunnel's run token, in the Keychain (`CloudflareRunTokenStore`). That token
connects the one deployed tunnel; it cannot create tunnels or change DNS. The
app uses it only for the tunnel ID it was saved with, only while the saved
address is still the chosen one, and only while the local server listens on
the port the domain was deployed with, because Cloudflare's copy of the
tunnel's settings sends requests to that port. Choosing another address
deletes the token. So does a start that Cloudflare rejects, after which Go
Public asks for a deploy again.

Custom-domain setup reads the existing named tunnel and DNS record before any
mutation. It rejects a foreign owner, rechecks DNS immediately before writes,
and preserves unrelated Cloudflare configuration. Browser Integrity Check is
disabled only for the exact MacRemote hostname because it otherwise rejects
legitimate non-browser MCP traffic before MacRemote can authenticate it. This
Cloudflare rule is not a security substitute for OAuth, Single Header, approval,
or in-process rate limiting.

## MCP Protocol Contract

### Dual-era version support

MacRemote supports:

- modern `2026-07-28`;
- legacy `2025-11-25`, `2025-06-18`, and `2025-03-26`.

Modern MCP is stateless at the protocol layer. There is no `initialize`
handshake. Every request carries:

- `_meta["io.modelcontextprotocol/protocolVersion"]`;
- `_meta["io.modelcontextprotocol/clientInfo"]` when sent by MacRemote as a
  client;
- `_meta["io.modelcontextprotocol/clientCapabilities"]`;
- the matching HTTP `MCP-Protocol-Version` header.

Era selection is an exact version claim, not a process of elimination. A
request is judged by modern rules when its `MCP-Protocol-Version` header is
exactly `2026-07-28` or when `params._meta` carries the namespaced
protocolVersion key. A lone namespaced clientCapabilities object is inert: live
ChatGPT adds it to otherwise legacy requests and does not thereby claim the
modern protocol. Claimless `server/discover` remains legacy and receives Method
not found, allowing automatic fallback to `initialize`.

A header naming any other version — older than the legacy set, or a future
revision MacRemote does not implement — is answered with `-32022` and
`{"requested": …, "supported": [ … ]}` before any era-specific validation runs,
without echoing the version just refused. The response and advertised list stay
within the inferred era: modern claims receive `2026-07-28`; legacy-shaped
requests receive `2025-11-25` plus the three-version legacy list.

`server/discover` is the authenticated discovery method. It returns the
modern version, server capabilities, extension map, and concise
instructions. MacRemote advertises `io.modelcontextprotocol/ui`. The
instructions describe MacRemote's own rules and name no particular author's
tools.

An `initialize` request intentionally selects legacy semantics. Its body's
`protocolVersion` is what is negotiated: an unrecognized value, or none at all,
settles on the newest recognized legacy version. The HTTP header is checked
first, so an `initialize` whose header names a version MacRemote does not
implement receives `-32022` rather than a legacy session. It returns top-level
`serverInfo` and keeps legacy result shapes. Modern-only fields are never
injected into legacy responses.

MacRemote also acts as a client when probing or calling an imported MCP server.
It tries `server/discover` with modern metadata first. It falls back to legacy
`initialize` when the response is not a recognized modern response, and the
three recognized modern errors then split two ways.

`-32020` and `-32021` prove that the upstream answered on current-protocol
terms, so they stop the connection outright and never trigger a downgrade.
`-32022` is the opposite claim: the upstream is saying it does not speak the
version MacRemote named. When its `error.data.supported` names a legacy
revision MacRemote's own initialize flow implements, the bridge accepts that
invitation and runs `initialize` at the newest mutually supported version. A
`server/discover` result that succeeds but advertises only implementable legacy
versions is the same offer phrased as a success, and is treated the same way.

A `-32022` with no list, a malformed list, or a list that overlaps nothing
MacRemote implements still fails closed. The rule is that a reserved code alone
never downgrades a connection — only a server's own explicit version list does.
A renegotiated version applies to that connection or launch only; the bridge's
persisted `protocolVersion` is fingerprinted security material and is never
rewritten from the wire.

This follows the dual-era safety rule: a client may fall back on an
unrecognized legacy-style response, or on a version list the server supplied
itself, but a recognized modern error carrying no such list requires a modern
retry or an explicit failure.

### Modern HTTP metadata mirrors

For modern Streamable HTTP requests, the JSON body remains authoritative and
the server validates its HTTP mirrors:

- `Mcp-Method` must exactly match the JSON-RPC method.
- `Mcp-Name` must match the tool name, prompt name, or resource URI for
  methods that target one named object.
- A tool parameter whose published schema contains `x-mcp-header: "Name"` must
  be mirrored as `Mcp-Param-Name`.

Mirrored values can be plain safe ASCII or the standard
`=?base64?<base64-utf8>?=` representation. A missing, malformed, or mismatched
mirror is `HeaderMismatch` (`-32020`).

MacRemote publishes `x-mcp-header` only when every annotation is:

- reachable through ordinary object `properties`;
- a unique valid HTTP field name;
- attached to a `string`, `integer`, or `boolean`.

Annotations hidden behind `$ref`, attached to unsupported types, or duplicated
are removed from the published modern schema rather than creating an
unverifiable routing contract. MacRemote applies the same bounded validation
when calling an upstream modern MCP server. Schema inspection accepts at most
64 levels of traversal and 4,096 container nodes; a schema one level or one
container node over either limit fails closed.

### Results, caching, identity, and errors

Every successful modern result has `resultType: "complete"`.

Modern `server/discover`, list, and resource-read results carry `ttlMs: 0` and
`cacheScope: "private"`. `tools/list` is sorted by stable tool ID and includes a
deterministic catalog revision so clients can cache safely without binding the
catalog to a token or session.

Modern server identity is emitted at
`result._meta["io.modelcontextprotocol/serverInfo"]`. It contains name, title,
version, description, website URL, and icons derived from the current canonical
request base. It is not duplicated as top-level `serverInfo`. Legacy
`initialize` keeps the older top-level `serverInfo` shape.

Modern protocol errors use:

- `-32020` — header mirror mismatch;
- `-32021` — missing required client capability;
- `-32022` — unsupported protocol version, with `requested` and `supported`;
  returned for an unsupported `MCP-Protocol-Version` header before any era
  validation, and for an unsupported version inside the modern envelope;
- `-32602` — invalid params, missing/unknown tool, or missing resource; a
  request that claims `2026-07-28` without the modern `_meta`
  envelope also fails here and is never silently executed as legacy;
- `-32601` — unknown request method;
- `-32603` — internal server failure;
- `-32700` — malformed JSON.

Recognized modern request errors use meaningful HTTP `400`, `404`, or `500`
status codes. Legacy JSON-RPC compatibility generally retains HTTP `200`, and a
legacy missing resource retains its historical `-32002`.

Execution and validation failures after a known tool is selected are normal
`CallToolResult` values with `isError: true` and a machine-readable `reason`;
they are not protocol errors. The reason taxonomy is `ok`, `nonzero_exit`,
`timeout`, `output_limit`, `killed`, `invalid_argument`, `not_approved`,
`unavailable`, and `internal_error`. Unknown notifications and
`notifications/cancelled` are acknowledged with HTTP `202` and no body.

### Tool and resource metadata

Every tool descriptor keeps standard MCP fields primary:

- stable `name` and human-readable `title`;
- concise `description`;
- JSON Schema `inputSchema` and `outputSchema`;
- `annotations` for title, read-only, destructive, idempotent, and open-world
  hints;
- top-level OAuth `securitySchemes`.

`_meta.securitySchemes` mirrors the top-level schemes for older hosts.
`structuredContent` and meaningful text `content` remain present for clients
that do not render an app.

`tools/list` returns the full shared catalog without pagination. Its revision is
also available through `macremote://catalog/v1`; this compact resource supports
stale-name recovery without replacing the authoritative tool schemas.

### Skills (D84)

Modern `server/discover` declares `io.modelcontextprotocol/skills` beside the
MCP Apps extension. `skills/list`, `skills/get`, and `resources/read` of a
`skill://` URI serve only the skills the owner shared, from
`ServedSkillCatalog` (`Services/SkillCatalog.swift`), with `ttlMs: 0` and
`cacheScope: "private"` like the other cacheable results. An unknown skill URI
is `-32602`. Legacy sessions get no capability and `-32601`; skills never
appear in `resources/list`.

A bridged or found skill's text reaches the remote model as instructions. The
controls: the owner opts in per skill (every skill except MacRemote's own
starts Not Shared, keyed by source and the skill's URI or real folder path),
each upstream file must match the size and SHA-256 its server listed, every
header is read exactly by `SkillFrontmatter` and a bridged header must equal
its listing, Claude's size limits are enforced when a skill is read, and the
skill keeps its origin (served under its server's or folder's slug, with
`_meta["net.viticci.macremote/origin"]` and a paragraph naming where it came
from). See `THREAT_MODEL.md` §"Skills over MCP".

Skills found on this Mac come from `FoundSkillScanner`, at launch and when the
owner scans. It reads nothing for a family MacRemote does not have, resolves a
linked skill folder once and opens each file without following a link, skips
protected locations, and runs nothing. Found skills are kept in memory and
leave with their family's tools. A bridged or found skill's note names only
the family's shared tools, and a skill whose family has no shared tool is
left out of what the server serves.

## MCP Apps Contract

MacRemote exposes one versioned HTML app resource:
`ui://macremote/output-v9.html`. The older
`ui://macremote/output-v8.html`, `ui://macremote/output-v7.html`, `ui://macremote/output-v6.html`, `ui://macremote/output-v5.html`, `ui://macremote/output-v4.html`, `ui://macremote/output-v3.html`,
`ui://macremote/output-v2.html`, and `ui://macremote/output` URIs remain readable
as cache-compatibility paths. Explicit typed `ToolWidgetPresentation` metadata
is authoritative and preserves curated columns, documents, accents, and row
actions. Every other registered tool receives the schema-free
`semanticResult` profile. This includes Flexible Commands, custom process
tools, imported HTTP/stdio bridge tools, and native File Transfer tools. The
generic profile does not inspect executable names or assume a product payload
schema. Historical fixed Reminders, Podcasts, and Habits tools retain their
richer category fallback. Native text `content` and `structuredContent` remain
available to clients that do not render the app. Early tool-execution errors
carry the same result-resource linkage, so they do not fall back to a host's
developer-facing JSON view. Linkage is also the owner's choice (decision D77):
it is off by default and can be turned off per tool family. A tool without
linkage returns the same text and `structuredContent`; the choice never
changes a security fingerprint, permission, or approval.

The HTML resource applies a final display-safety boundary after any curated
presentation hint. It constructs text through DOM APIs and removes commands,
argv, local paths, stdout/stderr labels, credentials, protocol metadata, and raw
JSON serialization from the person-facing view. Only assistant-visible MCP
content is eligible: blocks whose `annotations.audience` excludes `assistant`
and hidden result `_meta` do not enter the pretty UI. Resource links remain
links with semantic name, MIME type, and size; image and audio blocks become
bounded media labels; errors use a dedicated human state.
The widget never renders artifact backing paths, media bytes, hidden metadata,
or terminal output. Its Copy action derives text from the sanitized rendered
card, not from the outer execution envelope.

For a modern request, app metadata is capability scoped. The client must declare
`io.modelcontextprotocol/ui` with
`text/html;profile=mcp-app`. Every registered tool then receives standard nested
`_meta.ui.resourceUri` plus the additive flat and OpenAI compatibility aliases,
and the resource publishes standard `_meta.ui` CSP, permission, and presentation
policy. A modern client that omits the exact Apps capability receives no widget
resource listing or tool/result linkage; a direct read of a known current or
legacy `ui://` URI remains available.

The resource's own `_meta.ui` policy is the one part that is never capability
scoped (2026-07-30). Every read of the widget resource carries the CSP
allowlist, permissions, and presentation hints, on every negotiation path, and
the `resources/list` descriptor declares the same policy. `_meta` is ignorable
by contract, so a client that does not understand `ui` drops it; a client that
does understand it and receives no `csp` falls back to a default that blocks
the widget's one external origin.

Legacy clients have two compatibility behaviors for *linkage*:

- a legacy client that advertised the Apps extension during `initialize`
  receives standard nested UI metadata plus compatibility aliases;
- a legacy client with no Apps capability receives only the established flat
  `ui/resourceUri` and `openai/outputTemplate` aliases.

The aliases never replace the standard field. App actions re-enter ordinary
authenticated `tools/call` and the same Mac-side approval gate. The iframe never
gets a private execution shortcut or direct local endpoint. The widget's strict
human projection does not remove cross-host data: the outer result keeps its
meaningful `content`, `structuredContent`, assistant-visible annotated content,
and collision-safe metadata contract for the model and for clients that do not
render Apps.

## Result Artifacts

`/artifact/<token>` serves a result that is too large to return in the MCP
response, or a file staged by a built-in File Transfer download tool. It uses a
temporary store, a 256-bit capability token, 10-minute expiry, 3 downloads, a
512 MiB cap per file, and a 2 GiB cap on all staged files together. It returns
`Cache-Control: no-store` and an attachment disposition, requires no bearer
beyond its unguessable capability token, and is purged when the local server
stops. The file is sent from disk in pieces, never loaded into memory whole.
Staged files live in one folder in the temporary directory, which the app
empties at launch.

Large process or bridge results are bounded by the tool's 64 MiB output limit,
even though the store can hold a larger File Transfer download.

MacRemote adds a `download_url` to a result only for the built-in File Transfer
tools, which create the artifact themselves (`executeToolCall`). The output of
any other tool is untrusted text. MacRemote never reads link fields out of it,
so a tool cannot make MacRemote present a download link to an address of the
tool's choosing.

## Tool Execution and Imported MCP Servers

### Tool model

A process tool contains:

- a stable semantic ID, title, and description;
- an absolute executable path;
- an argv template and typed parameters;
- capability and approval policy;
- permission requirements;
- timeout and output limits;
- a working-directory and environment policy.

MacRemote supports **Fixed Command** tools for narrow typed workflows and
**Flexible Command** tools whose single `args` array delegates a broader
executable surface. Neither mode invokes `/bin/sh -c`.

A call runs inside the request that made it, and the Guide states the
[time limit](GUIDE.md#reliability), unless the request is modern and declares
the MCP Tasks extension. Then the same call can be answered with a task
(DESIGN-SPEC D81): at once for a tool the owner marked Long-Running or a
Flexible Command call with `run_in_background: true`, otherwise after 20
seconds. The call still passes validation, the approval gate, and the
execution limiter in the same order. `ToolCallTaskStore`
(`Services/ToolCallTasks.swift`) keeps tasks in memory only, keyed to the
calling app's client ID: `tasks/get`, `tasks/update`, and `tasks/cancel` from
any other app, for an unknown id, or for an expired id get `-32602`, and a
request that does not declare the extension gets `-32021`. Task ids are 256
random bits. At most 8 tasks run per app and 32 in all; past that the call
answers in its request. A finished result is kept for one hour, and at most
128 tasks are kept. Once a call is a task, a closed connection no longer stops
it; `tasks/cancel`, stopping the server, or quitting does, and cancelling stops
the process tree as it does for any cancelled call.

The runner:

- validates that the configured executable is still a readable executable
  immediately before launch;
- drains stdout and stderr concurrently;
- binds stdin to `/dev/null` unless supplied;
- disables interactive pagers;
- kills the process group and direct PID on timeout;
- caps concurrent executions after the approval gate;
- validates 1-second to 24-hour timeouts, 1 KiB to 64 MiB outputs, at most 64
  argv items, and 96 KiB combined argv plus stdin.

An executable can disappear after validation but before `Process.run()`. That
launch race and the ordinary missing/unreadable/non-executable preflight all map
to the same typed tool failure: `isError: true`, `reason: "unavailable"`, and
path-free guidance to install or restore the command. The assistant-visible
message does not contain the configured path, argv, or operating-system launch
error. MacRemote retains the saved definition and sharing choice so restoring
the optional CLI is sufficient.

Complete bounded output is preserved in a `0600` spool when it cannot remain
inline. Assistant, user-only, and hidden bridge preservation contexts stay in
separate content/artifact channels so audience annotations are not flattened.

### Native File Transfer

The ten `filesystem_*` tools execute in-process and are never written to
`tools.json`. They are Not Shared on first sight. `FileTransferPathPolicy`
decides every path.

The same policy bounds process tools that run without asking
(`ConfiguredToolExecutor.requireReachablePaths`). MacRemote cannot know which
arguments a program treats as paths, so the rule is by shape: a value that is
an absolute path must be reachable, and a value with a `..` component is
refused. Every tool process starts in an empty folder that cannot be written
to (`ProcessRunner.emptyWorkingDirectory`), so any other value names nothing
outside it. Tools that ask first are not checked; the owner sees the path on
the approval card.

For the File Transfer tools:

- A path is reachable only inside a folder the owner allowed. The defaults are
  Desktop, Documents, and Downloads. The owner edits the list in Settings ›
  Security › File Transfer Folders, and the tools read the saved list on every
  call.
- Any existing folder can be added, up to the whole Mac (`/`), which the owner
  adds with **Allow Whole Mac…** after a confirmation that says what it opens.
  How far the tools reach is the owner's decision; the app's part is to make
  the choice explicit and to keep the protected locations closed.
- Protected locations are never reachable, even inside an allowed folder or
  with the whole Mac allowed: `.ssh`, `.gnupg`, `.aws`, `.azure`, `.kube`,
  `.docker`, `.cloudflared`, `.config/gh`, `.config/gcloud`, `.netrc`,
  `.npmrc`, `.pypirc`, `.codex/auth.json`, `Library/Keychains`,
  `Library/LaunchAgents`, `Library/Preferences`, and
  `Library/Application Support/MacRemote`, all under the home folder. They hold
  credentials, MacRemote's own tool registry, and places where a written file
  would later run or change what apps are trusted. The list is a floor, not a
  complete inventory of secrets: with a broad folder allowed, other files that
  hold keys (shell startup files, app settings) are readable.
- `filesystem_find` has two modes. With a folder it walks the tree with
  `getattrlistbulk`, never follows a symbolic link, and skips every entry
  whose identity is a protected location (`isProtectedEntry`). Without a
  folder it asks Spotlight, scoped to the allowed folders, and passes each
  result through `resolveUserPath` before returning it.
- Both tests compare file identity (device and inode), not spelling. Spelling
  is unreliable: the default file system ignores letter case, the boot volume
  has more than one path, and a path with a missing component cannot be
  resolved by the system. A protected folder that a call would create is
  matched by spelling, ignoring case and Unicode composition.
- A path must be absolute after a leading `~` is expanded. A path containing
  `..` is refused outright.
- Directory listings leave protected entries out. Archiving a folder that
  contains a protected folder is refused.
- `path` and `base` are checked before a call runs. A refused one ends the
  call with `reason: invalid_argument` and a message that names the reachable
  folders, so the calling model can correct itself instead of probing. The
  code `path_denied` reaches an app only in the `stdout` of
  `filesystem_download_zip`, which checks the entries of `paths` and the
  folder's contents as it makes the zip.

Reading needs no approval, so allowing a folder lets a connected app read
everything in it. `filesystem_write_file` is a Write tool and asks first. One
call carries at most 96 KiB of characters, because the server accepts requests
up to 128 KiB; a larger file is sent in parts, the first with `create` and the
rest with `append`. `filesystem_append_file` and `filesystem_replace_in_file`
are Write tools too and ask first. They edit only an existing regular file of
UTF-8 text, at most 10 MiB, with a single hard link, that the app can write,
and check the file, and for a replace that `find` appears exactly once, before
the owner is asked and again before writing. An edit holds the file and its
folder open from the moment they are checked against the path policy, and
does every later step through those descriptors, never the path: the folder
is opened refusing a link anywhere in the path, the file refusing a link in
its place, and both are compared by file identity with what the policy
approves. The new contents go to a hidden file in the held folder, readable
only by the owner while it is written, which takes on the file's permissions,
ACLs, extended attributes, and creation date, with a new modification time.
The hidden file stays open until it is renamed, and is renamed over the file
only if the path still leads to the file that was read, nothing has written
to it since, and the hidden file's name still names the file written;
otherwise the edit fails and asks for a fresh read. A failed save removes
the hidden file only while its name is still the file written. A file that
can be written but not replaced, in an append-only folder or under an access
rule that forbids deleting it or files in its folder, is refused before the
owner is asked, so no save leaves a hidden file it cannot remove. A call that
reported a timeout, for instance while it waited for another edit of the
folder, saves nothing: the save commits only if no timeout was reported, and
from then on none is. A folder in the
path swapped for a link cannot send the write outside the allowed folders,
and a failure never leaves a half-written file. Edits in one folder run one
at a time, so two edits of a file never both succeed with one lost.

`filesystem_upload_file` (D83) saves a whole file, up to 512 MiB, that an app
with the MCP files extension sends out of band; it is a Destructive tool and
asks first. Its first call carries only the file's details. Everything that
does not need the bytes is checked before the owner is asked: the file object
(id, type, size, an optional SHA-256 digest; inline `data` is refused), the
path policy, the destination (no file there unless `overwrite`, a regular file
with one hard link if there is), its folder (exists, and passes the same save
checks as an edit), and room in staging. A legacy session gets a tool error
naming Write File; a modern request that did not declare `upload` gets
`-32021`. After approval the call answers `upload_required` with one `path`
target under the MCP address, sent with `credentials: "include"`, and a
`requestState`; it never becomes a task. `FileUploadStore`
(`Services/FileUploads.swift`) holds each upload in memory for an hour,
bound to the app's client ID, the tool name, the arguments compared as JSON,
and the approved tool definition, plus the real path the first call's `path`
resolved to before the owner was asked. The transfer route takes the app's
bearer token, matches the path's token to a waiting upload of that app,
refuses two `Content-Length` headers and a body longer than approved, and
streams it to a private staging file; a repeat replaces it. The second call must match the upload (`-32602` otherwise). The
bytes must be there at their declared size and, when given, match their
SHA-256, which MacRemote computes (a tool error otherwise; the app may send
them again). Then the upload is consumed in one step and the file is saved
through the same held-folder save as the edits, a new file only if nothing
has taken its name, with the path policy and destination checked again, and
only at the path the first call resolved (a tool error otherwise, which uses
up the upload). Staged bytes are deleted when the upload is used, expires, or
the server stops, and at launch; a transfer still arriving then is cut off and
its partial file deleted. The extension is a draft. Claude sends files only to
connectors listed in its directory at one address, so it does not send them
to MacRemote today.

Read chunks (16 KiB), tree depth (5), and entry count
(2,000) are bounded. `filesystem_download_zip` invokes only `/usr/bin/tar`
with an argv array. It reads the files where they are: nothing is copied to
the temporary directory first. The sizes are added up before anything is
written, and more than 512 MiB of files is refused. Entry names a caller
supplies are passed with a `./` prefix, so `tar` cannot read one as an option.

### First-party CLI catalog

MacRemote defines 14 UI categories. Its first-party Federico Viticci layer has
six providers on two surfaces. RemCTL, NotesCTL, MailCTL, PhotoCTL, and
MusicCTL ship their own MCP servers:
MacRemote launches the server over stdio, bridges every tool it publishes, and
adds only a category, every-call defaults, and widget hints from
`FirstPartyMCPProviderCatalog`. Their signed Capability Hosts own Full Disk
Access and privacy grants, so bridged tools declare no MacRemote permission
requirement and MacRemote never presents itself, a launcher, or an interpreter
as a permission target for them. The sixth, Apple Frames, is a process catalog
of 5 dedicated Fixed Commands and one Flexible Command. DESIGN-SPEC D88 removed
the Alexandria, HabitCTL, PocketCTL, OverCTL, GoodLinksCTL, and Iris catalogs;
their saved tools stay ordinary process tools, and a launch step run once
removes any Always Allow on a saved Flexible Command for those CLIs, which lost
its argument rules. Matter and Readwise remain generic third-party discoveries.

MusicCTL's protected MusicKit, Keychain, and Music.app operations go through
its signed Capability Host (role `capability-host`, scope
`music-app+musickit+keychain`, no network proxy); PhotoCTL's Photos access goes
through its own. `musicctl_new_releases` scans the complete cloud library and
keeps a 3,600-second timeout.

Exactly 3 process-catalog definitions ship with `approvalPolicy: everyCall`:
the Apple Frames Flexible Command and Apple Frames image and video rendering. The provider table applies
the same default to 14 bridged tools: `remctl_run`, `remctl_delete_reminder`,
`notesctl_run`, `notesctl_add_content`, `notesctl_apply_edit`,
`notesctl_remove_tags`, `notesctl_trash`, `mailctl_run`, `mailctl_archive`,
`mailctl_move`, `mailctl_rule_set_enabled`, `photoctl_run`, `musicctl_run`,
and `musicctl_rating_clear`. Any other tool a first-party server marks
destructive gets the same default, so a new destructive tool is guarded the day
a CLI adds it (on the CLI versions installed on 2026-11-25 that adds
`notesctl_apply_batch`). PhotoCTL's server marks `photoctl_run` read-only;
a tool the provider asks about on every call is served as a write, because a
read-only tool runs without asking. This remains a grantable risk marker, not
a permanent denial.

An added provider re-imports itself when its import stamp changes: the
provider's policy revision, raised by hand when MacRemote's policy for it
changes, and its executable's stat line (DESIGN-SPEC D86). Its tools still
naming a path the CLI moved from also make it due. That import starts the
server once to read `tools/list` and runs no tool; it never imports a CLI the
owner did not add. It never shares a tool the owner did not already share:
every tool new to the owner starts Not Shared, whatever the transaction finds.
Each import carries an intent (`AppModel.MCPImportIntent`): only `.add`, the
owner pressing Add or Import, shares the tools of a family the owner does not
have, and an `.update` or `.automatic` import whose family is gone when it
commits changes nothing. Two waiting jobs for one provider merge into the
stronger intent, and only the owner's Add is `.add`. A refresh frees an
existing id only for the upstream tool that held it (or a carried-over legacy
tool), so a different tool whose name maps to a retired id gets a fresh id and
starts Not Shared instead of keeping the retired tool's sharing. Like every refresh of an existing
family, it removes dropped tools with their grants, a tool whose security
fingerprint changed loses Always Allow, and a shared tool that asked first and
is now described as read-only goes Not Shared. A failed import saves nothing
and is tried again on the next launch or activation, once each; the
five-second activation guard skips only the rescan, and an activation during a
manual scan runs the check when the scan ends. The same transaction
carries the tools of MacRemote's retired RemCTL (9), NotesCTL (19), and
MusicCTL (16) process catalogs over to the provider's bridged tools of the
same ids, but only rows still as that catalog installed them (an executable
that catalog ran, `legacyExecutableNames`, and the same invocation arguments
and constraints for the id, or for the Flexible Command the same `{args}`
pattern, `legacyInvocationFingerprints`), and
only ids a bridged tool actually takes. A row the owner edited keeps its id,
command, and sharing, so a restriction the owner added is never traded for
the server's tool, which gets a fresh id and starts Not Shared. Each carried
tool keeps its Shared or Not Shared choice, and its Always Allow stops
applying because the bridged definition has a different fingerprint. When a
bridged tool of the same provider holds a suffixed id only because a legacy
row held the plain one, it moves to the plain id in that transaction and the
legacy row goes (D87): the moved tool keeps its own sharing and permission
epoch, the suffixed id's grants are removed, and since the tool id is
fingerprint material no Always Allow applies to the moved tool. An unedited
legacy row that no incoming tool takes is removed only when it is Not Shared,
which no app can call; a shared one stays exactly as it was, and a failed
import removes nothing. Until that import succeeds, a legacy `musicctl_run`
process tool keeps MusicCTL's Flexible Command blocks (authentication setup,
configuration writes, onboarding, raw requests, private-key inputs). A legacy
`remctl_run` or `notesctl_run` has no argument blocks (D61 removed NotesCTL's
and RemCTL had none); it is Destructive and asks on every call by default; an Always Allow the owner already granted for it still applies until the carry-over replaces it. A legacy row whose executable still exists carries over only when it is the detected CLI's own file, so a same-named wrapper keeps its definition and sharing, and a leftover whose twin the server lists but MacRemote skips is never removed.

The synthesized first-party candidate is owned by its provider
(`first_party.<provider id>`), not by its executable path, so a CLI that moves
keeps its family instead of losing it as an orphan; owners saved by earlier
builds (`first_party.<server>.<path hash>`) map to the same key. Only MacRemote
writes the `first_party` source. The exact executable stays in the runtime
identity and the approval fingerprint, so the import from the new path drops
Always Allow. Each queued import re-resolves the installed executable when it
starts, so an Update after a move lists the new path. A config row from
another app folds into the candidate, and so can be adopted, only when it
launches the same server: it sets no `env`, and its arguments are the
provider's serve arguments, give or take one `--client <label>` pair. Any
other row may run the same file against other data, so it stays a separate
server. Adoption also checks the family's saved launch with the same rule,
because the config row may have changed since the import: a family saved with
an override keeps its ids and sharing after the row drops it, and the
provider's own tools start Not Shared with fresh ids. The set that passes is
both the ids handed on and what the replace removes. MusicCTL is detected by `musicctl` alone: MailCTL installs an
`mctl` too, and a name that can start either CLI must not decide whose tools
and policy MacRemote applies.

A replace writes the Not Shared list, covering both the old and the new tools,
before it saves the tools file, which records the new tools' fingerprints as
seen. If MacRemote stops between the two writes, the next launch finds every
new tool already Not Shared.

A complete provider **Update from Catalog** is authoritative for that provider's
stable ID prefix. It refreshes retained IDs, adds missing current definitions,
and retires obsolete provider-owned IDs. It can also adopt one unique exact
scanner-provenance equivalent when no stable row exists and both the saved row
and current preset are unambiguous. Adoption replaces the scan ID with the
stable catalog ID, creates a fresh permission epoch, clears grants under both
identities, and transfers the sharing state. An ordinary Add never adopts.
Hand-authored or ambiguous signature matches remain untouched. Retirement
removes the obsolete row's sharing state, invalid-state record, and grants
without affecting unrelated tools.

### Imported MCP bridges

HTTP and stdio MCP servers can be imported as ordinary MacRemote tools. Secrets
are referenced from environment or supported config fields and resolved at
call time; secret-looking literal headers are not copied into the registry.
The remote client sees only MacRemote's authenticated tool, never the upstream
endpoint, process, credentials, or whole upstream catalog.

The bridge probes modern `server/discover` first and applies the safe dual-era
fallback described above. A modern call uses per-request metadata and validated
header mirrors. A legacy HTTP bridge keeps its returned session ID; a legacy
stdio bridge initializes, calls the selected tool, and terminates the child.
A tool call uses that tool's timeout (60 seconds for an imported tool unless
its policy sets another). Listing a server's tools (a probe) has its own
default of 20 seconds, or the startup timeout its config sets. Neither is a
global execution maximum.

When a modern upstream declares the Skills extension, the import, check, or
refresh probe also reads its skills on the same connection
(`MCPUpstreamSkillCollector`), and an import saves them in
`bridged-skills.json` next to the tool store. They leave with the server's tools.
The skills read has its own short deadline after the tools, so a slow or
failing `skills/list` costs only the skills, never the import.

Bridge normalization prefers upstream `structuredContent`, otherwise a sole
assistant-visible text block, otherwise the assistant-visible content array.
User-only content never enters unannotated stdout. Distinct annotated and
multimodal blocks remain real outer MCP content. Upstream metadata is placed in
collision-safe MacRemote namespaces. Upstream `isError` maps to a failed
execution without discarding semantic payloads.

### Upstream sign-in (OAuth) for imported HTTP servers

A local HTTP MCP server may protect itself with OAuth instead of a static
token; Paste 2.x does. MacRemote then acts as an OAuth client of that server
(D62). The flow follows RFC 9728 (protected resource metadata), RFC 8414
(authorization server metadata), RFC 7591 (dynamic client registration), RFC
7636 (PKCE, S256 only), RFC 8707 (the `resource` indicator), and RFC 8252
(a loopback redirect on `127.0.0.1` with a system-chosen port).

Invariants:

- Sign-in endpoints must be HTTPS, or plain HTTP only on a loopback host.
  MacRemote never sends a code or token in the clear to another machine. The
  check runs when metadata is read and again whenever a stored endpoint is
  used.
- Authorization server metadata must name the issuer it was fetched for, and
  a protected-resource document for another origin is ignored.
- Callers that find the same expired token share one refresh, so a refresh
  token is never presented twice.
- The reply listener exists only for one attempt, answers exactly one
  `GET /callback`, checks `state` before anything else, and closes. Any other
  request gets a static page and never completes a sign-in.
- MacRemote registers as a public client with `token_endpoint_auth_method:
  none` and the exact redirect URI it is listening on. It never asks for or
  stores a client secret.
- Tokens live in one Keychain item per server URL (service
  `MacRemote.upstream-mcp-oauth`). They never enter `tools.json`, logs,
  approval screens, security fingerprints, or runtime identities; the bridge
  header records only the kind `oauth`.
- A 401 on a bridged call triggers one refresh when the server issued a
  refresh token. When there is none, or the server refuses it, the token is
  forgotten and the call fails with a sentence that points at MacRemote ›
  Tools. A refresh that fails because the server or the network did leaves
  the sign-in in place. The remote app never learns the
  upstream endpoint or that a token existed.
- Sign Out revokes through `revocation_endpoint` when the server offers one,
  then forgets the token.
- The credential binding is part of the security fingerprint, so a family that
  moves from a manifest token to MacRemote's sign-in asks for Always Allow
  again.

### Discovery and stable authority

The app uses a schema-generic scanner for common local agent configurations.
Passive launch/activation discovery reads
configuration only; it does not launch a process, probe a URL, import a server,
or share a tool. Its cache contains hashed identities and a config fingerprint,
not endpoint URLs or secrets.

A manual scan (`LocalMCPScanner.scan`) asks only servers that are already
running, which means HTTP servers. A stdio server is a command line from
another app's config file. Launching every one because the owner pressed Scan
would run code they never chose, with MacRemote's own privacy grants. A stdio
server is launched only when the owner imports or checks that server.

The scanner deduplicates only an exact canonical runtime contract. HTTP identity
covers the complete URL plus credential-safe header bindings. Stdio identity
covers the exact command, full argv, startup timeout, and credential-safe
environment bindings. Literal secrets contribute only through a digest; sourced
credentials contribute their binding locator, not the resolved value. Exact
duplicates declared by Codex, Claude, or another supported config merge all
configuration owners. Different argv, endpoints, headers, environments, or auth
profiles remain separate imports.

Manual import is the authority boundary. Refresh preserves semantic IDs,
sharing state, and permission epochs for matching upstream tools. A changed
security fingerprint asks again. A server describes its own tools, so one
relabeling is not trusted: when a shared tool that asked first comes back
labeled read-only, it becomes Not Shared until the owner reviews it
(`replaceLocalMCPBridgeTools`). Reconciliation removes a config-owned family
only when every readable, non-manual owner is absent; one remaining owner keeps
it, and an unreadable owner fails closed and preserves it. Probe failure does
not prove that an offline configured server was removed. Direct URLs,
runtime-only Claude rows, and manual imports are not deletion evidence.

The supported source set is explicit in `MCPConfigLocator`: known config files
plus Claude Extension `manifest.json` files. MacRemote does not crawl general
Codex or Claude plugin registries. The one exception is the skills scanner
(D84): `FoundSkillScanner` reads `SKILL.md` and `references/*.md` from
`~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills`, and the newest version
of each plugin under `~/.claude/plugins/cache`, only for skills that match a
tool family MacRemote already has.

Sharing follows the tool the owner last saw. Each time the app saves
`tools.json`, it also records every tool's security fingerprint in its
preferences. At launch, a saved tool whose fingerprint is not on record, because
the row was added or changed by a hand edit, another program, or a file copied
from another Mac, starts Not Shared and Activity names it. When the preferences
are missing, every saved tool starts Not Shared, because the list of Not Shared
tools was lost with them.

Semantic tool IDs are stable across persistence, permission lookup, runtime
dispatch, and Apps actions. An Always Allow grant is keyed by:

`(clientTrustID, semanticToolID, securityFingerprint)`.

The fingerprint covers executable or backend authority, argv and validation
contract, capability, approval policy, timeout, output limit, permission
requirements, credential binding, and permission epoch. It excludes tokens,
sessions, issuers, resources, and cosmetic copy. The approval screen captures
the fingerprint and MacRemote checks it again before saving a grant and before
execution. Editing authority asks again; deleting and recreating a tool cannot
inherit the prior epoch.

## Authorization Design

MacRemote is both the MCP resource server and its OAuth authorization server.
Single Header bypasses the browser flow but is still validated by MacRemote.

### OAuth flow

1. An unauthenticated request receives a `401` challenge with RFC 9728
   protected-resource metadata and `mcp:tools`.
2. The client discovers MacRemote's authorization-server metadata.
3. The client uses a preconfigured credential or DCR.
4. It starts authorization code flow with S256 PKCE and the MCP `resource`.
5. MacRemote creates a pending request; only the host app can approve it. See
   [Sign-in approval](#sign-in-approval).
6. The authorization response returns a one-time code and `iss`.
7. The client exchanges the code, verifier, and identical `resource`.
8. Access and refresh tokens remain bound to the approved client, issuer,
   resource, redirect URI, scope, and tool policy.

Authorization codes expire within two minutes and are single use. Access tokens
default to 15 minutes; refresh tokens default to 24 hours and rotate on use.
Settings can change those defaults for newly issued tokens. Token and
registration records are bounded and expired state is pruned.

### Token rotation and sign-in methods

- Each refresh returns a new refresh token and the old one stops working. The
  exchange is one locked step (`issueTokensLocked`), so a second request
  cannot land between removing the old token and storing the new one.
- Every token records the approved sign-in it came from, and a refresh token
  starts with that sign-in's random ID. A refresh token that is not current but
  names a sign-in that still has tokens, or is the one a current token
  replaced, was used before. Every access and refresh token of that sign-in is
  revoked (`revokeSignInLocked`), both holders must sign in again, and
  `AppModel.handleRefreshTokenReuse` writes one Activity line. No list of used
  tokens is kept, so the saved file does not grow with each refresh.
- A used token presented again within `OAuthCoordinator.refreshRetryGrace`
  (60 seconds) is a retry: it passes the same checks and gets the same reply.
  The reply is held in memory only. After a relaunch a retry inside the window
  is refused without revoking anything.
- Tokens saved before sign-ins were tracked get one sign-in ID per app when
  they load. Such a refresh token has no ID inside it, so it is recognized as
  used only until the token that replaced it is itself replaced.
- One sign-in method is accepted at a time
  (`AppModel.currentOAuthClientAuthenticationPolicy`). Dynamic OAuth admits
  apps that register themselves and refuses the owner's client IDs. OAuth
  Client Secret admits only those client IDs. Single Header admits only the
  header token: no registration and no client ID. Changing the method
  (`signOutOtherSignInMethods`) signs out every app the new method does not
  admit, with its tokens, waiting calls, and Always Allow rules, and Settings
  states what was removed. An app connected under another method by an earlier
  build stays connected until the method is next changed.
- A client record is written to disk only once the owner approves one of its
  sign-ins (`approvedClientIDs`). Until then it lives in memory, and it is
  removed when its last waiting sign-in is denied or expires
  (`forgetClientIfNeverApprovedLocked`).
- An app that returns with a client ID this Mac issued but no longer has, and
  a web return address, is given a new record (`recoverDynamicClient`) under
  the same rule. Such an app kept its ID and cannot see the refusal, which
  happens in the browser, so without this it could never ask again.

The `WWW-Authenticate` challenge, protected-resource metadata, authorization
metadata, registration, and token responses use the required no-cache policy.
Invalid bearer tokens receive RFC 6750 `error="invalid_token"` so a client can
refresh instead of restarting authorization.

### Sign-in approval

`/register` and `/authorize` need no sign-in, so anyone who knows the public
address can start a sign-in and give the app any name. The name proves nothing.
MacRemote therefore ties the request on the Mac to the person who started it:

- The browser page of whoever started the sign-in shows a six-digit code
  derived from the random request ID (`ApprovalRequest.verificationCode`). The
  approval card on the Mac shows the same code and the destination the sign-in
  returns to: the host of a web address, or the scheme of an app link. The
  owner approves only when the code on their own sign-in page matches.
- An app name is untrusted text. `sanitizeClientName` keeps letters, digits,
  spaces, and plain punctuation, drops control and invisible characters and
  symbols such as a check mark, and cuts the name to 60 characters. A name
  recovered for an app that registered none (`recoveredClientName`) is
  cosmetic and changes no decision.
- Pending sign-ins are capped at 2 for one client ID and 16 in total. The caps
  are checked before anything is stored, so a refused request leaves no client
  record behind. A request expires after 5 minutes and then leaves the queue,
  the Dock badge, and the menu bar count without waiting for another request
  to arrive.
- Every return address is validated before use: HTTPS, loopback HTTP, or a
  private-use app scheme, with no user information or fragment. This includes
  OAuth Client Secret apps, whose address is not registered in advance,
  because the sign-in page navigates to it. A refusal is sent back only to a
  web address.
- An OAuth Client Secret app has no bound return address until its first
  sign-in completes with the secret. After that only the bound address is
  accepted, because `/authorize` cannot check the secret.
- Switching the sign-in method signs out every app the new method does not
  admit. See
  [Token rotation and sign-in methods](#token-rotation-and-sign-in-methods).

### DCR, RFC 9207, and CIMD

The 2026-07-28 MCP specification prefers Client ID Metadata Documents and
deprecates DCR for new deployments. MacRemote deliberately keeps DCR because
ChatGPT uses it whenever a server does not advertise CIMD. It does **not**
advertise CIMD or fetch a client document.

That deferral is explicit rather than accidental. Accepting a URL as a client ID
would add server-side metadata fetching, redirects, DNS and address validation,
document integrity, cache, and TOCTOU rules to a component that can reach local
resources. Claiming CIMD without those SSRF and metadata-substitution defenses
would weaken the authorization boundary. CIMD remains a standards `SHOULD` to
implement after that fetch-and-validation design exists; DCR is the tested
compatibility path today.

One published identity works without a fetch. Claude's "Add custom connector"
dialog offers **Use Claude's published identity** and can send that client ID
to a server that does not advertise CIMD. `Services/PublishedOAuthClient.swift`
carries the contents of Claude's document, and
`OAuthCoordinator.publishedClientLocked` accepts the exact ID
`https://claude.ai/oauth/mcp-oauth-client-metadata` with the document's one
return address. Any other web-address client ID gets `Unknown client_id.` The
record is a public client with its own trust ID
(`macremote-published-…`), kept in memory until the owner approves, like a
registration.

A sign-in request MacRemote refuses never reaches the approval window. A
browser gets a short page that says so, anything else gets the standard OAuth
error, and Activity records `Refused a sign-in request: …`.

DCR registers a public client when `token_endpoint_auth_method` is `none` or
left out. An app that asks for `client_secret_basic` or `client_secret_post`
gets a secret of its own, shown once and kept as a hash; Claude registers this
way. Either kind is an app that registered itself. A client ID and secret the
owner created is a different sign-in method and is refused under Dynamic
OAuth. Modern clients
must send `application_type` as `native` or `web`; `web` redirects must be
hosted HTTPS URLs. MacRemote still accepts an omitted `application_type` as a
narrow compatibility path for DCR clients predating 2026-07-28. A registration
with a secret of its own must authenticate with the Basic or POST method it
registered with.

MacRemote advertises
`authorization_response_iss_parameter_supported: true` and includes exact
`iss` on successful and error authorization redirects. This implements the
authorization-server side of RFC 9207 mix-up defense. Clients must compare it
as an exact string to the issuer recorded from validated discovery before
redeeming the code. Client credentials are issuer-bound and must not be reused
if that issuer changes.

PKCE is S256-only. The verifier is validated as 43–128 unreserved characters
before challenge comparison. `resource` is required through authorization and
token exchange, and access tokens are accepted only for the current canonical
MCP resource aliases. This prevents a token issued for another resource or
public origin from becoming a MacRemote bearer.

Proof-of-possession is deferred in the same explicit way. MacRemote's access
tokens are audience- and issuer-bound but not sender-bound: it does not implement
or advertise DPoP (RFC 9449), and it adds no
`dpop_signing_alg_values_supported`, no `DPoP` challenge, and no `token_type`
change. Mutual-TLS certificate binding (RFC 8705) is out of scope rather than
future work, because Cloudflare terminates client TLS at its edge and MacRemote
never observes the handshake; an edge-injected certificate header would only
substitute a proxy header for a cryptographic binding. Every client MacRemote
supports sends `Authorization: Bearer`, and RFC 9449 §7.2 requires a resource
server to reject a bound token presented as a bearer, so adopting proof-binding
today would break all of them at once. Short access-token lifetimes, rotating
refresh tokens, Mac-side approval, and immediate local revocation remain the
answer to token theft. One invariant follows regardless: `Bearer` must remain the
first scheme in the `WWW-Authenticate` challenge, because a widely embedded
client challenge parser returns nothing when it is not, silently losing
`resource_metadata` discovery. The full analysis, including the threshold for
revisiting it, is in `docs/THREAT_MODEL.md`.

## Approval, Privacy, Audit, and Revocation

### Tool-call approval

`ToolDefinition.asksBeforeRunning` decides whether a call needs the owner. It is
true for Write and Destructive tools and for every Flexible Command. A Flexible
Command passes any arguments through to its program, so nothing can check that
it only reads; a Read-only label on one would mean "runs anything, unasked".
Every other Read-only tool runs after authentication without asking. The same
property decides the Asks First label and the `readOnlyHint` annotation.

A call that asks first needs a host decision unless the connected app has an
exact Always Allow grant. `approvalPolicy: everyCall` is a risk marker, not a
wall: it is the shipped default for the 12 process-catalog tools and the 14
bridged tools enumerated above, and for any tool a first-party MCP server marks
destructive; it drives a heavier consent step before a grant is written, and it is
fingerprint material. An explicit owner grant, made per tool or through Allow
All Current Tools, overrides it and the runtime honors it. Revoking that grant
restores per-call prompting. A denial or expiry returns
`reason: "not_approved"` and never reaches the backend.

The order is fixed:

1. **Validate** (`ToolExecuting.validate`). Invalid arguments, a command a
   first-party policy blocks, and a path File Transfer refuses fail here as a
   normal tool error. The owner is asked only about a call that can run.
   Bridged MCP tools are not validated here; the upstream server owns their
   argument rules.
2. **Check the grant, then ask.** The request records the tool's security
   fingerprint, and execution checks it again.
3. **Wait for a slot and run.**

What the owner approves is what runs:

- The approval card shows every argument in full, in the form the tool will
  receive, including standard input (`ToolCallApprovalArgument`,
  `ApprovalArgumentList`). Each value sits in its own box and the list scrolls
  instead of shortening anything. Control and invisible characters are written
  as `\u{...}`, so a carriage return or a right-to-left override cannot
  disguise a command. A list of command-line items is quoted so `["a b"]` and
  `["a", "b"]` never look the same.
- No surface approves without showing the arguments. A notification banner
  offers Deny only; any other response opens the request. The menu bar item
  opens the Approval window. There is no "approve all".
- The Requests menu shortcuts act only on the request the Approval window is
  showing (`presentedPendingInterrupt`), never on one waiting behind it. Always
  Allow from the menu is unavailable for tools that ask every time, because
  their confirmation step exists only on the card.
- A call waits 90 seconds for the owner. A synchronous call must finish within
  the effective timeout of the public link and the app (Cloudflare's current
  default proxy read timeout is 125 seconds, and apps may give up sooner), so a
  longer wait would let the owner approve a call whose app has already been
  told it failed.
- One app can have 4 calls waiting and all apps 16
  (`ToolCallApprovalCoordinator`). A call over the cap fails with
  `reason: "unavailable"`.
- When the app disconnects, its waiting request is withdrawn.

### Permissions

Permission requirements are per tool. Full Disk Access, Reminders, Screen
Recording, Accessibility, Automation, Speech Recognition, and Local Network are
separate facts. Server startup fails when a currently shared tool is missing a
declared required permission.

macOS gives a command-line tool the access of the app that started it. The
tools MacRemote starts can therefore read protected data exactly when MacRemote
can, and MacRemote.app is the only Full Disk Access item the app names
(`FullDiskAccessService`). It does not list tool executables or script
interpreters: adding an interpreter would give Full Disk Access to every script
on the Mac. The app tests access by reading a protected folder itself. When no
such folder exists on the account, or the app is not running from an app
bundle, it reports that it could not test and asks the owner to confirm,
rather than claim a check passed.

Bridged RemCTL, NotesCTL, and MailCTL tools declare no requirement at all: their signed
Capability Hosts own the grants, and their own `doctor` commands diagnose them.

### Audit

Sensitive audit events include:

- local server and Cloudflare public-link lifecycle;
- OAuth request, approval, denial, expiry, token issue, refresh, and revocation;
- tool request, approval result, process exit, duration, and truncation;
- a tool that started Not Shared because it changed outside the app or was
  relabeled by its server;
- artifact staging and purge.

Logs do not contain bearer tokens, authorization codes, client secrets, refresh
tokens, artifact capability tokens, upload targets or `requestState` handles,
or full command output by default.

Every tool-call authorization decision additionally emits one structured line
to the unified log (subsystem `com.macstories.MacRemote`, category
`approvals`) and to a small ring buffer persisted beside `tools.json`
(`approval-decisions.json`, newest 200), so "why did this call prompt?" stays
answerable after a relaunch. A record carries the tool ID, a prefix of the
client trust ID, capability, approval policy, the decision source (read-only,
always-allow grant, user approved, user denied, gate unavailable), and whether
the grant store matched — never tokens, argv, or outputs.

### Revocation

The user can stop the local server, disable the public link, sign out one app or
every app, rotate individual configured credentials, rotate or delete the Single
Header token, and rotate the MacRemote instance ID. Instance rotation stops
exposure and clears OAuth grants and persistent tool permissions.

Signing out one app removes an exact, enumerated set: its client registration,
its authorization records, every access token and every refresh token issued to
it, every tool call of its own still waiting for a decision, and every Always
Allow rule bound to its trust ID. Each of those is selected by client ID and
registration-scoped OAuth trust ID only. A display name is never used to select what to
remove, so two registrations that both call themselves "Claude" cannot cancel
each other's work or clear each other's rules; signing out one leaves the other's
tokens, authorizations, and rules untouched. A configured credential that is
replaced or deleted performs the same scoped cleanup, including the pending calls
that can no longer be authorized. The reported result is measured from the
revocation itself rather than from the UI's prior snapshot, so the counts the
user sees are the counts that changed. Signing out every app is the same
operation applied across the board, plus the client registrations that were never
approved and therefore never appeared in the app list.

The app list states what is verifiable and nothing more: whether the app holds a
live token (active), is approved and mid-sign-in, or has an expired sign-in, plus
when it first connected and when it last connected. MacRemote has no device
identity, no location, and no presence signal for a connected app, and does not
render one.

## Current Shipped Scope

The shipped architecture includes:

- local loopback MCP and the app-managed Cloudflare public link;
- an optional managed Cloudflare helper: a build-pinned, checksum- and
  signature-verified download installed into an owner-only app-support directory,
  re-verified before every launch, preferred over an externally installed copy,
  and removable without touching one the user installed;
- Dynamic OAuth/DCR as the default sign-in, with OAuth Client Secret and Single
  Header as explicitly selected advanced methods;
- dual-era MCP with modern `2026-07-28` and three legacy revisions;
- modern discovery, request metadata, header mirrors, cache fields,
  `resultType`, final error allocation, version renegotiation for a client that
  names a revision MacRemote does not implement, and current-base server
  identity;
- capability-scoped universal MCP Apps linkage through the v7 safe semantic
  renderer, with tested visible-only copy, audience filtering, error,
  artifact, and multimodal presentation plus legacy compatibility metadata;
- process tools, native File Transfer limited to allowed folders, and imported
  HTTP/stdio MCP tools;
- the global 14-category catalog and the six-provider Federico layer: five
  bridged MCP servers that re-import themselves when their CLI changes, plus a
  process catalog of 5 dedicated tools and one Flexible Command, guarded
  provider reconciliation, and the narrow scanner-provenance adoption rule;
- stable permission identities, Mac-side approvals that show full arguments,
  sign-in codes, per-caller rate limits, execution limits, and artifact quotas.

This is an implementation claim, not a claim of complete support for every MCP
Apps host, plugin publication, or third-party marketplace approval.

## Sources

- [MCP 2026-07-28 changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog)
- [MCP versioning and dual-era compatibility](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning)
- [MCP Streamable HTTP transport](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http)
- [MCP authorization](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)
- [SEP-2243 HTTP header standardization](https://modelcontextprotocol.io/seps/2243-http-standardization)
- [MCP Apps overview](https://modelcontextprotocol.io/extensions/apps/overview)
- [MCP Apps specification repository](https://github.com/modelcontextprotocol/ext-apps)
- [OAuth Authorization Server Issuer Identification, RFC 9207](https://www.rfc-editor.org/rfc/rfc9207)
- [OAuth Protected Resource Metadata, RFC 9728](https://www.rfc-editor.org/rfc/rfc9728)
- [OAuth Resource Indicators, RFC 8707](https://www.rfc-editor.org/rfc/rfc8707)
- [OAuth Dynamic Client Registration, RFC 7591](https://www.rfc-editor.org/rfc/rfc7591)
- [OAuth Client ID Metadata Documents draft](https://datatracker.ietf.org/doc/draft-ietf-oauth-client-id-metadata-document/)
- [OAuth Demonstrating Proof of Possession (DPoP), RFC 9449](https://www.rfc-editor.org/rfc/rfc9449) — not implemented; see the deferral above
- [OAuth Mutual-TLS Client Authentication and Certificate-Bound Access Tokens, RFC 8705](https://www.rfc-editor.org/rfc/rfc8705) — out of scope behind the Cloudflare edge
- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [Cloudflare Configuration Rules](https://developers.cloudflare.com/rules/configuration-rules/)
- [OpenAI plugin authentication](https://developers.openai.com/plugins/build/auth)

Catalog presentation may set `automatic: false` for intermediate lookups and
diagnostics. These tools retain complete text and structured results without
automatically opening a card. See `docs/design/MCP-UI-SPEC.md`.
