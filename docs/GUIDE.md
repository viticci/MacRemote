# MacRemote Guide

Everything MacRemote does, in one place: going public, signing apps in, the
tools you share, approvals, File Transfer, and what MacRemote does in your
Cloudflare account. New here? The [Club Beta Guide](CLUB_BETA.md) walks you
through the first run, and the [README](../README.md) explains what MacRemote is.

- [Get Started](#get-started): [Instant Link](#fastest-instant-link),
  [Your Domain](#stable-address-your-domain), and
  [sign-in methods](#sign-in-methods)
- [Cloudflare Helper](#cloudflare-helper) and
  [Cloudflare API Token](#cloudflare-api-token)
- [Notifications](#notifications)
- [Tool Model](#tool-model): [sharing](#sharing), [approvals](#approvals),
  [reliability](#reliability), [File Transfer](#built-in-file-transfer-tools),
  and the [Local MCP Bridge](#local-mcp-bridge)
- [Presets](#presets) and [Permissions](#permissions)
- [Connected Apps](#connected-apps)

## Get Started

Welcome lets a fresh Mac start with the optional **Current Date** tool or an
available bundle, then handles any required macOS permissions and the public
address. For screenshots and troubleshooting, use the
[Club Beta Guide](CLUB_BETA.md).

### Fastest: Instant Link

Instant Link creates a random temporary address. It needs no Cloudflare account
or domain.

1. Open MacRemote. For the simplest first test, select **Current Date** in
   Welcome. It is a read-only starter built into macOS.
2. Continue through any macOS permission steps for those tools.
3. Choose **Instant Link**.
4. If asked, open **What gets installed** and choose **Install Helper**.
5. Choose **Start Instant Link**.
6. Copy the public URL and paste it into your MCP app.
7. Return to MacRemote and approve the connection in **Connect your app**. If
   you already closed Welcome, approve it in **Requests**. Approve only when
   the code matches; see [Connected Apps](#connected-apps).

The address changes each time you stop the link and go public again.

### Stable address: Your Domain

Your Domain creates a stable address such as `macremote.example.com`. Add your
domain to Cloudflare and create the [Cloudflare API token](#cloudflare-api-token)
before you begin.

1. In Welcome, choose **Your Domain**, then choose **Set Up Your Domain**. Later,
   open **Connection**, expand **Address**, and select **Your Domain**.
2. If asked, install Cloudflare's helper from the Address card.
3. Under **1. Create and paste an API token**, paste the token. MacRemote keeps
   it in memory and does not save it.
4. Choose **Load Domains**.
5. Choose your Cloudflare domain.
6. Enter a subdomain, such as `macremote`.
7. Choose **Deploy Your Domain**.
8. Copy the public URL, paste it into your MCP app, and approve the connection
   as in step 7 above.

After a deploy, MacRemote keeps one key in your Keychain: the key that runs
this public link. It cannot change your DNS or create tunnels. With it, **Go
Public** brings your domain back, also after a restart, with no API token and
no Wrangler. Changing the domain or subdomain deletes the key.

With **Your Domain** chosen and nothing deployed yet, **Go Public** opens the
Address card so you can deploy the domain. It does not start an Instant Link.
MacRemote's local server reuses the port your domain was deployed with. If
another program has taken that port, deploy your domain again.

The public URL ends in `/mcp`:

```text
https://<trycloudflare-host>/mcp
https://<subdomain.example.com>/mcp
```

Share that URL only with the MCP app you are connecting.

### Sign-in methods

**Dynamic OAuth** is the default: the app registers itself and you approve it on
the Mac. Use it for ChatGPT, Claude, Raycast, and Notion when the app supports
it. Two alternatives live behind **Advanced sign-in methods** in **Settings →
General → Connect an App**:

- **OAuth Client Secret** for an app that asks you for a client ID and secret.
  Copy them from **Settings → Security → OAuth Client Credentials**, and
  generate one entry per app. Apps that register themselves, including Claude
  and ChatGPT, cannot connect while this method is selected.
- **Single Header** for an app that can send one fixed `Authorization` header
  but cannot finish an OAuth sign-in. Generate, rotate, or delete the token in
  **Settings → Security → Single Header Token**. There is no connection
  approval in this mode. Tool-call approvals still apply.

MacRemote accepts one sign-in method at a time. Changing the method signs out
every app that connected another way, and Settings says what was removed. A
client ID and secret you created work only under **OAuth Client Secret**.

The **App** picker in that section only changes which setup instructions are
shown. It never changes the sign-in method.

Claude's **Add custom connector** dialog asks how Claude should identify
itself. **Use Claude's published identity** and **Register automatically** both
work with Dynamic OAuth. Keep **Sign in now** selected.

If MacRemote refuses a sign-in request, the browser page says so and
**Activity** records the reason. Nothing appears in **Requests**, because a
refused request never asks for your approval.

For ChatGPT, use the [developer-mode testing
guide](CHATGPT_DEVELOPER_MODE.md). It describes draft testing, not plugin
submission or publication.

### The icon an app shows for MacRemote

Each app decides this on its own, and MacRemote cannot set it for them:

- **ChatGPT** shows an icon only if you upload one in its **Add custom MCP
  server** form, as a PNG of 10 KB or less. Your link serves one that fits:
  open your public address with `/macremote-icon-256.png` in place of `/mcp`,
  save the image, and choose it under **Icon**.
- **Claude** shows the website icon of your link's main domain, not
  MacRemote's. With **Your Domain** on `mac.example.com`, that is whatever icon
  `example.com` serves. With an **Instant Link**, it is Cloudflare's.

## Cloudflare Helper

Public links run on `cloudflared`, Cloudflare's tunnel client. MacRemote can
install its own copy, so nothing has to be set up in a terminal first.

**Install Helper** appears in **Connection → Address**, in the Welcome window,
and in **Settings → General → Cloudflare Helper**. **What gets installed** shows
the exact version, publisher, download size, download URL, and SHA-256 before
anything is downloaded. MacRemote downloads that one pinned release itself and
keeps it only when the checksums and Cloudflare's signature match.

The managed copy lives in
`~/Library/Application Support/MacRemote/CloudflaredHelper/` and is checked
again before every launch. It is not a tool, and no remote app can call it.

MacRemote uses its own copy when it has one, otherwise a copy you installed,
for example with `brew install cloudflared`. **Settings → General → Cloudflare
Helper** shows which one is in use and offers **Update Helper** and **Remove
Helper…**. Both are unavailable while the public link is running. A copy you
installed yourself is reported, never modified.

A helper installed by an earlier MacRemote release keeps working after you
update the app. Settings offers the newer version.

Quitting MacRemote always stops the helper, so the public link stops too. The
same happens if MacRemote crashes or is force-quit: the helper stops at once.
While a public link is on, Activity Monitor shows a second, idle MacRemote
process. That is the part that stops the helper if the app goes away.

## Notifications

MacRemote uses macOS notifications to tell you that an app is waiting for
approval, or that a setup step that was passing has stopped. **Settings →
Notifications** shows whether they are allowed.

A notification banner offers **Deny** only. To approve, open the request in
MacRemote, where the arguments or the sign-in code are shown.

## Cloudflare API Token

Your Domain needs a Cloudflare API token. Create a custom user token; Cloudflare
documents the steps in its
[API-token guide](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/).

1. In the Cloudflare dashboard, open **My Profile → API Tokens**. For an
   account-owned token, an administrator instead opens **Manage Account → API
   Tokens**.
2. Choose **Create Token**, then **Create Custom Token**.
3. Give it a recognizable name, such as `MacRemote Tunnel`.
4. Add exactly these four permissions:
   - `Account -> Cloudflare Tunnel -> Edit`
   - `Zone -> Zone -> Read`
   - `Zone -> DNS -> Edit`
   - `Zone -> Config Rules -> Edit`
5. Under **Account Resources**, choose **Include -> Specific account**, then
   select only the account that owns the domain.
6. Under **Zone Resources**, choose **Include -> Specific zone**, then select
   only the zone MacRemote will use.
7. Continue to the summary, check the four permissions and both resource
   scopes, then create the token.
8. Copy the secret immediately. Cloudflare shows it only once.
9. Save it in your password manager, then paste it into MacRemote only when
   loading domains or deploying.

MacRemote keeps the token in memory only. If a token is pasted into a chat, a
log, or a public issue, revoke it and create a replacement.

- Choose **Zone -> DNS**, not **Zone -> DNS Settings**. DNS Settings does not
  grant access to DNS records.
- **Edit** already includes read access. Do not add broader permissions.
- Config Rules access lets MacRemote turn off Cloudflare's Browser Integrity
  Check for its own hostname only. That check otherwise blocks MCP apps, which
  are not browsers, before their requests reach MacRemote.

### What MacRemote creates

When you deploy, MacRemote:

1. Checks the selected domain and subdomain, and starts the local server if
   needed.
2. Refuses a DNS record or a same-name tunnel it cannot show it created.
3. Adds one rule that turns off Browser Integrity Check for the MacRemote
   hostname. Other rules are left alone.
4. Creates or reuses a Cloudflare Tunnel named after the hostname and points
   it at the local server.
5. Creates or updates the DNS record for the hostname.
6. Starts the tunnel. The link is ready when Cloudflare's helper reports a
   connection.

MacRemote checks every sign-in itself. Nothing is checked at Cloudflare.

To take over a hostname that already has a DNS record or tunnel, delete or
rename that resource in Cloudflare first, or pick another subdomain.

### Keeping the address private

The hostname is public. It serves a small landing page, icons, and the sign-in
pages. Calling a tool always needs a sign-in. A download link needs no sign-in
but cannot be guessed and expires; see
[Built-in File Transfer Tools](#built-in-file-transfer-tools).

- Do not post the hostname or the full MCP URL in public pages, logs, or
  screenshots.
- If the wrong app got access, sign it out in **Apps**, or use **Sign Out All
  Apps…** in **Settings → Security**, or stop the public link.
- Rotate the Single Header token in **Settings → Security** if its header was
  exposed.

### Troubleshooting

- **Deploy button is disabled**: choose a domain, enter a valid subdomain, paste
  an API token, and stop any running public link.
- **Cloudflare rejected the API token**: compare the token with the four
  permissions and two resource scopes above. `Zone -> DNS Settings` is not
  `Zone -> DNS`.
- **A non-MacRemote DNS record already exists**: pick a different subdomain or
  remove the record in Cloudflare.
- **MacRemote cannot prove that it owns a same-name tunnel**: pick a different
  subdomain or rename the existing tunnel.
- **Visitors see Cloudflare 1016 or connection errors**: the DNS record exists
  but the tunnel is not running. Go public again.
- **An app gets Cloudflare error 1010**: deploy again with a token that has
  Config Rules edit access.
- **Install Helper stopped with "didn't match what Cloudflare published"**:
  MacRemote discarded the download. Try again, or install `cloudflared`
  yourself and MacRemote will use your copy.
- **Remove Helper or Update Helper is disabled**: stop the public link first.
- **Two apps appear as one under Apps**: they share one OAuth client ID and
  secret. Generate a separate entry for each app in **Settings → Security →
  OAuth Client Credentials**.

## Tool Model

A command-line tool is authored in one of two modes:

- **Fixed Command**: one tool runs one fixed command. Placeholders such as
  `{query}` become typed inputs. Use this to share one workflow from a larger
  program.
- **Flexible Command**: one tool passes any arguments the calling app sends to
  one program. This shares everything the program can do.

Tools are never shell snippets. MacRemote blocks shell wrappers such as `sh`,
`bash`, `zsh`, `fish`, and `env`, and runs each command directly with a timeout
and an output cap. There is no `~`, `$HOME`, wildcard, pipe, or redirection
expansion.

Each tool is labeled **Read-only**, **Write**, or **Destructive**. Read-only
tools run without asking. Write and Destructive tools ask first. A Flexible
Command always asks first, even when it is labeled Read-only, because nothing
can check that the arguments it receives only read. An app's Always Allow rule
is the one exception; see [Connected Apps](#connected-apps).

### Sharing

Only tools with **Share** turned on are visible to connected apps. A Flexible
Command added from the Library starts **Not Shared**. So do tools found by a
scan and the built-in File Transfer tools.

Sharing follows the tool you last saw in MacRemote. If a tool appears or
changes in the saved tools file (`tools.json`) outside the app, it starts Not
Shared and Activity says so. If MacRemote's preferences are missing, every
saved tool starts Not Shared.

Tools can be added while the local server is running. Connected apps may need
to refresh their tool list.

### Approvals

When a tool asks first, MacRemote shows the request in the floating Approval
window and in **Requests**.

- Every argument is shown in full, including standard input, in a list that
  scrolls. Invisible characters are written out so they cannot hide what will
  run.
- A call is checked before you are asked. Invalid arguments, blocked commands,
  and paths that File Transfer refuses fail without a prompt.
- A call waits 90 seconds for your answer, then expires.
- One app can have 4 calls waiting. All apps together can have 16.
- The **Requests** menu shortcuts act only on the request the Approval window
  is showing. **Always Allow for App** is unavailable there for tools that ask
  every time; use the button on the request.
- If the app disconnects, its waiting request is withdrawn.

### Reliability

- Every call runs to completion inside the request that made it. There is no
  background execution. Over the public link, Cloudflare ends a request that
  has had no response for 100 seconds, so a call must finish within that time.
- A tool that reaches its timeout is stopped, together with every process it
  started.
- Only a limited number of calls run at once. Extra calls get an immediate
  "server is busy, retry shortly" result.
- A result too large to return directly is saved and returned as a download
  link.
- If the public link drops while the local server is healthy, MacRemote
  reconnects it and shows a reconnecting status.

### Built-in File Transfer Tools

MacRemote includes seven File Transfer tools that run inside the app:
`filesystem_stat`, `filesystem_list_tree`, `filesystem_find`,
`filesystem_read_file`, `filesystem_write_file`, `filesystem_download_file`,
and `filesystem_download_zip`. They are Not Shared until you share them.

They reach only the folders you allow:

- The default folders are Desktop, Documents, and Downloads. Add or remove
  folders in **Settings → Security → File Transfer Folders**. Any folder can be
  added, your home folder included.
- **Allow Whole Mac…** in the same place lets them reach every file your
  account can open. Choose it when you want an app you trust to find and read
  files anywhere. It applies to every connected app, so allow it only if you
  trust all of them. The folders you chose before stay in the list; remove
  **Whole Mac** to go back to them.
- Reading needs no approval. Add a folder only if an app may read everything in
  it. Writing a file always asks first.
- Protected locations are never reachable, even inside an allowed folder or
  with the whole Mac allowed: `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.azure`,
  `~/.kube`, `~/.docker`, `~/.cloudflared`, `~/.config/gh`, `~/.config/gcloud`,
  `~/.netrc`, `~/.npmrc`, `~/.pypirc`, `~/.codex/auth.json`,
  `~/Library/Keychains`, `~/Library/LaunchAgents`, `~/Library/Preferences`, and
  `~/Library/Application Support/MacRemote`.
  This list cannot name every file that holds a password or a key. Shell
  startup files and app settings, for example, are readable once their folder
  is allowed.
- A path must be absolute or start with `~/`. A path that contains `..` is
  refused.
- Listings and searches leave protected entries out. Archiving a folder that
  contains a protected location is refused.
- A refused call tells the calling app which folders are reachable.

`filesystem_find` looks for files and folders by name. Given a folder, it
walks that folder and everything under it: the result is exact and includes
hidden files, and a very large folder can reach the 20-second limit. Given no
folder, it asks Spotlight across everything File Transfer reaches, which is
fast on a whole disk but misses hidden files and folders Spotlight does not
index. `filesystem_read_file` returns text when asked with `encoding: "utf8"`.

To let an app run code, such as a Python script, add a Flexible Command for
that program from the Library (for example **Python 3 CLI**) and share it. It
asks before every run until you choose **Always Allow** for that app. A tool
that asks first is not limited to the File Transfer folders.

The same folders bound every other tool that runs without asking. A read-only
Fixed Command, such as a search or PDF reader you added, can only be pointed at
files inside them. A tool that asks first is not limited: you see the path
before you approve.

`filesystem_write_file` asks first. One call carries at most 96 KiB of
characters, so an app sends a larger file in parts. `filesystem_read_file`
returns at most 16 KiB per call; for a whole file, an app should use
`filesystem_download_file`.

The download tools return a one-time link instead of file contents. The link
needs no sign-in but cannot be guessed. It expires after 10 minutes, allows 3
downloads, is limited to 512 MiB, and stops working when the server stops.
MacRemote builds download links only for these built-in tools.

### Local MCP Bridge

MacRemote can import tools from MCP servers already set up on this Mac for
other apps, such as Claude Desktop, Claude Code, Codex, Cursor, VS Code,
Windsurf, Zed, and LM Studio, and share them through MacRemote.

In **Tools**, the column on the left lists command-line tool groups first and
MCP servers below them. **Scan This Mac** reads the known config files of those
apps. Each server has its own page with **Import** or **Refresh** and **Share
All**.

- A scan asks only servers that are already running. It does not start a
  server named in another app's config file. MacRemote starts such a server
  when you import or check it.
- MacRemote re-reads the same config files when you open or return to the app
  and marks new servers as **New**. Nothing is imported or shared
  automatically.
- If a server relabels a shared tool that asked first as read-only, that tool
  becomes Not Shared until you review it.
- Only servers on this Mac can be imported, not remote HTTPS servers.
- A server that requires its own sign-in shows **Sign In…**. MacRemote keeps
  that sign-in in your Keychain. **Sign Out** removes it.

RemCTL and NotesCTL are imported the same way when installed; see
[Federico Viticci tools](FEDERICO_CLI_TOOLS.md).

## Presets

**Add from Library** offers what is installed on this Mac:

- **Tool Sets**: groups you can add at once.
- **Detected CLIs**: Flexible Commands for installed programs.
- **Command Presets**: narrower Fixed Commands for common workflows.

The Library and Tools views split catalog tools into **Federico Viticci** and
**Everything Else**. **Update from Catalog** refreshes catalog tools you already
added and adds missing ones. A tool whose command or permissions changed asks
for approval again. Your own tools are not overwritten.

MacRemote supports ten command-line apps made by Federico Viticci. Their tool
IDs, inputs, approval rules, and blocked commands are in
[Federico Viticci tools](FEDERICO_CLI_TOOLS.md).

## Permissions

A tool can declare the macOS permissions it needs, such as Full Disk Access,
Reminders, Screen Recording, or Automation. MacRemote checks what the currently
shared tools need before the server starts.

**Full Disk Access.** macOS gives a command-line tool the access of the app
that started it. MacRemote starts the tools you share, so `MacRemote.app` is
the only item to add in **System Settings → Privacy & Security → Full Disk
Access**. Do not add tool programs or script interpreters. MacRemote tests
access by reading a protected folder itself. When it cannot run that test, it
says so and asks you to confirm the setup instead of reporting success.

After changing a permission, use **Relaunch MacRemote**, then open
**Connection → Readiness** and choose **Check Again**.

RemCTL and NotesCTL manage their own permissions through their own signed
helper apps. MacRemote does not ask for Full Disk Access for them. Run
`remctl doctor` or `notesctl doctor --json` to diagnose those.

## Connected Apps

### Approving a new app

Anyone who knows the public address can ask to connect, and can give any app
name. The name proves nothing. So a sign-in shows a code in two places:

- the browser page of whoever started the sign-in; and
- the request on the Mac, together with the destination the sign-in returns to.

Approve only when the six-digit code on your own sign-in page matches the code
in MacRemote. If you did not start a sign-in, deny the request.

A sign-in request expires after 5 minutes. One app can have 2 sign-in requests
waiting. All apps together can have 16.

### Managing apps

An approved app appears under **Apps**. From there you can turn on **Always
Allow** for a tool so that app's calls to it stop asking. The rule belongs to
that one app and that exact tool. Changing what the tool can run, its
capability, or its required permissions makes it ask again. Renaming it does
not.

Each app card shows one of three states:

- **Active**: the app is signed in.
- **Waiting to finish signing in**: you approved it and it has not finished
  yet.
- **Sign-in expired**: it was approved once and its sign-in has lapsed.

**Sign Out…** on a card removes that app's registration, sign-ins, waiting
requests, and Always Allow rules, and reports what it removed. **Settings →
Security → Sign Out All Apps…** does the same for every app. A signed-out app
can ask to connect again, and you approve it again.

Two apps with the same name are still separate. Signing out one does not affect
the other. An app that registered but was never approved does not appear under
**Apps**; **Sign Out All Apps…** clears it.

App icons are decoration. An icon is picked from the name the app gave itself
and grants nothing. Artwork licenses are in
[Resources/ConnectedAppIcons/THIRD-PARTY-NOTICES.md](../Resources/ConnectedAppIcons/THIRD-PARTY-NOTICES.md).
