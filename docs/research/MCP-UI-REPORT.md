# MCP UI mode for MacRemote

**Research report — 2026-07-02.** All load-bearing claims below were adversarially verified against primary sources (spec text, Anthropic docs, GitHub issues, and the MacRemote repo itself); see the appendix.

---

## TL;DR — Ship it

**Ship Phase 1 now: one universal, adaptive "terminal output" widget bound to every tool.** Not a prototype, not a wait. Three reasons:

1. **The bet is asymmetric.** The spec *mandates* meaningful text `content` as fallback, and MacRemote already emits it on every call. Claude Code, Raycast, and every non-rendering client see literally nothing change. The only possible downside is a widget that fails to render on Claude — which degrades to today's behavior.
2. **MacRemote is accidentally optimized for this.** Every registered tool returns one identical `structuredContent` envelope through one shared `outputSchema()` (verified: `LocalMCPServer.swift:745–759`, `:849–878` — even bridged MCP tools get normalized). One HTML file covers the entire catalog at O(1) cost. Most MCP Apps servers hand-craft a widget per tool; you get full coverage from one template.
3. **The cost is ~2–3 days**, all in `LocalMCPServer.swift` plus one bundled HTML file, and the production endpoint is the only real test bed for Claude custom-connector rendering anyway.

Gate "done" on the render checklist in the Security section — Claude's custom-connector rendering has documented flakiness (open bug anthropics/claude-ai-mcp#61), and that's a reliability risk you verify empirically, not a policy risk. **Skip permanently:** in-chat approval widgets (they'd move approval into the channel being gated — violates AGENTS.md D2–D4 and the threat model), live-progress widgets (no job model exists), and per-CLI bespoke widgets (violates the "no special product modes" rule).

One correction to prior notes: the catalog is dynamic, not "219 tools" — currently 218 registered (141 process, 66 stdio-bridge, 11 HTTP-bridge), ~189 exposed after disabled-tool filtering. None of this changes the architecture.

---

## How MCP Apps & mcp-ui actually work

MCP Apps (SEP-1865) is the first official MCP extension — status **Final**, with a frozen stable spec dated 2026-01-26 and SDK v1.0.0. The mechanism: a UI is a **predeclared MCP resource** with a `ui://` URI and MIME type exactly `text/html;profile=mcp-app`, served as a self-contained HTML5 document via a plain `resources/read` request. A tool opts in by carrying `_meta.ui.resourceUri: "ui://..."` in its `tools/list` entry (the flat `_meta["ui/resourceUri"]` form is deprecated — use the nested form). The *host* (not the server) advertises support via `capabilities.extensions["io.modelcontextprotocol/ui"]` in its `initialize` request; the server needs only the standard `resources` capability. When a UI-enabled tool runs, the host renders the HTML in a sandboxed iframe (web hosts use a double-iframe sandbox proxy on a separate origin) and delivers the tool's full `CallToolResult` — including `structuredContent` — to the widget via `ui/notifications/tool-result` over a JSON-RPC-over-postMessage channel. Nothing about this requires SSE, sessions, or server-initiated notifications: discovery is `tools/list`, fetch is `resources/read`, hydration is host↔iframe postMessage. **MacRemote's stateless, POST-only, `Connection: close` server is fully spec-compliant as-is** (verified against the Streamable HTTP spec — sessions are optional, GET may return 405). Widgets can also call back: an app-initiated `tools/call` is proxied by the host over the *same authenticated server connection* as model calls — there is no side channel.

mcp-ui is where this came from: Ido Salomon and Liad Yosef's community project, unified with OpenAI's Apps SDK into SEP-1865 by the same authors. The convergence question is closed — mcp-ui deleted its own spec (March 2026), the `@mcp-ui/*` packages now implement the official standard, and mcp-ui positions itself as the reference *client* SDK. There is no fork risk. The one gap that matters for MacRemote: official SDKs are TypeScript/Python/Ruby only, so the Swift server side is hand-rolled — which is fine, because the server contract is tiny (serve one resource, add one `_meta` key) and the spec explicitly supports raw postMessage without any SDK. Residual churn to track: the flat-key removal before GA, plus additive draft-spec evolution (bidirectional tools, sampling) that lands in future dated versions and doesn't affect the frozen 2026-01-26 spec you'd build against.

---

## Host support reality

| Host | Renders MCP Apps? | Notes for MacRemote |
|---|---|---|
| **Claude.ai (web)** | **Yes** | Full remote MCP + MCP Apps. Custom (non-directory) connectors render — **verified, no directory allowlist** — but reliability bugs are real and open (claude-ai-mcp#61). Per-connector "Always allow" prompt on first render. |
| **Claude Desktop** | **Yes** | Local stdio and remote connectors. Known flakiness class: full protocol handshake succeeds, text fallback renders anyway (ext-apps#671). |
| **Claude iOS** | **Yes** (WKWebView) | Remote connectors; debuggable via Safari Web Inspector. **No confirmed custom-remote-connector render report found for iOS specifically** — this is your highest-value verification target, since it's your dominant surface. |
| **Claude Code** | **No — terminal, by design** | Ignores `_meta.ui` silently (verified in claude-ai-mcp#61: doesn't advertise the extension, falls back to text). Separate 25k-token MCP output limit. Nothing regresses. |
| ChatGPT | Yes | Apps SDK lineage; UI actions partial. Free upside, not a target. |
| VS Code (Copilot) | Yes (stable) | — |
| M365 Copilot, Goose, Postman, LibreChat, MCPJam, mcp-use, Smithery, Archestra | Yes | MCPJam is the useful one: neutral debug host for smoke-testing before blaming Claude. |
| Cursor | No | Open feature request. |
| **Raycast** | **No evidence of support** | Absent from every support matrix. Assume text-only; fallback covers it. |

The critical Claude-specific gotcha: **tool results over ~150,000 characters get diverted to Claude's code-execution sandbox filesystem** (when code execution is active — it is by default), and the widget receives a file pointer instead of `structuredContent` and never hydrates. This is confirmed in Anthropic's own troubleshooting doc. It matters acutely for MacRemote because your output caps are far above the threshold: default 512 KB (`ToolDefinitionDraft.swift:26`), presets mostly 1024–2048 KB, some 5120 KB. Mitigation is in your hands (below).

---

## Would it work generically for any CLI?

**Yes — automatically, with zero per-tool adapters. This is the headline finding.**

The reason is a property of MacRemote's own design, verified in the code: every tool — Flexible Command, Fixed Command, and both bridge types — returns the *same* ten-field envelope (`toolID, toolName, exitCode, succeeded, stdout, stderr, durationSeconds, timedOut, truncatedStdout, truncatedStderr`) built by a single function (`structuredContent(for:)`, `LocalMCPServer.swift:745–759`) and described by a single schema with no per-tool variance (`outputSchema()`, `:849–878`). Bridged MCP tools can't break uniformity because `MCPHTTPBridgeClient`/`MCPStdioBridgeClient` serialize upstream results into the `stdout` string of a `ToolExecutionOutcome` before they ever reach the envelope. A widget that knows how to render this envelope renders **every** tool, including any CLI you add next week. Dedicated adapters are not just unnecessary — they'd be worse: `category` doesn't predict output shape (git and codex are both `.developer`), and per-CLI widgets would recreate the "special product modes" AGENTS.md forbids.

**Recommended architecture — one adaptive universal widget:**

- **Server side:** a single `ui://macremote/terminal-output` resource, referenced by every tool's `_meta.ui.resourceUri`. That's the entire per-tool "adapter": one shared URI.
- **Widget side (where the adaptivity lives):** self-contained HTML, ~400–600 lines, no build step. It inspects `structuredContent` and picks a rendering: `stdout` parses as JSON → collapsible tree; array of objects → sortable table; otherwise → styled monospace terminal panel. Plus exit-code badge, duration, collapsible stderr tab, truncation warnings, copy button, Claude theme variables from `hostContext.styles`. Since remctl/pocketctl/habitctl tool descriptions already steer clients toward `--json`, the structured path fires constantly with zero server work.
- **ANSI color is mostly moot** — tools run with piped stdio, so most CLIs emit plain text. A styled `<pre>` is still a clear win over raw JSON blobs in chat. Optionally set `FORCE_COLOR=1` per-tool later and inline a 2 KB ANSI converter.
- **Phase 2, opt-in only:** an optional `uiResource` field on `ToolDefinition` for flagship tools (a remctl dashboard whose checkboxes fire proxied `tools/call remctl done` through your approval gate), plus `visibility: ["app"]` helper tools — e.g. a hidden `read-output-page` tool for paginating big results, or a `list-directory` picker to solve the "use absolute paths" pain in Flexible Command adapters. Do remctl first, and only after Phase 1 renders reliably.
- **Skip:** per-category templates (all cost, no marginal payoff over the adaptive widget) and streaming/progress (execution is synchronous within one POST; MCP Apps has no server-push — a widget shows a *completed* run, and that's fine).

Ship it behind a global "UI mode" toggle plus per-tool opt-out in the Tools UI — some tools genuinely read better as plain text in context.

---

## What MacRemote would implement

All changes land in `Services/LocalMCPServer.swift` plus one file in `Resources/`:

1. **`resources/read` handler** in the JSON-RPC dispatch switch (`:599–626` — today anything beyond `initialize`/`ping`/`tools/list`/`tools/call`/`notifications/initialized` returns `-32601`). For `ui://macremote/terminal-output`, return the bundled HTML with `mimeType: "text/html;profile=mcp-app"`. Reuse the existing `staticResourceData(fileName:)` plumbing (`:1180–1204`). Behind the same OAuth gate as `tools/call`. `resources/list` is optional — the spec lets you omit UI-only resources; hosts MUST fetch via the tool's `resourceUri` directly.
2. **`initialize` capabilities** (`:603–607`): add `"resources": {}`. **Do not** add `capabilities.extensions["io.modelcontextprotocol/ui"]` server-side — the two analyses contradicted each other here and the spec resolves it decisively: only the *host* advertises that extension; a server-side entry is meaningless. (Optionally read the client's extension capability from the initialize request — today only `protocolVersion` is read — but don't gate on it; see 3.)
3. **`_meta.ui.resourceUri`** (nested form) added to every entry in `toolJSON()` (`:765–774`), emitted **unconditionally**. Per-session capability gating is a SHOULD, not a MUST, and is impractical in a stateless server; verified spec-legal and empirically tolerated — Claude Code ignores the key, non-supporting hosts fall back to text, no client errors on it.
4. **The widget itself**: one self-contained HTML file implementing `ui/initialize` → `ui/notifications/initialized`, listening for `ui/notifications/tool-result`, hydrating from `structuredContent`, emitting `size-changed`, applying host theme variables. Raw postMessage JSON-RPC, no npm dependency — appropriate for a hand-rolled Swift server. Declare **no** `_meta.ui.csp` (see Security).
5. **150k-char mitigation — not optional.** Your output caps (512 KB default, presets to 5 MB) sit 3–35× above Claude's hydration threshold, and the current `content` block duplicates the envelope JSON, roughly halving the effective budget. When emitting `_meta.ui`, cap the `stdout`/`stderr` fields so the *total* `CallToolResult` stays comfortably under ~150k chars (~60 KB stdout is safe), set `truncatedStdout: true`, and let Phase 2's app-only pagination tool recover the rest.
6. **Tests** in the existing `Tests/MacRemoteTests/LocalMCPServerTests.swift` patterns (which already assert the envelope): resource served with correct MIME type, 401 without auth, `_meta.ui` present on tools/list, envelope size cap, adversarial-output injection tests (see below).

Nothing else: no SSE, no session state, no transport changes, no display-mode work. The approval path (`callTool` → `ToolCallApprovalCoordinator`, `:647–697`) needs **zero changes** — verified below.

---

## Security posture

MacRemote's position is unusual and mostly favorable: **first-party server, first-party HTML, third-party host.** The spec's threat model protects hosts from malicious servers; you're the server author, the user, and the machine owner. What remains:

- **The one real risk: reflected injection through tool output.** The widget renders output of arbitrary CLIs and bridged third-party MCP servers — untrusted data flowing into your HTML. An XSS in your own widget executes inside the host sandbox, which holds a live channel that can `tools/call` back into MacRemote — i.e., a laundered RCE path onto the Mac Studio. Mitigation is entirely yours: **treat all tool output as text (`textContent`, never `innerHTML`)**, and add adversarial payloads (`<script>`, `<img onerror>`, closing tags, ANSI escapes) to the Swift Testing suite.
- **Approval parity holds structurally — verified.** A widget's *only* path to a tool is postMessage → host → ordinary `tools/call` over the same authenticated connection into the same `callTool` path, where `ToolCallApprovalCoordinator` gates every non-read-only call and blocks execution entirely if absent. The server cannot even distinguish widget-originated from model-originated calls, so the Mac-side gate applies identically. There is no spec'd channel that skips the server; the OAuth token lives in the host, never in the iframe. Interactive widgets that *still* can't touch your Mac without a Mac-side approval is a genuinely good story. The corollary rule: never create an "our own widget is trusted" bypass.
- **Zero CSP is the right posture.** Declare no `_meta.ui.csp`; the host-enforced default (`connect-src 'none'`, `default-src 'none'`) means even a compromised widget can't exfiltrate anywhere. Bundle everything into the single HTML file. Any future CSP entry is a deliberate widening.
- **No new anonymous surface.** `ui://` resources are served via `resources/read` behind the same OAuth gate on the same endpoint.
- **`visibility: ["app"]` tools (Phase 2):** enforce server-side too, not just host-side — hosts MUST reject model calls to app-only tools, but #671-class bugs prove host enforcement can fail.

**Pre-ship checklist (ship when all true):** widget renders as an actual iframe — not the "[This tool call rendered an interactive widget...]" fallback — on claude.ai web, Desktop, **and iOS**; Claude Code and Raycast output unchanged; hydration works at realistic output sizes (test 100k/150k/200k chars against the cap); injection tests pass; unauthenticated `resources/read` returns 401; a widget-initiated call to a non-approved tool is rejected by the coordinator; a widget `fetch()` to an external origin is blocked by the default CSP.

---

## Verified-claims appendix

| Claim | Verdict | Source |
|---|---|---|
| Uniform `structuredContent` envelope + one shared `outputSchema` across all tools, including bridged MCP tools — basis for the O(1) universal widget | **Confirmed** (tool count corrected: 218 registered / ~189 enabled, dynamic — not a fixed 219) | `LocalMCPServer.swift:745–759, 849–878`; `MCPHTTPBridgeClient.swift:22–46`; `MCPStdioBridgeClient.swift:131,144`; `LocalMCPServerTests.swift:445, 754–756` |
| Claude renders MCP Apps for self-hosted custom connectors, not only directory-listed ones | **Confirmed** — no allowlist; failures are triaged as bugs, not policy; caveat: reliability flaky, no confirmed custom-remote render on iOS specifically | support.claude.com/en/articles/13454812; github.com/anthropics/claude-ai-mcp issues #61, #471; cto4.ai/p/mcp-apps-in-context |
| Discovery via `_meta.ui.resourceUri` + plain `resources/read`; no SSE/sessions/server-push needed — works on MacRemote's stateless POST-only transport | **Confirmed** | ext-apps spec 2026-01-26 (apps.mdx); modelcontextprotocol.io/specification/2025-11-25/basic/transports; claude.com/docs/connectors/building/mcp-apps/troubleshooting.md |
| Ungated `_meta.ui` emission is spec-legal (SHOULD not MUST) and tolerated by all clients; Claude Code ignores it; no regression possible | **Confirmed** — ship the nested `_meta.ui.resourceUri` form; flat form dies before GA | ext-apps spec §Server Behavior; claude-ai-mcp#61 (empirical, incl. a stateless FastMCP server); MCP base spec `_meta` definition |
| Widget-initiated `tools/call` hits the same authenticated `callTool` path and Mac-side approval gate; no bypass channel exists | **Confirmed** | ext-apps spec sequence diagram + threat model; SEP-1865; `LocalMCPServer.swift:647–697`; OpenAI Apps SDK reference (same architecture) |
| Claude diverts tool results >~150k chars to the sandbox filesystem; widget never hydrates; MacRemote's caps (512 KB–5 MB) far exceed the threshold | **Confirmed** — the single biggest engineering constraint; divert conditional on code execution being active (default on) | claude.com/docs/connectors/building/mcp-apps/troubleshooting; `ToolDefinitionDraft.swift:26`; `DefaultToolPresetCatalog.swift` |
| Contradiction between analyses on server-side extension advertisement | **Resolved** — host-only advertises `io.modelcontextprotocol/ui`; server adds only `"resources": {}` | ext-apps spec §Capability Negotiation; ext-apps SDK `getUiCapability` (reads *client* capabilities only); MCP draft schema |
| SEP-1865 Final, stable 2026-01-26 spec, first official extension; mcp-ui fully converged, no fork risk | **Confirmed** — but residual churn is broader than the flat-key removal (draft adds ~955 lines, all additive; the dated spec is immutable) | modelcontextprotocol.io/seps/1865; ext-apps repo release commits; MCP-UI-Org/mcp-ui commit "remove legacy spec" #185 (2026-03-09) |

---

## Sources

**Spec / official:** modelcontextprotocol.io/seps/1865-mcp-apps-interactive-user-interfaces-for-mcp · github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx · blog.modelcontextprotocol.io/posts/2026-01-26-mcp-apps/ · modelcontextprotocol.io/extensions/apps/overview · modelcontextprotocol.io/specification/2025-11-25/basic/transports

**Anthropic / Claude:** support.claude.com/en/articles/13454812-use-interactive-connectors-in-claude · claude.com/docs/connectors/building/mcp-apps/getting-started.md · claude.com/docs/connectors/building/mcp-apps/troubleshooting.md · claude.com/docs/connectors/building/mcp-apps/cross-compatibility.md · claude.com/blog/interactive-tools-in-claude · github.com/anthropics/claude-ai-mcp (issues #61, #165, #471)

**mcp-ui / ecosystem:** github.com/MCP-UI-Org/mcp-ui · mcpui.dev/guide/supported-hosts · github.com/modelcontextprotocol/ext-apps/issues/671 · developers.openai.com/apps-sdk/reference · dev.to/infoxicator/i-reverse-engineered-chatgpt-apps-iframe-sandbox-2ok3 · backslash.security/blog/new-mcp-spec-opens-new-attack-surfaces · forum.cursor.com/t/mcp-apps-support/146072

**Repo (primary source):** /Users/viticci/Projects/MacRemote/Services/LocalMCPServer.swift · Services/ToolSurfaceRuntime.swift · Services/MCPHTTPBridgeClient.swift · Models/ToolDefinitionDraft.swift · Models/DefaultToolPresetCatalog.swift · AGENTS.md (D2–D4, no-special-modes rule) · Tests/MacRemoteTests/LocalMCPServerTests.swift