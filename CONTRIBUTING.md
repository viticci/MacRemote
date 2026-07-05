# Contributing

This is a private project. Keep changes small, testable, and aligned with the
generic tool model.

## Before Editing

```bash
git status --short --branch
script/macremotectl doctor --json
```

The working tree may contain local user changes. Do not revert changes you did
not make.

## Development Checks

Run these before submitting or pushing non-trivial changes:

```bash
swift build
swift test
script/build_and_run.sh --verify
```

For Python CLI changes:

```bash
python3 -m py_compile script/macremotectl
script/macremotectl list-presets --json
script/macremotectl list-preset-sets --json
```

## Design Constraints

- MacRemote is not a remote shell.
- Tools run as exact executable paths plus argv arrays.
- Built-in native tools (`ToolBackend.native`, the `builtin.fs.*` File Transfer
  group) are the only tools that run in-process instead of as an
  executable-plus-argv subprocess. Do not add new native backends without a
  documented decision; user-defined and preset tools stay process/bridge only.
- Shell wrappers such as `sh`, `bash`, `zsh`, `fish`, and `env` stay blocked.
- RemCTL, PocketCTL, Codex, and other CLIs receive the same visual and runtime
  treatment.
- Optional CLIs must remain optional in docs, code, and `doctor`.
- Connected clients can refresh `tools/list`; adding tools should not require
  stopping the tunnel unless a specific client caches the tool list.
- macOS privacy requirements belong on tools through `permissionRequirements`.

## Commit Style

Use short imperative commit messages. Include docs and tests with the code change
when behavior changes.
