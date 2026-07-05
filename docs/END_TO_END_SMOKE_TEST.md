# End-to-End Smoke Test

This is the verification path for proving that a remote MCP client can reach
MacRemote over a public MCP URL, complete OAuth with host approval, discover the
currently exposed tools, call one selected tool, and receive a structured result.

The Anthropic smoke script follows Anthropic's remote MCP connector shape:
`mcp_servers` plus a matching `tools: [{ "type": "mcp_toolset", ... }]` entry.

Source: https://platform.claude.com/docs/en/agents-and-tools/mcp-connector

## Preconditions

1. Build and launch MacRemote:

   ```bash
   ./script/build_and_run.sh --verify
   ```

2. Choose the exposed surface in **Tools**. Add individual presets, one of the
   bulk **Tool Sets**, or a custom command. MacRemote has no required default CLI;
   RemCTL, PocketCTL, Codex, and every other command are optional tools.

3. In **Settings**, run **Check Access** when the exposed surface includes tools
   with Full Disk Access or macOS privacy requirements. The **Tunnel** view also
   surfaces readiness failures before remote proof.

4. If access is required, grant every listed target in System Settings, relaunch
   MacRemote, then check again. Script-based CLIs may list both the CLI and the
   interpreter that actually reads protected data.

5. Start the local MCP server in **Dashboard**. This remains blocked until
   required permission checks pass from MacRemote's process context.

6. Start the Cloudflare Tunnel in **Tunnel** and copy the public MCP URL. For a
   quick tunnel it should look like:

   ```text
   https://<host>.trycloudflare.com/mcp
   ```

   For a custom Cloudflare domain deployed from the same view, it should look
   like:

   ```text
   https://<subdomain.example.com>/mcp
   ```

   If OAuth Client Secret mode is enabled, copy a generated client ID and secret
   from **Settings**. Use a separate credential entry for each remote app you
   want MacRemote to show and revoke independently. If Single Header mode is
   enabled, copy the generated `Authorization` header instead.

7. In **Tunnel**, run **Check Readiness**. Remote proof requires:

   - required Full Disk Access and macOS privacy checks to be ready;
   - local MCP server running;
   - public MCP URL created;
   - at least one exposed tool;
   - at least one read-only tool for the default full API smoke test;
   - an Anthropic API key for the full API smoke test.

## Direct MCP Preflight

Run the script from the repository root:

```bash
MACREMOTE_MCP_URL="https://<host>.trycloudflare.com/mcp" \
./script/anthropic_mcp_smoke.py --mcp-preflight-only
```

For OAuth Client Secret mode:

```bash
MACREMOTE_MCP_URL="https://<host>.trycloudflare.com/mcp" \
MACREMOTE_OAUTH_CLIENT_ID="<client-id>" \
MACREMOTE_OAUTH_CLIENT_SECRET="<client-secret>" \
./script/anthropic_mcp_smoke.py --mcp-preflight-only
```

Single Header mode skips OAuth entirely — check it directly with curl using
the header MacRemote copied:

```bash
curl -s -X POST "https://<host>/mcp" \
  -H "Authorization: Bearer <macremote-generated-token>" \
  -H "Content-Type: application/json" \
  -H "MCP-Protocol-Version: 2025-06-18" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

Expected successful output includes:

```text
oauth_status=waiting_for_host_approval
oauth_status=approved
mcp_preflight=passed
anthropic_call=skipped
```

The preflight checks:

- protected-resource metadata at the root and path-specific well-known URL;
- authorization-server issuer metadata;
- OAuth registration, approval polling, and token exchange;
- `initialize`;
- `notifications/initialized`;
- `tools/list`, including the selected tool.

## Full Anthropic Smoke Test

```bash
ANTHROPIC_API_KEY="<key>" \
MACREMOTE_MCP_URL="https://<host>.trycloudflare.com/mcp" \
./script/anthropic_mcp_smoke.py
```

The script selects the first exposed read-only tool by default. Override it with
`--tool` when you want a specific tool.

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

## Broad CLI Adapter Variant

To prove a broad CLI adapter, choose a harmless read-only command and approve the
tool call in **Approvals**, or pre-approve that tool for the client in
**Clients**:

```bash
ANTHROPIC_API_KEY="<key>" \
MACREMOTE_MCP_URL="https://<host>.trycloudflare.com/mcp" \
./script/anthropic_mcp_smoke.py \
  --tool custom.tool-id \
  --prompt 'Use the selected MacRemote MCP tool exactly once with harmless read-only arguments. Summarize only whether the call succeeded.'
```

For CLI adapters, the prompt must pass exact argv items as an array. There is no
shell expansion.

## File Download Variant

To exercise the built-in File Transfer tools, share `builtin.fs.download_file`
in **Tools**, call it against a small file, then fetch the handle. The tool
result carries `download_url`; fetch it directly (no bearer needed):

```bash
curl -sSL -OJ "https://<host>/artifact/<token>"
```

The link stops working after 3 downloads or 10 minutes, and immediately when
the server stops.

## Changing Tools While Connected

MacRemote updates the running tool surface when tools are added, removed, or
toggled. Connected clients must refresh `tools/list` to see the new surface. If a
client caches tool lists and does not refresh, reconnect that client; the tunnel
does not need to be stopped solely because the tool registry changed.
