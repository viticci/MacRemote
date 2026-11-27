# MacRemote Guide

Everything MacRemote does, in one place: going public, signing apps in, the
tools you share, approvals, File Transfer, and what MacRemote does in your
Cloudflare account. New here? [Install MacRemote](../INSTALL.md) walks you
through the download and the first run, and the [README](../README.md) explains
what MacRemote is.

- [Get Started](#get-started): [Instant Link](#fastest-instant-link),
  [Your Domain](#stable-address-your-domain),
  [back after a restart](#always-on-macs-back-after-a-restart), and
  [sign-in methods](#sign-in-methods)
- [Cloudflare Helper](#cloudflare-helper) and
  [Cloudflare API Token](#cloudflare-api-token)
- [Notifications](#notifications)
- [Tool Model](#tool-model): [sharing](#sharing), [approvals](#approvals),
  [result cards](#result-cards), [reliability](#reliability),
  [long calls](#long-calls-in-the-background),
  [File Transfer](#built-in-file-transfer-tools),
  the [Local MCP Bridge](#local-mcp-bridge), and [skills](#skills)
- [Presets](#presets) and [Permissions](#permissions)
- [Connected Apps](#connected-apps)

## Get Started

Welcome lets a fresh Mac start with the optional **Current Date** tool or an
available bundle, then handles any required macOS permissions and the public
address. For the first run step by step, the Cloudflare API token, and
troubleshooting, see [Install MacRemote](../INSTALL.md#install-the-app).

### Fastest: Instant Link

Instant Link creates a random temporary address. It needs no Cloudflare account
or domain. [Install MacRemote](../INSTALL.md#instant-link) has the steps, both
in Welcome and in the main window, and [Connect your AI
app](../INSTALL.md#5-connect-your-ai-app) covers the approval. Approve only
when the code matches; see [Connected Apps](#connected-apps).

The address changes each time you stop the link and go public again.

### Stable address: Your Domain

Your Domain creates a stable address such as `macremote.example.com`. Add your
domain to Cloudflare before you begin. MacRemote reaches your Cloudflare
account in one of two ways: a [Cloudflare API token](#cloudflare-api-token) you
paste, or the saved sign-in of Wrangler, Cloudflare's command-line tool, after
`wrangler login`. A pasted token takes priority, both to load domains and to
deploy; with the field empty, MacRemote uses Wrangler.

1. In Welcome, choose **Your Domain**, then choose **Set Up Your Domain**. Later,
   open **Connection**, expand **Address**, and select **Your Domain**.
2. If asked, install Cloudflare's helper from the Address card.
3. Under **1. Sign in to Wrangler or paste an API token**, paste the token, or
   leave the field empty to use Wrangler's sign-in. MacRemote keeps a pasted
   token in memory and does not save it.
4. Choose **Load Domains**.
5. Choose your Cloudflare domain.
6. Enter a subdomain, such as `macremote`.
7. Choose **Deploy Your Domain**.
8. Copy the public URL, paste it into your MCP app, and approve the connection
   in **Requests**, as in [Connect your AI
   app](../INSTALL.md#5-connect-your-ai-app). **Set Up Your Domain** closes
   Welcome, so the request does not appear there.

After a deploy, MacRemote keeps one key in your Keychain: the key that runs
this public link. It cannot change your DNS or create tunnels. With it, **Go
Public** brings your domain back, also after a restart, with no API token and
no Wrangler. Changing the domain or subdomain deletes the key.

With **Your Domain** chosen and nothing deployed yet, **Go Public** opens the
Address card so you can deploy the domain. It does not start an Instant Link.
MacRemote's local server reuses the port your domain was deployed with. If
another program has taken that port, deploy your domain again.

### Always-on Macs: back after a restart

For a Mac that stays on with nobody at it, such as a Mac mini, **Settings ›
General ▸ Startup** has two settings. Both start off.

- **Open at login** opens MacRemote when you log in. After a restart, someone
  has to log in, or automatic login must be on. If macOS asks you to allow
  MacRemote first, the setting says so and **Open Login Items Settings** takes
  you there.
- **Go public at launch** works only with a deployed Your Domain, never with an
  Instant Link. Turning it on shows the Go Public confirmation once. After
  that, each time MacRemote opens, it starts the local server and makes your
  domain public with the key saved in your Keychain. It waits up to two
  minutes for the network after a restart. If you stop sharing, or start or
  stop the server yourself while it waits, it leaves the link to you.

When the Mac restarts, shuts down, or logs out, MacRemote quits without asking
**Stop sharing and quit?**, so a scheduled update or a remote restart never
waits for someone to click. Pressing Command-Q while sharing still asks.

Each time MacRemote goes public by itself, Activity and a notification say so.
When it can't (you changed the domain, the saved key is gone or Cloudflare
refuses it, the port is taken, no tools are shared, or the link never
connected), nothing goes public, and Activity and a notification say why. The
setting is tied to the address you confirmed: after you change the domain, turn
it off and on again. New apps still need your approval, and tools that ask
first still ask.

### Menu bar only

To keep MacRemote out of the Dock, turn off **Show Dock icon** in **Settings ›
General ▸ App Behavior**. MacRemote then lives in the menu bar: its windows
still open from the menu bar icon, and **Settings…** is in that menu too. The
menu bar icon stays on while the Dock icon is hidden, because it is the way
back to the app and it shows how many requests are waiting. If you remove the
menu bar icon by Command-dragging it out of the menu bar, the Dock icon comes
back.

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
work with Dynamic OAuth: MacRemote knows Claude's published identity without
fetching it, and registering automatically is Dynamic OAuth's own path. Keep
**Sign in now** selected.

If MacRemote refuses a sign-in request, the browser page says so and
**Activity** records the reason. Nothing appears in **Requests**, because a
refused request never asks for your approval.

For ChatGPT, see [Connect ChatGPT](CHATGPT.md). It covers adding MacRemote as
a custom MCP server, not plugin submission or publication.

### The icon an app shows for MacRemote

Each app decides this on its own, and MacRemote cannot set it for them:

- **ChatGPT** shows an icon only if you upload one when you add MacRemote.
  OpenAI's current steps do not mention an icon field; if yours has one, your
  link serves a small PNG for it: open your public address with
  `/macremote-icon-256.png` in place of `/mcp` and save the image.
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

Your Domain needs a Cloudflare API token unless you use Wrangler's sign-in
instead; see [Your Domain](#stable-address-your-domain). Create a custom user
token; Cloudflare documents the steps in its
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

- **Deploy button is disabled**: choose a domain, enter a valid subdomain,
  paste an API token or install Wrangler, and stop any running public link.
- **MacRemote couldn't find Wrangler**: an app opened from Finder doesn't get
  your shell's `PATH`, so MacRemote looks in fixed folders: Homebrew's,
  `~/.local/bin`, `~/bin`, `~/.npm-global/bin`, the `bin` folder of the
  `prefix` in `~/.npmrc`, and the Volta, pnpm, and Yarn folders. If Wrangler
  is somewhere else, for example under nvm, paste an API token instead.
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

Only tools with **Share** turned on are visible to connected apps. A tool you
make yourself starts **Shared**, even a Flexible Command, and so does a Fixed
Command preset from the Library. A Flexible Command added from the Library
starts **Not Shared**. So do tools found by a scan and the built-in File
Transfer tools. [Share more tools](../INSTALL.md#6-share-more-tools) has the
full list.

Sharing follows the tool you last saw in MacRemote. If a tool appears or
changes in the saved tools file (`tools.json`) outside the app, it starts Not
Shared and Activity says so. If MacRemote's preferences are missing, every
saved tool starts Not Shared.

Tools can be added while the local server is running. Connected apps may need
to refresh their tool list.

### Result cards

Apps that support MCP Apps, such as Claude and ChatGPT, can show a tool's
result as a card. Cards are off until you turn on **Show result cards** in
**Settings › General ▸ Result Cards**. Then each tool family has its own
switch: each MCP server (such as RemCTL), each of my command-line apps (such as
Apple Frames), File Transfer, and other command-line tools grouped by program.
With a card off, the app gets the same result as plain text; sharing and
approvals don't change. A tool's inspector shows its **Result Card** state.
Apps pick up a change the next time they reload MacRemote's tools; in ChatGPT,
choose **Refresh** on MacRemote's plugin at chatgpt.com/plugins. A card an app still
links from an older tool list draws nothing once you turn it off.

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

- In apps that support MCP Tasks, such as Claude and Claude Code, a call that
  takes longer than 20 seconds continues in the background; see
  [Long calls in the background](#long-calls-in-the-background). In other
  apps, every call runs to completion inside the request that made it, so it
  must finish before the public link or the app gives up waiting. Cloudflare's
  current default is 125 seconds without a response, and an app may stop
  sooner.
- A tool that reaches its timeout is stopped, together with every process it
  started.
- Only a limited number of calls run at once. Extra calls get an immediate
  "server is busy, retry shortly" result.
- A result too large to return directly is saved and returned as a download
  link.
- If the public link drops while the local server is healthy, MacRemote
  reconnects it and shows a reconnecting status.

### Long calls in the background

In apps that support MCP Tasks, such as Claude and Claude Code, a tool call
that is still running after 20 seconds continues in the background. The app
gets an answer at once and picks up the result when the command finishes, so a
long Codex run or library scan does not have to finish inside the public
link's time limit. Other apps wait for the result.

- Turn on **Long-Running** in a tool's Overview in **Tools** for a tool you
  know takes a while. It then starts in the background right away instead of
  after 20 seconds.
- Flexible Commands accept an optional `run_in_background` argument, so the
  model can ask for the same thing on a single call.
- A call that waits for your approval can become a background task too. The
  app shows "Waiting for approval on the Mac" until you answer. Approvals work
  the same either way.
- Background tasks end when MacRemote quits or stops sharing. A finished
  result stays available to the app for one hour.

### Built-in File Transfer Tools

MacRemote includes ten File Transfer tools that run inside the app:
`filesystem_stat`, `filesystem_list_tree`, `filesystem_find`,
`filesystem_read_file`, `filesystem_write_file`, `filesystem_append_file`,
`filesystem_replace_in_file`, `filesystem_upload_file`,
`filesystem_download_file`, and `filesystem_download_zip`. They are Not Shared
until you share them.

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
  it. Writing, appending to, editing, or uploading a file always asks first.
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

`filesystem_append_file` (**Append to File**) adds text to the end of an
existing text file, and `filesystem_replace_in_file` (**Replace in File**)
changes one passage, so an app does not have to send the whole file again.
The text to replace must appear exactly once; if it appears zero times or more
than once, nothing changes and the app is told how many matches there were.
Both ask first and show exactly what will be added or replaced. They work on
UTF-8 text files of up to 10 MiB, and everything outside the change stays as
it was. If another app changes the file before the edit is saved, nothing is
saved.

`filesystem_upload_file` (**Upload File**) is for apps that support MCP file
uploads. You approve the destination and the file's name, type, and size on
your Mac, and the app then sends the file straight to MacRemote, up to
512 MiB, without its contents passing through the conversation. It never
replaces a file unless the call asks to overwrite it. **Claude does not send
files to MacRemote yet**; apps without file uploads keep using
`filesystem_write_file`. MCP file uploads are a draft extension, so this may
change. Through the public link, Cloudflare may refuse a single upload larger
than its own request limit (100 MB on its free plan).

The download tools return a short-lived link instead of file contents. The link
needs no sign-in but cannot be guessed. It expires after 10 minutes, works for
up to 3 downloads, is limited to 512 MiB, and stops working when the server
stops. MacRemote uses the same kind of link for results too large to return
inline: a command's complete output, or the full result of a tool from an
imported MCP server. MacRemote makes every such link itself. It never turns a
link that a command prints into a MacRemote download link.

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
- When a server needs to ask you something in the middle of a tool call, the
  question appears in the app you are using, with the server's name in front
  of it, and your answer goes back to the server. This works in apps that
  support MCP questions (elicitation); in other apps the server is told no,
  and the call carries on. A server's question never appears in the Approval
  window, and a tool that asks first is still approved on your Mac.
- A server that runs long calls as tasks of its own works too: MacRemote
  waits for the task to finish.

Federico Viticci's CLIs that ship their own MCP server (RemCTL, NotesCTL,
MailCTL, PhotoCTL, and MusicCTL) are found the same way when installed, and
appear under **Federico Viticci** in Tools. One that is not added yet shows
under **Not Yet Added** with an **Add** button. See [Presets](#presets) for how
their tools stay current, and [Federico Viticci tools](FEDERICO_CLI_TOOLS.md)
for the full list.

### Skills

Apps that support MCP skills, such as Claude Code, can get skills from
MacRemote. A skill is a short guide an assistant reads before it uses tools.
In Claude Code, shared skills appear as `<connector>:macremote` and so on.

- **macremote**, MacRemote's own skill, explains how its tools work: there is
  no shell, some tools ask first on your Mac, what each result code means, and
  how File Transfer and download links work. It is shared by default.
- An MCP server you imported can offer its own skills. MacRemote reads them
  when it imports or refreshes that server.
- MacRemote also finds skills already on your Mac for the tools you use
  through it, in `~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills`,
  and Claude Code plugins. It reads only skills whose name matches a
  command-line tool or MCP server you have in Tools, and looks when MacRemote
  opens and when you scan. Because these skills were written for a terminal,
  MacRemote adds a short note telling the assistant which MacRemote tools to
  use instead. The note names only tools you share.
- Every skill except **macremote** starts Not Shared, because a skill's text
  becomes instructions for the assistant.

Skills live in **Tools**. Each page lists the skills for its tools at the top,
with where each comes from and a **Shared** switch. Select a skill to read
exactly what an app gets, MacRemote's note included. A skill MacRemote can't
share says why, and so does a shared skill apps don't get, for example when
none of its tools are shared.

## Presets

**Add from Library** offers what is installed on this Mac:

- **Bundles**: groups you can add at once.
- **Found on This Mac**: Flexible Commands for installed programs.
- **Presets**: narrower Fixed Commands for common workflows.

In **Found on This Mac**, **Quarantined** marks a program macOS has not let
run yet: it was downloaded from the web and never opened. Once you open it and
macOS approves it, the label goes away the next time you scan.

A tool added from a scan remembers who signed its program. Before each run,
and when you turn sharing on, MacRemote checks that signature again. For a
Homebrew command that starts an app through a small launcher script, such as
`vlc`, it checks the app. If the publisher changed, MacRemote stops sharing
the tool and shows **Review…**. Review shows who signed it when you added it
and who signs it now. **Trust New Publisher** accepts the change: Always Allow
no longer applies to the tool, and you turn sharing back on yourself.

The Library and Tools views split catalog tools into **Federico Viticci** and
**Everything Else**. **Update from Catalog** refreshes catalog tools you already
added and adds missing ones. A tool whose command or permissions changed asks
for approval again. Your own tools are not overwritten.

MacRemote supports six command-line apps made by Federico Viticci: RemCTL,
NotesCTL, MailCTL, PhotoCTL, MusicCTL, and Apple Frames. Their
tool IDs, inputs, approval rules, and blocked commands are in
[Federico Viticci tools](FEDERICO_CLI_TOOLS.md).

The ones with their own MCP server (RemCTL, NotesCTL, MailCTL, PhotoCTL, and
MusicCTL) appear under **Federico Viticci** in **Bundles**, **Presets**, and
**Found on This Mac**, and one installed while MacRemote runs shows up the next
time you open the Library. They get their tools from the CLI itself, so the
tools match the installed version and stay current on their own:

- When the CLI's file changes, for example after an update, MacRemote reads its
  tool list again the next time it launches or becomes active, and Activity
  says what changed, in one line.
- New tools start Not Shared, and nothing MacRemote adds this way is shared
  for you. A tool whose behavior changed asks again, even if you chose Always
  Allow. A tool the CLI marks destructive asks every time.
- If reading the list fails, nothing changes, and MacRemote tries again the
  next time it becomes active.
- Some CLIs start through a small script that an update leaves alone. For
  those, press **Update**, which always reads the list fresh.

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

After changing a permission, open **Connection → Readiness** and choose
**Check Again**. For Full Disk Access, use **Open System Settings** to get
there, and Check Again quits and reopens MacRemote once if macOS still reports
the old answer. For Reminders, **Privacy Permissions** offers **Open Reminders
Privacy**. For any other permission, open **System Settings → Privacy &
Security** and turn on MacRemote under that permission. [Grant macOS
permissions](../INSTALL.md#7-grant-macos-permissions) has the steps.

RemCTL, NotesCTL, MailCTL, PhotoCTL, and MusicCTL manage their own
permissions through their own signed helper apps. MacRemote does not ask for
Full Disk Access for them. Run `remctl doctor`, `notesctl doctor --json`,
`mailctl doctor`, `photoctl doctor`, or `musicctl doctor` to diagnose those.

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
