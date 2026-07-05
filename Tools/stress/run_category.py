#!/usr/bin/env python3
"""Run one MacRemote MCP stress category and print a JSON summary to stdout."""

from __future__ import annotations

import json
import sys
import urllib.error

from mcp_client import MCPClient, is_connection_failure, structured_reason


CATEGORIES = ("concurrency", "largeoutput", "hang", "badargs", "protocol")


def summarize(category: str, passed: bool, checks: list[dict], extra: dict | None = None) -> dict:
    payload = {
        "category": category,
        "passed": passed,
        "checks": checks,
    }
    if extra:
        payload.update(extra)
    return payload


def run_concurrency(client: MCPClient) -> dict:
    checks: list[dict] = []
    client.initialize()

    def one_call(index: int) -> dict:
        return client.call_tool("stress_echo", {"args": [f"burst-{index}"]}, timeout=30.0)

    outcomes = client.run_concurrent(one_call, 50, max_workers=16)
    connection_failures = sum(1 for item in outcomes if isinstance(item, BaseException) and is_connection_failure(item))
    other_failures = sum(1 for item in outcomes if isinstance(item, BaseException) and not is_connection_failure(item))
    responses = [item for item in outcomes if isinstance(item, dict)]

    checks.append({
        "name": "no_connection_failures",
        "passed": connection_failures == 0,
        "connection_failures": connection_failures,
        "other_failures": other_failures,
        "responses": len(responses),
    })

    invalid = 0
    for response in responses:
        if "error" in response:
            invalid += 1
            continue
        result = response.get("result")
        if not isinstance(result, dict):
            invalid += 1
            continue
        reason = structured_reason(response)
        is_error = result.get("isError") is True
        if reason == "unavailable" and is_error:
            continue
        if reason in {"ok", "output_limit", "timeout", "nonzero_exit"} or (reason == "invalid_argument" and is_error):
            continue
        if reason is None and not is_error:
            continue
        if reason == "unavailable":
            continue
        invalid += 1

    checks.append({
        "name": "responses_structured",
        "passed": invalid == 0 and len(responses) == 50,
        "invalid_responses": invalid,
    })

    try:
        status, health = client.health()
        checks.append({
            "name": "health_after_burst",
            "passed": status == 200 and health.get("ok") is True,
            "status": status,
            "ok": health.get("ok"),
        })
    except urllib.error.URLError as exc:
        checks.append({
            "name": "health_after_burst",
            "passed": False,
            "error": str(exc),
        })

    passed = all(check["passed"] for check in checks)
    return summarize("concurrency", passed, checks, {"workers": 16, "calls": 50})


def run_largeoutput(client: MCPClient) -> dict:
    checks: list[dict] = []
    client.initialize()

    response = client.call_tool("stress_bigout", {}, timeout=120.0)
    checks.append({
        "name": "http_200",
        "passed": "error" not in response,
        "has_error": "error" in response,
    })

    result = response.get("result", {})
    structured = result.get("structuredContent", {}) if isinstance(result, dict) else {}
    reason = structured.get("reason") if isinstance(structured, dict) else None
    checks.append({
        "name": "reason_output_limit",
        "passed": reason == "output_limit",
        "reason": reason,
    })

    content = result.get("content", []) if isinstance(result, dict) else []
    resource_links = [
        item for item in content
        if isinstance(item, dict) and item.get("type") == "resource_link"
    ]
    checks.append({
        "name": "resource_link_present",
        "passed": len(resource_links) >= 1,
        "resource_link_count": len(resource_links),
    })

    # HTTP receive buffer is capped at 128 KB — keep stdin well under that.
    stdin_payload = "y" * 32_000
    stdin_response = client.call_tool("stress_cat_stdin", {"stdin": stdin_payload}, timeout=120.0)
    stdin_result = stdin_response.get("result", {})
    stdin_structured = stdin_result.get("structuredContent", {}) if isinstance(stdin_result, dict) else {}
    stdout = stdin_structured.get("stdout", "") if isinstance(stdin_structured, dict) else ""
    checks.append({
        "name": "large_stdin_round_trip",
        "passed": isinstance(stdout, str) and len(stdout) == len(stdin_payload),
        "stdout_bytes": len(stdout) if isinstance(stdout, str) else None,
    })

    passed = all(check["passed"] for check in checks)
    return summarize("largeoutput", passed, checks)


def run_hang(client: MCPClient) -> dict:
    checks: list[dict] = []
    client.initialize()

    response = client.call_tool("stress_sleep", {}, timeout=30.0)
    reason = structured_reason(response)
    structured = {}
    result = response.get("result")
    if isinstance(result, dict):
        structured = result.get("structuredContent", {})

    checks.append({
        "name": "reason_timeout",
        "passed": reason == "timeout",
        "reason": reason,
    })
    checks.append({
        "name": "timed_out_flag",
        "passed": isinstance(structured, dict) and structured.get("timedOut") is True,
        "timedOut": structured.get("timedOut") if isinstance(structured, dict) else None,
    })

    follow_up = client.call_tool("stress_echo", {"args": ["after-timeout"]}, timeout=15.0)
    checks.append({
        "name": "server_responsive_after_timeout",
        "passed": structured_reason(follow_up) == "ok",
        "reason": structured_reason(follow_up),
    })

    passed = all(check["passed"] for check in checks)
    return summarize("hang", passed, checks)


def run_badargs(client: MCPClient) -> dict:
    checks: list[dict] = []
    client.initialize()

    banana = client.call_tool("stress_typed", {"count": "banana"}, timeout=15.0)
    banana_reason = structured_reason(banana)
    banana_error = banana.get("result", {}).get("isError") if isinstance(banana.get("result"), dict) else None
    checks.append({
        "name": "non_integer_count",
        "passed": banana_reason == "invalid_argument" and banana_error is True,
        "reason": banana_reason,
        "isError": banana_error,
    })

    negative = client.call_tool("stress_typed", {"count": -1}, timeout=15.0)
    negative_reason = structured_reason(negative)
    negative_error = negative.get("result", {}).get("isError") if isinstance(negative.get("result"), dict) else None
    checks.append({
        "name": "out_of_range_count",
        "passed": negative_reason == "invalid_argument" and negative_error is True,
        "reason": negative_reason,
        "isError": negative_error,
    })

    passed = all(check["passed"] for check in checks)
    return summarize("badargs", passed, checks)


def run_protocol(client: MCPClient) -> dict:
    checks: list[dict] = []
    client.initialize()

    cancelled_status, cancelled_body = client.notify_cancelled("call-1")
    checks.append({
        "name": "notifications_cancelled",
        "passed": cancelled_status == 202,
        "status": cancelled_status,
        "body": cancelled_body,
    })

    unknown_method = client.raw("tools/unknown", {})
    error = unknown_method[1].get("error", {}) if isinstance(unknown_method[1], dict) else {}
    checks.append({
        "name": "unknown_method",
        "passed": error.get("code") == -32601,
        "code": error.get("code"),
    })

    unknown_tool = client.call_tool("does_not_exist", {}, timeout=15.0)
    tool_error = unknown_tool.get("error", {})
    checks.append({
        "name": "unknown_tool",
        "passed": tool_error.get("code") == -32602,
        "code": tool_error.get("code"),
    })

    passed = all(check["passed"] for check in checks)
    return summarize("protocol", passed, checks)


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] not in CATEGORIES:
        print(f"usage: {argv[0]} <{'|'.join(CATEGORIES)}>", file=sys.stderr)
        return 2

    category = argv[1]
    client = MCPClient()
    runners = {
        "concurrency": run_concurrency,
        "largeoutput": run_largeoutput,
        "hang": run_hang,
        "badargs": run_badargs,
        "protocol": run_protocol,
    }
    summary = runners[category](client)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
