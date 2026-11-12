#!/usr/bin/env python3
"""Dependency-free MCP HTTP client for the MacRemote stress harness."""

from __future__ import annotations

import base64
import json
import os
import threading
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from enum import Enum
from typing import Any, Callable, Mapping


DEFAULT_ENDPOINT_FILE = "/tmp/mr_stress_harness/endpoint.json"
LEGACY_PROTOCOL_VERSION = "2025-11-25"
MODERN_PROTOCOL_VERSION = "2026-07-28"
# Compatibility name retained for external scripts importing the old constant.
MCP_PROTOCOL_VERSION = LEGACY_PROTOCOL_VERSION

PROTOCOL_VERSION_META_KEY = "io.modelcontextprotocol/protocolVersion"
CLIENT_INFO_META_KEY = "io.modelcontextprotocol/clientInfo"
CLIENT_CAPABILITIES_META_KEY = "io.modelcontextprotocol/clientCapabilities"


class ProtocolMode(str, Enum):
    LEGACY = "legacy"
    MODERN = "modern"


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


@dataclass(frozen=True)
class PreparedMCPRequest:
    body: dict[str, Any]
    headers: dict[str, str]


def encoded_mcp_header_value(value: str) -> str:
    """Encode an Mcp-Name value using the 2026 Base64 sentinel rules."""
    try:
        encoded = value.encode("ascii")
    except UnicodeEncodeError:
        encoded = b""

    is_visible_ascii = bool(encoded) or value == ""
    is_visible_ascii = is_visible_ascii and all(
        byte == 0x09 or 0x20 <= byte <= 0x7E for byte in encoded
    )
    has_edge_whitespace = value != value.strip(" \t")
    matches_sentinel = value.startswith("=?base64?") and value.endswith("?=")
    if is_visible_ascii and not has_edge_whitespace and not matches_sentinel:
        return value

    payload = base64.b64encode(value.encode("utf-8")).decode("ascii")
    return f"=?base64?{payload}?="


def mirrored_name(method: str, params: Mapping[str, Any] | None) -> str | None:
    if params is None:
        return None
    if method == "tools/call" or method == "prompts/get":
        value = params.get("name")
    elif method == "resources/read":
        value = params.get("uri")
    else:
        return None
    return value if isinstance(value, str) else None


class MCPRequestBuilder:
    """Pure JSON-RPC/body/header construction for modern and legacy MCP."""

    def __init__(
        self,
        *,
        mode: ProtocolMode = ProtocolMode.LEGACY,
        protocol_version: str | None = None,
        client_info: Mapping[str, Any] | None = None,
        client_capabilities: Mapping[str, Any] | None = None,
    ) -> None:
        self.mode = ProtocolMode(mode)
        self.protocol_version = protocol_version or (
            MODERN_PROTOCOL_VERSION
            if self.mode is ProtocolMode.MODERN
            else LEGACY_PROTOCOL_VERSION
        )
        self.client_info = dict(
            client_info
            or {"name": "MacRemote Stress Driver", "version": "1.0"}
        )
        self.client_capabilities = dict(client_capabilities or {})

    def prepare(
        self,
        method: str,
        params: Mapping[str, Any] | None,
        *,
        request_id: str | int | None,
        notification: bool = False,
        session_headers: Mapping[str, str] | None = None,
    ) -> PreparedMCPRequest:
        body: dict[str, Any] = {
            "jsonrpc": "2.0",
            "method": method,
        }
        if not notification:
            body["id"] = request_id

        copied_params = dict(params or {})
        if self.mode is ProtocolMode.MODERN:
            existing_meta = copied_params.get("_meta")
            meta = dict(existing_meta) if isinstance(existing_meta, Mapping) else {}
            meta.update({
                PROTOCOL_VERSION_META_KEY: self.protocol_version,
                CLIENT_INFO_META_KEY: dict(self.client_info),
                CLIENT_CAPABILITIES_META_KEY: dict(self.client_capabilities),
            })
            copied_params["_meta"] = meta

        if copied_params or params is not None or self.mode is ProtocolMode.MODERN:
            body["params"] = copied_params

        headers = {"MCP-Protocol-Version": self.protocol_version}
        if self.mode is ProtocolMode.MODERN:
            headers["Mcp-Method"] = method
            name = mirrored_name(method, copied_params)
            if name is not None:
                headers["Mcp-Name"] = encoded_mcp_header_value(name)
        if session_headers:
            headers.update(session_headers)
        return PreparedMCPRequest(body=body, headers=headers)


class MCPClient:
    def __init__(
        self,
        endpoint: Endpoint | None = None,
        *,
        endpoint_file: str | None = None,
        mode: ProtocolMode = ProtocolMode.LEGACY,
        protocol_version: str | None = None,
        client_capabilities: Mapping[str, Any] | None = None,
    ) -> None:
        self.endpoint = endpoint or Endpoint.load(endpoint_file)
        self.builder = MCPRequestBuilder(
            mode=mode,
            protocol_version=protocol_version,
            client_capabilities=client_capabilities,
        )
        self._request_id = 0
        self._lock = threading.Lock()
        self._legacy_session_headers: dict[str, str] = {}

    @classmethod
    def modern(
        cls,
        endpoint: Endpoint | None = None,
        *,
        endpoint_file: str | None = None,
    ) -> "MCPClient":
        return cls(
            endpoint,
            endpoint_file=endpoint_file,
            mode=ProtocolMode.MODERN,
        )

    def _next_id(self) -> str:
        with self._lock:
            self._request_id += 1
            return f"stress-{self._request_id}"

    def build_request(
        self,
        method: str,
        params: Mapping[str, Any] | None = None,
        *,
        request_id: str | int | None = None,
        notification: bool = False,
    ) -> PreparedMCPRequest:
        resolved_id = None if notification else (
            request_id if request_id is not None else self._next_id()
        )
        return self.builder.prepare(
            method,
            params,
            request_id=resolved_id,
            notification=notification,
            session_headers=self._legacy_session_headers,
        )

    def _request_with_headers(
        self,
        method: str,
        url: str,
        *,
        body: dict[str, Any] | None = None,
        timeout: float = 60.0,
        headers: Mapping[str, str] | None = None,
        expect_json: bool = True,
    ) -> tuple[int, dict[str, Any] | str, dict[str, str]]:
        request_headers = {
            "Authorization": f"Bearer {self.endpoint.token}",
            "Accept": "application/json",
        }
        data = None
        if body is not None:
            request_headers["Content-Type"] = "application/json"
            data = json.dumps(body).encode("utf-8")
        if headers:
            request_headers.update(headers)

        request = urllib.request.Request(
            url,
            data=data,
            headers=request_headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                status = response.getcode()
                raw = response.read()
                response_headers = dict(response.headers.items())
        except urllib.error.HTTPError as exc:
            status = exc.code
            raw = exc.read()
            response_headers = dict(exc.headers.items())

        if not raw:
            return status, {} if expect_json else "", response_headers

        if not expect_json:
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                text = raw.decode("utf-8", errors="replace")
            return status, text, response_headers

        try:
            return status, json.loads(raw.decode("utf-8")), response_headers
        except json.JSONDecodeError:
            return (
                status,
                {"_raw": raw.decode("utf-8", errors="replace")},
                response_headers,
            )

    def _request(
        self,
        method: str,
        url: str,
        *,
        body: dict[str, Any] | None = None,
        timeout: float = 60.0,
        headers: Mapping[str, str] | None = None,
        expect_json: bool = True,
    ) -> tuple[int, dict[str, Any] | str]:
        status, payload, _ = self._request_with_headers(
            method,
            url,
            body=body,
            timeout=timeout,
            headers=headers,
            expect_json=expect_json,
        )
        return status, payload

    def health(self, timeout: float = 5.0) -> tuple[int, dict[str, Any]]:
        url = f"{self.endpoint.base_url.rstrip('/')}{self.endpoint.health_path}"
        request = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
            return response.getcode(), payload

    def raw(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        *,
        request_id: str | None = None,
        timeout: float = 60.0,
    ) -> tuple[int, dict[str, Any]]:
        prepared = self.build_request(method, params, request_id=request_id)
        status, payload = self._request(
            "POST",
            self.endpoint.mcp_url,
            body=prepared.body,
            timeout=timeout,
            headers=prepared.headers,
        )
        assert isinstance(payload, dict)
        return status, payload

    def _notification(
        self,
        method: str,
        params: dict[str, Any],
        *,
        timeout: float,
    ) -> tuple[int, dict[str, Any] | str]:
        prepared = self.build_request(method, params, notification=True)
        return self._request(
            "POST",
            self.endpoint.mcp_url,
            body=prepared.body,
            timeout=timeout,
            headers=prepared.headers,
        )

    def initialize(self, timeout: float = 30.0) -> dict[str, Any]:
        if self.builder.mode is ProtocolMode.MODERN:
            raise RuntimeError("Modern MCP uses server/discover, not initialize.")

        prepared = self.build_request(
            "initialize",
            {
                "protocolVersion": self.builder.protocol_version,
                "capabilities": {},
                "clientInfo": {"name": "MacRemote Stress Driver", "version": "1.0"},
            },
            request_id="init",
        )
        status, payload, response_headers = self._request_with_headers(
            "POST",
            self.endpoint.mcp_url,
            body=prepared.body,
            timeout=timeout,
            headers=prepared.headers,
        )
        assert isinstance(payload, dict)
        if status != 200:
            raise RuntimeError(f"initialize HTTP {status}: {payload}")
        if "error" in payload:
            raise RuntimeError(f"initialize failed: {payload['error']}")

        session_id = _case_insensitive_header(
            response_headers,
            "Mcp-Session-Id",
        )
        if session_id:
            self._legacy_session_headers["Mcp-Session-Id"] = session_id
        result = payload["result"]
        if isinstance(result, dict):
            negotiated = result.get("protocolVersion")
            if isinstance(negotiated, str):
                self.builder.protocol_version = negotiated
        return result

    def discover(self, timeout: float = 30.0) -> dict[str, Any]:
        if self.builder.mode is not ProtocolMode.MODERN:
            raise RuntimeError("server/discover is the modern MCP handshake.")
        status, payload = self.raw("server/discover", {}, timeout=timeout)
        if status != 200:
            raise RuntimeError(f"server/discover HTTP {status}: {payload}")
        if "error" in payload:
            raise RuntimeError(f"server/discover failed: {payload['error']}")
        return payload["result"]

    def list_tools(
        self,
        cursor: str | None = None,
        timeout: float = 30.0,
    ) -> dict[str, Any]:
        params = {"cursor": cursor} if cursor else {}
        status, payload = self.raw("tools/list", params, timeout=timeout)
        if status != 200:
            raise RuntimeError(f"tools/list HTTP {status}: {payload}")
        if "error" in payload:
            raise RuntimeError(f"tools/list failed: {payload['error']}")
        return payload["result"]

    def call_tool(
        self,
        name: str,
        arguments: dict[str, Any] | None = None,
        timeout: float = 60.0,
    ) -> dict[str, Any]:
        params: dict[str, Any] = {
            "name": name,
            "arguments": arguments or {},
        }
        status, payload = self.raw(
            "tools/call",
            params,
            timeout=timeout,
        )
        if status != 200:
            raise RuntimeError(f"tools/call HTTP {status}: {payload}")
        return payload

    def notify_cancelled(
        self,
        request_id: str,
        reason: str = "user",
        timeout: float = 10.0,
    ) -> tuple[int, dict[str, Any] | str]:
        return self._notification(
            "notifications/cancelled",
            {"requestId": request_id, "reason": reason},
            timeout=timeout,
        )

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
                except BaseException as exc:  # noqa: BLE001 — collect all failures
                    outcomes.append(exc)
        return outcomes


def _case_insensitive_header(
    headers: Mapping[str, str],
    name: str,
) -> str | None:
    target = name.lower()
    return next(
        (value for key, value in headers.items() if key.lower() == target),
        None,
    )


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
    return isinstance(
        exc,
        (urllib.error.URLError, TimeoutError, ConnectionError, OSError),
    )
