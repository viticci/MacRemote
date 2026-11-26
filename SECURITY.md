# Security

MacRemote exposes local Mac tools to remote MCP clients. Treat every change to
auth, tunnel handling, tool serialization, process execution, approval policy,
or logging as security-sensitive.

This page lists the rules. The mechanisms are in
[docs/ARCHITECTURE_SECURITY.md](docs/ARCHITECTURE_SECURITY.md), the reasoning is
in [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md), and the first-party CLI
contract is in [docs/FEDERICO_CLI_TOOLS.md](docs/FEDERICO_CLI_TOOLS.md).

## Reporting

For private security reports, contact the repository owner directly. Do not file
public issues with secrets, tunnel URLs, OAuth tokens, or local command output.

## Security Model

- The local MCP server binds to `127.0.0.1`.
- The product connection paths are Local and the app-managed Cloudflare public
  link. The public MCP URL ends in `/mcp`; its hostname can be temporary or a
  user-owned Cloudflare custom domain. Cloudflare transports requests but does
  not authorize them.
- MacRemote reports which `cloudflared` serves the public link: its own managed
  helper or one the user installed. It never claims to manage an external
  install. The managed copy is fetched only when the user asks for it, over
  HTTPS from a compile-time-pinned URL, following at most five redirects
  confined to `github.com`, `release-assets.githubusercontent.com`, and
  `objects.githubusercontent.com`, under a hard byte cap. Extraction is
  in-process and single-entry USTAR: symlinks, hard links, directories, path
  traversal, PAX and GNU extensions, and any second entry are rejected. The
  archive digest, the executable SHA-256 and byte count, and a
  `Developer ID Application: Cloudflare Inc.` team match are all checked against
  a built-in manifest that is never refreshed over the network. The manifest
  also lists the executable digests of earlier MacRemote releases, so a helper
  one of them installed keeps working until the owner updates it. An
  external `cloudflared` is looked up in Homebrew and system folders before
  folders inside the home folder.
- The managed helper is re-verified before every launch, keyed on inode, mtime,
  and size. A copy that fails verification is quarantined rather than executed,
  and MacRemote falls back to an external `cloudflared` or to none. Its
  directory is owner-only, sits inside a folder File Transfer never reaches, and
  stays outside the executable search path. Removing the helper deletes only
  MacRemote's own files and is refused while a public link is live.
- Quitting MacRemote stops the helper on every quit path. If MacRemote crashes
  or is force-quit, a small tether process stops the helper at once. A helper
  that still outlives the app is stopped at the next launch, after its process
  ID, start time, and executable path are matched against the saved record.
- Dynamic OAuth is MacRemote's default and the method a fresh install uses.
  OAuth Client Secret and Single Header are Advanced choices for apps that
  cannot self-register, are selected explicitly, and have their credentials
  generated only on selection. Selecting a different app never changes the
  method. All three are enforced by MacRemote's own server; none is gated at the
  tunnel edge.
- OAuth client-secret mode disables dynamic client registration and requires
  `client_secret_basic` or `client_secret_post` before token issuance.
- One sign-in method is accepted at a time. Changing it signs out every app the
  new method does not admit, with its tokens, and stops the Single Header
  token. Client IDs and secrets you created sign in only under OAuth Client
  Secret.
- A refresh token is replaced each time it is used. A used one presented again
  more than a minute later revokes every token from that sign-in, and Activity
  names the app.
- An app you never approved is not written to disk, and its record is dropped
  when its last waiting sign-in is denied or expires.
- Dynamic OAuth keeps DCR as a compatibility registration path. It validates
  DCR metadata, hosted HTTPS/loopback/private-use redirects, the exact
  `mcp:tools` scope, and an authorization-code flow with S256 PKCE.
  `application_type`, when present, must be `native` or `web`; `web` clients
  require HTTPS redirects. Omission remains accepted for legacy MCP clients.
  Registered clients and token hashes persist; token responses are
  non-cacheable. ChatGPT's custom MCP server connection uses this Dynamic
  OAuth/DCR path.
- Authorization-server metadata advertises RFC 9207 issuer identification.
  Authorization success and error redirects both include `iss`, and OAuth
  grants, codes, and tokens remain bound to the exact issuer and MCP resource.
- MacRemote does not advertise Client Identifier Metadata Document (CIMD)
  support. CIMD is a protocol SHOULD, not a MUST, and implementing it as an
  ordinary URL fetch would add an SSRF and DNS-rebinding boundary to the
  authorization server. Safe future support requires a pinned-public-IP TLS
  fetch with private and loopback targets rejected, redirects forbidden or
  independently revalidated, strict time/size/content limits, exact
  client-document URL and redirect-URI membership checks, authentication-method
  restrictions, and bounded cache/revocation behavior. DCR remains the
  compatibility path until those controls exist.
- One published client ID is accepted without any fetch. Claude's connector
  dialog can send its published identity
  (`https://claude.ai/oauth/mcp-oauth-client-metadata`) to a server that does
  not advertise CIMD. MacRemote carries that document's contents
  (`Services/PublishedOAuthClient.swift`) and accepts that exact ID only with
  the document's one return address. Every other web-address client ID is
  refused. The ID names the app, not a person: each sign-in still needs
  approval on the Mac.
- Proof-of-possession tokens are deferred for the same reason. MacRemote's
  bearer tokens remain bearer tokens: DPoP (RFC 9449) and mutual-TLS
  client-certificate binding (RFC 8705) are neither advertised nor accepted, and
  a partial implementation would be worse than none because it would suggest a
  binding that is not enforced. Safe future support requires nonce issuance with
  a replay window, proof binding at the token endpoint and on every MCP request,
  a JWK thumbprint carried through refresh rotation, bounded clock skew, and no
  downgrade path for a client that already bound its tokens. Until then, host
  approval, issuer/resource binding, and per-call approval remain the controls.
- Single Header is a generic sign-in method. Its generated bearer must be stored
  outside source, checked-in profiles, logs, and support exports.
- A leaked URL alone must not authorize tool calls.
- OAuth modes require PKCE and host-side approval before token issuance.
- Anyone who knows the public address can start a sign-in under any name. The
  sign-in page and the Mac's approval card both show the same six-digit code
  and the card shows where the sign-in returns to. The owner approves only when
  the codes match. App names are reduced to plain text, pending sign-ins are
  capped and expire, and a Client Secret app's return address stays bound after
  its first completed sign-in. See
  [Sign-in approval](docs/ARCHITECTURE_SECURITY.md#sign-in-approval).
- Switching to OAuth Client Secret signs out every app that registered itself
  without a client secret.
- Tool calls require a valid bearer token bound to the approved resource.
- A request's `Host` must name this Mac's loopback address on the server's port
  or the current public host; anything else receives `421`. This stops DNS
  rebinding from a browser page, and it also refuses a port forward or tunnel
  that MacRemote did not start.
- The Cloudflare API token is never saved. After a Your Domain deploy,
  MacRemote keeps only that tunnel's run token in the Keychain so **Go Public**
  can restart it. The run token cannot change DNS or create tunnels, and
  changing the domain or subdomain deletes it.
- Authentication runs before MCP method dispatch. An unauthenticated GET or
  DELETE receives a `401` OAuth discovery challenge; an authenticated
  unsupported method receives `405`.
- Browser CORS reflects only exact allowed origins, never `*`. Trusted ChatGPT
  origins are accepted only on requests whose canonical MCP base is public;
  direct loopback requests do not gain access by sending a ChatGPT `Origin`.
- The current MCP core is `2026-07-28`. Modern requests are stateless and carry
  required protocol version and client capabilities plus optional client
  information in per-request `_meta`, with matching `MCP-Protocol-Version` and
  `Mcp-Method` HTTP headers.
  Methods with a semantic target also require `Mcp-Name`; schema properties
  marked with `x-mcp-header` require matching `Mcp-Param-*` headers. Missing,
  malformed, or divergent mirrored headers fail with `-32020`; a missing
  required client extension fails with `-32021`; an unsupported protocol
  version fails with `-32022`. That answer is returned with the supported
  version list, and — when the `MCP-Protocol-Version` header itself names a
  version MacRemote does not implement — before any modern-metadata
  requirement applies.
- A modern request that declares the MCP Tasks extension can get a task
  instead of a result for a long call. A task is held in memory, belongs to
  the app that created it (any other caller gets `-32602`), and runs the same
  validation, approval, and execution limits as any call.
- `server/discover` is the modern handshake. Modern complete results carry
  `resultType: "complete"` and namespaced server information; cacheable
  discovery/list/read results explicitly use `ttlMs: 0` and
  `cacheScope: "private"`. The 2025 protocol versions retain their legacy
  `initialize` and result shapes without modern request headers.
- HTTP and stdio MCP bridges probe `server/discover` first. They fall back to
  legacy `initialize` for an unrecognized legacy-style response, a transport
  timeout, or an upstream `-32022` that names a legacy version MacRemote
  implements in `data.supported`, requesting the newest mutually supported one.
  A `-32020` or `-32021`, and a `-32022` with no usable list, are never
  downgraded: only a server's own explicit version list can move a connection
  down, and the result never rewrites the bridge's persisted `protocolVersion`.
- Write and Destructive tools require per-call approval unless the owner
  granted that app Always Allow. So does every Flexible Command, a tool that
  passes any arguments through to its program, even when it is labeled
  Read-only. A Flexible Command added from the Library starts Not Shared.
- An approval shows every argument in full, including standard input. No
  surface approves without showing them: notification banners offer Deny only,
  and the Requests menu acts only on the request the Approval window is showing.
  A call is validated before the owner is asked. See
  [Tool-call approval](docs/ARCHITECTURE_SECURITY.md#tool-call-approval).
- Sharing fails closed. A tool that appears or changes in `tools.json` outside
  the app starts Not Shared, and so does every saved tool when the app's
  preferences are missing.
- Sign-out is scoped by client ID and OAuth trust identity, never by display
  name. It removes the registration, its authorizations, access tokens, refresh
  tokens, waiting approval requests, and Always Allow rules, and reports the
  counts it actually removed. Two apps sharing a display name can never revoke
  each other. Session state stays truthful — active, awaiting sign-in, or
  expired — so an approved app that has not yet completed code exchange is not
  shown as expired, and MacRemote makes no device, location, or presence claim.
- A connected app's icon is presentation only. The mark is chosen from
  attacker-controlled `client_name` and redirect URIs, so any app can register
  as "Claude" and receive that glyph; matching is exact-alias and grants
  nothing. Authentication, Always Allow rules, tokens, and revocation are keyed
  on client ID and trust identity alone, and the identity type is unreachable
  from `Services/` and `Stores/`. Artwork is bundled only with a documented
  redistribution grant, an SF Symbol is used otherwise, and nothing is fetched
  at runtime. See
  [Resources/ConnectedAppIcons/THIRD-PARTY-NOTICES.md](Resources/ConnectedAppIcons/THIRD-PARTY-NOTICES.md).
- Tools run through direct process execution, never `/bin/sh -c`.
- Process-backed tools fail closed when their configured executable is absent,
  unreadable, not executable, or disappears between validation and process
  launch. Preflight failures and launch races both return a normal MCP tool
  result with `isError: true`, `reason: "unavailable"`, and path-free guidance
  to install or restore the command. The remote result does not expose the
  executable path, argv, or launch error. A missing command does not delete the
  saved tool or change its sharing policy.
- Built-in File Transfer tools run natively in the app and reach only folders
  the owner allowed (Desktop, Documents, and Downloads by default), or the
  whole Mac after one confirmed **Allow Whole Mac…** choice. Protected
  folders, which hold credentials, MacRemote's own data, and files that run at
  login, are never reachable, even inside an allowed folder. Both tests compare
  where a path really is on disk, not how it is spelled. Reading needs no
  approval, so allowing a folder lets a connected app read everything in it.
  A process tool that runs without asking (a Read-only Fixed Command) gets the
  same limit: an absolute path argument must be reachable, and a `..`
  component is refused.
  See [Native File Transfer](docs/ARCHITECTURE_SECURITY.md#native-file-transfer).
- File download tools return a short-lived capability token, not file bytes.
  So do results too large to return inline: a command's complete output, and
  the full result of a bridged MCP tool. MacRemote mints every such token
  itself; it never turns text in a tool's output into a MacRemote download
  link. The
  `GET/HEAD /artifact/<token>` route is unauthenticated by design but requires a
  256-bit token, expires in 10 minutes, allows at most 3 GET downloads, caps
  size at 512 MiB per file and 2 GiB across all waiting downloads, is
  rate-limited, sends `Cache-Control: no-store`, and is purged when the server
  stops.
- The public tunnel forwards the artifact route along with `/mcp`; a leaked
  artifact URL grants at most the 3 downloads of that single staged file before
  expiry.
- Logs must redact tokens, authorization codes, refresh tokens, Cloudflare
  credentials, Single Header values, and other secrets.
- Automatic MCP discovery only re-reads local configs; its cache at
  `~/Library/Application Support/MacRemote/mcp-scan-cache.json` stores hashed
  identities and a config fingerprint, never raw URLs, headers, or tokens.
- A scan never starts a stdio server named in another app's config file. Such a
  server starts only when the owner imports or checks it. If a refreshed server
  relabels a shared tool that asked first as read-only, the tool becomes Not
  Shared until the owner reviews it.
- Standard MCP/MCP Apps fields remain the primary cross-host contract. OpenAI
  widget keys are additive aliases. When Apps was negotiated and the owner
  turned result cards on (off by default, decision D77), each eligible tool
  and early execution error links the shared
  `ui://macremote/output-v9.html` resource. The v8, v7, v6, v5, v4, v3, v2, and unversioned
  URIs remain readable for cached clients. Catalog presentations may add richer
  rows, documents, accents, and authenticated actions; every other tool uses the
  schema-free `semanticResult` presentation. A catalog presentation may set
  `automatic: false` for intermediate lookups and diagnostics; those tools keep
  complete text and structured results without opening a card. See
  `docs/design/MCP-UI-SPEC.md`.
- The widget is a person-facing projection, not a wire-result inspector. Its
  final display filter removes commands, argv, local paths, stdout/stderr labels,
  credentials, protocol metadata, and raw JSON serialization. Only
  assistant-visible content blocks enter the pretty result; a block whose
  `annotations.audience` excludes `assistant`, and hidden result `_meta`, stay
  out. Artifact links, images, and audio use bounded semantic labels rather
  than exposing backing paths, bytes, or metadata. Copy exports only the
  sanitized text visible in the widget.
- Widget actions always re-enter authenticated `tools/call` and the normal
  Mac-side approval gate. Clients without Apps keep meaningful text `content`
  and `structuredContent`, and the complete MCP result remains available to the
  model independently of the widget's stricter human display. This preserves
  Anthropic and generic MCP fallback behavior and does not imply that the Swift
  server embeds the OpenAI Apps SDK. See OpenAI's
  [MCP server guide](https://developers.openai.com/plugins/build/mcp-server).

## Reliability and Denial of Service

A remote client can send bursts, oversized payloads, hanging commands, and
malformed arguments. These are treated as a security surface, because a client
that can exhaust the host or crash the server can deny the local user their own
tools. Mitigations:

- **Limits on public requests.** Unauthenticated public requests are limited
  per caller address, with a higher ceiling for all callers together, so one
  stranger cannot lock every app out of sign-in. At most 96 connections are
  open at once, and a client has 30 seconds to send a complete request. See
  [Local MCP Server](docs/ARCHITECTURE_SECURITY.md#local-mcp-server).
- **Bounded waiting.** One app can have 4 tool calls and 2 sign-ins waiting for
  the owner; all apps together can have 16 of each. A tool call waits 90
  seconds and a sign-in 5 minutes. A call whose app disconnects is withdrawn.
- **Bounded concurrency.** A global limiter caps how many tool executions run at
  once (acquired after the approval gate, so approval waits don't count). When
  saturated, a call fast-fails with a structured `isError` result and
  `reason: "unavailable"` (retryable) instead of spawning unbounded child
  processes.
- **Process-tree reaping.** A timed-out or cancelled tool is killed by its
  process group, each descendant process, and its direct pid (SIGTERM, then
  SIGKILL), so a pager or spawned subprocess cannot outlive the timeout. Child stdout/stderr are drained concurrently while
  the process runs, so a tool emitting large output can't deadlock on a full
  pipe buffer. Tools run with stdin from `/dev/null` and pagers disabled by
  default.
- **Checked argument parsing.** Numeric tool arguments are parsed with a checked
  conversion; an out-of-range or non-integral number returns a structured
  `invalid_argument` error instead of trapping. A single malformed remote
  argument can no longer crash the server.
- **Structured load-shedding and error model.** Argument/validation failures
  return a normal tool result with `isError: true` and a machine-readable
  `reason` code; JSON-RPC protocol errors are reserved for malformed envelopes
  and unknown methods/tools. Output and body sizes remain capped.

See [docs/ARCHITECTURE_SECURITY.md](docs/ARCHITECTURE_SECURITY.md) and
[docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) for details.
