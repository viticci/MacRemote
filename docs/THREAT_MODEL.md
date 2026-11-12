# MacRemote Repository Threat Model

## Overview

MacRemote is a macOS app that exposes a small, user-approved set of local Mac
tools to remote MCP clients. Its primary surfaces are a native SwiftUI
configuration app, a loopback-only MCP HTTP server, a command runner, an OAuth
authorization flow, and an app-managed Cloudflare Tunnel integration. Local and
the app-managed Cloudflare public link are the product connection paths.

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
- the selected remote MCP client only after MacRemote validates its credential.
  OAuth modes additionally require host approval before token issuance.

Untrusted or attacker-controlled actors:

- anyone who learns or guesses the public MCP URL;
- malicious or compromised remote MCP clients;
- prompt-injected model behavior that attempts unexpected tool calls;
- attacker-controlled MCP request fields, JSON-RPC inputs, OAuth client names,
  redirect URIs, tool parameters, and HTTP headers;
- attacker-controlled browser `Origin` values and CORS preflight requests;
- local malware or another local user process.

Core boundaries:

- public internet to Cloudflare Tunnel;
- Cloudflare Tunnel to `127.0.0.1:<port>`;
- Cloudflare's release CDN to the MacRemote-owned helper directory
  (`~/Library/Application Support/MacRemote/CloudflaredHelper/`), and from that
  directory to a launched process;
- an app's self-reported registration strings (`client_name`, redirect URIs) to
  what the UI draws for it — presentation only, never to authorization state;
- HTTP server to auth/session state;
- MCP tool call to command runner;
- command runner to local CLIs such as `musicctl`, `codex`, `pocketctl`, or
  `iris`;
- stdio MCP bridge to the RemCTL and NotesCTL servers (`remctl mcp`,
  `notesctl mcp serve`), whose signed Capability Hosts own protected-store
  access and privacy grants;
- MusicCTL launcher to its signed Capability Host on macOS; protected features
  route automatically over capability protocol 1. The Host reports role
  `capability-host` and scope `music-app+musickit+keychain`, owns protected
  MusicKit authorization, Keychain credentials, and Music.app Automation, and
  does not provide a network proxy;
- public `/artifact/<token>` route to short-lived artifact files;
- native File Transfer tools to the local filesystem (read/write), inside the
  folders the owner allowed;
- the saved tools file (`tools.json`), which other programs can write, to the
  set of tools MacRemote shares;
- app UI to persistent configuration and secrets.

## Core Assumptions

- The local MCP server binds only to loopback.
- The app-managed public link forwards only to the MCP server port. It does not
  justify a LAN or `0.0.0.0` listener.
- A leaked URL alone must not authorize a client.
- User-defined tools are exact executable paths plus argv templates, not shell
  strings.
- Secrets are stored in Keychain or protected app support files and never
  committed.
- MacRemote launches a helper it installed only after that exact file proves its
  pinned digest, size, owner-only permissions, and expected Developer ID team on
  the launch path — including a supervised watchdog relaunch, which re-proves
  the pinned session path before starting the process. The install record's own
  type, ownership, and mode are checked in the same pass. A copy that cannot be
  proven is quarantined, not run.
- A brand mark or display name never grants privilege. Every authorization
  decision keys on the client ID and the stable OAuth trust ID.

## Attack Surface

Remote HTTP/MCP inputs are the largest attack surface. The server must validate
all JSON-RPC shapes, reject unknown methods, cap body size, cap output size, and
avoid reflecting attacker-controlled strings into HTML without escaping.

The current `2026-07-28` MCP core is stateless. Every modern request carries
required protocol version and client capabilities plus optional client
information in `_meta`, with the version and method mirrored in
`MCP-Protocol-Version` and `Mcp-Method`.
Targeted methods also mirror the semantic name or URI in `Mcp-Name`; tool
arguments whose schema declares `x-mcp-header` are mirrored in validated
`Mcp-Param-*` fields. An attacker may omit a required field, send a malformed
encoded value, exploit duplicate or invalid schema annotations, or make the HTTP
header disagree with the JSON body. MacRemote rejects these cases with
`HeaderMismatch` (`-32020`) rather than choosing one attacker-controlled view.
Schema traversal accepts at most 64 levels and 4,096 container nodes; a schema
one level or one container node over either limit fails closed. External
references are not fetched.

Client capabilities are per request rather than connection state. A caller
cannot use a capability it did not declare: a method that needs a missing
capability fails with `MissingRequiredClientCapability` (`-32021`), and an
unsupported protocol version fails with `UnsupportedProtocolVersion`
(`-32022`), whether it arrives inside the modern `_meta` envelope or as an
`MCP-Protocol-Version` header alone. Version counter-offers are era-specific:
modern claims are offered only `2026-07-28`, while legacy-shaped requests are
offered only the three retained 2025 revisions. Modernity is claimed by the
exact `2026-07-28` header or the namespaced protocolVersion key. A lone
clientCapabilities object does not claim a version; live ChatGPT sends that
field on otherwise legacy requests, where it is inert. A bare modern header is
still malformed modern and never executes under legacy rules. Legacy requests
pass the same OAuth, approval, and fingerprint enforcement, while modern
mirrored-header validation remains mandatory for every modern claim (D52).
Modern discovery begins with authenticated `server/discover`; cacheable
discovery/list/read results have zero TTL and private scope, complete results
identify their type, and namespaced server information is rebuilt from the
canonical request base. That base comes from a host the app already knows
(loopback, or the public link's host), so a caller-chosen `Host` or
forwarded-host header cannot manufacture icon or website origins; a request
for any other host is refused with `421`.

Upstream sign-in (D62) adds a second, outbound OAuth role: MacRemote as a
client of a local MCP server such as Paste. The risks are a hostile local
server steering MacRemote to a remote authorization page, a reply forged on
the loopback listener, and token exposure. MacRemote refuses sign-in endpoints
that are neither HTTPS nor on this Mac, binds the reply listener to
`127.0.0.1` on a system-chosen port for one attempt only, ties the reply to a
random `state`, exchanges the code with a PKCE verifier and the `resource`
indicator, and stores the result in the Keychain rather than in the tool
registry, logs, or fingerprints. A server that answers 401 can only make
MacRemote show **Sign In…**; it cannot make MacRemote open anything without
the user clicking that verb.

Claimless `server/discover` is handled as an unknown legacy method, which lets a
dual-era client fall back automatically to `initialize`. Legacy `2025-11-25`,
`2025-06-18`, and `2025-03-26` clients retain their
`initialize` and result shapes without modern mirrored headers. HTTP and stdio
bridges probe `server/discover` first and fall back to legacy `initialize` for
unrecognized legacy-style failures, a transport timeout, or an upstream
`-32022` whose `data.supported` names a legacy revision MacRemote implements —
in which case the fallback asks for the newest mutually supported version. A
`-32020` or `-32021`, and a `-32022` with no usable list, are never downgraded.
Only a version list the server supplied itself can move a connection down; the
renegotiated version is per connection and never rewrites the bridge's
persisted, fingerprinted `protocolVersion`. An upstream `resultType: "task"`
handle is rejected rather than proxied: MacRemote runs every call synchronously
and does not own an upstream task lifecycle.

Browser CORS is a compatibility surface, not proof of caller identity. A
malicious page may send a trusted-looking `Origin` or preflight unexpected
methods. MacRemote reflects only exact allowed origins, uses `Vary: Origin`, and
never emits a wildcard. The ChatGPT origins are allowed only when the canonical
request base is public, not for direct loopback requests. Preflight is limited to
known MCP/OAuth paths, methods, and headers. Authentication is still performed
before MCP method dispatch: unauthenticated `GET`/`DELETE` requests receive a
`401` discovery challenge, while authenticated unsupported methods receive
`405`.

OAuth and client registration are critical. A malicious client may try open
redirects, PKCE bypass, authorization code replay, refresh token reuse, or client
impersonation. Dynamic registration accepts only the authorization-code flow
with optional refresh, response type `code`, the `mcp:tools` scope, and the
`none`, `client_secret_basic`, or `client_secret_post` token authentication
method. An app that asks for a secret gets one of its own and must use the
Basic or POST method it registered with. That secret only proves the caller is
the app that registered; it is not the owner's OAuth Client Secret, which is
refused while apps register themselves. Redirects must be hosted HTTPS, loopback
HTTP (including IPv6 loopback), or a valid private-use scheme. PKCE is S256-only
and the verifier must match the RFC length/character constraints. Unsupported
metadata and scope changes return the specific OAuth error; a rejected
refresh-scope change does not consume the otherwise valid refresh grant.
Mitigations also include one-time authorization codes, short token lifetimes,
refresh-token rotation with reuse detection, and persisted client/grant records
containing token hashes rather than bearer values. Registration and token
responses are `no-store`, and code issuance still requires host-side approval.

A refresh token is replaced each time it is used. If a used one is presented
again more than a minute later, a copy exists and nobody can tell which holder
is the real app, so every token from that approved sign-in is revoked and
Activity names the app. A repeat within the minute is answered with the same
new tokens, because an app whose reply was lost retries. Exactly one sign-in
method is accepted at a time: changing it signs out every app the new method
does not admit and stops the Single Header token. A client the owner never
approved is kept in memory only and dropped when its last waiting sign-in is
denied or expires. The mechanism is in
[Token rotation and sign-in methods](ARCHITECTURE_SECURITY.md#token-rotation-and-sign-in-methods).

Host-side approval is only as good as what the owner can tell from the prompt.
Registration and authorization need no sign-in, so anyone who learns the public
address can start a sign-in and call the app "Claude". An owner who expects a
connection could approve the stranger's request instead of their own. The
defense is a six-digit code shown on the browser page of whoever started the
sign-in and on the Mac's approval card, with the destination the sign-in
returns to; the owner approves only when the code on their own page matches.
App names are reduced to plain text so a name cannot carry a fake badge or
hidden characters. Pending sign-ins are capped per client and in total and
expire after 5 minutes, so a stranger cannot bury the owner's request. Every
return address is validated, including for OAuth Client Secret apps, and a
Client Secret app's address stays bound after its first completed sign-in. The
mechanism is in
[Sign-in approval](ARCHITECTURE_SECURITY.md#sign-in-approval).

DCR remains a compatibility registration path. When `application_type` is
present it must be `native` or `web`, and `web` registrations require HTTPS
redirects; omission remains accepted for older MCP clients. RFC 9207 protects
against authorization-server mix-up: metadata advertises issuer identification,
both successful and error authorization redirects include `iss`, and grants,
codes, and tokens are issuer- and resource-bound.

MacRemote deliberately does not advertise Client Identifier Metadata Document
(CIMD) support. CIMD is a protocol SHOULD, not a MUST. Fetching an
attacker-selected client document with a normal URL client after a DNS preflight
would create SSRF and DNS-rebinding TOCTOU risk, including access to loopback or
private services and unsafe redirect pivots. Safe future support requires
pinned-public-IP TLS, rejection of loopback/private targets, redirects forbidden
or re-resolved and revalidated at every hop, strict time, 5 KiB, and content-type
limits, exact binding between `client_id` and the document URL, redirect
membership and authentication-method validation, plus bounded caching and
revocation. DCR remains the compatibility path until that fetch boundary exists.

One published client ID is accepted with no fetch at all, so none of the risk
above applies to it. Claude's connector dialog can send its published identity
to a server that does not advertise CIMD. MacRemote carries the contents of
that document in `Services/PublishedOAuthClient.swift` and accepts the exact ID
`https://claude.ai/oauth/mcp-oauth-client-metadata` only with the document's
one return address on `claude.ai`. The name shown in the approval comes from
that list, not from the request. The ID is shared by everyone who uses Claude,
so it identifies the app and never a person: the owner still approves each
sign-in against the matching code, and an attacker who starts one gains nothing
without that approval. If Anthropic changes the document, sign-in with the
published identity fails closed until MacRemote's copy is updated.

Persistent tool approval must not follow attacker-supplied OAuth metadata.
MacRemote keys Always Allow to one OAuth registration identity plus the semantic
tool ID and the tool's current security fingerprint. Access-token refresh,
refresh-token rotation, and reconnects within that stored registration keep the
identity. Every new Dynamic Client Registration receives a new identity, even
when its name and redirect metadata exactly match an existing client. This asks
again after re-registration, but prevents a lookalike public client from
inheriting another app's tool policy. Persisted metadata-derived legacy trust
IDs migrate to per-registration IDs; their old grants remain unreachable.

Tool execution is critical. A malicious model may try command injection through
tool parameters or ask for a broader tool than approved. Mitigations include no
shell execution, exact executable allow-lists, per-tool parameter schemas, argv
construction from typed values, fixed timeouts, environment allow-lists, and
separate capability classes for read-only, write, and destructive tools.
Generic CLI adapters intentionally expose one executable plus model-supplied
argv and optional stdin. That is universal but not a sandbox. Each generic
adapter must be treated as delegation of the whole executable's reachable
capability surface. Shell interpreters and `/usr/bin/env` are blocked because
they erase the executable boundary. Because nothing can check that the argv a
Flexible Command receives only reads, a Flexible Command always needs approval,
even when labeled Read-only, unless the owner granted Always Allow. One added
from the Library starts Not Shared.

Approval is a decision about specific arguments, so the prompt must show them. A
shortened or summarized argument, an invisible character, or an approve button
on a surface that shows nothing would let a model run something the owner never
saw. The approval card shows every argument in full with invisible characters
written out. Notification banners offer Deny only, and the Requests menu acts
only on the request on screen. A call is validated before the owner is asked,
so a prompt always describes a call that can run. A call waits 90 seconds, under
Cloudflare's 100-second limit, so the owner cannot approve a call whose app was
already told it failed. The mechanism is in
[Tool-call approval](ARCHITECTURE_SECURITY.md#tool-call-approval).

The saved tools file is plain JSON in the user's Application Support folder, so
another program running as the user can add or rewrite a tool. Sharing therefore
follows the tool the owner last saw in the app: a row that appears or changes
any other way starts Not Shared with a line in Activity, and every saved tool
starts Not Shared when the app's preferences are missing.

Every user CLI is optional. Its configured path is checked again immediately
before launch, but the file can still disappear in the interval before
`Process.run()`. Both the ordinary missing/unreadable/non-executable preflight
and that launch race fail as a typed MCP tool result with `isError: true` and
`reason: "unavailable"`. The assistant-visible guidance says to install or
restore the command and deliberately omits the path, argv, and operating-system
launch error. MacRemote keeps the saved tool and sharing choice; absence is a
recoverable availability state, not evidence that the owner intended deletion.

A stable tool name alone is insufficient authorization. Editing a tool after it
was approved, or deleting and recreating the same name, could otherwise reuse a
standing policy for different executable behavior. The security fingerprint
covers executable/backend authority, argv and input validation, capability,
declarative invocation and preflight behavior, approval policy, macOS permission
requirements, credential bindings, and a persisted installation epoch. Approval
requests capture it, and execution rechecks it after every
approval wait. Security-contract changes ask again; deletion/recreation gets a
new epoch. Cosmetic metadata does not invalidate the grant. Timeout and output
limits are execution bounds, so changing either requires fresh approval.

The Federico catalog narrows routine delegation without pretending a CLI is a
sandbox. Eight process providers expose 66 dedicated tools with typed semantic
inputs and declarative exact-argv lowering plus eight Flexible Commands: 74
definitions. Supported mutations run CLI preflight first. RemCTL and NotesCTL
are bridged from their own MCP servers: the CLI validates its own inputs,
enforces its own guards (numeric ids, preview and revision-bound apply), and
reaches protected data only through its signed Capability Host. MacRemote adds
Mac-side approval, output caps, and every-call defaults for the destructive and
broad tools.

MusicCTL contributes 15 dedicated tools plus `musicctl_run`. On macOS, protected
MusicKit, Keychain, and Music.app operations route automatically through the
signed MusicCTL Capability Host over protocol 1. Its reported role is
`capability-host`, its scope is `music-app+musickit+keychain`, and it does not
provide a network proxy. MusicKit catalog and cloud-library reads are open-world
network operations; Music.app status and route reads are local. Every dedicated
player or output-route mutation first runs the same command without `--apply`;
MacRemote launches the applying form only after that non-applying preview
succeeds. Authentication setup, configuration writes, onboarding, and raw
request commands are blocked from `musicctl_run`. New Releases can scan a
complete cloud library, so it uses a 3,600-second execution limit.

Alexandria exposes bounded library and agent workflows without giving its broad
adapter access to deployment, checkout verification, privileged execution, or
endpoint redirection. OverCTL exposes bounded Overcast reads and dry-run/readback
writes; its broad command cannot enter sign-in, upload, credential-bearing
disclosure, forced replacement, receipt clearing, or protocol decoding. Iris
exposes bounded iPhone reads and dry-run writes; pairing, device authorization,
transport configuration, and root `migrate` stay off the broad adapter. Screen
read/capture, clipboard get, and Iris's 13 `--confirm` actions are reachable only
through `iris_run` with per-call approval.

Exactly 13 process-catalog tools ship with `approvalPolicy: everyCall`: the
eight Flexible Commands; Alexandria agent run; OverCTL archive; GoodLinksCTL
delete; and Apple Frames image and video rendering. Seven bridged tools get the
same default from the provider table: `remctl_run`, `remctl_delete_reminder`,
`notesctl_run`, `notesctl_add_content`, `notesctl_apply_edit`,
`notesctl_remove_tags`, and `notesctl_trash`.

Each Flexible Command remains delegation of its executable’s broad capability
surface even when one invocation is harmless. It therefore installs Not Shared,
is classified Destructive, and asks on every call by default. An explicit owner
can still grant Always Allow after the heavier consent step. HabitCTL,
PocketCTL, OverCTL, MusicCTL, and GoodLinksCTL additionally block login, tokens,
secret files, disclosure surfaces, configuration or endpoint overrides as their
individual policies require; Alexandria applies the stronger operator boundary
above; Iris applies the pairing/transport/`migrate` boundary above. There is
still no shell.

A complete first-party provider refresh is authoritative for that stable-ID
prefix. It refreshes retained definitions, adds missing current definitions, and
retires obsolete provider-owned IDs. It may also adopt exactly one saved
scanner-provenance tool when exactly one current preset has the same execution
signature and no stable catalog row exists. Adoption is a security-boundary
change: the scanned ID is replaced by the stable semantic ID with a fresh
permission epoch, grants for both identities are cleared, and the sharing state
transfers to the new identity. A hand-authored tool,
multiple matching saved rows, or multiple matching presets is not provenance and
remains untouched. An ordinary Add operation never adopts an equivalent scan.
Retirement removes the obsolete tool's sharing and invalid-state records and
grants; it does not affect unrelated custom tools.

Resource exhaustion is a remote-reachable denial-of-service surface: a client
can send bursts, hang commands, stream oversized output, or pass malformed
arguments to starve the host or crash the server. Mitigations: a global
execution concurrency limiter caps simultaneous tool runs (acquired after the
approval gate) and sheds excess load with a structured `reason: "unavailable"`
result instead of spawning unbounded processes; timed-out tools are killed by
both their process group and direct pid (SIGTERM then SIGKILL) so pagers and
spawned subprocesses are reaped; child stdout/stderr are drained concurrently
to avoid a pipe-buffer deadlock, with validated timeouts of 1–86,400 seconds and
per-tool output caps of 1 KiB–64 MiB; stdin defaults
to `/dev/null` and pagers are disabled; and numeric arguments are parsed with a
checked conversion so an out-of-range integer returns `invalid_argument`
instead of trapping the process. Argument and validation failures return a tool
result with `isError: true` and a machine-readable `reason`; JSON-RPC errors are
reserved for malformed envelopes and unknown methods/tools.

Unauthenticated public requests are limited per caller address, taken from
Cloudflare's `CF-Connecting-IP`, with a ceiling for all callers together that
is eight times higher. A single shared bucket would let one stranger lock every
legitimate app out of sign-in and token refresh. The server holds at most 96
connections and gives a client 30 seconds to send a complete request, so idle
sockets cannot use up its file descriptors. One app can keep 4 calls waiting
for approval and all apps 16, because each waiting call is a prompt on the Mac
and an open connection.

For stdout beyond the inline presentation budget, the runner switches to a
mode-`0600` spool after 100,000 bytes. MCP keeps at most 48,000 UTF-8 bytes in
the result and links the complete bounded stream through the artifact store.
Inline truncation alone keeps `reason: "ok"`; `output_limit` is reserved for
bytes lost at the configured hard cap, and a preservation failure is
`internal_error` without hiding the authoritative exit status.

A read-only Fixed Command runs without asking, so one that takes a file path
could otherwise read any file. Such a tool can only be pointed at files inside
the allowed folders: an absolute path must be reachable, a value containing
`..` is refused, and tool processes start in an empty folder. The check is by
the shape of each value, so it does not see a path a program builds itself, for
example from an option value such as `--file=/path`. Share read-only tools
with that in mind.

The built-in File Transfer tools reach the filesystem directly rather than
through a delegated CLI, and reading needs no approval. A list of forbidden
paths cannot bound that: everything not on the list stays readable. The tools
therefore reach only folders the owner allowed (Desktop, Documents, and
Downloads by default), and never a protected location inside one. The owner can
allow any folder, up to the whole Mac. That choice hands every connected app
unasked read access to everything outside the protected list, including files
that hold keys the list does not name, so the app asks for confirmation and
says so. A prompt-injected app with whole-Mac reach can read and send out
anything such a file contains; the owner accepts that risk for all connected
apps when they make the choice. Path tests compare file
identity, not spelling, so letter case, a second path to the same volume, a
symlink, or `x/..` behind a missing component cannot step around them, and a
path containing `..` is refused. Listings omit protected entries, and archiving
a folder that contains one is refused, so a walk cannot carry protected files
out. The protected list includes `~/Library/LaunchAgents` and
`~/Library/Preferences` because a file written there would later run or change
what apps are trusted. `write_file` carries the `write` capability, so each
call needs host approval. These tools are Not Shared by default and never enter
`tools.json`. The full policy is in
[Native File Transfer](ARCHITECTURE_SECURITY.md#native-file-transfer).

Cloudflare Browser Integrity Check is disabled by a Configuration Rule only for
the exact MacRemote custom-domain hostname. This is required because BIC rejects
legitimate non-browser MCP clients before MacRemote can authenticate them. The
rest of the zone keeps its existing setting; MacRemote's OAuth or Single Header
authentication, approval gates, capability tokens, and in-process rate limits
remain the security boundary for this API hostname.

The `/artifact/<token>` download route is unauthenticated and reachable over the
app-managed public tunnel. It trades the bearer for a 256-bit capability token
with tight bounds: 10-minute expiry, 3 GET downloads max, 512 MiB size cap,
a 2 GiB cap on all staged downloads together, per-route rate limiting,
`no-store`, and purge-on-server-stop. A leaked artifact
URL exposes at most that one already-approved file, and only until the token's
downloads or expiry run out. The token is generated with `SecRandomCopyBytes`;
path traversal in the token is rejected (`/` disallowed in the token component).
Artifacts can contain complete Apple Notes bodies, exported metadata, drawings,
or transcripts. Treat each URL as a short-lived secret: it includes size and
SHA-256 for verification, is never logged with bearer credentials, and is
purged with its owning server/store. All stores stage into one folder that
the app empties at launch, and each deletes only its own files, so one server
cannot purge another server's live artifact and a crash leaves nothing behind
for good. MacRemote
builds download links only for the built-in File Transfer tools. Any other
tool's output is untrusted text; reading link fields out of it would let a tool
present a MacRemote-authored link to any address.

The 13 default command categories are only catalog and UI classification. They
must not auto-enable or silently add tools to the exposed MCP surface. A preset
that can change files must ask first: Move To Trash and image conversion are
labeled write tools, and broad adapters such as rsync are Destructive Flexible
Commands. No Fixed Command preset deletes a file permanently.

Tunnel setup is high risk. A bug that binds the local server to `0.0.0.0` or
forwards a broad local service would expose more than the intended MCP process.
Mitigations include loopback-only listeners, health checks before the built-in
Cloudflare tunnel starts, single-origin routing, and explicit stop, revoke,
OAuth credential rotation, and instance rotation controls in the UI. A helper
that keeps running after the app is gone would leave the public address
connected to a port nothing owns, so every quit path stops it, a tether
process stops it when the app crashes or is killed, and the next launch stops
one that outlived both. The run token of a deployed Your Domain
tunnel is kept in the Keychain so the domain can go public again without
Cloudflare credentials. Someone who reads it can connect their own helper to
that tunnel and receive requests sent to the owner's hostname; they cannot
change DNS or create tunnels with it. Cloudflare accepts it until the tunnel
is deleted or its secret is rotated there; MacRemote deletes its own copy when
another address is chosen or Cloudflare rejects it. OAuth
credential rotation invalidates connected clients and tokens. Instance rotation
remains a private local compatibility control, not the public URL authority.

Installing the Cloudflare helper is a supply-chain surface, and it is the only
code MacRemote ever adds to the Mac. It is treated as one: the release the app
will install is pinned in the committed manifest — version, download URL, exact
archive and executable byte counts, exact SHA-256 for both, and the exact
uncompressed tar length. No checksum, version, or "latest" pointer is fetched at
runtime, so a pinned build cannot change under the user and a compromised release
channel cannot retroactively alter what an installed MacRemote will accept. The
download is HTTPS-only against a three-host allowlist enforced on the initial
request and on every redirect, with a bounded redirect chain and a hard byte cap;
a transfer whose size does not match the published size exactly is discarded. The
archive is verified before it is opened. Extraction is entirely in-process — no
`tar`, no subprocess, no shell, no package manager, no piped installer — through
a gzip reader capped at the published uncompressed length and checked against the
container's own CRC-32 and length trailer, then a deliberately narrow USTAR
reader that accepts exactly one regular file with the expected name and size and
rejects symlinks, hard links, directories, path traversal, prefixed paths, PAX
and GNU extensions, and any second entry. The unpacked binary is re-read from
disk and re-checked for size, SHA-256, and the expected Developer ID team before
it is committed. The install directory is owner-only (0700) with the binary at
0500 and the record at 0600; publication is atomic and rolls back rather than
leaving an unrecorded binary behind. Every launch re-verifies ownership,
permissions, size, digest, and signing team, and any failure quarantines the copy
instead of running it. The digest must both match the install record and belong
to the compile-time pinned digest set — the record is rewritable by any process
running as the user, the pin is not, so a self-consistent record cannot
authorize an unpublished binary. The record file's own type, ownership, and
mode are checked in the same pass, and a supervised watchdog relaunch re-proves
the pinned session path before starting the process, failing the tunnel rather
than substituting a different executable. Status readouts use a cheap
no-hashing path and prove nothing about the bytes; only the full verification
gates execution. The helper is launched with an exact path and an argv
array, never through a shell. MacRemote removes only files it created: a helper
the user installed is never modified or deleted, and quarantine handling applies
only to MacRemote's own copy.

Single Header is a generic sign-in method, and it is deliberately not the
default. Dynamic OAuth is MacRemote's declared default because it reaches
Mac-side approval before any token exists and requires no secret to be copied by
hand; OAuth Client Secret and Single Header are advanced options the user must
select explicitly. Selecting an app never selects a method — the app picker is
advisory and cannot rewrite the sign-in configuration or mint a credential as a
side effect, which removes a path where merely reading setup instructions could
switch the server into a confidential-client mode that disables self-registration
for every client. Single Header's generated bearer is a credential, not a
transport boundary: it must remain outside source, checked-in profiles, logs, and
support exports, and it must be sent only to the intended MacRemote origin.
Because that token stays valid until it is rotated or deleted, its section is
always visible and always removable rather than disappearing along with the mode
that created it. A public ChatGPT developer-mode draft remains a compatibility
use of the app-managed Cloudflare path with Dynamic OAuth/DCR. MacRemote's bearer
tokens are audience- and issuer-bound but not sender-bound; see **Proof-bound
tokens** at the end of this section.

Widget content is another remote-data boundary. Tool output, bridged MCP output,
widget inputs, and action metadata are untrusted. The widget must construct text
with safe DOM APIs, keep `connectDomains` empty, and limit resource domains to
the explicit catalog need. Widget actions must re-enter ordinary authenticated
`tools/call` and the same approval coordinator. Standard MCP Apps metadata stays
primary; OpenAI metadata is additive only. A versioned resource URI prevents a
breaking widget bundle from being confused with an older cached contract, while
the legacy URI remains a read-only compatibility alias.

The v6 contract links every registered tool and early execution error after
Apps negotiation. Curated presentation metadata
may refine the view, but uncurated Flexible Commands, custom tools, imported
bridges, and native tools use the same schema-free semantic renderer. Universal
linkage is safe only because the widget is a stricter human projection than the
outer MCP result: commands, argv, local paths, stdout/stderr labels,
credentials, protocol metadata, and raw JSON serialization are removed at the
final display boundary. Content blocks enter only when their
`annotations.audience` includes `assistant` or carries no audience restriction;
user-only blocks and result `_meta` remain outside the pretty UI. Artifact
links, images, and audio receive bounded semantic labels without
backing paths, bytes, or hidden metadata. Copy derives from the sanitized visible
card. Meaningful `content`, `structuredContent`, annotated assistant content,
and collision-safe result metadata remain intact for the model and for clients
that do not render Apps.

A connected app's displayed name and mark are attacker-controlled presentation.
Both are derived from strings the app supplied at registration — its
`client_name` and its redirect URIs — so any client can register as "Claude" and
be drawn as Claude. MacRemote therefore treats brand resolution as a picture
lookup with no security meaning. Matching is a deterministic table lookup on
exact alias membership after normalization, plus one last-resort exact-host rule
that applies only when the app supplied no informative name at all; there is no
substring matching, and hosts are never suffix-matched. The resolved identity is
never read by authentication, authorization, Always Allow lookup, token
validation, or revocation, all of which key on the client ID and the stable OAuth
trust ID. No mark is ever accompanied by a verification claim, because MacRemote
has verified nothing. Artwork is bundled only where a public license documents
redistribution, is reproduced unaltered, and is never fetched at runtime — there
is no favicon lookup and no per-app network request, so an app cannot cause an
outbound fetch merely by registering.

The compact `macremote://catalog/v1` resource is discovery metadata, not an
authorization shortcut. It contains semantic names, titles, categories,
capabilities, source classifications, and schema revisions, but no executable
paths, bridge endpoints, headers, credentials, permission fingerprints, OAuth
identity, or token state. Its catalog revision is derived only from public MCP
descriptors. Unknown-tool suggestions are informational and never dispatch a
different tool automatically.

Logs and diagnostics can leak secrets. Audit logs must redact tokens,
authorization codes, refresh tokens, Single Header values, Cloudflare
credentials, request headers, and full command output by default.

Local MCP discovery reads local agent config files. At launch and on activation
the app passively re-reads those configs with no subprocess and no network, and
persists a discovery cache at `~/Library/Application
Support/MacRemote/mcp-scan-cache.json`. That cache must store only hashed
seen-identities and a config fingerprint; it must never persist raw endpoint
URLs, request headers, or tokens, so a leaked cache file cannot reveal upstream
MCP endpoints or secrets. Passive discovery must not probe, import, or expose any
server. A manual scan asks only HTTP servers that are already running. A stdio
server is a command line from another app's config file, so a scan never
launches one; it starts only when the owner imports or checks that server. A
server also describes its own tools: when a refresh relabels a shared tool that
asked first as read-only, the tool becomes Not Shared until the owner reviews
it. A canonical runtime identity covers the complete URL and
credential-safe header bindings for HTTP, or the exact command, full argv,
startup timeout, and credential-safe environment bindings for stdio. Literal
secrets contribute only through a digest. Exact duplicate runtimes merge every
configuration owner; different auth profiles remain separate.

Passive discovery does reconcile tools imported earlier. It removes a family
and its Always Allow grants transactionally only after every readable,
non-manual owner disappears. One remaining owner keeps it; an unreadable owner
is unknown evidence and fails closed by preserving it. An offline server remains
present in its config and is preserved; runtime-only and explicit direct-URL
imports are not config-owned. Legacy rows without persisted ownership survive
until explicit Refresh attaches a selected config—automatic discovery never
infers ownership from matching endpoints. Supported sources are the explicit
`MCPConfigLocator` paths and Claude Extension `manifest.json` files, not general
Codex or Claude plugin registries. This prevents a stale owned bridge from
remaining callable without turning ambiguous or partially unreadable state into
automatic data loss.

### Proof-bound tokens (DPoP and mTLS): future seam, not shipped

MacRemote issues opaque bearer access tokens. They are audience-bound and
issuer-bound — every token record carries the client, issuer, resource, and
scopes, and a token is accepted only for the current canonical MCP resource
aliases — but they are not sender-bound. Whoever holds the token string can use
it until it expires or is revoked. Proof-of-possession schemes exist to close
that gap: DPoP (RFC 9449) binds a token to a client-held key proven on every
request, and mutual-TLS certificate binding (RFC 8705) binds a token to the
client certificate presented on the TLS connection. MacRemote implements
neither today, advertises neither, and must not advertise a capability it does
not implement.

The threat proof-binding would actually reduce is narrow and specific to the
public path. On loopback, a token thief already has code execution on the Mac,
which is a larger compromise than any token. Over the app-managed Cloudflare
link, the realistic leak paths are a token copied out of a client's own storage,
a token pasted into a log or support export, or a token exfiltrated by a
compromised client process. DPoP would make the first two useless to an
attacker who did not also steal the client's private key. It would not help
against the third: RFC 9449 §11.4 is explicit that an adversary running code in
the client's context can mint proofs at will, and §11.2 notes that proofs can be
pre-generated and exfiltrated unless the server issues nonces. DPoP does not
prevent token theft; it narrows who can use a stolen token. It also does nothing
for the risks MacRemote actually treats as Critical — approval bypass, command
injection, or a leaked artifact URL — because those do not depend on token
possession at all.

Certificate binding is not achievable on the public path at all, and the reason
is structural rather than a matter of effort. Cloudflare terminates the client's
TLS at its edge and delivers plain HTTP to the loopback listener, so MacRemote
never observes the handshake. RFC 8705 §6.5 declares the intermediary-to-origin
communication of certificate metadata out of scope. The only available
substitute is an edge-injected header — Cloudflare's `Cf-Client-Cert-*` fields
or an RFC 9440 `Client-Cert` header — and Cloudflare's own documentation warns
that those fields are populated regardless of validation result and that the
origin must strip any client-supplied copy. That reduces a cryptographic binding
to trusting a proxy header, which this threat model already classifies as
attacker-controlled input. Quick tunnels cannot carry client certificates at
all, and no MCP client presents a user-supplied certificate. Certificate binding
is therefore recorded as out of scope, not as future work.

Proof-binding would also create a key and device lifecycle MacRemote does not
have and does not want. Today a user revokes access by revoking a grant, a
client, the Single Header token, or the whole instance, and every check is a
hash lookup that takes effect on the next request. With DPoP the client holds a
private key, and the questions that follow are all new: what happens when the
key rotates mid-session and outstanding tokens silently stop working; what a
user does when the device holding the key is lost, given that MacRemote has no
account, no device registry, and no recovery channel; whether the server keeps a
`jti` replay cache and for how long; whether it issues nonces, and therefore
whether it must reject every proof without one from that point forward per
RFC 9449 §11.3. MacRemote runs as one process on one Mac, so a strict `jti`
single-use cache is genuinely feasible here in a way it is not for distributed
servers — that is the one part of the topology that helps. Everything else on
that list is new persistent state and new failure modes in the exact code path
that must never fail closed against a legitimate user. Note also that any `htu`
validation behind the tunnel would rest on the same known-host check already
used to derive the canonical request base, so it would inherit that trust
property rather than add an independent guarantee.

A MacRemote-only proof scheme is not an option. Every supported client — the
ChatGPT connector, Claude on the web, Desktop, and Code, Notion, Raycast,
T3 Code, Codex, Grok, and the official TypeScript, Python, and Rust SDKs —
attaches `Authorization: Bearer` and nothing else. The TypeScript, Python, and
Rust SDKs list the DPoP conformance scenarios as documented expected failures.
Codex accepts a `DPoP` token type during deserialization and then discards the
binding, sending the token as a bare bearer. Requiring proof-of-possession, or
even issuing a token with `token_type: "DPoP"`, would break all of them at once,
because RFC 9449 §7.2 requires a resource server to reject a bound token
presented as a bearer token. A private, non-standard variant would be worse:
it would break the same clients while also forfeiting the interoperability that
makes the standard worth adopting.

The threshold for revisiting this is a standards and client-support threshold,
not a calendar. SEP-1932, the DPoP profile for MCP, remains an open pull request
against the specification. It does not appear in the published SEP index, the
`ext-auth` repository's main branch does not contain it, and the official
extension client matrix does not list DPoP as an extension. Client conformance
scenarios merged in July 2026; the server and authorization-server scenarios are
still open. MacRemote should reconsider only when SEP-1932 or its successor
reaches Final with the full conformance set merged, and at least two of the
clients MacRemote actually supports ship documented DPoP support that a user can
turn on. Until then the core specification's own answer to token theft — short
access-token lifetimes and rotating refresh tokens — is what MacRemote already
does.

If that threshold is ever met, the transition is additive and the shape is fixed
by the RFC. MacRemote would keep accepting bearer tokens and add DPoP as an
opt-in alongside them: publish `dpop_signing_alg_values_supported` in
authorization-server metadata, accept `dpop_bound_access_tokens` at
registration for clients that ask for it, record the JWK thumbprint alongside
the existing token record, and honor `Authorization: DPoP` with a per-request
proof. Bound tokens must then be rejected when presented as bearer tokens, and
unbound tokens must keep working exactly as they do now. Two implementation
constraints are already known and must be respected. MCP's own extension
negotiation lives in client and server capabilities inside the JSON-RPC layer,
which a protected server only reaches after authentication has already
succeeded, so DPoP can only be negotiated at the OAuth layer. And the
`WWW-Authenticate` challenge must keep `Bearer` first: the TypeScript SDK's
challenge parser, which Claude Code embeds, returns nothing at all when the
first scheme in the header is not `Bearer`, silently losing the
`resource_metadata` URL. A `DPoP algs="ES256"` challenge may only ever be
appended after the existing Bearer challenge, and only once it is backed by a
real implementation.

Making proof-bound tokens the default would require more evidence still: that
every client MacRemote lists can complete an end-to-end DPoP flow against it,
that key rotation and device loss have a recovery path a single user can execute
without an account or a device registry, that the replay cache and nonce policy
survive restart and instance rotation without locking out a legitimate client,
and that the whole path is covered by the same test discipline as the existing
OAuth flow. Absent all of that, bearer tokens with short lifetimes, rotating
refresh tokens, host-side approval, and immediate local revocation remain the
correct design.

## Severity Calibration

Critical:

- arbitrary shell command execution through a remote MCP call;
- token issuance without host-side approval;
- public tunnel exposing anything beyond the MacRemote MCP server;
- auth bypass allowing leaked URL holders to call exposed tools;
- launching a downloaded helper binary that did not pass its pinned digest,
  size, and Developer ID team verification, or launching one from a path
  MacRemote did not create and cannot prove.

High:

- redirect URI validation flaw that leaks authorization codes;
- DCR metadata or PKCE validation flaws that permit an unsupported client or
  authorization-code replay;
- missing or incorrect RFC 9207 `iss` handling that permits authorization-server
  mix-up;
- a future CIMD fetch that can reach loopback/private addresses, change DNS
  targets after validation, or follow an unvalidated redirect;
- refresh token replay or non-rotating refresh tokens;
- modern header/body mismatch accepted instead of returning `-32020`;
- a connection downgraded to the legacy handshake without an explicit
  server-supplied version list, or a `-32020`/`-32021` triggering any downgrade
  at all;
- a Flexible Command running without approval and without an Always Allow
  grant, whatever its label;
- an approval surface that shortens, summarizes, or hides an argument, or any
  surface that approves a call or a sign-in without showing the arguments or
  the code;
- a sign-in approved for a request the owner did not start, because the code
  or the return destination was missing or the app name was trusted;
- a tool added or changed outside the app staying shared;
- tools exposed before required Full Disk Access or macOS privacy checks pass;
- the app naming a tool executable, a launcher, or an interpreter as a Full
  Disk Access item, or a bridged RemCTL or NotesCTL tool acquiring a
  MacRemote-side permission requirement its signed Capability Host already
  owns;
- a complete catalog refresh adopting a hand-authored or ambiguous
  signature-equivalent tool, retaining either identity's grants, or reusing its
  permission epoch;
- any File Transfer tool reaching a path outside the allowed folders or inside
  a protected folder, including through a listing or an archive (path-policy
  bypass);
- persistent client tool policies applied to the wrong OAuth client or resource;
- stale Always Allow policies accepted after a tool's executable authority,
  validation contract, capability, permission requirements, credential binding,
  or installation generation changed;
- a tool edited between host approval and execution without a fingerprint
  recheck at the execution boundary;
- wildcard/mis-scoped CORS that lets an untrusted browser origin read protected
  MCP or OAuth responses;
- logs or profiles storing bearer tokens, Single Header values, or Cloudflare
  credentials;
- the managed helper directory being writable by another user or process, or
  its permissions/ownership no longer being checked before launch;
- an integrity, signature, or archive-shape failure that does not block the
  launch — including accepting a redirect outside the download allowlist, a
  second archive entry, a symlink entry, or a traversal path;
- a brand mark or self-reported display name influencing trust identity, grant
  lookup, or which client a revocation targets;
- a widget action bypassing MCP authentication or Mac-side approval, or the
  pretty UI exposing credentials, command/argv/path details, hidden result
  metadata, or content whose audience excludes the assistant.

For RemCTL and NotesCTL, MacRemote checks nothing about permissions. The CLI's
MCP server reports a missing grant as a tool error, and `remctl doctor` or
`notesctl doctor --json` names the signed Capability Host that needs it. The
Access Fixer lists nothing for those tools.

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
- one caller exhausting the public rate limit, the connection limit, or the
  pending-approval queue for every other app;
- a cancelled approval or execution-slot wait continuing to execute, or a
  request staying approvable after its app disconnected or its wait expired;
- an upstream task handle being proxied as though MacRemote owned it;
- the Cloudflare helper still running after MacRemote quit or crashed;
- weak or predictable instance identifiers;
- incomplete audit records that prevent the user from understanding which client
  called which tool;
- UI state desynchronization that shows the tunnel stopped while it is still
  running;
- an interrupted or failed helper download leaving an executable-looking
  artifact behind, staging directories surviving a restart, or a quarantined
  copy remaining reachable on the launch path;
- a self-reported client name selecting a brand mark in a way that implies
  verification, or artwork bundled without a documented redistribution license;
- an optional CLI's preflight or launch-race failure surfacing as an internal or
  nonzero-exit error, deleting the saved tool, or leaking its executable path or
  argv instead of returning the typed path-free `unavailable` result.

Low:

- cosmetic UI mistakes that do not affect auth or execution;
- non-sensitive log wording issues;
- failure to detect Cloudflare availability when the local server remains
  stopped and no exposure occurs.
