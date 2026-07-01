# MacRemote Implementation Status

Historical note: this file used to hold the original phase plan. Current setup
and agent guidance now live in `README.md`, `INSTALL.md`, `AGENTS.md`, and the
security docs.

## Current Shape

- SwiftPM macOS app with a native SwiftUI shell.
- User-defined tool registry with selectable exposure.
- Detected CLI presets and bulk preset sets.
- Generic CLI adapters and fixed command templates.
- Direct `Process` execution with no shell runner.
- Loopback-only MCP server.
- OAuth + PKCE with host approval before token issuance.
- Per-call approval for write/destructive tools.
- Persistent per-client tool policies for approved clients.
- Cloudflare Tunnel public MCP URL with a stable `/mcp` path.
- Full Disk Access and macOS privacy readiness checks driven by per-tool
  `permissionRequirements`.
- Remote MCP smoke test script.

## Current Gates

- No shell-based tool runner.
- No generic wrappers for shell interpreters or `/usr/bin/env`.
- No filesystem delete/unlink/trash presets.
- No server binding outside `127.0.0.1`.
- No public tunnel before local health passes.
- No OAuth token without host approval.
- No write or destructive tool execution without per-call approval or an
  explicit persistent client policy.
- No secrets in logs, git, screenshots, or command output.
- No protected-data tool exposure before required macOS access is verified from
  MacRemote's own process context.
