# MacRemote Repository Threat Model

## Overview

MacRemote is a macOS app that exposes a small, user-approved set of local Mac
tools to remote MCP clients. Its primary surfaces are a native SwiftUI
configuration app, a loopback-only MCP HTTP server, a command runner, an OAuth
authorization flow, and a Cloudflare Tunnel integration.

The most sensitive asset is the local Mac user session. A successful compromise
could run local commands, read local data, manipulate Reminders through RemCTL,
or mint remote tokens that let a chatbot keep calling tools after initial
authorization. Command execution, token issuance, tunnel exposure, and audit
logging are security-critical runtime code.

## Trust Boundaries

Trusted actors:

- the local Mac user operating the app;
- the app code and bundled helper code after local installation;
- Cloudflare Tunnel as a transport provider, when configured by the user;
- the selected remote MCP client only after successful OAuth and host approval.

Untrusted or attacker-controlled actors:

- anyone who learns or guesses the public MCP URL;
- malicious or compromised remote MCP clients;
- prompt-injected model behavior that attempts unexpected tool calls;
- attacker-controlled MCP request fields, JSON-RPC inputs, OAuth client names,
  redirect URIs, tool parameters, and HTTP headers;
- local malware or another local user process.

Core boundaries:

- public internet to Cloudflare Tunnel;
- Cloudflare Tunnel to `127.0.0.1:<port>`;
- HTTP server to auth/session state;
- MCP tool call to command runner;
- command runner to local CLIs such as `/Users/viticci/bin/remctl`;
- app UI to persistent configuration and secrets.

## Core Assumptions

- The local MCP server binds only to loopback.
- The tunnel forwards only to the MCP server port.
- A leaked URL alone must not authorize a client.
- User-defined tools are exact executable paths plus argv templates, not shell
  strings.
- Secrets are stored in Keychain or protected app support files and never
  committed.

## Attack Surface

Remote HTTP/MCP inputs are the largest attack surface. The server must validate
all JSON-RPC shapes, reject unknown methods, cap body size, cap output size, and
avoid reflecting attacker-controlled strings into HTML without escaping.

OAuth and client registration are critical. A malicious client may try open
redirects, PKCE bypass, authorization code replay, refresh token reuse, or client
impersonation. Mitigations include strict redirect URI validation, PKCE required
for code flow, one-time authorization codes, short token lifetimes, refresh token
rotation, token hashing or encryption at rest, and host-side approval before
code issuance.

Tool execution is critical. A malicious model may try command injection through
tool parameters or ask for a broader tool than approved. Mitigations include no
shell execution, exact executable allow-lists, per-tool parameter schemas, argv
construction from typed values, fixed timeouts, environment allow-lists, and
separate capability classes for read-only, write, and destructive tools.
Generic CLI adapters intentionally expose one executable plus model-supplied
argv and optional stdin. That is universal but not a sandbox. Each generic
adapter must be treated as delegation of the whole executable's reachable
capability surface. Shell interpreters and `/usr/bin/env` are blocked because
they erase the executable boundary.

Default command categories are only preset drafts. They must not be auto-enabled
or silently added to the exposed MCP surface. Filesystem presets are constrained
to read-only commands and must not include delete, unlink, or trash operations;
write-capable presets such as image conversion must be labeled as write tools.

Tunnel setup is high risk. A bug that binds the local server to `0.0.0.0` or
forwards a broad local service would expose more than the intended MCP process.
Mitigations include loopback-only listeners, health checks before tunnel start,
single-origin tunnel routing, high-entropy instance identifiers, and explicit
stop/rotate controls in the UI.

Logs and diagnostics can leak secrets. Audit logs must redact tokens,
authorization codes, refresh tokens, Cloudflare credentials, request headers,
and full command output by default.

## Severity Calibration

Critical:

- arbitrary shell command execution through a remote MCP call;
- token issuance without host-side approval;
- public tunnel exposing anything beyond the MacRemote MCP server;
- auth bypass allowing leaked URL holders to call RemCTL tools.

High:

- redirect URI validation flaw that leaks authorization codes;
- refresh token replay or non-rotating refresh tokens;
- full RemCTL CLI exposed without host-approved OAuth, destructive tool
  annotation, or per-call host approval for writes;
- RemCTL exposed before a verified Full Disk Access gate passes from
  MacRemote's process context;
- logs storing bearer tokens or Cloudflare credentials.

Medium:

- missing request or output size limits causing local denial of service;
- weak or predictable instance identifiers;
- incomplete audit records that prevent the user from understanding which client
  called which tool;
- UI state desynchronization that shows the tunnel stopped while it is still
  running.

Low:

- cosmetic UI mistakes that do not affect auth or execution;
- non-sensitive log wording issues;
- failure to detect optional tunnel providers when the local server remains
  stopped and no exposure occurs.
