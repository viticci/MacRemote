---
name: macremote
description: How to use MacRemote, which runs tools on the owner's Mac. Use it before calling MacRemote tools, when a call asks for approval, or when a result has a reason code or a download link.
---

# Using MacRemote

MacRemote runs tools on the owner's Mac. It offers only the tools the owner
chose to share. Each tool's description and input schema are the contract:
follow them exactly. Prefer a dedicated tool over a Flexible Command.

## No shell

MacRemote starts each program directly. There is no shell, so `~`, `$HOME`,
wildcards (`*`), pipes (`|`), redirection (`>`), `&&`, and quotes mean nothing.

- A Flexible Command takes `args`, an array of exact argument strings, one item
  per argument: `["search", "--json", "milk"]`, not `["search --json milk"]`.
- Use absolute paths, such as `/Users/name/Documents/report.pdf`. The File
  Transfer tools also accept a path that starts with `~/`.
- To run several steps, make several calls. Use a tool's batch input when it has
  one.

## Tools that ask first

Read-only tools run right away. Write and Destructive tools, and every Flexible
Command, ask the owner first: the request appears in a window on the Mac, with
every argument in full, and the owner approves or declines it there.

- The call waits up to 90 seconds for an answer. Tell the user to check their
  Mac when you make a call that asks first.
- Some tools ask on every call, even after earlier approvals. Treat a prompt as
  likely.
- The owner can choose Always Allow for your app, and then the tool runs without
  asking.
- A declined or expired call did not run. Do not send it again unless the user
  asks.

## Long calls

In an app that supports MCP Tasks, a call that is still running after 20
seconds carries on in the background, and the app collects the result when it
is ready. A Flexible Command also takes `run_in_background: true`: set it for a
command you expect to run longer than a few seconds, and the call goes to the
background at once. It has no effect in an app without background tasks, where
a call must finish inside its request.

## Results and reason codes

A completed tool result has a `reason` in `structuredContent`. Text output is
in `stdout` and errors in `stderr`. A failed call is a normal result with
`isError: true`.

A call can first get an interim reply instead, marked by `resultType`: `task`
(the call runs in the background), `input_required` (a question for the user),
or `upload_required` (MacRemote is waiting for a file). Collect the task's
result, answer the question, or send the file first. Only the completed result
has a `reason` to read.

| `reason` | What happened | What to do |
|---|---|---|
| `ok` | The tool ran and succeeded. | Use the result. A successful write is its own receipt; do not read it back unless the user asks. |
| `nonzero_exit` | The program ran and reported a failure. | Read `stderr`, fix the input, and try once more if it makes sense. Check before repeating a write. |
| `invalid_argument` | MacRemote refused the input before anything ran. | Fix the input to match the schema. The message says what is wrong. |
| `not_approved` | The owner declined, or 90 seconds passed. Nothing ran. | Tell the user. Do not retry unless they ask. |
| `timeout` | The tool reached its time limit and was stopped. | Narrow the request. A write may have partly happened, so check before retrying. |
| `output_limit` | The output was larger than the limit and was cut. | Narrow the request with filters or limits, or use the download link if there is one. |
| `killed` | The program was stopped before it finished. | Report it. Do not retry in a loop. |
| `unavailable` | The tool cannot run right now, or MacRemote is busy. | If the message says busy, wait and retry once. Otherwise tell the user. |
| `internal_error` | MacRemote failed. | Tell the user. The exit code, when present, is still correct. |

## Large results

A result too large to return directly is saved on the Mac, and the result
links to it. Download links need no sign-in, cannot be guessed, expire after 10
minutes, allow 3 downloads, and stop working when the server stops. Fetch a
link soon after you get it.

## File Transfer tools

Ten built-in tools move and edit files. Each is available only if the owner shared it.

- `filesystem_stat`, `filesystem_list_tree`, and `filesystem_find` look at
  files and folders. `filesystem_find` with a folder searches that folder and
  everything in it, within 20 seconds; with no folder it asks Spotlight, which
  is fast but skips hidden files.
- `filesystem_read_file` returns at most 16 KiB per call. Pass `offset` and
  `length`, then call again at `offset` plus `length_returned` until `eof` is
  true. Use `encoding: "utf8"` for text. For a whole file, use
  `filesystem_download_file` instead.
- `filesystem_write_file` asks first. Its `data` holds at most 98,304
  characters per call. `encoding` defaults to `base64`, so one call carries
  about 72 KiB of file bytes; with `encoding: "utf8"`, `data` is the text
  itself. Send a larger file in parts: the first with `mode: "create"`, the
  rest with `mode: "append"`.
- `filesystem_append_file` and `filesystem_replace_in_file` ask first. They
  change an existing UTF-8 text file without sending the rest of it; prefer
  them to writing the whole file again. Append adds text at the end, exactly
  as given, so include your own newline. Replace changes one passage: `find`
  must appear exactly once. If it appears zero times or more than once, nothing
  changes and the error says how many times it appeared; add surrounding text
  to `find` and try again.
- `filesystem_upload_file` asks first. It saves a whole file, up to 512 MiB,
  without putting its bytes in the conversation. It works only in an app that
  supports MCP file uploads; in any other app, use `filesystem_write_file`.
- `filesystem_download_file` and `filesystem_download_zip` return a download
  link (`download_url`) instead of the contents, for files up to 512 MiB.

They reach only the folders the owner allowed: Desktop, Documents, and Downloads
by default, up to the whole Mac if the owner chose that. A few locations are
never reachable, whatever the owner allowed: SSH and GnuPG keys; the AWS,
Azure, Kubernetes, Docker, Cloudflare, GitHub CLI, and Google Cloud credential
folders; `.netrc`, `.npmrc`, and `.pypirc`; Codex's `auth.json`; keychains,
launch agents, and app preferences; and MacRemote's own data. Any other file in
an allowed folder is reachable, even one that holds a secret.

MacRemote checks `path` and `base` before anything runs. A path it refuses
(outside the allowed folders, protected, relative, or with `..`) ends the call
with `isError: true`, `reason: "invalid_argument"`, and a message that says
why; for a path outside the allowed folders, the message names the ones you can
reach. `filesystem_download_zip` checks the entries of `paths`, and whether a
folder contains a protected location, as it makes the zip: a refusal there
fails the call with `reason: "nonzero_exit"`, and `stdout` says why.

## Finding tools

The resource `macremote://catalog/v1` lists every shared tool with its name,
title, whether it reads or writes, where it comes from, and its schema
revision. Read it when you need an overview, then call the tool by its `name`.

Tools from another MCP server on the Mac carry that server's name as a prefix,
such as `remctl_lists`. A skill that comes from such a server says how its tool
names map here.

## Good habits

- Ask the user before a Destructive call unless they already asked for it.
- Reuse identifiers a tool returned, such as list or note ids, within the
  conversation instead of looking them up again.
- If a call is refused or fails twice, stop and tell the user what happened.
