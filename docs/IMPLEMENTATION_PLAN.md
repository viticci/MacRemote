# MacRemote Implementation Plan

## Phase 1: Secure Skeleton

- Create SwiftPM macOS app scaffold.
- Add project-local `script/build_and_run.sh`.
- Add `.codex/environments/environment.toml`.
- Build the native SwiftUI shell.
- Add persistent app model for server, tunnel, tools, auth requests, and logs.
- Add RemCTL read-only tool definitions.
- Add direct process runner that never invokes a shell.
- Add unit tests for command validation and argv construction.

## Phase 2: Local MCP Server

- Add local HTTP listener bound to `127.0.0.1`.
- Add `/health`.
- Add minimal OAuth metadata endpoints.
- Add pending host-approval flow in app state.
- Add token issuance with PKCE.
- Add `/mcp` JSON-RPC handling for `tools/list` and `tools/call`.
- Wire RemCTL read-only tools through the MCP handler.
- Add an explicit Reminders permission preflight for GUI-launched RemCTL reads.

## Phase 3: Tunnel

- Detect `cloudflared`.
- Start from a local-only server health check.
- Create or reuse a named Cloudflare Tunnel.
- Route a single hostname or high-entropy path to the local MCP port.
- Show the MCP URL in the app.
- Add stop/disable/rotate actions.

## Phase 4: Remote Model Smoke Test

- Get a provider API key from 1Password at runtime.
- Use the public HTTPS MCP URL in an Anthropic or OpenAI API call.
- Confirm the model can discover the RemCTL tool.
- Approve the auth request on the Mac.
- Confirm a read-only RemCTL result returns through MCP.

## Phase 5: Computer Use Verification

- Launch the built app.
- Inspect the UI visually.
- Start server from the app.
- Confirm status changes, pending approval state, and log entries.
- Keep destructive actions disabled unless explicitly approved.

## Non-Negotiable Gates

- No shell-based tool runner.
- No server binding outside `127.0.0.1`.
- No public tunnel before local health passes.
- No OAuth token without host approval.
- No RemCTL write command in the first public tunnel profile.
- No secrets in logs, git, screenshots, or command output.
- No silent bypass around macOS privacy permissions; if RemCTL cannot read the
  local store from the app bundle, show the permission failure and stop.
