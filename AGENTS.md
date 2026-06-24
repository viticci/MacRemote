# Agent Instructions

This repo builds a macOS app that exposes user-approved local CLI tools over
remote MCP. Keep the implementation generic: RemCTL, PocketCTL, Codex, and every
other command are optional tools, not special product modes.

## Rules

- Do not edit installed user CLIs. Fix MacRemote, docs, or presets instead.
- Do not introduce shell execution for tools. Use exact executable paths and argv
  arrays.
- Do not hardcode user-specific absolute home paths in code or docs except in
  test fixtures that explicitly require a fake path.
- Do not make RemCTL required. It is optional and should appear only when
  detected or explicitly configured.
- Preserve user-defined tool data. Avoid deleting
  `~/Library/Application Support/MacRemote/tools.json` unless the user asks to
  start fresh.
- Treat macOS privacy as per-tool metadata. Use `permissionRequirements` instead
  of CLI-specific checks where possible.

## Common Commands

```bash
script/macremotectl doctor --json
script/macremotectl list-presets --json
script/macremotectl list-preset-sets --json
script/macremotectl add-preset-set set.detected_clis --replace
script/macremotectl clear-tools --yes
```

Build and test:

```bash
swift build
swift test
script/build_and_run.sh --verify
```

## Tool Definitions

User tools are persisted as JSON dictionaries with:

- `name`, `summary`
- `executablePath`
- `argumentPattern`
- `parameters`
- `capability`: `readOnly`, `write`, or `destructive`
- `category`
- `permissionRequirements`

Use **CLI Adapter** mode for broad command delegation:

```text
argumentPattern: ["{args}"]
```

Use **Command Template** mode for narrow tools:

```text
argumentPattern: ["--json", "search", "{query}"]
```

Remote clients do not get shell expansion. Tell clients to pass exact argv items
and absolute paths.

## MCP Description Expectations

The server should expose tool metadata aligned with the current MCP schema:

- `name`: stable programmatic id.
- `title`: human-readable display name.
- `description`: concise behavior, argument, permission, and approval guidance.
- `inputSchema`: JSON Schema object for accepted arguments.
- `outputSchema`: JSON Schema object for structured results.
- `annotations`: include `readOnlyHint`, `destructiveHint`, `idempotentHint`,
  `openWorldHint`, and `title`.

For broad CLI adapters, descriptions must explicitly say there is no shell and
that `args` is an argv array.

## Verification

For any non-trivial change, run:

```bash
swift build
swift test
script/build_and_run.sh --verify
```

For docs-only changes, at least run:

```bash
script/macremotectl doctor --json
python3 -m py_compile script/macremotectl
```
