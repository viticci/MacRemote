#!/usr/bin/env python3

from __future__ import annotations

import base64
import copy
import sys
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools" / "stress"))

from mcp_client import (  # noqa: E402
    CLIENT_CAPABILITIES_META_KEY,
    TASKS_CAPABILITIES,
    CLIENT_INFO_META_KEY,
    LEGACY_PROTOCOL_VERSION,
    MODERN_PROTOCOL_VERSION,
    PROTOCOL_VERSION_META_KEY,
    Endpoint,
    MCPClient,
    MCPRequestBuilder,
    ProtocolMode,
    encoded_mcp_header_value,
)


def endpoint() -> Endpoint:
    return Endpoint(
        port=8765,
        token="test-token",
        instance_id="test",
        mcp_path="/mcp/test",
        health_path="/health",
        base_url="http://127.0.0.1:8765",
        tools=[],
    )


class StressMCPRequestBuilderTests(unittest.TestCase):
    def test_legacy_request_keeps_the_original_envelope(self) -> None:
        request = MCPRequestBuilder().prepare(
            "tools/call",
            {"name": "echo", "arguments": {}},
            request_id="legacy-1",
        )

        self.assertEqual(request.body["id"], "legacy-1")
        self.assertNotIn("_meta", request.body["params"])
        self.assertEqual(
            request.headers,
            {"MCP-Protocol-Version": LEGACY_PROTOCOL_VERSION},
        )

    def test_modern_request_mirrors_metadata_and_tool_name(self) -> None:
        params = {
            "name": "echo",
            "arguments": {"value": "hello"},
            "_meta": {"caller": "preserved"},
        }
        original = copy.deepcopy(params)
        request = MCPRequestBuilder(mode=ProtocolMode.MODERN).prepare(
            "tools/call",
            params,
            request_id="modern-1",
        )

        self.assertEqual(params, original)
        self.assertEqual(request.headers["MCP-Protocol-Version"], MODERN_PROTOCOL_VERSION)
        self.assertEqual(request.headers["Mcp-Method"], "tools/call")
        self.assertEqual(request.headers["Mcp-Name"], "echo")
        metadata = request.body["params"]["_meta"]
        self.assertEqual(metadata["caller"], "preserved")
        self.assertEqual(metadata[PROTOCOL_VERSION_META_KEY], MODERN_PROTOCOL_VERSION)
        self.assertEqual(
            metadata[CLIENT_INFO_META_KEY],
            {"name": "MacRemote Stress Driver", "version": "1.0"},
        )
        self.assertEqual(metadata[CLIENT_CAPABILITIES_META_KEY], {})

    def test_modern_name_header_is_conditional_and_resource_aware(self) -> None:
        builder = MCPRequestBuilder(mode=ProtocolMode.MODERN)
        listed = builder.prepare("tools/list", {}, request_id="list")
        resource = builder.prepare(
            "resources/read",
            {"uri": "ui://macremote/über"},
            request_id="read",
        )

        self.assertNotIn("Mcp-Name", listed.headers)
        expected = base64.b64encode("ui://macremote/über".encode()).decode()
        self.assertEqual(resource.headers["Mcp-Name"], f"=?base64?{expected}?=")

    def test_modern_notification_omits_id_but_keeps_method_mirror(self) -> None:
        notification = MCPRequestBuilder(mode=ProtocolMode.MODERN).prepare(
            "notifications/cancelled",
            {"requestId": "call-1"},
            request_id=None,
            notification=True,
        )

        self.assertNotIn("id", notification.body)
        self.assertEqual(
            notification.headers["Mcp-Method"],
            "notifications/cancelled",
        )

    def test_task_methods_mirror_the_task_id_and_carry_the_extension(self) -> None:
        builder = MCPRequestBuilder(
            mode=ProtocolMode.MODERN,
            client_capabilities=TASKS_CAPABILITIES,
        )
        for method in ("tasks/get", "tasks/update", "tasks/cancel"):
            with self.subTest(method=method):
                request = builder.prepare(method, {"taskId": "abc123"}, request_id="t")
                self.assertEqual(request.headers["Mcp-Name"], "abc123")
                self.assertEqual(
                    request.body["params"]["_meta"][CLIENT_CAPABILITIES_META_KEY],
                    TASKS_CAPABILITIES,
                )

    def test_header_encoding_handles_edges_and_sentinel_literals(self) -> None:
        self.assertEqual(encoded_mcp_header_value("plain-ascii"), "plain-ascii")
        for value in (" leading", "trailing\t", "=?base64?literal?="):
            with self.subTest(value=value):
                expected = base64.b64encode(value.encode()).decode()
                self.assertEqual(
                    encoded_mcp_header_value(value),
                    f"=?base64?{expected}?=",
                )


class LegacySessionClient(MCPClient):
    def __init__(self) -> None:
        super().__init__(endpoint=endpoint())
        self.requests: list[tuple[dict[str, Any], dict[str, str]]] = []

    def _request_with_headers(
        self,
        method: str,
        url: str,
        *,
        body: dict[str, Any] | None = None,
        timeout: float = 60.0,
        headers: dict[str, str] | None = None,
        expect_json: bool = True,
    ) -> tuple[int, dict[str, Any], dict[str, str]]:
        self.requests.append((body or {}, headers or {}))
        return (
            200,
            {
                "jsonrpc": "2.0",
                "id": "init",
                "result": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                },
            },
            {"mcp-session-id": "session-123"},
        )


class ScriptedTaskClient(MCPClient):
    """Answers `tasks/get` from a script of task states."""

    def __init__(self, states: list[dict[str, Any]]) -> None:
        super().__init__(endpoint=endpoint(), mode=ProtocolMode.MODERN)
        self.states = list(states)

    def raw(self, method, params=None, *, request_id=None, timeout=60.0):
        return 200, {"result": self.states.pop(0)}


class StressMCPClientHelperTests(unittest.TestCase):
    def test_wait_for_task_polls_at_the_server_interval_until_final(self) -> None:
        client = ScriptedTaskClient([
            {"status": "working", "pollIntervalMs": 2000},
            {"status": "working", "pollIntervalMs": 50},
            {"status": "completed", "result": {"isError": False}},
        ])
        sleeps: list[float] = []

        task = client.wait_for_task("t", sleep=sleeps.append, clock=lambda: 0.0)

        self.assertEqual(task["status"], "completed")
        self.assertEqual(sleeps, [2.0, 0.25])

    def test_initialize_captures_session_and_negotiated_version(self) -> None:
        client = LegacySessionClient()
        result = client.initialize()
        follow_up = client.build_request("tools/list", {}, request_id="list")

        self.assertEqual(result["protocolVersion"], "2025-06-18")
        self.assertEqual(follow_up.headers["Mcp-Session-Id"], "session-123")
        self.assertEqual(follow_up.headers["MCP-Protocol-Version"], "2025-06-18")


if __name__ == "__main__":
    unittest.main()
