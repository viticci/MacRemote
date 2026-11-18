# ChatGPT Developer-Mode Testing

MacRemote can be tested as a draft ChatGPT app in developer mode. The public
Dynamic OAuth path has completed a live ChatGPT end-to-end verification. This
is still a development workflow only: do not submit MacRemote through the
plugin submission portal, and do not describe it as reviewed or published.

ChatGPT connects through MacRemote's app-managed Cloudflare **Public URL** with
**Dynamic OAuth** and Dynamic Client Registration (DCR). Dynamic OAuth is
MacRemote's default sign-in method, so a fresh install is already set up for this
flow. MacRemote's generic **Single Header** sign-in method is an *Advanced*
option that remains available for MCP clients that can only send a static bearer
header; it is not the ChatGPT developer-mode setup documented here, and ChatGPT
cannot use it.

## Live validation status

On 2026-07-11, a ChatGPT Pro Work conversation connected through a Cloudflare
custom domain, completed confidential Dynamic Client Registration plus S256
PKCE after approval on the Mac, called the shared RemCTL **Upcoming** tool, and
rendered MacRemote's adaptive Reminders widget in ChatGPT for iPhone. This proves
the public Dynamic OAuth path, a read-only tool call, and widget delivery. It
predates MCP `2026-07-28`, so it does not prove current protocol or MCP Apps
negotiation, publication review, or every write and destructive approval flow.

## Before you start

You need:

- macOS 26 or later and a running MacRemote build;
- at least one tool added and shared in **Tools**;
- ChatGPT developer-mode access on the web;
- a current browser session at [chatgpt.com](https://chatgpt.com).

Review OpenAI's [developer-mode warning and safety
guidance](https://developers.openai.com/api/docs/guides/developer-mode) before
sharing write or destructive tools. A ChatGPT confirmation and a MacRemote
approval are independent controls. Neither one replaces the other.

## Connect a public ChatGPT draft with Dynamic OAuth

### 1. Prepare MacRemote

1. Open MacRemote **Settings → General**.
2. Choose **ChatGPT** under **App**. This only changes the setup instructions
   shown below it; it does not change your sign-in method.
3. Confirm the read-only **Sign-in method** row says **Dynamic OAuth** with a
   **Default** chip. It should already. If it shows **Advanced** instead, open
   **Advanced sign-in methods** — which opens by itself in that case — and choose
   **Dynamic OAuth (Default)**. ChatGPT cannot connect over the public link while
   OAuth Client Secret or Single Header is active.
4. In **Tools**, add the tools you want to test and turn on **Share** only for
   those tools.
5. In **Connection**, start the local server.
6. Expand **Address**, choose **Instant Link** or **Your Domain**, and go public.
7. Copy the public MCP URL. It must end in `/mcp`:

   ```text
   https://<public-host>/mcp
   ```

An Instant Link changes when it is restarted. Use **Your Domain** when you need
a saved ChatGPT draft to keep the same URL.

### 2. Enable ChatGPT developer mode

1. On the ChatGPT web app, open **Settings → Security and login**.
2. Turn on **Developer mode**.
3. Open **Settings → Plugins**, or go to
   [chatgpt.com/plugins](https://chatgpt.com/plugins).
4. Select the plus button to create a developer-mode app.

OpenAI documents current eligibility, workspace controls, and risks in
[ChatGPT developer mode](https://developers.openai.com/api/docs/guides/developer-mode).

### 3. Create the draft app

1. Name the draft **MacRemote**.
2. Optional: add the icon. ChatGPT shows one only if you upload it here, as a
   PNG of 10 KB or less. Open your public address with
   `/macremote-icon-256.png` in place of `/mcp`, save the image, and choose it
   under **Icon**.
3. Choose a public URL connection and paste MacRemote's `/mcp` URL.
4. Choose **OAuth** authentication.
5. Let ChatGPT discover MacRemote's protected-resource and authorization-server
   metadata.
6. In advanced OAuth settings, keep **Dynamic Client Registration (DCR)**.
   ChatGPT selects it and lists CIMD as unavailable.
7. Use `mcp:tools` when ChatGPT asks for a default scope.
8. Read and select ChatGPT's custom-MCP risk acknowledgement.
9. Create the app, then choose **Connect MacRemote**. It should appear as a
   development app. ChatGPT surfaces may group it under **Drafts** or
   **Installed**.

MacRemote registers DCR clients and uses authorization-code PKCE with `S256`.
Under Dynamic OAuth it advertises the `none`, `client_secret_basic`, and
`client_secret_post` token authentication methods. An app that asks for one of
the secret methods gets a secret of its own; an app that names no method is
registered as a public client. MacRemote does **not**
advertise Client Identifier Metadata Document
(CIMD) support, so ChatGPT does not offer CIMD. Do not manually fill only one of the
authorization and token URLs; ChatGPT's manual OAuth form requires both, while
normal MacRemote setup uses discovery.

### 4. Approve the connection on the Mac

ChatGPT's OAuth flow creates a separate request in MacRemote:

1. Open **Requests** in MacRemote.
2. Review the ChatGPT connection request. Compare its six-digit code with the
   code on the MacRemote sign-in page that ChatGPT opened in your browser.
3. Approve it only when the codes match. See
   [Approving a new app](GUIDE.md#approving-a-new-app).
4. Return to ChatGPT and let the draft finish connecting.

ChatGPT developer mode does not auto-approve MacRemote. MacRemote also does not
auto-approve ChatGPT's confirmations. Write, destructive, and broad command
calls can therefore require a ChatGPT confirmation and a separate MacRemote
request.

### 5. Use and verify the draft

1. On the web, start a new conversation, choose **Plus → Developer mode**, and
   select **Mac Remote**. In ChatGPT for iPhone, the live-tested alternative is
   to attach **Mac Remote** from the Work/app picker.
2. Confirm **Mac Remote** is attached to the new conversation.
3. Ask for one harmless read-only task in natural language, such as "Show me
   tasks due tomorrow." An exact tool-name prompt is useful for diagnosis, but
   normal ChatGPT routing works best from the task itself.
4. In the draft's detail page, use **Refresh** after changing MacRemote's shared
   tools or descriptions.
5. Test one write-capable tool only with reversible input, and confirm that its
   MacRemote request appears before execution unless that app already has an
   explicit Always Allow policy.

For the MCP Apps UI path, call a shared tool that has automatic UI enabled. RemCTL lookup, diagnostic, and flexible-command tools intentionally return results without cards. A tool with an explicit typed
presentation can use a richer treatment: bridged RemCTL reads use purple
reminder rows, bridged NotesCTL reads use yellow documents/rows, and dedicated
OverCTL tools use orange episode rows. Every other
tool, including a Flexible Command, uses the safe semantic result. Its pretty UI
does not show raw JSON, terminal commands, executable paths, credentials, hidden
metadata, or user-only content. A host that does not negotiate MCP Apps ignores
the UI metadata and receives the same text and structured fallback; that
capability fallback is different from a tool having no curated presentation
profile.

Recorded pass (2026-07-11): the RemCTL **Upcoming** call returned successfully
and ChatGPT for iPhone rendered the then-current `ui://macremote/output-v2.html`
with the returned reminders.

If a shared tool result does not render as a widget after ChatGPT negotiated MCP
Apps:

- confirm **Show result cards** is on in MacRemote's Settings › General, and
  the tool's family is on (cards are off by default);
- refresh the draft app in ChatGPT;
- confirm the tool descriptor points to `ui://macremote/output-v9.html`;
- confirm `resources/read` returns `text/html;profile=mcp-app`;
- check the browser console for widget CSP or resource-loading errors.

For NotesCTL, verify Markdown and transcript text render as text rather than
HTML, and that View Note re-enters the safe `notesctl_show` route. For OverCTL,
verify the orange treatment, nested `data` rows, Preview state for a dry-run,
and a visible warning when a submitted write was not confirmed by read-back.
These are developer-mode test instructions, not evidence that the current v7
widget has been proved live in ChatGPT.

MacRemote publishes standard MCP Apps metadata and compatibility aliases for
older hosts, including `_meta.ui.resourceUri`, `ui/resourceUri`, and
`openai/outputTemplate`. Tool results keep `content` and `structuredContent` as
the non-widget fallback; widget-only render hints stay in `_meta`.

### OAuth setup errors

- **DCR is unavailable:** ChatGPT did not discover a `registration_endpoint`.
  Confirm **Dynamic OAuth** is selected in MacRemote, verify the public URL ends
  in `/mcp`, and confirm both `/.well-known/oauth-authorization-server` and
  ChatGPT's `/.well-known/oauth-authorization-server/mcp` compatibility route
  return the same registration endpoint. Refresh OAuth discovery and recreate
  the draft if it cached older metadata.
- **ChatGPT asks for both Auth URL and Token URL:** the manual OAuth form was
  partially enabled. Clear the manual values and use discovery. Supplying only
  one endpoint is invalid.
- **`Missing code_challenge`:** the authorization endpoint was opened without
  ChatGPT's PKCE request. Use the current MacRemote build and let ChatGPT start
  the DCR flow; do not browse directly to `/authorize`.
- **ChatGPT says the MCP server does not implement OAuth:** verify that the
  public well-known metadata routes return JSON.
- **The app is installed but a tool appears unavailable:** start a new Work
  conversation, attach **Mac Remote** again, and ask for the task naturally.
  ChatGPT tool routing can differ by conversation and product surface. Check
  MacRemote Activity for an incoming call before treating this as a server
  discovery failure.
- **ChatGPT reports `search action not found` or marks the app
  non-retrievable:** this is not a developer-mode tool-call requirement.
  OpenAI's [developer-mode
  guide](https://developers.openai.com/api/docs/guides/developer-mode#how-to-use)
  says `search` and `fetch` are not required in developer mode. Attach **Mac
  Remote** through the Work or Developer mode picker and ask for the desired
  tool task.

### Protocol version errors

These are protocol answers, not OAuth failures. Their `supported` lists stay in
the request's era so a legacy client is never invited into modern MCP.

- **`Unsupported protocol version.` (`-32022`, HTTP `400`):** the client sent
  an `MCP-Protocol-Version` header MacRemote does not implement — either older
  than the `2025` compatibility set or a future revision. `error.data` carries
  `requested` and `supported`; the client should send one of the listed
  versions. A legacy-shaped request receives only `2025-11-25`,
  `2025-06-18`, and `2025-03-26`; a modern claim receives only `2026-07-28`.
- **`Modern MCP requests require protocolVersion and clientCapabilities
  metadata.` (`-32602`, HTTP `400`):** the client explicitly claimed modern MCP
  through the `2026-07-28` header or the namespaced protocolVersion key but did
  not send a valid complete envelope —
  `params._meta["io.modelcontextprotocol/protocolVersion"]` plus
  `params._meta["io.modelcontextprotocol/clientCapabilities"]`. A lone
  clientCapabilities object does not select the modern era: live ChatGPT sends
  exactly that field on otherwise legacy `tools/call` requests, so MacRemote
  keeps the call in its negotiated legacy session (D52). A bare modern header
  remains malformed modern and never downgrades.

## Publication status

These instructions create a private developer-mode draft. They do not establish
that MacRemote meets the [plugin app
guidelines](https://developers.openai.com/apps-sdk/app-guidelines), has a
submission-ready production widget domain and listing, or has passed OpenAI
review. Do not submit or publish it yet. Before any future submission, perform a
fresh guidelines audit, complete the required production metadata and policy
work, and repeat a fresh public-URL test against the current ChatGPT product.

Official references:

- [ChatGPT developer mode](https://developers.openai.com/api/docs/guides/developer-mode)
- [Authentication](https://developers.openai.com/apps-sdk/build/auth)
- [Build an MCP server](https://developers.openai.com/apps-sdk/build/mcp-server)
- [Risks and safety](https://developers.openai.com/api/docs/mcp#risks-and-safety)
- [Submit plugins](https://learn.chatgpt.com/docs/submit-plugins)
