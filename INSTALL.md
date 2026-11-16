# Install MacRemote

Club members should start with the [MacRemote 1.1 Club Beta
guide](docs/CLUB_BETA.md). It covers the complete first run, including the
choice between a temporary Instant Link and a stable Your Domain link.

## Install the Club package

MacRemote 1.1 requires macOS 26 or later. Club members do not need Git, Swift,
Xcode, Homebrew, Wrangler, or a Cloudflare account for the fastest setup.

1. Download `MacRemote-1.1.zip` from the Club post.
2. Double-click the ZIP, open the **MacRemote 1.1** folder it creates, and move
   **MacRemote** into `/Applications`.
3. In Applications, double-click MacRemote and confirm **Open**. MacRemote 1.1
   is signed with a Developer ID and notarized, so macOS opens it normally.
   To check that yourself, run `spctl -a -vv /Applications/MacRemote.app`; the
   answer should say `source=Notarized Developer ID`.
4. Follow the Welcome screens. For the simplest first test, select the optional
   **Current Date** starter, which is built into macOS. You can instead choose an
   available bundle. Confirm that at least one tool has **Share** turned on.

MacRemote can download and verify its own pinned Cloudflare helper when you
create a public link. A command-line app that is not installed simply does not
appear in the available first-party sets. If a saved tool later loses its CLI,
its call fails safely with `reason: "unavailable"` and a path-free install or
restore message; the server and other tools keep working.

## Build from source

This section is for contributors and private testers who choose to build the
app themselves. It does not describe a notarized public release or an OpenAI
plugin submission.

### 1. Clone

```bash
git clone https://github.com/viticci/MacRemote.git
cd MacRemote
```

### 2. Install requirements

MacRemote needs:

- macOS 26 or later;
- Xcode Command Line Tools with the macOS 26.5 SDK and `/usr/bin/swift`.

Public HTTPS links need Cloudflare's `cloudflared` helper, but you do not
install it in advance. The first time you need it, MacRemote offers to download
the pinned 2026.10.3 release itself, checks it against a built-in SHA-256 and
Cloudflare's Developer ID signature, and keeps its own copy under
`~/Library/Application Support/MacRemote/CloudflaredHelper/`. If you would
rather manage it yourself, `brew install cloudflared` still works and MacRemote
uses your copy when it finds one. It never modifies an install you made.

Optional components:

- `wrangler`, authenticated with `wrangler login`, to list Cloudflare domains;
- a Cloudflare API token for persistent custom-domain deployment;
- the local CLIs you actually want to expose, such as RemCTL, NotesCTL, MusicCTL,
  Alexandria, PocketCTL, OverCTL, HabitCTL, Iris, Codex, Peekaboo, Spogo, Summarize,
  Gog, or GitHub CLI.

MacRemote recognizes ten first-party Federico Viticci CLIs when installed.
RemCTL and NotesCTL ship their own MCP servers; MacRemote bridges every tool
they publish and adds them from the Library's Federico Viticci tab. The other
eight (Alexandria, HabitCTL, PocketCTL, OverCTL, MusicCTL, GoodLinksCTL, Apple
Frames, and Iris) are a process catalog of 74 tools: 66 Fixed Commands plus 8
Flexible Commands. MusicCTL contributes 15 Fixed Commands plus one Flexible
Command. Add or update all eight from the same tab.

For a persistent Cloudflare domain, the API token needs:

- Account → Cloudflare Tunnel → Edit;
- Zone → Zone → Read;
- Zone → DNS → Edit for the selected zone;
- Zone → Config Rules → Edit for the selected zone.

Choose **Zone → DNS**, not **DNS Settings**. Config Rules access lets MacRemote
disable Browser Integrity Check only for its exact public hostname, so MCP apps,
which are not browsers, can reach MacRemote instead of receiving Cloudflare
error 1010. The Guide has the
[step-by-step token instructions](docs/GUIDE.md#cloudflare-api-token).

### 3. Build, install, and launch

```bash
script/build_and_run.sh
```

The script builds the app, signs it, installs it in `/Applications`, quits a
running copy, and opens the new one. Use `--build-only` to stage
`dist/MacRemote.app` without installing it, or `--verify` to also confirm that
the installed copy is running. Developer ID signing and notarization are
recommended before broader distribution, but are not required for a private
source checkout.

The script signs with `MACREMOTE_CODESIGN_IDENTITY` when it is set, otherwise
with the first Apple code-signing identity it finds. With no identity it signs
ad hoc with a fixed identifier requirement, so macOS privacy grants are not tied
to one build.

When invoking Swift directly, use the repository's pinned SDK:

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swift build
```

## Add and share tools

Open **Tools** and add detected tools or tool sets. Tools added manually or from
the Library start Shared, except Flexible Commands, which start Not Shared.
Tools added from a scan and the built-in File Transfer tools also start Not
Shared. Review every **Share** toggle before connecting a remote app. The Guide
explains [sharing](docs/GUIDE.md#sharing), [approvals](docs/GUIDE.md#approvals), and the
[folders File Transfer can reach](docs/GUIDE.md#built-in-file-transfer-tools).

A number on **Tools** means MacRemote found that many new MCP server runtimes for
review. It is not the **Requests** approval count, and nothing was imported or
shared automatically.

**Update from Catalog** refreshes retained first-party tools, adds missing
current tools, and retires obsolete provider IDs only for a complete provider
scope. It can adopt one uniquely matching scanner-added process tool into the
stable catalog ID; adoption preserves its sharing state, assigns a new
permission epoch, and clears Always Allow grants for the old and new IDs. It
never adopts hand-authored or ambiguous equivalents.

For RemCTL and NotesCTL, **Update** on the provider row in the Library re-imports
the tools after a CLI upgrade. Ids, sharing state, and permission epochs are
kept; a changed tool contract asks for approval again.

For local MCP bridges, exact duplicate runtimes in supported Codex and Claude
direct configs appear once while retaining every declaring config as an owner.
Different endpoint, argv, environment, header, timeout, or auth bindings remain
separate. General plugin registries are outside the scanner; a plugin-provided
server appears only through a supported direct config or the explicit Claude
Extensions manifest source.

## Grant macOS permissions

Some tools need macOS privacy access. MacRemote checks only the requirements
declared by the currently shared tool surface.

1. Open **Connection** and expand **Readiness**.
2. Expand **Full Disk Access** or **Privacy Permissions** when it needs
   attention.
3. Choose **Open System Settings**. For Full Disk Access, add MacRemote and
   turn it on.
4. Relaunch MacRemote when requested.
5. Return to **Connection → Readiness** and choose **Check Again**.

MacRemote is the only item to add to Full Disk Access; the Guide explains
[why](docs/GUIDE.md#permissions). RemCTL and NotesCTL manage their own Reminders and
Notes permissions through their own signed helper apps. Run `remctl doctor` or
`notesctl doctor --json` locally when one of them reports missing access.

## Start MCP

### Local connection

1. In **Connection**, start the local server.
2. Copy the local MCP URL shown in the connection status:

   ```text
   http://127.0.0.1:<port>/mcp
   ```

3. Add that URL and the selected sign-in credentials to an MCP app running on
   this Mac.

The local server binds only to `127.0.0.1`; another computer or device cannot
connect to it directly. MacRemote can choose a new port each time the server
starts, so update local app configuration if the displayed URL changes.

### Public HTTPS connection

1. In **Connection**, start the local server.
2. Expand **Address**.
3. If Cloudflare's helper isn't on this Mac yet, choose **Install Helper**.
   Expand **What gets installed** first to see the exact download address,
   SHA-256, license, and source before agreeing. MacRemote skips this step when
   it already has a verified copy or finds one you installed.
4. Choose one setup:

   - **Instant Link:** choose **Start Instant Link**, wait for the temporary
     `trycloudflare.com` address, then copy it. No Cloudflare account, domain,
     API token, Homebrew, or Wrangler is required. The address changes when you
     start a new Instant Link.
   - **Your Domain:** create a Cloudflare API token with the permissions listed
     above. Paste it into MacRemote, choose **Load Domains**, choose the domain,
     enter a subdomain, then choose **Deploy Your Domain**. Wait for the stable
     address and copy it. MacRemote keeps this token in memory only. After
     the first deploy, **Go Public** brings the same domain back, also after a
     restart, without the token.

5. Confirm that the copied public MCP URL ends in `/mcp`:

   ```text
   https://<public-host>/mcp
   ```

6. Add that URL to the remote MCP app.
7. If using OAuth, approve its connection request in **Requests**, and only
   when [the code matches](docs/GUIDE.md#approving-a-new-app).
8. Review later tool-call requests in **Requests**; manage persistent per-tool
   allowances in **Apps**.

Sign-in lives in **Settings → General**. A fresh install is already on
**Dynamic OAuth**, MacRemote's default: the app registers itself over the public
link and you approve it on the Mac. Use this flow for ChatGPT, Claude, Raycast,
and Notion when the target app supports Dynamic OAuth/DCR; there is nothing to
paste.

Change it under **Advanced sign-in methods**, and only when an app cannot do
the default:

- **OAuth Client Secret** when the app asks you for a client ID and secret.
  While it is on, apps that register themselves — including ChatGPT and Claude
  over the public link — cannot connect.
- **Single Header** when the app can send one static `Authorization` header but
  cannot finish an OAuth sign-in. ChatGPT, Claude, and Notion cannot send it.

Only one method works at a time. Changing it signs out every app that connected
another way; MacRemote asks first and then says what it removed.

The **App** picker above changes only the instructions shown next to it; it
never changes the sign-in method. MacRemote checks every sign-in itself. Nothing
is checked at Cloudflare.

For ChatGPT's exact public-URL, OAuth/DCR, approval, and widget checks, follow
[docs/CHATGPT_DEVELOPER_MODE.md](docs/CHATGPT_DEVELOPER_MODE.md).

MacRemote supports two connection paths: its loopback URL for apps on this Mac,
and an app-managed Cloudflare public URL for remote apps. MacRemote answers
only requests addressed to its loopback address or its own public link, so an
SSH forward or a tunnel you start yourself is refused.

## Verify

Run the pinned local build and tests first:

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swift build
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swift test
python3 -m unittest discover -s Tests/Python -p 'test_*.py'
```

Then run the build and launch verification when it is safe to relaunch the app:

```bash
script/build_and_run.sh --verify
```

Verify ChatGPT by creating a developer-mode draft, refreshing its
tool list, calling one harmless read-only tool, checking the pretty result, and
confirming that a reversible write produces the expected independent ChatGPT
and MacRemote approval steps.

The current MCP Apps resource is `ui://macremote/output-v8.html`; v7, v6, v5, v4, v3,
v2, and the unversioned URI remain readable. Result cards are off until you turn
on **Show result cards** in Settings › General. Then, when the target host
negotiates MCP Apps, shared tools link the widget unless you switched their
family off or catalog presentation explicitly disables automatic UI. A tool with a curated profile may show
a richer table or card. Every other tool, including Flexible Commands, uses the
safe semantic result instead of raw JSON, a terminal view, commands, executable
paths, credentials, or hidden metadata. A host that does not negotiate MCP Apps
still receives meaningful text and `structuredContent`; that is different from
a tool having no curated presentation profile.

Catalog presentation may set `automatic: false` for intermediate lookups and
diagnostics. These tools retain complete text and structured results without
automatically opening a card. See `docs/design/MCP-UI-SPEC.md`.

## Publication status

Do not submit or publish MacRemote as an OpenAI plugin yet. Developer-mode
connectivity does not establish compliance with OpenAI's [app
guidelines](https://developers.openai.com/apps-sdk/app-guidelines) or
[submission requirements](https://learn.chatgpt.com/docs/submit-plugins).
MacRemote still needs a dedicated publication audit, production listing and
widget-domain work, and live OpenAI end-to-end verification before any
submission-readiness claim.
MacRemote is a hand-written Swift MCP implementation with standard fields first
and additive OpenAI compatibility aliases; it does not embed the OpenAI Apps SDK.
