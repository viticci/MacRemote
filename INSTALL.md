# Private Installation

These instructions are for private testers installing MacRemote from source.

## 1. Clone

```bash
git clone https://github.com/viticci/MacRemote.git
cd MacRemote
```

## 2. Install Requirements

MacRemote needs:

- macOS 14 or later.
- Xcode Command Line Tools or Xcode with `/usr/bin/swift`.
- `cloudflared` for public MCP tunnels.

Optional CLIs are detected automatically. Install only the commands you want to
expose, such as RemCTL, PocketCTL, Codex, Peekaboo, Spogo, Summarize, Gog, GitHub
CLI, or other local tools.

Check the machine:

```bash
script/macremotectl doctor --json
```

Swift and Cloudflare Tunnel are required. Optional CLIs can be missing.

## 3. Build

```bash
script/macremotectl install --launch
```

For a reusable local app copy:

```bash
script/macremotectl install --copy-to-applications --force --launch
```

The development build script signs the app automatically. Developer ID signing
and notarization are recommended before broader distribution, but are not
required for a private source checkout.

## 4. Add Tools

Open **Tools** in the app and add detected tools or preset sets.

Equivalent CLI commands:

```bash
script/macremotectl list-presets --json
script/macremotectl list-preset-sets --json
script/macremotectl add-preset-set set.detected_clis --replace
```

To remove all user-defined tools and start over:

```bash
script/macremotectl clear-tools --yes
```

## 5. Grant macOS Permissions

Some tools need macOS privacy access. MacRemote only asks for permissions needed
by the exposed tool surface.

When the app reports missing access:

1. Open **Settings**.
2. Run **Check Access**.
3. Grant every listed target in System Settings.
4. Relaunch MacRemote.
5. Run **Check Access** again.

Full Disk Access can require multiple targets: the MacRemote app, the CLI
executable, and sometimes the interpreter used by a script-based CLI.

## 6. Start MCP

In the app:

1. Start the local server from **Dashboard**.
2. Start the tunnel from **Tunnel**.
3. Copy the public MCP URL.
4. Add that URL to the remote MCP client.
5. Approve the OAuth client request in **Approvals**.

The URL shape is:

```text
https://<trycloudflare-host>/mcp/<instance-id>
```

Rotate the instance ID from **Settings** when the URL should be invalidated.

## 7. Verify

Run the local build and launch verification:

```bash
script/build_and_run.sh --verify
```

Run the remote MCP preflight after a tunnel exists:

```bash
MACREMOTE_MCP_URL="https://<host>.trycloudflare.com/mcp/<instance-id>" \
./script/anthropic_mcp_smoke.py --mcp-preflight-only
```

Expected marker:

```text
mcp_preflight=passed
```
