# Connect ChatGPT

ChatGPT connects to MacRemote as a **custom MCP server**: you add MacRemote's
public `/mcp` address in ChatGPT's Plugins page, sign in with OAuth, and
approve the sign-in on your Mac. This page has the steps, what ChatGPT needs,
and what MacRemote does during sign-in.

**Not yet checked live.** These steps follow OpenAI's documentation as of
November 2026. Nobody has run them against MacRemote 1.0 in the current
Plugins flow. The open questions are listed in [Not checked
yet](#not-checked-yet). If something on screen differs from this page, trust
the screen and tell us.

## Before you start

You need:

- ChatGPT on the web, at [chatgpt.com](https://chatgpt.com). OpenAI says you
  can add a custom MCP server only on the web, not in the mobile apps.
- A ChatGPT plan that allows custom MCP servers. OpenAI's [Help
  Center](https://help.openai.com/en/articles/12584461) says:
  - **Business**: full MCP, read and write. Only admins and owners can add a
    custom MCP server.
  - **Enterprise and Edu**: full MCP. Admins and owners can add one, and can
    let other members do it with the **Create plugins with MCPs** permission.
  - **Pro**: custom MCP servers with read and fetch permissions only. Most
    MacRemote tools that change something may not be available.
  - **Plus, Go, and Free**: OpenAI does not say.
- MacRemote open on your Mac, with at least one tool shared in **Tools** and a
  public link running. [Install MacRemote](../INSTALL.md) covers both.

Use **Your Domain** if you can. An **Instant Link** changes each time you start
it, and you would have to remove MacRemote from ChatGPT and add it again with
the new address.

A ChatGPT confirmation and a MacRemote approval are separate. Neither one
replaces the other. Read OpenAI's [risks and
safety](https://developers.openai.com/api/docs/mcp#risks-and-safety) notes
before you share tools that write or delete.

## 1. Prepare MacRemote

1. Leave the sign-in method on **Dynamic OAuth**, the default. In **Settings →
   General → Connect an App**, the **Sign-in method** row should say
   **Dynamic OAuth** with a **Default** chip. ChatGPT cannot connect while
   **OAuth Client Secret** or **Single Header** is selected.
2. Optional: choose **ChatGPT** under **App** in the same section. This only
   changes the instructions shown there.
3. Copy the public address from **Connection**. It ends in `/mcp`:

   ```text
   https://<public-host>/mcp
   ```

## 2. Add MacRemote in ChatGPT

1. Go to [chatgpt.com/plugins](https://chatgpt.com/plugins), or open
   **Plugins** in the sidebar.
2. Select the **+** button, then **Add custom MCP server**.
3. Enter a name, such as **MacRemote**, and an optional description.
4. Under **Connection**, choose **Server URL** and paste MacRemote's `/mcp`
   address.
5. Under authentication, choose **OAuth**. Let ChatGPT discover MacRemote's
   settings; do not fill in the authorization and token URLs by hand.
6. If ChatGPT asks how it should register, keep **Dynamic Client Registration
   (DCR)**. MacRemote does not offer the other method, CIMD.
7. Read the risk warning and select **I understand and want to continue**.
8. Select **Create as a plugin**.

ChatGPT then opens a MacRemote sign-in page in your browser. The page shows a
six-digit code. Approve it on your Mac as soon as it opens, as in the next
section. MacRemote checks the sign-in before it answers any request, including
ChatGPT's request for the tool list, so ChatGPT cannot show the tools until you
approve.

**Icon.** OpenAI's current steps do not mention an icon field in this form. If
yours has one, MacRemote serves a small PNG for it: open your public address
with `/macremote-icon-256.png` in place of `/mcp`, save the image, and choose
it there.

## 3. Approve the sign-in on your Mac

1. Open **Requests** in MacRemote.
2. Compare the six-digit code with the code on the sign-in page ChatGPT
   opened. Approve only when they match. See [Approving a new
   app](GUIDE.md#approving-a-new-app).
3. Return to ChatGPT and let it finish connecting.
4. Review the tools ChatGPT found, and install the plugin.

A sign-in request expires after 5 minutes. If it expires, start again in
ChatGPT.

## 4. Use MacRemote in a chat

1. In the prompt box, type `@` and pick MacRemote.
2. Ask for something harmless and read-only first. With **Current Date**
   shared, ask what day it is.
3. The choice applies to that one message. Type `@` and pick MacRemote again
   when a follow-up needs it.

ChatGPT may ask you to confirm a tool that can change something, depending on
your ChatGPT app permissions and on what the chat is doing. MacRemote's own
approval does not depend on ChatGPT: a tool that can change something asks on
your Mac before it runs, unless you chose **Always Allow** for ChatGPT and that
tool. Test a tool that writes with something you can undo, and expect the
MacRemote prompt.

**After you change your shared tools**, open MacRemote's plugin at
[chatgpt.com/plugins](https://chatgpt.com/plugins), choose **Refresh**, and
start a new conversation. A workspace admin refreshes a published workspace
plugin from the workspace settings instead.

MacRemote has no `search` or `fetch` tools. ChatGPT does not need them for a
custom MCP server, but without them MacRemote is not used by company knowledge,
and deep research can use custom servers only to read.

## What MacRemote does during sign-in

ChatGPT finds everything it needs from MacRemote's public address. This is
what MacRemote offers under **Dynamic OAuth**:

- **Discovery.** `/.well-known/oauth-protected-resource` (also at `…/mcp`)
  names MacRemote's own public address as the one authorization server.
  `/.well-known/oauth-authorization-server` (also at `…/mcp`) gives the
  `/authorize`, `/token`, and `/register` endpoints, with an `issuer` that
  matches.
- **Registration.** ChatGPT registers itself through `/register` (DCR).
  MacRemote does not advertise CIMD (Client ID Metadata Documents), so ChatGPT
  does not offer it.
- **PKCE.** MacRemote requires PKCE with `S256` and refuses a sign-in without
  it.
- **Client authentication.** MacRemote accepts `none`, `client_secret_basic`,
  and `client_secret_post` at the token endpoint. An app that asks for a
  secret method gets a secret of its own; one that names no method is
  registered as a public client.
- **Scope.** The only scope is `mcp:tools`. MacRemote lists it in its metadata
  and in the `WWW-Authenticate` header it sends with a 401.
- **Issuer check (RFC 9207).** MacRemote advertises
  `authorization_response_iss_parameter_supported: true` and adds `iss` to
  every redirect back to the app, after both an approval and a denial. OpenAI
  says ChatGPT then uses its stable redirect address,
  `https://chatgpt.com/connector_platform_oauth_redirect`. MacRemote sends the
  app back to whatever redirect address it registered.
- **Tokens.** An access token lasts 15 minutes and a refresh token 24 hours by
  default. Change both in **Settings → Security → Token lifetime**. Each
  refresh hands out a new refresh token with a fresh lifetime, so an app that
  uses MacRemote at least once a day stays signed in. After a longer gap, sign
  in again.

MCP's 2026-07-28 revision deprecates DCR in favor of CIMD, with removal no
earlier than mid-2027. ChatGPT and Claude both still support DCR.

## Result cards

ChatGPT supports MCP Apps, so MacRemote can show results as cards there. Cards
are off until you turn on **Show result cards** in **Settings → General →
Result Cards**, and each tool family has its own switch. Tools then point to
`ui://macremote/output-v9.html` through `_meta.ui.resourceUri`, with the older
`openai/outputTemplate` name as an alias. Every result also carries plain text
and `structuredContent`, so a tool works without its card.

If a card does not appear:

- check **Show result cards** and the tool's family switch in MacRemote;
- refresh the plugin in ChatGPT and start a new conversation;
- check that `resources/read` for the card returns `text/html;profile=mcp-app`;
- look in the browser console for content-security or loading errors.

## Troubleshooting

- **ChatGPT says DCR is unavailable, or the server does not implement OAuth.**
  Confirm that **Dynamic OAuth** is selected in MacRemote and that the address
  ends in `/mcp`. Open
  `https://<public-host>/.well-known/oauth-authorization-server` in a browser:
  it should return JSON with a `registration_endpoint`. Then remove the plugin
  and add it again, in case ChatGPT kept older settings.
- **ChatGPT asks for both an Auth URL and a Token URL.** The manual OAuth fields
  were opened. Clear them and let ChatGPT discover the settings.
- **The sign-in page says `Missing code_challenge`.** The sign-in page was
  opened without ChatGPT's PKCE values. Start the connection from ChatGPT; do
  not open `/authorize` yourself.
- **A tool seems unavailable.** Start a new conversation, type `@`, pick
  MacRemote, and ask for the task in plain words. Check MacRemote's
  **Activity** for an incoming call. On a plan with read-only access, ChatGPT
  may hide tools that change things.
- **The browser says the sign-in can't start.** MacRemote refused the request.
  **Activity** says why.

### Protocol version errors

These are MCP protocol answers, not sign-in failures. Each lists the versions
MacRemote supports for the kind of request that was sent.

- **`Unsupported protocol version.`** (`-32022`, HTTP 400): the app sent an
  `MCP-Protocol-Version` header MacRemote does not implement. `error.data`
  carries `requested` and `supported`. An older-style request is offered
  `2025-11-25`, `2025-06-18`, and `2025-03-26`; a request for the current
  protocol is offered `2026-07-28`.
- **`Modern MCP requests require protocolVersion and clientCapabilities
  metadata.`** (`-32602`, HTTP 400): the app asked for `2026-07-28`, through
  the header or the `io.modelcontextprotocol/protocolVersion` key, but did not
  send both `params._meta["io.modelcontextprotocol/protocolVersion"]` and
  `params._meta["io.modelcontextprotocol/clientCapabilities"]`. A
  `clientCapabilities` object on its own does not count as asking for the
  current protocol, because ChatGPT sends one on otherwise older-style calls
  (DESIGN-SPEC D52).

## Not checked yet

None of these has been tried with MacRemote 1.0:

- the whole Plugins flow above, from **Add custom MCP server** to a tool call;
- which tools a Pro, Plus, or other personal plan shows, given that MacRemote
  shares tools that change things;
- whether the add form has an icon field, and its size limit;
- whether ChatGPT asks for a default scope;
- whether ChatGPT uses its stable redirect address with MacRemote;
- using an installed plugin from ChatGPT's iPhone or Mac app;
- whether ChatGPT uses MCP 2026-07-28 or the older protocol with MacRemote.

## Publication

MacRemote is not in ChatGPT's plugin directory and has not been submitted.
A submission goes through [OpenAI's plugin
submission](https://developers.openai.com/plugins/deploy/submission), needs a
verified developer identity and a stable public HTTPS address (an Instant Link
does not qualify), and must meet the [plugin
guidelines](https://developers.openai.com/plugins/plugin-guidelines). It would
need its own audit and live tests first.

## OpenAI references

- [Add custom MCP server](https://developers.openai.com/api/docs/guides/custom-mcp-server)
- [Connecting custom MCP servers in ChatGPT](https://help.openai.com/en/articles/12584461) (Help Center)
- [Connect and test in ChatGPT](https://developers.openai.com/plugins/deploy/connect-chatgpt)
- [Authentication](https://developers.openai.com/plugins/build/auth)
- [Build an MCP server](https://developers.openai.com/plugins/build/mcp-server)
- [Risks and safety](https://developers.openai.com/api/docs/mcp#risks-and-safety)
