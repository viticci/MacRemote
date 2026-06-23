#!/usr/bin/env python3
"""End-to-end Anthropic MCP smoke test for MacRemote.

The script intentionally avoids printing OAuth or Anthropic tokens. It can run
MacRemote's OAuth flow, wait while the user approves the client in the app, then
call Anthropic's Messages API with the remote MCP URL.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any


ANTHROPIC_ENDPOINT = "https://api.anthropic.com/v1/messages"
DEFAULT_MODEL = "claude-opus-4-8"
DEFAULT_BETA = "mcp-client-2025-11-20"
DEFAULT_TOOL = "remctl.today"
DEFAULT_PROTOCOL_VERSION = "2025-11-25"


@dataclass(frozen=True)
class HTTPResult:
    status: int
    body: bytes
    headers: dict[str, str]

    def json(self) -> dict[str, Any]:
        return json.loads(self.body.decode("utf-8"))

    def text(self) -> str:
        return self.body.decode("utf-8", errors="replace")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run an Anthropic Messages API smoke test against a MacRemote MCP URL."
    )
    parser.add_argument("--mcp-url", default=os.environ.get("MACREMOTE_MCP_URL"), help="Public MacRemote MCP URL.")
    parser.add_argument(
        "--access-token",
        default=os.environ.get("MACREMOTE_ACCESS_TOKEN"),
        help="Existing MacRemote OAuth access token. If omitted, the script performs the host-approved OAuth flow.",
    )
    parser.add_argument(
        "--anthropic-api-key",
        default=os.environ.get("ANTHROPIC_API_KEY"),
        help="Anthropic API key. Can also be provided via ANTHROPIC_API_KEY.",
    )
    parser.add_argument("--model", default=os.environ.get("ANTHROPIC_MODEL", DEFAULT_MODEL))
    parser.add_argument("--beta", default=os.environ.get("ANTHROPIC_BETA", DEFAULT_BETA))
    parser.add_argument("--tool", default=os.environ.get("MACREMOTE_SMOKE_TOOL", DEFAULT_TOOL))
    parser.add_argument("--protocol-version", default=os.environ.get("MACREMOTE_MCP_PROTOCOL_VERSION", DEFAULT_PROTOCOL_VERSION))
    parser.add_argument(
        "--prompt",
        default=None,
        help="Override the prompt sent to Claude. Defaults to a read-only RemCTL tool call request.",
    )
    parser.add_argument("--server-name", default="macremote")
    parser.add_argument("--oauth-timeout", type=int, default=180)
    parser.add_argument(
        "--skip-mcp-preflight",
        action="store_true",
        help="Skip direct MacRemote discovery, initialize, and tools/list checks before the Anthropic call.",
    )
    parser.add_argument(
        "--mcp-preflight-only",
        action="store_true",
        help="Validate MacRemote discovery, OAuth, initialize, and tools/list, then exit before calling Anthropic.",
    )
    parser.add_argument("--show-response", action="store_true", help="Print the full Anthropic JSON response.")
    args = parser.parse_args()

    if args.skip_mcp_preflight and args.mcp_preflight_only:
        fail("--skip-mcp-preflight cannot be combined with --mcp-preflight-only.")
    if not args.mcp_url:
        fail("Missing --mcp-url or MACREMOTE_MCP_URL.")
    if not args.anthropic_api_key and not args.mcp_preflight_only:
        fail("Missing --anthropic-api-key or ANTHROPIC_API_KEY.")
    if not args.mcp_url.startswith("https://"):
        fail("MacRemote smoke tests require an HTTPS MCP URL.")

    access_token = args.access_token
    if not access_token:
        access_token = obtain_macremote_access_token(args.mcp_url, timeout_seconds=args.oauth_timeout)

    if not args.skip_mcp_preflight:
        preflight_macremote_mcp(
            mcp_url=args.mcp_url,
            access_token=access_token,
            expected_tool=args.tool,
            protocol_version=args.protocol_version,
        )

    if args.mcp_preflight_only:
        print("anthropic_call=skipped")
        return 0

    response = call_anthropic(
        api_key=args.anthropic_api_key,
        model=args.model,
        beta=args.beta,
        mcp_url=args.mcp_url,
        server_name=args.server_name,
        authorization_token=access_token,
        tool_name=args.tool,
        prompt=args.prompt or default_prompt(args.tool),
    )

    if args.show_response:
        print(json.dumps(response, indent=2, sort_keys=True))

    content = response.get("content", [])
    tool_uses = [block for block in content if block.get("type") == "mcp_tool_use"]
    tool_results = [block for block in content if block.get("type") == "mcp_tool_result"]
    matching_tool_uses = [
        block for block in tool_uses
        if block.get("name") == args.tool and block.get("server_name") == args.server_name
    ]

    print(f"model={args.model}")
    print(f"mcp_url={redacted_url(args.mcp_url)}")
    print(f"tool={args.tool}")
    print(f"mcp_tool_use_count={len(tool_uses)}")
    print(f"mcp_tool_result_count={len(tool_results)}")

    for index, block in enumerate(tool_uses, start=1):
        print(
            "tool_use[{index}] name={name} server={server}".format(
                index=index,
                name=block.get("name", "<unknown>"),
                server=block.get("server_name", "<unknown>"),
            )
        )

    for index, block in enumerate(tool_results, start=1):
        content_bytes = len(json.dumps(block.get("content", []), sort_keys=True).encode("utf-8"))
        print(
            "tool_result[{index}] is_error={is_error} content_bytes={content_bytes}".format(
                index=index,
                is_error=block.get("is_error"),
                content_bytes=content_bytes,
            )
        )

    if not matching_tool_uses:
        fail(f"Claude did not call expected MCP tool {args.tool!r}.")
    if not tool_results:
        fail("Claude did not return an MCP tool result.")

    print("smoke_test=passed")
    return 0


def obtain_macremote_access_token(mcp_url: str, timeout_seconds: int) -> str:
    base_url = macremote_base_url(mcp_url)
    resource = canonical_mcp_resource_url(mcp_url)
    verifier = secrets.token_urlsafe(48)
    challenge = pkce_challenge(verifier)
    redirect_uri = "http://127.0.0.1/callback"
    state = secrets.token_urlsafe(24)

    register_response = http_json(
        "POST",
        f"{base_url}/register",
        {
            "client_name": "MacRemote Anthropic Smoke Test",
            "redirect_uris": [redirect_uri],
            "scope": "mcp:tools",
        },
    )
    client_id = register_response.get("client_id")
    if not isinstance(client_id, str) or not client_id:
        fail("MacRemote did not return a client_id during OAuth registration.")

    authorize_query = urllib.parse.urlencode(
        {
            "response_type": "code",
            "client_id": client_id,
            "redirect_uri": redirect_uri,
            "scope": "mcp:tools",
            "state": state,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "resource": resource,
        }
    )
    authorize_result = http_request("GET", f"{base_url}/authorize?{authorize_query}")
    request_id = extract_request_id(authorize_result.text())
    if not request_id:
        fail("Could not find MacRemote OAuth request id in authorization page.")

    print("oauth_status=waiting_for_host_approval")
    print("Approve 'MacRemote Anthropic Smoke Test' in MacRemote > Approvals.")
    deadline = time.monotonic() + timeout_seconds
    code = None
    while time.monotonic() < deadline:
        status = http_json("GET", f"{base_url}/authorize/status?request_id={urllib.parse.quote(request_id)}")
        status_value = status.get("status")
        if status_value == "approved":
            redirect = status.get("redirect_uri")
            if not isinstance(redirect, str):
                fail("MacRemote approval response did not include redirect_uri.")
            code = code_from_redirect(redirect, expected_state=state)
            break
        if status_value in {"denied", "expired", "not_found"}:
            fail(f"MacRemote OAuth request ended with status={status_value}.")
        time.sleep(2)

    if not code:
        fail("Timed out waiting for MacRemote OAuth host approval.")

    token = http_form(
        "POST",
        f"{base_url}/token",
        {
            "grant_type": "authorization_code",
            "client_id": client_id,
            "redirect_uri": redirect_uri,
            "code": code,
            "code_verifier": verifier,
            "resource": resource,
        },
    )
    access_token = token.get("access_token")
    if not isinstance(access_token, str) or not access_token:
        fail("MacRemote token endpoint did not return an access_token.")

    print("oauth_status=approved")
    return access_token


def preflight_macremote_mcp(
    *,
    mcp_url: str,
    access_token: str,
    expected_tool: str,
    protocol_version: str,
) -> None:
    base_url = macremote_base_url(mcp_url)
    resource = canonical_mcp_resource_url(mcp_url)
    metadata_path = path_protected_resource_metadata_url(mcp_url)

    root_resource_metadata = http_json("GET", f"{base_url}/.well-known/oauth-protected-resource")
    path_resource_metadata = http_json("GET", metadata_path)
    authorization_server_metadata = http_json("GET", f"{base_url}/.well-known/oauth-authorization-server")

    assert_equal(root_resource_metadata.get("resource"), resource, "root protected-resource metadata resource")
    assert_equal(path_resource_metadata.get("resource"), resource, "path protected-resource metadata resource")
    assert_contains(
        path_resource_metadata.get("authorization_servers"),
        base_url,
        "path protected-resource authorization server",
    )
    assert_equal(authorization_server_metadata.get("issuer"), base_url, "authorization server issuer")

    initialize = mcp_json_rpc(
        mcp_url=mcp_url,
        access_token=access_token,
        protocol_version=protocol_version,
        body={
            "jsonrpc": "2.0",
            "id": "initialize",
            "method": "initialize",
            "params": {
                "protocolVersion": protocol_version,
                "capabilities": {},
                "clientInfo": {
                    "name": "MacRemote Anthropic Smoke Test",
                    "version": "0.1.0",
                },
            },
        },
    )
    initialize_result = json_rpc_result(initialize, "initialize")
    negotiated = initialize_result.get("protocolVersion")
    if not isinstance(negotiated, str) or not negotiated:
        fail("MacRemote initialize response did not include protocolVersion.")

    initialized = http_request(
        "POST",
        mcp_url,
        data=json.dumps(
            {
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
            }
        ).encode("utf-8"),
        headers=mcp_headers(access_token, negotiated),
    )
    if initialized.status not in {200, 202}:
        fail(f"MacRemote initialized notification returned HTTP {initialized.status}.")

    tools_list = mcp_json_rpc(
        mcp_url=mcp_url,
        access_token=access_token,
        protocol_version=negotiated,
        body={
            "jsonrpc": "2.0",
            "id": "tools/list",
            "method": "tools/list",
        },
    )
    tools_result = json_rpc_result(tools_list, "tools/list")
    tools = tools_result.get("tools")
    if not isinstance(tools, list):
        fail("MacRemote tools/list response did not include a tools array.")

    tool_names = [tool.get("name") for tool in tools if isinstance(tool, dict)]
    if expected_tool not in tool_names:
        fail(f"MacRemote tools/list did not include expected tool {expected_tool!r}.")

    print("mcp_preflight=passed")
    print(f"mcp_protocol_version={negotiated}")
    print(f"mcp_tool_count={len(tools)}")


def call_anthropic(
    *,
    api_key: str,
    model: str,
    beta: str,
    mcp_url: str,
    server_name: str,
    authorization_token: str,
    tool_name: str,
    prompt: str,
) -> dict[str, Any]:
    body = {
        "model": model,
        "max_tokens": 1000,
        "messages": [{"role": "user", "content": prompt}],
        "mcp_servers": [
            {
                "type": "url",
                "url": mcp_url,
                "name": server_name,
                "authorization_token": authorization_token,
            }
        ],
        "tools": [
            {
                "type": "mcp_toolset",
                "mcp_server_name": server_name,
                "default_config": {"enabled": False},
                "configs": {
                    tool_name: {
                        "enabled": True,
                        "defer_loading": False,
                    }
                },
            }
        ],
    }

    return http_json(
        "POST",
        ANTHROPIC_ENDPOINT,
        body,
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "anthropic-beta": beta,
            "content-type": "application/json",
        },
    )


def default_prompt(tool_name: str) -> str:
    return (
        f"Use the MacRemote MCP tool `{tool_name}` now. Do not answer from memory. "
        "After the tool result, summarize only whether the call succeeded and the "
        "stdout byte length from the structured tool result."
    )


def macremote_base_url(mcp_url: str) -> str:
    parsed = urllib.parse.urlparse(mcp_url)
    if parsed.scheme != "https" or not parsed.netloc:
        fail("MCP URL must be an absolute HTTPS URL.")
    return urllib.parse.urlunparse((parsed.scheme, parsed.netloc, "", "", "", ""))


def canonical_mcp_resource_url(mcp_url: str) -> str:
    parsed = urllib.parse.urlparse(mcp_url)
    if parsed.scheme != "https" or not parsed.netloc or not parsed.path:
        fail("MCP URL must be an absolute HTTPS URL with a path.")
    return urllib.parse.urlunparse(
        (
            parsed.scheme.lower(),
            parsed.netloc.lower(),
            parsed.path.rstrip("/") or "/",
            "",
            "",
            "",
        )
    )


def path_protected_resource_metadata_url(mcp_url: str) -> str:
    parsed = urllib.parse.urlparse(mcp_url)
    if parsed.scheme != "https" or not parsed.netloc or not parsed.path:
        fail("MCP URL must be an absolute HTTPS URL with a path.")
    metadata_path = "/.well-known/oauth-protected-resource" + parsed.path.rstrip("/")
    return urllib.parse.urlunparse((parsed.scheme.lower(), parsed.netloc.lower(), metadata_path, "", "", ""))


def mcp_json_rpc(
    *,
    mcp_url: str,
    access_token: str,
    protocol_version: str,
    body: dict[str, Any],
) -> dict[str, Any]:
    return http_json(
        "POST",
        mcp_url,
        body,
        headers=mcp_headers(access_token, protocol_version),
    )


def mcp_headers(access_token: str, protocol_version: str) -> dict[str, str]:
    return {
        "authorization": f"Bearer {access_token}",
        "accept": "application/json, text/event-stream",
        "mcp-protocol-version": protocol_version,
    }


def json_rpc_result(response: dict[str, Any], label: str) -> dict[str, Any]:
    error = response.get("error")
    if error:
        fail(f"MacRemote {label} returned JSON-RPC error: {json.dumps(error, sort_keys=True)}")
    result = response.get("result")
    if not isinstance(result, dict):
        fail(f"MacRemote {label} did not return a JSON-RPC result object.")
    return result


def assert_equal(actual: Any, expected: Any, label: str) -> None:
    if actual != expected:
        fail(f"Unexpected {label}: expected {expected!r}, got {actual!r}.")


def assert_contains(actual: Any, expected: Any, label: str) -> None:
    if not isinstance(actual, list) or expected not in actual:
        fail(f"Unexpected {label}: expected list containing {expected!r}, got {actual!r}.")


def pkce_challenge(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


def extract_request_id(html: str) -> str | None:
    match = re.search(
        r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
        html,
    )
    return match.group(0) if match else None


def code_from_redirect(redirect_uri: str, expected_state: str) -> str:
    parsed = urllib.parse.urlparse(redirect_uri)
    query = urllib.parse.parse_qs(parsed.query)
    state = first(query, "state")
    if state != expected_state:
        fail("OAuth state mismatch.")
    error = first(query, "error")
    if error:
        fail(f"OAuth redirect returned error={error}.")
    code = first(query, "code")
    if not code:
        fail("OAuth redirect did not include a code.")
    return code


def first(query: dict[str, list[str]], key: str) -> str | None:
    values = query.get(key)
    return values[0] if values else None


def http_json(method: str, url: str, body: dict[str, Any] | None = None, headers: dict[str, str] | None = None) -> dict[str, Any]:
    request_headers = {"content-type": "application/json"}
    if headers:
        request_headers.update(headers)
    data = None if body is None else json.dumps(body).encode("utf-8")
    result = http_request(method, url, data=data, headers=request_headers)
    try:
        return result.json()
    except json.JSONDecodeError as error:
        fail(f"Expected JSON from {url}, got invalid response: {error}")


def http_form(method: str, url: str, body: dict[str, str]) -> dict[str, Any]:
    data = urllib.parse.urlencode(body).encode("utf-8")
    result = http_request(
        method,
        url,
        data=data,
        headers={"content-type": "application/x-www-form-urlencoded"},
    )
    try:
        return result.json()
    except json.JSONDecodeError as error:
        fail(f"Expected JSON from {url}, got invalid response: {error}")


def http_request(method: str, url: str, data: bytes | None = None, headers: dict[str, str] | None = None) -> HTTPResult:
    request = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            return HTTPResult(
                status=response.status,
                body=response.read(),
                headers={key.lower(): value for key, value in response.headers.items()},
            )
    except urllib.error.HTTPError as error:
        body = error.read()
        fail(f"HTTP {error.code} from {url}: {body.decode('utf-8', errors='replace')}")
    except urllib.error.URLError as error:
        fail(f"Could not reach {url}: {error.reason}")


def redacted_url(url: str) -> str:
    parsed = urllib.parse.urlparse(url)
    return urllib.parse.urlunparse((parsed.scheme, parsed.netloc, parsed.path, "", "", ""))


def fail(message: str) -> None:
    print(f"error={message}", file=sys.stderr)
    raise SystemExit(1)


if __name__ == "__main__":
    raise SystemExit(main())
