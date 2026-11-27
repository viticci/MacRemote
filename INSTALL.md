# Install MacRemote

MacRemote lets an AI app that speaks MCP, such as ChatGPT or Claude, use the
tools you choose on your Mac. You choose which tools to share. MacRemote asks
before an app connects, and tools that can change something ask again before
they run.

This page has two parts:

- [Install the app](#install-the-app) is for everyone. It takes you from the
  download to a first tool call.
- [Build from source](#build-from-source) is for contributors who want to
  build MacRemote themselves.

The [Guide](docs/GUIDE.md) explains everything else in detail.

## Install the app

You need:

- a Mac with macOS 26 or later, Apple silicon or Intel;
- an AI app that can connect to a remote MCP server, such as ChatGPT or Claude.

You do not need Xcode, Swift, Homebrew, Wrangler, or a Cloudflare account for
the fastest setup.

### 1. Download and open MacRemote

1. Open [MacRemote's releases on
   GitHub](https://github.com/viticci/MacRemote/releases) and download
   `MacRemote-1.1.2-macos-universal2.zip` from the latest release.
2. Double-click the ZIP. **MacRemote** appears next to it.
3. Drag **MacRemote** into your Applications folder.
4. Open Applications and double-click **MacRemote**.
5. macOS asks whether you want to open an app downloaded from the internet.
   Choose **Open**.

MacRemote is signed with a Developer ID and notarized by Apple, so it opens like
any other app you download.

To update later, quit MacRemote, replace the copy in Applications with the new
one, and open it. Your tools, connected apps, and settings carry over. If you
ran a build from before 1.0, read [If you used an earlier
build](docs/releases/1.0.md#if-you-used-an-earlier-build) first: a few tools
ask again.

#### Optional: check the download

macOS checks the signature and Apple's notarization when you first open the
app. To see the result yourself, open Terminal and run:

```bash
spctl -a -vv /Applications/MacRemote.app
```

The answer should say `accepted`, `source=Notarized Developer ID`, and
`origin=Developer ID Application: Federico Viticci (4W35M4UN6R)`. If it does
not, delete the app and the ZIP and download them again.

Each release also lists a `.sha256` file. To compare it with your download, run
`shasum -a 256` on the ZIP in Terminal; the two values should match.

### 2. Choose at least one tool

MacRemote opens with a Welcome window.

1. Choose **Get Started**. The next screen, **Pick what this Mac can share**,
   shows the tools that are available on your Mac. A command-line app that is
   not installed simply does not appear. That is normal.
2. For the simplest first test, select **Current Date** and deselect any other
   bundles. It is a safe read-only tool built into macOS. You can instead
   choose a small bundle with tools you recognize.
3. Choose **Add 1 Tool**. If you selected a bundle, the button shows its tool
   count instead.
4. If a tool you added needs a macOS permission, Welcome shows **Some tools
   need permission first**. Follow it now, or choose **Later** or
   **Continue** and come back in [Grant macOS
   permissions](#7-grant-macos-permissions). Current Date needs no
   permission, so Welcome goes straight to **Start the connection**.

Current Date is optional; MacRemote never adds it unless you select it. If you
skip this step, open **Tools**, choose **Add from Library…**, add a tool, and
check that its **Share** switch is on before you start the connection. Apps
can see only tools with **Share** turned on.

If you use Federico's command-line apps, MacRemote finds them. See [Federico
Viticci tools](docs/FEDERICO_CLI_TOOLS.md).

- **RemCTL, NotesCTL, MailCTL, PhotoCTL, and MusicCTL:** open **Tools →
  Federico Viticci**. Each one that is installed but not added yet shows under
  **Not Yet Added** with an **Add** button.
- **Apple Frames:** open **Tools → Add from Library… → Bundles → Apple
  Frames**.

### 3. Install Cloudflare's helper

An AI app on the web or on your phone reaches your Mac through a public link.
MacRemote makes that link with Cloudflare's `cloudflared` helper. It can
download and check its own copy, so you do not need Homebrew.

1. In Welcome, continue to **Start the connection**. Later, open
   **Connection** and expand **Address**.
2. If you see the one-time helper setup, open **What gets installed** to see
   the download address, SHA-256, license, and source.
3. Choose **Install Helper**.
4. Wait until MacRemote says **Cloudflare's helper is ready**. The message
   appears briefly; setup is also done when the helper row disappears.

MacRemote skips this step when it already has a verified copy, or finds one you
installed yourself with `brew install cloudflared`.

### 4. Choose a public link

MacRemote offers two kinds of public link.

| | Instant Link | Your Domain |
|---|---|---|
| Address | Random, such as `https://….trycloudflare.com` | Stable, such as `https://macremote.example.com` |
| Needs | Nothing | A Cloudflare account, a domain in it, and Wrangler's sign-in or an API token |
| Changes | Each time you start a new Instant Link | Only when you change the domain or subdomain |
| After a restart | Start it again, and update the address in your app | **Go Public** brings it back, no token needed |

Start with Instant Link. Move to Your Domain when you want an address that
stays the same.

#### Instant Link

In Welcome, on **Start the connection**:

1. Choose **Instant Link**.
2. Choose **Start Instant Link**. MacRemote starts its local server first when
   needed.
3. Wait for the public link to appear.
4. Choose **Continue**. The **Connect your app** screen shows the address,
   which ends in `/mcp`, and **Copy Public URL** copies it.
5. Continue to [Connect your AI app](#5-connect-your-ai-app).

If you closed Welcome or skipped it, use the main window instead:

1. Open **Connection**, expand **Address**, and choose **Instant Link**.
2. Choose **Start Server**, unless the server is already running.
3. Choose **Go Public…**, then **Go Public** to confirm.
4. Wait for the public link to appear, then choose **Copy URL** in the
   toolbar.
5. Continue to [Connect your AI app](#5-connect-your-ai-app).

To use MacRemote only from an app on this same Mac, skip the public link:
choose **Just Start Locally** in Welcome, or **Start Server** in
**Connection**. See **Apps on this Mac** under [Connect your AI
app](#5-connect-your-ai-app).

Keep MacRemote open while you use the link. If you stop sharing, quit
MacRemote, or start a new Instant Link, update the saved address in your app.

#### Your Domain

Before you start, you need:

- a Cloudflare account;
- a domain you own that is active in that account; and
- one way for MacRemote to reach that account:
  - **Wrangler**, Cloudflare's command-line tool, installed and signed in with
    `wrangler login`. MacRemote uses its saved sign-in.
  - **A Cloudflare API token** you paste into MacRemote. The Guide's
    [Cloudflare API Token](docs/GUIDE.md#cloudflare-api-token) section lists
    the four permissions it needs and how to create it.

If you paste a token, MacRemote uses it, both to load domains and to deploy.
If the token field is empty, it uses Wrangler's sign-in. Treat a token like a
password: keep it in your password manager, and never paste it into a message,
log, screenshot, or issue.

**Deploy the link**, in this order:

1. In Welcome, choose **Your Domain**, then **Set Up Your Domain**. This closes
   Welcome and opens **Connection → Address** in the main window. Later, open
   **Connection**, expand **Address**, and choose **Your Domain**.
2. Under **1. Sign in to Wrangler or paste an API token**, paste your token,
   or leave the field empty to use Wrangler's sign-in.
3. Choose **Load Domains**.
4. Choose your domain.
5. Enter a subdomain, such as `macremote`.
6. Choose **Deploy Your Domain**.
7. Wait for the public link to appear, then copy the address ending in `/mcp`.
8. Continue to [Connect your AI app](#5-connect-your-ai-app).

MacRemote keeps a pasted API token in memory only; it never saves it. After
the first deploy, it keeps one key in your Keychain: the key that runs this
public link, which cannot change your DNS or create tunnels. With it, **Go
Public** brings the same address back, also after a restart, without a token
or Wrangler. Changing the domain or subdomain deletes the key. The Guide
explains [what
MacRemote creates in your Cloudflare
account](docs/GUIDE.md#what-macremote-creates) and how to keep a Mac that stays
on [online after a restart](docs/GUIDE.md#always-on-macs-back-after-a-restart).

### 5. Connect your AI app

Leave the sign-in method on **Dynamic OAuth**, the default. The app registers
itself over the public link and you approve it on the Mac. There is nothing to
paste but the address.

1. If Welcome is still open, its **Connect your app** screen shows short steps
   for the app you use. Otherwise, keep the address you copied at hand.
2. Paste the public `/mcp` address into the app where it asks for a remote MCP
   server, custom connector, or custom MCP server.
3. The app opens a MacRemote sign-in page in your browser. The page shows a
   six-digit code.
4. Return to MacRemote and find the request in **Connect your app**. If
   Welcome is closed, for example after **Set Up Your Domain**, open
   **Requests**.
5. Compare the code in MacRemote with the code on your sign-in page. Approve
   only when they match. If you did not start a sign-in, choose **Deny**:
   anyone who knows your public address can ask to connect under any name.
6. In the app, try a harmless read-only tool first. With Current Date shared,
   ask it what day it is.

A sign-in request expires after 5 minutes. If it expires, start the connection
again in the app.

App-specific notes:

- **Claude.** Open [Connectors](https://claude.ai/customize/connectors),
  choose **Add**, then **Add custom connector**, and enter a name and the
  address. Keep **Sign in now**. Under **OAuth client**, **Use Claude's
  published identity** and **Register automatically** both work. On a Team or
  Enterprise plan, an Owner adds the connector in **Organization settings →
  Connectors**, then each member chooses **Connect**. Claude Free allows one
  custom connector.
- **ChatGPT.** Go to [chatgpt.com/plugins](https://chatgpt.com/plugins),
  select **+**, then **Add custom MCP server**, and choose **OAuth**. It works
  only on the web, and only some ChatGPT plans allow it. [Connect
  ChatGPT](docs/CHATGPT.md) has the steps, the plans, and what has not been
  checked yet.
- **Other apps.** Any app that can add a remote MCP server with OAuth sign-in
  works the same way. An app that cannot finish an OAuth sign-in may need one
  of the [advanced sign-in methods](docs/GUIDE.md#sign-in-methods).
- **Apps on this Mac.** An app running on the same Mac can use the local
  address shown in **Connection** instead, `http://127.0.0.1:<port>/mcp`,
  without a public link. Another computer or device cannot reach it. The port
  can change each time the server starts.

An app's own confirmation and a MacRemote approval are separate. A tool that
can change something asks for another approval on your Mac before it runs, and
the request shows everything the tool will receive. A notification banner can
deny a request but cannot approve one; open MacRemote to approve. The Guide
explains [approvals](docs/GUIDE.md#approvals) and [managing connected
apps](docs/GUIDE.md#managing-apps).

Keep MacRemote open while the app is connected. The local server and the public
link stop when MacRemote quits.

### 6. Share more tools

Open **Tools** to add more tools: from the Library, from a scan of this Mac, or
by hand. Review every **Share** toggle before you connect an app.

Apps see tools whose **Share** switch is on. Some tools start Shared and some
do not:

- **Start Shared:** tools you make yourself with **New Tool…**, the Library's
  **Custom** tab, or **Duplicate**, including a Flexible Command you make this
  way; Fixed Command presets and bundles from the Library; and the tools of an
  MCP server you import yourself.
- **Start Not Shared:** Flexible Commands (tools that pass any arguments to
  their program) from Library presets and bundles; tools found by a scan; the
  built-in File Transfer tools; skills other than **macremote**; and new tools
  that a CLI or MCP server adds later, after an update.
- A tool that needs Full Disk Access starts Not Shared while the server is
  running and that access is not confirmed yet.
- File Transfer reaches only Desktop, Documents, and Downloads until you add
  folders in **Settings → Security → File Transfer Folders**.
- A number on **Tools** means MacRemote found new MCP servers on this Mac for
  you to review. Nothing was imported or shared automatically.

The Guide explains [sharing](docs/GUIDE.md#sharing), the [File Transfer
tools](docs/GUIDE.md#built-in-file-transfer-tools), the [Local MCP
Bridge](docs/GUIDE.md#local-mcp-bridge) for MCP servers you already use, and
[skills](docs/GUIDE.md#skills).

### 7. Grant macOS permissions

Some tools need macOS privacy access. MacRemote checks only what the tools you
share need.

Open **Connection** and expand **Readiness**. Then follow the row that needs
attention.

**Full Disk Access:**

1. Expand **Full Disk Access** and choose **Open System Settings**.
2. Add MacRemote to the list and turn it on.
3. Return to MacRemote and choose **Check Again**. If macOS still reports the
   old answer, MacRemote quits and reopens itself once to see the change.

**Privacy Permissions** (such as Reminders, Screen Recording, or Automation):

1. Expand **Privacy Permissions** to see which permissions your shared tools
   need.
2. For Reminders, choose **Open Reminders Privacy** and turn on MacRemote.
   For any other permission, open **System Settings → Privacy & Security**,
   choose that permission, and turn on MacRemote. macOS may also ask you the
   first time a tool runs.
3. Return to MacRemote and choose **Check Again**.

MacRemote is the only item to add to Full Disk Access; the Guide explains
[why](docs/GUIDE.md#permissions). RemCTL, NotesCTL, MailCTL, PhotoCTL, and
MusicCTL manage their own Reminders, Notes, Mail, Photos, and Music permissions
through their own signed helper apps. Run `remctl doctor`, `notesctl doctor
--json`, `mailctl doctor`, `photoctl doctor`, or `musicctl doctor` in Terminal
when one of them reports missing access.

### Troubleshooting

#### No tools appear

Missing command-line apps are normal. Open **Tools**, choose **Add from
Library**, and add a tool that is available on your Mac. Confirm that at least
one tool has **Share** turned on.

#### The Instant Link button is unavailable

Confirm that at least one tool is shared. Then return to **Connection →
Address**. If Cloudflare's helper is missing, choose **Install Helper** and wait
for the ready message.

#### Cloudflare's helper does not become ready

Choose **Try Again** after a failed install, or **Check Again** if you already
installed it. You can also review its status in **Settings → General →
Cloudflare Helper**. MacRemote discards a download that does not match its
published checksum or signature.

#### Load Domains is unavailable or fails

**Load Domains** becomes available when you paste a Cloudflare API token, or
when Wrangler is installed on this Mac. MacRemote checks Wrangler's sign-in only
when you choose the button, so if loading fails, run `wrangler login` in
Terminal or paste a token, then choose **Load Domains** again. Confirm that the
domain is active in that account. Deploying uses the same token or sign-in.

#### Cloudflare rejects the API token

Check all four permissions and both resource limits in the Guide's [Cloudflare
API Token](docs/GUIDE.md#cloudflare-api-token) section. If the token was copied
wrong or exposed, revoke it, create a new one, and save the new one in your
password manager.

#### The app does not connect

Confirm that MacRemote is still open and the public link is still visible.
Confirm that the address you pasted ends in `/mcp`, and leave MacRemote's
sign-in method on **Dynamic OAuth**. Look in **Requests** for a connection
waiting for approval. A request that waited more than 5 minutes has expired;
start the connection again in the app.

If the browser says the sign-in can't start, MacRemote refused the request.
Open **Activity** to see why, then remove MacRemote in the app and add it
again.

MacRemote answers only at its own local address and its own public link. An SSH
forward or a tunnel you start yourself is refused.

#### File Transfer cannot reach a file

The built-in File Transfer tools reach only Desktop, Documents, and Downloads
until you add folders in **Settings → Security → File Transfer Folders**. To
let apps you trust reach every file, choose **Allow Whole Mac…** there.
Protected locations, such as SSH keys and Keychains, stay closed either way.

#### macOS will not open the app

Confirm that MacRemote is in Applications and double-click it once. Then open
**System Settings → Privacy & Security** and choose **Open Anyway** for
MacRemote. Do not turn off Gatekeeper. If **Open Anyway** does not appear or the
same message returns, download a fresh copy from [GitHub
Releases](https://github.com/viticci/MacRemote/releases), check it as described
in [Optional: check the download](#optional-check-the-download), and note the
exact macOS message.

The Guide has [more troubleshooting](docs/GUIDE.md#troubleshooting) for
Cloudflare and Your Domain.

## Build from source

This part is for contributors who want to build MacRemote themselves. A build
from source is signed with your own identity, or ad hoc, and is not notarized.

### 1. Clone

```bash
git clone https://github.com/viticci/MacRemote.git
cd MacRemote
```

### 2. Install requirements

MacRemote needs:

- macOS 26 or later;
- Xcode Command Line Tools with the macOS 26.5 SDK and `/usr/bin/swift`.

Public links need Cloudflare's `cloudflared` helper, but you do not install it
in advance. The first time you need it, MacRemote offers to download the pinned
2026.10.3 release itself, checks it against a built-in SHA-256 and Cloudflare's
Developer ID signature, and keeps its own copy under
`~/Library/Application Support/MacRemote/CloudflaredHelper/`. If you would
rather manage it yourself, `brew install cloudflared` still works and MacRemote
uses your copy when it finds one. It never modifies an install you made.

Optional:

- `wrangler`, signed in with `wrangler login`, to load domains and deploy Your
  Domain without a pasted token;
- a Cloudflare API token for Your Domain, with the permissions in the Guide's
  [Cloudflare API Token](docs/GUIDE.md#cloudflare-api-token) section;
- the command-line tools you want to share.

### 3. Build, install, and launch

```bash
script/build_and_run.sh
```

The script builds the app, signs it, installs it in `/Applications`, quits a
running copy, and opens the new one. Use `--build-only` to stage
`dist/MacRemote.app` without installing it, or `--verify` to also confirm that
the installed copy is running.

The script signs with `MACREMOTE_CODESIGN_IDENTITY` when it is set, otherwise
with the first Apple code-signing identity it finds. With no identity it signs
ad hoc with a fixed identifier requirement, so macOS privacy grants are not tied
to one build.

When you run Swift directly, use the repository's pinned SDK:

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swift build
```

### 4. Test

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swift test
python3 -m unittest discover -s Tests/Python -p 'test_*.py'
```

Then run the build and launch check when it is safe to relaunch the app:

```bash
script/build_and_run.sh --verify
```

To check ChatGPT end to end, add MacRemote as a custom MCP server (see
[Connect ChatGPT](docs/CHATGPT.md)), refresh its tool list, call one harmless
read-only tool, check the formatted result, and confirm that a reversible write
without Always Allow brings up MacRemote's approval prompt. ChatGPT may also
ask first, depending on its app permissions and the chat.

Result cards use the MCP Apps resource `ui://macremote/output-v9.html`; v8, v7,
v6, v5, v4, v3, v2, and the unversioned URI remain readable. Cards are off until
you turn on **Show result cards** in **Settings › General**. Then, when the host
negotiates MCP Apps, shared tools link the card unless you switched their
family off or the catalog sets `automatic: false`. A host that does not
negotiate MCP Apps still receives meaningful text and `structuredContent`. See
`docs/design/MCP-UI-SPEC.md`.

### 5. Package a release

`script/package_release.sh` builds, signs, notarizes, staples, and verifies the
release ZIP. It needs a clean checkout, a Developer ID Application identity, and
a notary profile. "Release Packaging" in [CONTRIBUTING.md](CONTRIBUTING.md)
has the details. For a local check without notarization:

```bash
script/package_release.sh --local-signing --allow-dirty
```

## Publication status

MacRemote 1.1.2 is a public release: a Developer ID signed and notarized app,
published on GitHub, under the [MIT License](LICENSE).

It is not listed in the ChatGPT or Claude directories, and it has not been
submitted to OpenAI as a plugin. Connecting it as a custom MCP server does not
show that it meets OpenAI's [plugin
guidelines](https://developers.openai.com/plugins/plugin-guidelines) or
[submission requirements](https://developers.openai.com/plugins/deploy/submission);
a submission would need its own audit, a production listing, widget-domain
work, and live end-to-end checks.

MacRemote is a hand-written Swift MCP implementation with standard fields first
and additive OpenAI compatibility aliases; it does not embed the OpenAI Apps SDK.
