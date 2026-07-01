# MacRemote

MacRemote is a native macOS app that exposes user-approved local CLI tools to
remote MCP clients. It is not a remote shell. Every exposed tool is an exact
executable path plus argv behavior, every remote client must complete OAuth with
host approval, and write-capable or broad CLI calls require host approval before
execution unless the user explicitly grants that client a persistent policy.

RemCTL, PocketCTL, Codex, Peekaboo, and other CLIs are all treated the same way:
they are optional tools the user can add from detected presets or define by hand.

## What You Get

- Native SwiftUI app for managing the exposed MCP tool surface.
- Local MCP server bound to `127.0.0.1`.
- Cloudflare Tunnel for a temporary public HTTPS MCP URL or a persistent
  Cloudflare custom domain.
- OAuth + PKCE with host-side approval before token issuance.
- Per-client tool policies for pre-approving selected tools.
- Optional Pushover or Brrr alerts for approval requests and tunnel failures.
- Direct process execution with no shell interpolation.
- Generic CLI adapters for whole-command delegation.
- Command templates for narrow, schema-driven MCP tools.
- System presets and bulk preset sets for detected CLIs.
- Full Disk Access and macOS privacy checks before protected tools are served.
- `script/macremotectl` for agent-friendly install and configuration.

## Requirements

- macOS 14 or later.
- Swift toolchain available at `/usr/bin/swift`.
- `cloudflared` on `PATH` or in a standard Homebrew location.
- Optional: `wrangler` authenticated with `wrangler login` to list Cloudflare
  domains.
- Optional: a Cloudflare API token for persistent custom-domain deployment. The
  token needs account-level Cloudflare Tunnel read/write access plus
  selected-zone Zone read, DNS read/write, Access Apps and Policies read/write,
  and Access Service Tokens read/write access. Use **DNS**, not **DNS
  Settings**. MacRemote keeps the token in memory only.
- Optional CLIs such as RemCTL, PocketCTL, Codex, Peekaboo, Spogo, Summarize,
  Gog, GitHub CLI, and other commands on `PATH` or in common user/Homebrew bin
  directories.

Check the local machine:

```bash
script/macremotectl doctor --json
```

`doctor` requires Swift and Cloudflare Tunnel. All user CLIs are optional; missing
CLIs simply mean their presets will not appear.

## Quick Start

Build and open the app:

```bash
script/macremotectl install --launch
```

Then in the app:

1. Open **Tools**.
2. Add one tool, several detected CLI adapters, or a full preset set.
3. Use the per-tool toggles to decide what is exposed.
4. Open **Dashboard** and start the local server.
5. Open **Tunnel** and start a temporary Cloudflare tunnel, or deploy a custom
   Cloudflare domain from a Wrangler-authenticated account.
6. Copy the public MCP URL.
7. Approve the remote client in **Approvals**.
8. Approve individual write/destructive calls, or open **Clients** and grant that
   client persistent access to selected tools.

The public URL has this shape:

```text
https://<trycloudflare-host>/mcp
```

Persistent Cloudflare domains use the same MCP path:

```text
https://<subdomain.example.com>/mcp
```

Share that URL only with the remote MCP client you are testing. If Cloudflare
Access protection is enabled, copy the generated headers into clients that can
send static request headers. For clients that support OAuth client ID and secret
fields, use MacRemote's generated OAuth credentials instead. MacRemote OAuth
still remains required in every mode.

For persistent custom domains, follow the full setup below.

## Notifications

MacRemote can send alerts through Pushover, Brrr, or both. Alerts fire when a
new OAuth client is waiting for host approval, when `cloudflared` exits
unexpectedly, and when MacRemote starts after a tunnel was previously marked
active.

Configure notifications from **Settings**:

- **Pushover**: enable Pushover alerts, then enter the Pushover User ID and API
  key.
- **Brrr**: enable Brrr alerts, then enter the webhook secret. MacRemote sends
  Brrr messages with `POST https://api.brrr.now/v1/send` and an
  `Authorization: Bearer <secret>` header, so the secret is not placed in the
  URL.

Use **Send Test Notification** after saving each provider.

## Persistent Cloudflare Custom Domains

MacRemote has two Cloudflare tunnel modes:

- **Temporary tunnel**: starts `cloudflared tunnel --url ...` and receives a
  random `*.trycloudflare.com` hostname. This needs no Cloudflare account and is
  useful for short tests, but the hostname is not stable.
- **Custom domain tunnel**: creates or reuses a named Cloudflare Tunnel, routes a
  hostname such as `macremote.example.com` to it, and runs `cloudflared` with the
  tunnel token. This is the right mode for saved clients such as Raycast.

Custom-domain deployment requires:

- A Cloudflare zone using Cloudflare nameservers.
- `cloudflared` installed locally.
- `wrangler` authenticated with `wrangler login` if you want the app to list
  available zones.
- A Cloudflare API token with the exact permissions below.

### Cloudflare API token

Create a custom token in Cloudflare. Account-owned tokens and user tokens both
work as long as the token can call the endpoints below.

Use two permission policies:

1. Account policy
   - Resources: include the Cloudflare account that owns the zone.
   - `Account -> Cloudflare Tunnel -> Read`
   - `Account -> Cloudflare Tunnel -> Write` or `Edit`
2. Zone policy
   - Resources: include the specific zone, for example `example.com`.
   - `Zone -> Zone -> Read`
   - `Zone -> DNS -> Read`
   - `Zone -> DNS -> Write` or `Edit`
   - `Zone -> Access: Apps and Policies -> Read`
   - `Zone -> Access: Apps and Policies -> Write` or `Edit`
   - `Zone -> Access: Service Tokens -> Read`
   - `Zone -> Access: Service Tokens -> Write` or `Edit`

Important details:

- Choose **Zone -> DNS**, not **Zone -> DNS Settings**. DNS Settings does not
  grant access to DNS records, and MacRemote must read and create a CNAME record.
- If you disable Cloudflare Access protection in MacRemote, the Access Apps and
  Service Tokens permissions are not used for that deploy. They are still
  recommended for the default protected setup.
- Store the token in a password manager and paste it only into MacRemote when
  deploying. MacRemote keeps the API token in memory only. If a token is pasted
  into chat, logs, or a public issue, revoke it and create a new one.

### What MacRemote creates

When you deploy a custom domain, MacRemote:

1. Validates the selected zone and subdomain.
2. Starts the local MCP server if it is not already running.
3. Creates or reuses a named Cloudflare Tunnel named after the hostname.
4. Writes the tunnel ingress config so the hostname forwards to the local
   MacRemote server on `127.0.0.1`.
5. Creates or updates a proxied DNS CNAME for the hostname, pointing to
   `<tunnel-id>.cfargotunnel.com`.
6. If Cloudflare Access protection is enabled, creates or reuses a self-hosted
   Access application scoped to `hostname/mcp*`.
7. If Access is enabled, creates a Cloudflare Access service token and creates
   or updates the MacRemote Service Auth policy for that token.
8. Fetches the tunnel run token and starts the named tunnel locally.

Access is deliberately scoped to `/mcp*`, not the entire hostname. This covers
the exact `/mcp` endpoint and legacy `/mcp/...` paths while leaving OAuth
bootstrap routes outside the Access gate. Dynamic MCP clients need to fetch
`/.well-known/oauth-protected-resource`,
`/.well-known/oauth-authorization-server`, `/register`, `/authorize`, and
`/token` before they have a MacRemote bearer token. Some clients do not attach
custom static headers to those OAuth bootstrap requests. If Cloudflare Access
guards the whole hostname, those clients will fail with errors such as "Could
not fetch MCP OAuth metadata" or HTML/DOCTYPE responses from Cloudflare Access.

MacRemote refuses to overwrite a DNS record or Access application that does not
look like it was created by MacRemote. Delete or rename conflicting Cloudflare
resources manually if you want MacRemote to take over that hostname.

### Deploy from the app

1. Open **Dashboard** and make sure the local server can start.
2. Open **Tunnel**.
3. In **Custom Domain**, click refresh if the domain list is empty.
4. Select the Cloudflare domain.
5. Enter a subdomain, for example `macremote` or `macremote-home`.
6. Paste the Cloudflare API token.
7. Choose the privacy mode:
   - **OAuth Client Secret** for Claude, Notion, and clients with OAuth client
     ID/secret fields.
   - **Access Headers** for clients that can send both Cloudflare Access service
     token headers, such as Raycast.
   - **Single Header** only when a client can send one custom static header in
     addition to the OAuth bearer token.
   - **Dynamic OAuth** only as a compatibility fallback.
8. Click **Deploy Custom Domain**.
9. Copy the public MCP URL from **Tunnel**. It has this shape:

```text
https://<subdomain.example.com>/mcp
```

For Raycast or another client that supports static headers, copy the generated
Cloudflare Access headers and paste them into the client:

```json
{
  "CF-Access-Client-Id": "<client-id>",
  "CF-Access-Client-Secret": "<client-secret>"
}
```

Single Header mode copies one custom header instead:

```json
{
  "CF-Access-Service-Token": "{\"cf-access-client-id\":\"<client-id>\",\"cf-access-client-secret\":\"<client-secret>\"}"
}
```

Keep Raycast's OAuth type set to Dynamic. Cloudflare Access is only an outer
transport gate; MacRemote's OAuth, host approval, and tool permissions still
control actual MCP access.

For Claude, Notion, or another client with OAuth client ID and secret fields,
copy the credentials from **Settings -> OAuth Client Credentials**. MacRemote
stores the secret in Keychain, disables dynamic registration for that mode, and
requires `client_secret_basic` or `client_secret_post` at the token endpoint.
Generate one credential entry per remote app. Static OAuth credentials are the
client identity; if Claude and Raycast reuse the same client ID and secret,
MacRemote correctly treats them as one client and only one entry appears under
**Clients**.

If Raycast reports that it cannot fetch MCP OAuth metadata, check the Cloudflare
Access application domain. It must be scoped to:

```text
<subdomain.example.com>/mcp*
```

It must not cover the entire hostname. Re-running **Deploy Custom Domain** with
a current MacRemote build migrates older MacRemote-created whole-host Access
applications and older `/mcp/*` applications to the path-scoped form.

### Deploy from the CLI

List available zones:

```bash
script/macremotectl cloudflare-zones --json
```

Provision Cloudflare resources:

```bash
script/macremotectl cloudflare-zones --json
CLOUDFLARE_API_TOKEN="<token>" \
script/macremotectl cloudflare-deploy \
  --zone example.com \
  --subdomain macremote \
  --origin-url http://127.0.0.1:60735 \
  --protect-access \
  --json
```

The CLI output includes the hostname, public URL, tunnel name, Access headers,
and an MCP URL hint. The tunnel run token is sensitive and is hidden by default.
Pass `--print-tunnel-token` only when you need to copy the token into another
runner:

```bash
CLOUDFLARE_API_TOKEN="<token>" \
script/macremotectl cloudflare-deploy \
  --zone example.com \
  --subdomain macremote \
  --origin-url http://127.0.0.1:60735 \
  --protect-access \
  --print-tunnel-token
```

The app path is preferred for normal use because it provisions the resources and
starts the named tunnel in one flow.

### Search indexing and URL privacy

MacRemote does not publish a website, sitemap, or directory page for the custom
domain. A client receives an OAuth-gated MCP endpoint, not a public landing
page. Still, do not treat the hostname as secret security.

For the lowest chance of the URL appearing in search results:

- Keep Cloudflare Access protection enabled.
- Do not link to the MacRemote hostname from public pages, docs, social posts,
  or issue trackers.
- Do not paste the full MCP URL into public logs or screenshots.
- Revoke OAuth grants, delete the specific client from **Clients**, rotate the
  OAuth client credentials, or stop the tunnel if access was shared with the
  wrong client.
- Revoke and recreate Cloudflare Access service tokens if their headers were
  exposed.

Cloudflare Access blocks ordinary crawlers that do not have the service-token
headers, and MacRemote OAuth still blocks tool access behind that. No custom
domain, hidden URL, or robots rule is a replacement for those controls.

### Troubleshooting

- **Deploy button is disabled**: choose a domain, enter a valid subdomain, paste
  a non-empty API token, and stop any currently running tunnel before deploying.
- **Cloudflare rejected the API token while trying to read DNS records**: the
  token is missing `Zone -> DNS -> Read` for the selected zone, or it was scoped
  to the wrong zone. `Zone -> DNS Settings` is not enough.
- **Rejected while creating or updating DNS record**: add `Zone -> DNS ->
  Write/Edit` for the selected zone.
- **Rejected while listing or creating Cloudflare Tunnels**: add account-level
  `Cloudflare Tunnel -> Read` and `Cloudflare Tunnel -> Write/Edit` for the
  account that owns the zone.
- **Rejected while listing Access applications or service tokens**: add
  zone-level `Access: Apps and Policies` read/write and `Access: Service Tokens`
  read/write for the selected zone.
- **`policy precedences must be unique`**: an older MacRemote-created Access app
  already has a policy at the requested precedence. Redeploy with a current
  MacRemote build; it lists existing policies, updates the MacRemote policy when
  present, and otherwise creates a new policy at the first free precedence.
- **Could not fetch MCP OAuth metadata**: Cloudflare Access is probably
  protecting the whole hostname. Edit the Access application domain to
  `<hostname>/mcp*`, or redeploy the custom domain from MacRemote so it can
  migrate the older whole-host Access app.
- **DOCTYPE HTML response from an MCP client**: the client received a Cloudflare
  Access HTML page instead of MCP/OAuth JSON. Use the copied `https://<host>/mcp`
  URL. If Access is enabled, confirm the client sends the copied Access headers
  on every MCP request.
- **A non-MacRemote DNS record already exists**: the hostname already has a DNS
  record that MacRemote will not overwrite. Pick a different subdomain or remove
  the conflicting record in Cloudflare.
- **A non-MacRemote Access application already exists**: the hostname already has
  an Access app that MacRemote will not overwrite. Pick a different subdomain or
  remove the conflicting Access app.
- **Visitors see Cloudflare 1016 or connection errors**: the DNS route may exist,
  but the named tunnel connector is not running on the Mac. Start the tunnel from
  MacRemote again.
- **Raycast gets blocked by Cloudflare Access**: paste both
  `CF-Access-Client-Id` and `CF-Access-Client-Secret` as static headers in the
  Raycast MCP server config.
- **Raycast connected but does not appear as a separate client**: generate a
  separate OAuth credential entry for Raycast in **Settings -> OAuth Client
  Credentials**, then reconnect Raycast with that client ID and secret. Reusing
  Claude's static OAuth credentials makes both apps the same OAuth client.

## Tool Model

MacRemote supports two tool modes:

- **CLI Adapter**: one MCP tool wraps one executable. The client supplies
  `args: string[]` and optional `stdin`. This delegates the executable's broad
  capability surface, so it should normally be `destructive`.
- **Command Template**: one MCP tool wraps a fixed argv template. Placeholders
  such as `{query}` become typed MCP parameters. This is the safer mode for
  exposing one workflow from a larger CLI.

Tools are never shell snippets. MacRemote blocks shell wrappers such as `sh`,
`bash`, `zsh`, `fish`, and `env`, then runs commands through direct `Process`
execution with a bounded environment, timeout, and output cap. Remote clients
must pass exact argv items; there is no `~`, `$HOME`, glob, pipe, redirection, or
command substitution expansion.

Current MCP tool descriptions include `title`, `description`, `inputSchema`,
`outputSchema`, and tool `annotations` such as `readOnlyHint`,
`destructiveHint`, `idempotentHint`, and `openWorldHint`.

### Local MCP Bridge

MacRemote can also import tools from local MCP servers and
re-expose them through the remote MacRemote MCP surface. This is for Mac-only
MCP servers already attached to local clients such as Claude Code, Codex,
Grok, OpenCode, Cursor, LM Studio, Xcode Coding Assistant, or Claude Desktop.

In the app, open **Tools → Local MCPs**, then use **Scan This Mac** to detect
local servers, inspect their upstream tools, import or refresh bridge tools,
and enable or disable the imported server surface.

Bridge tools do not use a shell. For streamable HTTP/SSE servers, MacRemote
initializes the upstream MCP server over HTTP, tracks the negotiated
`Mcp-Session-Id`, forwards exact JSON arguments to `tools/call`, and returns
the upstream result as the MacRemote tool output. For stdio servers, MacRemote
launches the configured executable path directly with its configured argv,
speaks JSON-RPC over stdin/stdout, forwards exact JSON arguments to
`tools/call`, and terminates the short-lived upstream process after the probe
or call. Upstream `inputSchema` and tool annotations are preserved where
available.

Scan known local agent configs and Claude extension manifests:

```bash
script/macremotectl scan-mcp --json --probe
```

Import a detected local MCP server from the CLI:

```bash
script/macremotectl add-mcp-server claude_extension.paste --replace
```

Or import a direct endpoint:

```bash
script/macremotectl add-mcp-server http://127.0.0.1:39725/mcp --name Paste --replace
```

By default, CLI imports allow local stdio MCP servers and loopback HTTP MCP
endpoints. Remote HTTPS MCP URLs require `--include-remote`. Secret-looking
literal headers are refused; use environment-backed headers, TOML config
references, or extension manifest references so tokens are resolved at call
time instead of copied into MacRemote's tool registry.

When a local client splits one upstream service into multiple MCP auth profiles,
MacRemote imports each configured server as its own bridge. MacRemote preserves
the upstream tool list exposed by each wrapper, so service-specific filtering
stays in the wrapper instead of becoming product-specific MacRemote behavior.

## Presets

The app detects installed commands and offers:

- **Tool Sets**: bulk-add groups such as All System Presets, Detected CLIs,
  Reminders, Podcasts, Developer, Text and Data, Media, Utilities, and
  Steipete / OpenClaw.
- **Detected CLIs**: direct adapters for installed commands.
- **Command Presets**: narrower read-only or write templates for common tasks.

From the command line:

```bash
script/macremotectl list-presets --json
script/macremotectl list-preset-sets --json
script/macremotectl add-preset preset.developer.codex --replace
script/macremotectl add-preset-set set.detected_clis --replace
```

To start fresh:

```bash
script/macremotectl clear-tools --yes
```

## Permissions

Each tool can declare macOS permission requirements:

- Full Disk Access
- Reminders, Calendars, Contacts, Photos, Camera, Microphone, Speech Recognition,
  Location
- Screen Recording, Accessibility, Automation, Local Network

MacRemote checks requirements from the same app-launched process context used for
remote tool calls. If protected access is missing, the app blocks server/tunnel
readiness and shows the exact targets to grant in System Settings. After changing
System Settings, use **Relaunch MacRemote** in the app or quit and reopen it
manually, then run **Check Access** again.

Full Disk Access is layered. Some CLIs need access on the host app, some need it
on the executable, and script-based CLIs may need it on their interpreter. Grant
every target MacRemote lists.

## Connected Clients

When a client connects for the first time, MacRemote records it under
**Clients**. From there, the user can pre-approve tools for that client so future
calls do not stop on per-call approval.

Tools can be added while the local server is running. MacRemote updates the
running tool surface immediately; connected clients need to refresh `tools/list`
or reconnect if their UI caches the list.

## Remote MCP Smoke Test

After the tunnel is running, copy the public MCP URL from **Tunnel**.

Direct MCP preflight:

```bash
MACREMOTE_MCP_URL="https://<host>.trycloudflare.com/mcp" \
./script/anthropic_mcp_smoke.py --mcp-preflight-only
```

Full Anthropic API smoke:

```bash
ANTHROPIC_API_KEY="<key>" \
MACREMOTE_MCP_URL="https://<host>.trycloudflare.com/mcp" \
./script/anthropic_mcp_smoke.py
```

Expected success markers:

```text
mcp_preflight=passed
mcp_tool_use_count=1
mcp_tool_result_count=1
smoke_test=passed
```

For a broad CLI adapter, use a harmless command and approve the call in
**Approvals**:

```bash
ANTHROPIC_API_KEY="<key>" \
MACREMOTE_MCP_URL="https://<host>.trycloudflare.com/mcp" \
./script/anthropic_mcp_smoke.py \
  --tool preset-or-custom-tool-id \
  --prompt 'Call the selected MacRemote MCP tool once with harmless read-only arguments.'
```

## Agent CLI

`script/macremotectl` configures MacRemote without clicking through the UI. It
does not approve OAuth clients, approve tool calls, or start public tunnels.

Install the CLI into `~/.local/bin`:

```bash
script/macremotectl install-cli
```

Build and launch:

```bash
macremotectl install --launch
```

Add a generic CLI adapter:

```bash
macremotectl add-tool \
  --name "GitHub CLI" \
  --summary "Run GitHub CLI by passing argv directly." \
  --executable "$(command -v gh)" \
  --mode cli \
  --category developer \
  --capability destructive \
  --replace
```

Add a fixed command template:

```bash
macremotectl add-tool \
  --name "Git Status" \
  --summary "Return short git status for this repository." \
  --executable /usr/bin/git \
  --mode template \
  --arg=-C \
  --arg="$PWD" \
  --arg=status \
  --arg=--short \
  --category developer \
  --capability readOnly \
  --replace
```

Use `--arg=value` for argv entries that start with a dash. Use `--require
fullDiskAccess`, `--require screenRecording`, and similar flags when a custom
tool needs macOS privacy access.

For tests or dry runs, write to a temporary registry:

```bash
MACREMOTE_TOOLS_FILE="$(mktemp -t macremote-tools.XXXXXX.json)" \
script/macremotectl add-preset preset.utilities.current_date
```

## Development

Build:

```bash
swift build
```

Test:

```bash
swift test
```

Build app bundle without launching:

```bash
script/build_and_run.sh --build-only
```

The development script signs the app with `MACREMOTE_CODESIGN_IDENTITY` when
set, otherwise it uses the first local Apple code-signing identity it can find.
If no usable identity is available, it falls back to local ad-hoc signing with a
stable designated requirement for `com.macstories.MacRemote`. That keeps macOS
privacy grants from being tied to a rebuild-specific code hash during local
development. Release builds should be Developer ID signed and notarized before
sharing broadly.

Build and verify launch:

```bash
script/build_and_run.sh --verify
```

Repository layout:

```text
App/       SwiftUI app entrypoint
Models/    Domain models
Services/  Server, tunnel, auth, process, and tool services
Stores/    App state and persistence
Support/   Formatting and small helpers
Views/     SwiftUI views
docs/      Architecture, threat model, and smoke-test notes
script/    Build, CLI, and smoke-test entrypoints
```

More docs:

- [INSTALL.md](INSTALL.md)
- [AGENTS.md](AGENTS.md)
- [CONTRIBUTING.md](CONTRIBUTING.md)
- [SECURITY.md](SECURITY.md)
- [docs/ARCHITECTURE_SECURITY.md](docs/ARCHITECTURE_SECURITY.md)
- [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md)
- [docs/END_TO_END_SMOKE_TEST.md](docs/END_TO_END_SMOKE_TEST.md)
