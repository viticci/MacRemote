#!/usr/bin/env python3
"""Dependency-free MCP HTTP client for the MacRemote stress harness."""

from __future__ import annotations

import json
import os
import threading
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from typing import Any, Callable


DEFAULT_ENDPOINT_FILE = "/tmp/mr_stress_harness/endpoint.json"
MCP_PROTOCOL_VERSION = "2025-11-25"


@dataclass(frozen=True)
class Endpoint:
    port: int
    token: str
    instance_id: str
    mcp_path: str
    health_path: str
    base_url: str
    tools: list[dict[str, Any]]

    @classmethod
    def load(cls, path: str | None = None) -> "Endpoint":
        endpoint_path = path or os.environ.get("MR_STRESS_ENDPOINT_FILE", DEFAULT_ENDPOINT_FILE)
        with open(endpoint_path, encoding="utf-8") as handle:
            payload = json.load(handle)
        base_url = payload.get("baseURL") or f"http://127.0.0.1:{payload['port']}"
        return cls(
            port=int(payload["port"]),
            token=str(payload["token"]),
            instance_id=str(payload["instanceID"]),
            mcp_path=str(payload["mcpPath"]),
            health_path=str(payload.get("healthPath", "/health")),
            base_url=str(base_url),
            tools=list(payload.get("tools", [])),
        )

    @property
    def mcp_url(self) -> str:
        return f"{self.base_url.rstrip('/')}{self.mcp_path}"


class MCPClient:
    def __init__(self, endpoint: Endpoint | None = None, *, endpoint_file: str | None = None) -> None:
        self.endpoint = endpoint or Endpoint.load(endpoint_file)
        self._request_id = 0
        self._lock = threading.Lock()

    def _next_id(self) -> str:
        with self._lock:
            self._request_id += 1
            return f"stress-{self._request_id}"

    def _request(
        self,
        method: str,
        url: str,
        *,
        body: dict[str, Any] | None = None,
        timeout: float = 60.0,
        include_mcp_version: bool = True,
        expect_json: bool = True,
    ) -> tuple[int, dict[str, Any] | str]:
        headers = {
            "Authorization": f"Bearer {self.endpoint.token}",
            "Accept": "application/json",
        }
        data = None
        if body is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(body).encode("utf-8")
        if include_mcp_version:
            headers["MCP-Protocol-Version"] = MCP_PROTOCOL_VERSION

        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                status = response.getcode()
                raw = response.read()
        except urllib.error.HTTPError as exc:
            status = exc.code
            raw = exc.read()

        if not raw:
            return status, {} if expect_json else ""

        if not expect_json:
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                text = raw.decode("utf-8", errors="replace")
            return status, text

        try:
            return status, json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            return status, {"_raw": raw.decode("utf-8", errors="replace")}

    def health(self, timeout: float = 5.0) -> tuple[int, dict[str, Any]]:
        url = f"{self.endpoint.base_url.rstrip('/')}{self.endpoint.health_path}"
        request = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
            return response.getcode(), payload

    def raw(self, method: str, params: dict[str, Any] | None = None, *, request_id: str | None = None, timeout: float = 60.0) -> tuple[int, dict[str, Any]]:
        body: dict[str, Any] = {
            "jsonrpc": "2.0",
            "id": request_id if request_id is not None else self._next_id(),
            "method": method,
        }
        if params is not None:
            body["params"] = params
        return self._request("POST", self.endpoint.mcp_url, body=body, timeout=timeout)

    def initialize(self, timeout: float = 30.0) -> dict[str, Any]:
        status, payload = self.raw(
            "initialize",
            {
                "protocolVersion": MCP_PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "MacRemote Stress Driver", "version": "1.0"},
            },
            request_id="init",
            timeout=timeout,
        )
        if status != 200:
            raise RuntimeError(f"initialize HTTP {status}: {payload}")
        if "error" in payload:
            raise RuntimeError(f"initialize failed: {payload['error']}")
        return payload["result"]

    def list_tools(self, cursor: str | None = None, timeout: float = 30.0) -> dict[str, Any]:
        params = {"cursor": cursor} if cursor else None
        status, payload = self.raw("tools/list", params, timeout=timeout)
        if status != 200:
            raise RuntimeError(f"tools/list HTTP {status}: {payload}")
        if "error" in payload:
            raise RuntimeError(f"tools/list failed: {payload['error']}")
        return payload["result"]

    def call_tool(self, name: str, arguments: dict[str, Any] | None = None, timeout: float = 60.0) -> dict[str, Any]:
        status, payload = self.raw(
            "tools/call",
            {"name": name, "arguments": arguments or {}},
            timeout=timeout,
        )
        if status != 200:
            raise RuntimeError(f"tools/call HTTP {status}: {payload}")
        return payload

    def notify_cancelled(self, request_id: str, reason: str = "user", timeout: float = 10.0) -> tuple[int, dict[str, Any] | str]:
        body = {
            "jsonrpc": "2.0",
            "method": "notifications/cancelled",
            "params": {"requestId": request_id, "reason": reason},
        }
        return self._request("POST", self.endpoint.mcp_url, body=body, timeout=timeout, expect_json=True)

    def call_many(
        self,
        calls: list[tuple[str, dict[str, Any]]],
        *,
        max_workers: int = 16,
        timeout: float = 60.0,
    ) -> list[dict[str, Any]]:
        def run_one(item: tuple[str, dict[str, Any]]) -> dict[str, Any]:
            name, arguments = item
            return self.call_tool(name, arguments, timeout=timeout)

        results: list[dict[str, Any]] = []
        with ThreadPoolExecutor(max_workers=max_workers) as pool:
            futures = [pool.submit(run_one, call) for call in calls]
            for future in as_completed(futures):
                results.append(future.result())
        return results

    def run_concurrent(
        self,
        fn: Callable[[int], dict[str, Any]],
        count: int,
        *,
        max_workers: int = 16,
    ) -> list[dict[str, Any] | BaseException]:
        outcomes: list[dict[str, Any] | BaseException] = []
        with ThreadPoolExecutor(max_workers=max_workers) as pool:
            futures = [pool.submit(fn, index) for index in range(count)]
            for future in as_completed(futures):
                try:
                    outcomes.append(future.result())
                except BaseException as exc:  # noqa: BLE001 — stress harness collects all failures
                    outcomes.append(exc)
        return outcomes


def structured_reason(response: dict[str, Any]) -> str | None:
    if "error" in response:
        return None
    result = response.get("result")
    if not isinstance(result, dict):
        return None
    structured = result.get("structuredContent")
    if isinstance(structured, dict):
        reason = structured.get("reason")
        if isinstance(reason, str):
            return reason
    return None


def is_connection_failure(exc: BaseException) -> bool:
    return isinstance(exc, (urllib.error.URLError, TimeoutError, ConnectionError, OSError))
