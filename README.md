<p align="center">
  <img src="docs/images/banner.png" alt="MacRemote: let your AI apps use your Mac. Only the parts you choose." width="100%">
</p>

<p align="center">
  <b>Private beta for MacStories Club members</b><br>
  macOS 26 or later · Apple silicon and Intel · Version 1.1
</p>

<p align="center">
  <a href="docs/CLUB_BETA.md">Club Beta Guide</a> ·
  <a href="docs/GUIDE.md">Guide</a> ·
  <a href="docs/releases/1.1.md">What's New</a> ·
  <a href="SECURITY.md">Security</a>
</p>

---

## Why I Made This

I use ChatGPT and Claude every day, on every device I own. But a lot of the
stuff I care about lives on my Mac: my reminders and notes, my files, my
podcast queue, and a pile of command-line tools I've built over the years. I
wanted my AI apps to use those things, from my iPhone or anywhere else, without
handing them a terminal and hoping for the best.

So I made MacRemote. It's a native Mac app that shares the tools you pick with
ChatGPT, Claude, and other AI apps over MCP. MCP, the Model Context Protocol,
is the standard those apps use to call tools that live outside of them.

The idea is simple: your Mac, your rules. You choose every tool an app can
see. You approve every new app on the Mac. Anything that can change something
asks you first and shows you exactly what it's about to run.

— Federico

## What It Does

- **Shares the tools you choose.** Add a command-line app, a single workflow
  from one, or a whole bundle from the Library. Nothing is visible to apps
  until you turn on **Share**.
- **Brings your existing MCP servers along.** MacRemote can import the MCP
  servers you've already set up for Claude Desktop, Claude Code, Codex, Cursor,
  VS Code, and others, and share them from one place.
- **Moves files, carefully.** Built-in File Transfer tools can list, find,
  read, write, and download files, but only in the folders you allow.
- **Goes public in a minute.** An **Instant Link** gives you a temporary
  address with no account. **Your Domain** gives you a stable address on a
  domain you own through Cloudflare.
- **Looks good in chat, if you want it to.** Apps that support MCP Apps can
  show results as cards; turn them on for all tools or only some. Everything
  else gets clean text and structured data.
- **Stays up on an always-on Mac.** MacRemote can open at login and bring your
  own domain back online by itself after a restart.
- **Works with my apps out of the box.** If you use RemCTL, NotesCTL,
  PocketCTL, MusicCTL, or my other command-line apps, MacRemote finds them and
  knows how to share them safely. All of them are optional.

## How It Keeps Your Mac Yours

MacRemote is not a remote shell, and that's on purpose.

- **No shell, ever.** Every tool runs as one exact program with an exact list
  of arguments. There are no pipes, wildcards, or `~` expansion, and shells
  like `bash` and `zsh` can't be added as tools.
- **You approve every app.** A new app shows a six-digit code in its sign-in
  page and in MacRemote. Approve only when they match.
- **Tools that change things ask first.** You see every argument in full,
  invisible characters included, before anything runs. You can choose
  **Always Allow** for one app and one tool when you trust it.
- **The server stays on your Mac.** MacRemote listens only on this Mac.
  Cloudflare carries requests to it, but MacRemote checks every sign-in
  itself.
- **Secrets stay put.** SSH keys, cloud credentials, Keychains, and other
  protected locations are never reachable through File Transfer, even if you
  allow the whole Mac.
- **You can pull the plug anytime.** Sign out one app or all of them, or stop
  the public link. Quitting MacRemote always stops it too.

The full design is in [Architecture and Security](docs/ARCHITECTURE_SECURITY.md)
and the [Threat Model](docs/THREAT_MODEL.md).

## Get Started

You need macOS 26 or later, an AI app that can connect to an MCP server (like
ChatGPT or Claude), and at least one tool to share. You don't need Xcode,
Homebrew, or a Cloudflare account. MacRemote installs and verifies the one
helper it needs by itself.

1. **Download it.** Club members download `MacRemote-1.1.zip` from the Club
   post.
2. **Install it.** Unzip it, open the **MacRemote 1.1** folder, move
   **MacRemote** to Applications, and open it. It's signed and notarized by
   Apple, so it opens like any other app.
3. **Pick a tool.** For your first test, select **Current Date** in the
   Welcome window. It's read-only and built into macOS.
4. **Go public.** Choose **Instant Link**, install the helper if asked, and
   choose **Start Instant Link**.
5. **Connect your app.** Paste the public URL, which ends in `/mcp`, into
   ChatGPT, Claude, or another MCP app. Your browser and MacRemote both show a
   six-digit code. Approve the request in MacRemote only when they match.

That's it. Ask your AI app what day it is, and the answer comes from your Mac.

The [Club Beta Guide](docs/CLUB_BETA.md) covers the first run in detail,
including how to check that the app is the notarized one. When you want a permanent address,
follow the [Your Domain](docs/GUIDE.md#stable-address-your-domain) steps.
ChatGPT users should also read the
[developer-mode guide](docs/CHATGPT_DEVELOPER_MODE.md).

## Documentation

| Read this | For |
|---|---|
| [Club Beta Guide](docs/CLUB_BETA.md) | Your first run, step by step |
| [Guide](docs/GUIDE.md) | Everything else: sign-in methods, Cloudflare, approvals, File Transfer, permissions, and troubleshooting |
| [ChatGPT developer mode](docs/CHATGPT_DEVELOPER_MODE.md) | Connecting ChatGPT |
| [Federico Viticci tools](docs/FEDERICO_CLI_TOOLS.md) | What MacRemote shares from my command-line apps |
| [What's new in 1.1](docs/releases/1.1.md) · [1.0](docs/releases/1.0.md) | The release notes, and what changed if you tried an earlier version |
| [Security](SECURITY.md) | The rules, and how to report a problem |
| [Architecture and Security](docs/ARCHITECTURE_SECURITY.md) · [Threat Model](docs/THREAT_MODEL.md) | How it all works, and why |

## Building From Source

MacRemote is a Swift package with no Xcode project. [INSTALL.md](INSTALL.md)
covers building, testing, and packaging a release.
[CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md) have the rules
for changing it.

```text
App/        SwiftUI app entry point
Models/     Domain models
Services/   Server, tunnel, sign-in, process, and tool services
Stores/     App state and persistence
Views/      SwiftUI views
Support/    Formatting and small helpers
Widget/     The page that shows formatted results in MCP apps
Shaders/    Metal shader for the light behind the connection status
Resources/  Icon, bundled assets, and third-party notices
Tests/      Swift and Python tests
Tools/      Icon and banner build scripts
docs/       Guides, design, security, and release notes
script/     Build and release scripts
```

---

<p align="center">
  Made by <a href="https://www.macstories.net">Federico Viticci</a> for MacStories Club members.<br>
  Copyright © 2026 Federico Viticci. All rights reserved.
</p>
