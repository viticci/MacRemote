#!/usr/bin/env python3
"""Run one MacRemote MCP stress category and print a JSON summary to stdout."""

from __future__ import annotations

import json
import os
import sys
import urllib.error

from mcp_client import (
    ELICITATION_CAPABILITIES,
    FILES_CAPABILITIES,
    FILES_EXTENSION,
    MODERN_PROTOCOL_VERSION,
    TASKS_CAPABILITIES,
    TASKS_EXTENSION,
    MCPClient,
    is_connection_failure,
    structured_reason,
)


CATEGORIES = (
    "concurrency",
    "largeoutput",
    "hang",
    "badargs",
    "protocol",
    "modern",
    "tasks",
    "elicitation",
    "files",
)


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
        "name": "no_call_exceptions",
        "passed": connection_failures == 0 and other_failures == 0,
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
        if reason == "ok" and not is_error:
            continue
        if reason == "unavailable" and is_error:
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
        "name": "reason_ok_when_artifact_preserves_full_output",
        "passed": reason == "ok",
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


def run_modern(client: MCPClient) -> dict:
    checks: list[dict] = []
    modern = MCPClient.modern(endpoint=client.endpoint)

    discovery = modern.discover()
    supported_versions = discovery.get("supportedVersions", [])
    capabilities = discovery.get("capabilities")
    checks.append({
        "name": "modern_discovery",
        "passed": (
            isinstance(supported_versions, list)
            and MODERN_PROTOCOL_VERSION in supported_versions
            and isinstance(capabilities, dict)
        ),
        "supportedVersions": supported_versions,
    })

    listed = modern.list_tools()
    tools = listed.get("tools")
    checks.append({
        "name": "modern_tools_list",
        "passed": (
            listed.get("resultType") == "complete"
            and isinstance(listed.get("ttlMs"), int)
            and listed.get("cacheScope") in {"public", "private"}
            and isinstance(tools, list)
        ),
        "resultType": listed.get("resultType"),
        "ttlMs": listed.get("ttlMs"),
        "cacheScope": listed.get("cacheScope"),
        "tools": len(tools) if isinstance(tools, list) else None,
    })

    response = modern.call_tool(
        "stress_echo",
        {"args": ["modern-round-trip"]},
        timeout=30.0,
    )
    result = response.get("result", {})
    checks.append({
        "name": "modern_direct_tool_result",
        "passed": (
            isinstance(result, dict)
            and result.get("resultType") == "complete"
            and structured_reason(response) == "ok"
        ),
        "resultType": result.get("resultType") if isinstance(result, dict) else None,
        "reason": structured_reason(response),
    })

    passed = all(check["passed"] for check in checks)
    return summarize("modern", passed, checks)


def run_tasks(client: MCPClient) -> dict:
    """MCP Tasks (SPEC D81). The harness server turns a call into a task
    after 2 seconds; `stress_task_sleep` runs for 5."""
    checks: list[dict] = []
    tasks = MCPClient.modern(endpoint=client.endpoint, client_capabilities=TASKS_CAPABILITIES)

    extensions = tasks.discover().get("capabilities", {}).get("extensions", {})
    checks.append({
        "name": "discovery_advertises_tasks",
        "passed": isinstance(extensions.get(TASKS_EXTENSION), dict),
    })

    created = tasks.call_tool("stress_task_sleep", {}, timeout=30.0).get("result", {})
    task_id = created.get("taskId")
    checks.append({
        "name": "slow_call_becomes_task",
        "passed": created.get("resultType") == "task"
        and created.get("status") == "working"
        and isinstance(task_id, str),
        "resultType": created.get("resultType"),
        "status": created.get("status"),
    })
    if isinstance(task_id, str):
        finished = tasks.wait_for_task(task_id)
        result = finished.get("result", {})
        reason = result.get("structuredContent", {}).get("reason") if isinstance(result, dict) else None
        checks.append({
            "name": "task_completes_with_tool_result",
            "passed": finished.get("status") == "completed" and reason == "ok",
            "status": finished.get("status"),
            "reason": reason,
        })

    background = tasks.call_tool(
        "stress_echo",
        {"args": ["from-background"], "run_in_background": True},
        timeout=30.0,
    ).get("result", {})
    background_id = background.get("taskId")
    stdout = None
    if background.get("resultType") == "task" and isinstance(background_id, str):
        done = tasks.wait_for_task(background_id)
        stdout = done.get("result", {}).get("structuredContent", {}).get("stdout")
    checks.append({
        "name": "run_in_background_starts_at_once",
        "passed": background.get("resultType") == "task"
        and isinstance(stdout, str)
        and stdout.strip() == "from-background",
        "resultType": background.get("resultType"),
        "stdout": stdout,
    })

    doomed = tasks.call_tool("stress_task_sleep", {}, timeout=30.0).get("result", {})
    doomed_id = doomed.get("taskId")
    cancel_ack = tasks.cancel_task(doomed_id) if isinstance(doomed_id, str) else {}
    after_cancel = tasks.get_task(doomed_id).get("result", {}) if isinstance(doomed_id, str) else {}
    checks.append({
        "name": "cancel_ends_task",
        "passed": cancel_ack.get("result", {}).get("resultType") == "complete"
        and after_cancel.get("status") == "cancelled",
        "status": after_cancel.get("status"),
    })

    unknown = tasks.get_task("no-such-task").get("error", {})
    checks.append({
        "name": "unknown_task_is_invalid_params",
        "passed": unknown.get("code") == -32602,
        "code": unknown.get("code"),
    })

    without = MCPClient.modern(endpoint=client.endpoint).get_task(task_id or "x").get("error", {})
    checks.append({
        "name": "task_methods_need_the_extension",
        "passed": without.get("code") == -32021,
        "code": without.get("code"),
    })

    status, health = client.health()
    checks.append({
        "name": "health_after_tasks",
        "passed": status == 200 and health.get("ok") is True,
    })

    passed = all(check["passed"] for check in checks)
    return summarize("tasks", passed, checks)


def upstream_answers(result: object) -> list | None:
    """The answers `stress_ask`'s upstream server reports it received."""
    if not isinstance(result, dict):
        return None
    stdout = result.get("structuredContent", {}).get("stdout")
    try:
        return json.loads(stdout).get("answers") if isinstance(stdout, str) else None
    except (ValueError, AttributeError):
        return None


def only_question(result: dict) -> tuple[str | None, dict]:
    requests = result.get("inputRequests") if isinstance(result, dict) else None
    if not isinstance(requests, dict) or len(requests) != 1:
        return None, {}
    key, request = next(iter(requests.items()))
    return key, request if isinstance(request, dict) else {}


def run_elicitation(client: MCPClient) -> dict:
    """Questions from a bridged server (SPEC D82). `stress_ask` bridges a
    legacy stdio server that asks one form question, "Pick a color.", and
    reports the answer it got back. The same call reaches each kind of app a
    different way."""
    checks: list[dict] = []
    blue = {"action": "accept", "content": {"color": "blue"}}

    # An app with Tasks and elicitation: the call is a task at once, waiting.
    tasks_app = MCPClient.modern(
        endpoint=client.endpoint,
        client_capabilities={**TASKS_CAPABILITIES, **ELICITATION_CAPABILITIES},
    )
    created = tasks_app.call_tool("stress_ask", {}, timeout=30.0).get("result", {})
    key, question = only_question(created)
    message = (question.get("params") or {}).get("message")
    task_id = created.get("taskId")
    checks.append({
        "name": "tasks_app_gets_input_required_task",
        "passed": created.get("resultType") == "task"
        and created.get("status") == "input_required"
        and question.get("method") == "elicitation/create"
        and message == "[fixture] Pick a color.",
        "resultType": created.get("resultType"),
        "status": created.get("status"),
        "message": message,
    })
    if isinstance(task_id, str) and key:
        ack = tasks_app.update_task(task_id, {key: blue}).get("result", {})
        done = tasks_app.wait_for_task(task_id)
        received = upstream_answers(done.get("result"))
        checks.append({
            "name": "tasks_update_delivers_the_answer",
            "passed": ack.get("resultType") == "complete"
            and done.get("status") == "completed"
            and received == [blue],
            "status": done.get("status"),
            "upstreamReceived": received,
        })

    # An app with elicitation only: input_required, then the call again.
    forms_app = MCPClient.modern(endpoint=client.endpoint, client_capabilities=ELICITATION_CAPABILITIES)
    first = forms_app.call_tool("stress_ask", {}, timeout=30.0).get("result", {})
    key, _ = only_question(first)
    state = first.get("requestState")
    checks.append({
        "name": "elicitation_app_gets_input_required",
        "passed": first.get("resultType") == "input_required" and isinstance(state, str) and key is not None,
        "resultType": first.get("resultType"),
    })
    if isinstance(state, str) and key:
        final = forms_app.call_tool(
            "stress_ask", {}, timeout=30.0, request_state=state, input_responses={key: blue}
        ).get("result", {})
        received = upstream_answers(final)
        checks.append({
            "name": "request_state_delivers_the_answer",
            "passed": final.get("resultType") == "complete" and received == [blue],
            "upstreamReceived": received,
        })
        reused = forms_app.raw("tools/call", {
            "name": "stress_ask",
            "arguments": {},
            "requestState": state,
            "inputResponses": {key: blue},
        })[1].get("error", {})
        checks.append({
            "name": "request_state_works_once",
            "passed": reused.get("code") == -32602,
            "code": reused.get("code"),
        })

    # An app that declared neither: the upstream is declined at once.
    declined = MCPClient.modern(endpoint=client.endpoint).call_tool("stress_ask", {}, timeout=30.0).get("result", {})
    received = upstream_answers(declined)
    checks.append({
        "name": "nobody_to_ask_declines_and_finishes",
        "passed": declined.get("resultType") == "complete" and received == [{"action": "decline"}],
        "upstreamReceived": received,
    })

    status, health = client.health()
    checks.append({
        "name": "health_after_elicitation",
        "passed": status == 200 and health.get("ok") is True,
    })

    passed = all(check["passed"] for check in checks)
    return summarize("elicitation", passed, checks)


def run_files(client: MCPClient) -> dict:
    """File uploads through the MCP files extension (SPEC D83). The harness
    shares Upload File, Always Allowed, saving only into its scratch upload
    folder, which is also the policy's home: `~/name` is a file there."""
    checks: list[dict] = []
    tool = "filesystem_upload_file"
    app = MCPClient.modern(endpoint=client.endpoint, client_capabilities=FILES_CAPABILITIES)
    folder = client.endpoint.upload_folder

    discovery = app.discover()
    settings = ((discovery.get("capabilities") or {}).get("extensions") or {}).get(FILES_EXTENSION)
    checks.append({
        "name": "discovery_advertises_uploads",
        "passed": settings == {"upload": {}},
        "settings": settings,
    })

    listed = next((t for t in app.list_tools().get("tools", []) if t.get("name") == tool), {})
    file_schema = ((listed.get("inputSchema") or {}).get("properties") or {}).get("file") or {}
    checks.append({
        "name": "tool_marks_its_file_argument",
        "passed": isinstance(file_schema.get("x-mcp-file"), dict)
        and file_schema.get("required") == ["id", "mimeType", "size"],
    })

    def first_call(name: str, data: bytes) -> tuple[dict, dict]:
        arguments = {"path": f"~/{name}", "file": {"id": "file-1", "name": name, "mimeType": "application/octet-stream", "size": len(data)}}
        return arguments, app.call_tool(tool, arguments, timeout=30.0).get("result", {})

    # The whole flow, with a body larger than any request read whole.
    data = os.urandom(300 * 1024)
    arguments, first = first_call("stress-upload.bin", data)
    targets = first.get("uploads") or [{}]
    state = first.get("requestState")
    checks.append({
        "name": "first_call_asks_for_the_bytes",
        "passed": first.get("resultType") == "upload_required"
        and len(targets) == 1
        and targets[0].get("credentials") == "include"
        and str(targets[0].get("path", "")).startswith("/uploads/")
        and isinstance(state, str),
        "resultType": first.get("resultType"),
    })
    if isinstance(state, str) and "path" in targets[0]:
        checks.append({"name": "transfer_without_token_is_401", "passed": app.put_upload(targets[0], data, token=None) == 401})
        checks.append({"name": "longer_body_is_413", "passed": app.put_upload(targets[0], data + b"x") == 413})
        status = app.put_upload(targets[0], data)
        checks.append({"name": "transfer_is_2xx", "passed": 200 <= status < 300, "status": status})
        second = app.call_tool(tool, arguments, timeout=60.0, request_state=state).get("result", {})
        landed = None
        if folder:
            try:
                with open(os.path.join(folder, "stress-upload.bin"), "rb") as handle:
                    landed = handle.read() == data
            except OSError:
                landed = False
        checks.append({
            "name": "second_call_saves_the_bytes",
            "passed": second.get("resultType") == "complete" and second.get("isError") is False and landed is not False,
            "isError": second.get("isError"),
            "bytesMatch": landed,
        })
        repeated = app.raw("tools/call", {"name": tool, "arguments": arguments, "requestState": state})[1].get("error", {})
        checks.append({"name": "repeated_second_call_is_32602", "passed": repeated.get("code") == -32602, "code": repeated.get("code")})

    _, missing = first_call("never-sent.bin", b"abc")
    missing_state = missing.get("requestState")
    if isinstance(missing_state, str):
        no_bytes = app.call_tool(tool, {"path": "~/never-sent.bin", "file": {"id": "file-1", "name": "never-sent.bin", "mimeType": "application/octet-stream", "size": 3}},
                                 timeout=30.0, request_state=missing_state).get("result", {})
        checks.append({"name": "no_bytes_is_a_tool_error", "passed": no_bytes.get("isError") is True})

    status, undeclared = MCPClient.modern(endpoint=client.endpoint).raw("tools/call", {"name": tool, "arguments": arguments})
    checks.append({
        "name": "undeclared_upload_is_32021",
        "passed": status == 400 and (undeclared.get("error") or {}).get("code") == -32021,
        "status": status,
    })

    status, health = client.health()
    checks.append({"name": "health_after_files", "passed": status == 200 and health.get("ok") is True})

    passed = all(check["passed"] for check in checks)
    return summarize("files", passed, checks)


def parse_category(argv: list[str]) -> str:
    if len(argv) != 2 or argv[1] not in CATEGORIES:
        raise ValueError(f"usage: {argv[0]} <{'|'.join(CATEGORIES)}>")
    return argv[1]


def category_runner(category: str):
    runners = {
        "concurrency": run_concurrency,
        "largeoutput": run_largeoutput,
        "hang": run_hang,
        "badargs": run_badargs,
        "protocol": run_protocol,
        "modern": run_modern,
        "tasks": run_tasks,
        "elicitation": run_elicitation,
        "files": run_files,
    }
    try:
        return runners[category]
    except KeyError as exc:
        raise ValueError(f"unknown stress category: {category}") from exc


def main(argv: list[str]) -> int:
    try:
        category = parse_category(argv)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    client = MCPClient()
    summary = category_runner(category)(client)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
