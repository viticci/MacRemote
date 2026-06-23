# End-to-End Smoke Test

This is the final verification path for proving that Anthropic can reach
MacRemote over a public MCP URL, complete MacRemote OAuth with host approval,
discover a RemCTL tool, call it, and receive a tool result.

The script follows Anthropic's current remote MCP connector shape:
`mcp_servers` plus a matching `tools: [{ "type": "mcp_toolset", ... }]` entry
with the `anthropic-beta: mcp-client-2025-11-20` header.

Source: https://platform.claude.com/docs/en/agents-and-tools/mcp-connector

## Preconditions

1. Build and launch MacRemote:

   ```bash
   ./script/build_and_run.sh --verify
   ```

2. In MacRemote > Settings, run **Check Access**.

3. If Full Disk Access is required, grant access to the exact targets shown in
   Settings, then relaunch MacRemote and check again. In the current development
   build those targets are typically:

   ```text
   /Library/Frameworks/Python.framework/Versions/3.13/bin/python3.13
   /Users/viticci/Projects/MacRemote/dist/MacRemote.app
   ```

4. Start the local MCP server in Dashboard. This remains blocked until
   `remctl doctor --for-agent --json` passes from MacRemote's process context.

5. Start the Cloudflare Tunnel in MacRemote and copy the public MCP URL shown in
   Tunnel. It should look like:

   ```text
   https://<host>.trycloudflare.com/mcp/<instance-id>
   ```

   The Tunnel view can also run or copy the exact preflight and full Anthropic
   smoke test commands once the public MCP URL exists.

## Anthropic Smoke Test

Run the script from the repository root. Do not paste or store secrets in files.
You can also run both checks directly from MacRemote > Tunnel. The full API
smoke path reads the Anthropic key with `/Users/viticci/bin/op-get` at runtime
and does not write it to the audit log.

To validate MacRemote before calling Anthropic:

```bash
MACREMOTE_MCP_URL="https://<host>.trycloudflare.com/mcp/<instance-id>" \
./script/anthropic_mcp_smoke.py --mcp-preflight-only
```

Expected successful preflight output includes:

```text
oauth_status=waiting_for_host_approval
oauth_status=approved
mcp_preflight=passed
anthropic_call=skipped
```

Then run the full API smoke test:

```bash
ANTHROPIC_API_KEY="$(/Users/viticci/bin/op-get "Anthropic API Key")" \
MACREMOTE_MCP_URL="https://<host>.trycloudflare.com/mcp/<instance-id>" \
./script/anthropic_mcp_smoke.py
```

The script will:

1. Register a temporary OAuth client with MacRemote.
2. Open a host approval request in MacRemote > Approvals, including the public
   MCP URL as the OAuth `resource` indicator.
3. Poll MacRemote until the request is approved.
4. Exchange the authorization code for an access token bound to that same MCP
   resource.
5. Call Anthropic's Messages API with the MacRemote MCP URL.
6. Enable only the selected tool, defaulting to `remctl.today`.
7. Report whether Claude produced `mcp_tool_use` and `mcp_tool_result` blocks.

Before the Anthropic call, the script also performs a direct MCP preflight
against the same URL and access token:

- protected-resource metadata at the root and path-specific well-known URL;
- authorization-server issuer metadata;
- `initialize`;
- `notifications/initialized`;
- `tools/list`, including the selected tool.

Expected successful output includes:

```text
oauth_status=waiting_for_host_approval
oauth_status=approved
mcp_preflight=passed
mcp_tool_use_count=1
mcp_tool_result_count=1
smoke_test=passed
```

The script does not print the OAuth access token or Anthropic API key.

## Full CLI Variant

The default smoke test uses the read-only `remctl.today` helper to avoid a
second per-call approval. To prove the full `remctl.run` adapter instead, use a
prompt that supplies argv and approve the tool call in MacRemote > Approvals:

```bash
ANTHROPIC_API_KEY="$(/Users/viticci/bin/op-get "Anthropic API Key")" \
MACREMOTE_MCP_URL="https://<host>.trycloudflare.com/mcp/<instance-id>" \
./script/anthropic_mcp_smoke.py \
  --tool remctl.run \
  --prompt 'Use the MacRemote MCP tool `remctl.run` with args ["--format", "json", "today"]. Do not answer from memory. Summarize only whether the call succeeded.'
```

For `remctl.run`, MacRemote will pause execution until the host approves that
specific command in Approvals.

Use `--skip-mcp-preflight` only when debugging Anthropic connector behavior
after the direct MacRemote preflight has already passed.
