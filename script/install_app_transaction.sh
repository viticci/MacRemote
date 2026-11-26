#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: install_app_transaction.sh <source.app> <target.app>" >&2; exit 2; }

SOURCE_BUNDLE="$1"
TARGET_BUNDLE="$2"
[[ "$SOURCE_BUNDLE" == *.app && -d "$SOURCE_BUNDLE" ]] \
  || { echo "installation failed: source app is missing" >&2; exit 1; }
[[ "$TARGET_BUNDLE" == /*.app ]] \
  || { echo "installation failed: target must be an absolute app path" >&2; exit 1; }

TARGET_PARENT="$(/usr/bin/dirname "$TARGET_BUNDLE")"
TARGET_NAME="$(/usr/bin/basename "$TARGET_BUNDLE")"
STAGING_BUNDLE="$TARGET_BUNDLE.new"
PREVIOUS_BUNDLE="$TARGET_BUNDLE.previous"
JOURNAL="$TARGET_PARENT/.$TARGET_NAME.install-transaction"
TRANSACTION_ACTIVE=0

[[ ! -L "$SOURCE_BUNDLE" ]] \
  || { echo "installation failed: source app must not be a symbolic link" >&2; exit 1; }
[[ ! -L "$TARGET_BUNDLE" && ! -L "$PREVIOUS_BUNDLE" ]] \
  || { echo "installation failed: managed app paths must not be symbolic links" >&2; exit 1; }
[[ ! -e "$TARGET_BUNDLE" || -d "$TARGET_BUNDLE" ]] \
  || { echo "installation failed: target is not an app directory" >&2; exit 1; }

verify_copy() {
  local bundle="$1"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$bundle" >/dev/null 2>&1
  /usr/bin/cmp -s \
    "$SOURCE_BUNDLE/Contents/MacOS/MacRemote" \
    "$bundle/Contents/MacOS/MacRemote"
  /usr/bin/diff -q -r "$SOURCE_BUNDLE" "$bundle" >/dev/null
}

verify_signature() {
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$1" >/dev/null 2>&1
}

write_journal() {
  local state="$1"
  local temporary="$JOURNAL.tmp.$$"
  printf '%s\n' "$state" >"$temporary"
  /bin/chmod 600 "$temporary"
  /bin/mv -f "$temporary" "$JOURNAL"
  /bin/sync
}

rollback_transaction() {
  [[ -f "$JOURNAL" ]] || { TRANSACTION_ACTIVE=0; return 0; }

  if [[ "$(<"$JOURNAL")" == "committed" ]]; then
    verify_signature "$TARGET_BUNDLE" \
      || { echo "installation recovery failed: committed app signature is invalid" >&2; return 1; }
    /bin/rm -rf "$PREVIOUS_BUNDLE" "$STAGING_BUNDLE"
    /bin/rm -f "$JOURNAL"
    /bin/sync
    TRANSACTION_ACTIVE=0
    return 0
  fi

  if [[ -d "$PREVIOUS_BUNDLE" ]]; then
    /bin/rm -rf "$TARGET_BUNDLE"
    /bin/mv "$PREVIOUS_BUNDLE" "$TARGET_BUNDLE"
  elif [[ "$(<"$JOURNAL")" == "absent" ]]; then
    /bin/rm -rf "$TARGET_BUNDLE"
  elif [[ ! -d "$TARGET_BUNDLE" ]]; then
    echo "installation recovery failed: previous app is missing" >&2
    return 1
  fi
  /bin/rm -rf "$STAGING_BUNDLE"
  /bin/sync
  /bin/rm -f "$JOURNAL"
  TRANSACTION_ACTIVE=0
}

recover_interrupted_transaction() {
  if [[ -f "$JOURNAL" ]]; then
    rollback_transaction
  elif [[ -d "$PREVIOUS_BUNDLE" ]]; then
    if [[ -d "$TARGET_BUNDLE" ]] && verify_copy "$TARGET_BUNDLE"; then
      /bin/rm -rf "$PREVIOUS_BUNDLE"
    elif [[ ! -e "$TARGET_BUNDLE" ]]; then
      /bin/mv "$PREVIOUS_BUNDLE" "$TARGET_BUNDLE"
    else
      /bin/rm -rf "$TARGET_BUNDLE"
      /bin/mv "$PREVIOUS_BUNDLE" "$TARGET_BUNDLE"
    fi
  fi
  /bin/rm -rf "$STAGING_BUNDLE"
}

exit_handler() {
  local exit_code=$?
  if [[ $TRANSACTION_ACTIVE -eq 1 ]]; then
    rollback_transaction || exit_code=1
  fi
  return "$exit_code"
}

inject_failure() {
  if [[ "${MACREMOTE_TEST_SIGNAL_INSTALL_STEP:-}" == "$1" ]]; then
    /bin/kill -TERM $$
  fi
  if [[ "${MACREMOTE_TEST_FAIL_INSTALL_STEP:-}" == "$1" ]]; then
    echo "injected installation failure at $1" >&2
    return 97
  fi
}

trap exit_handler EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

recover_interrupted_transaction
/usr/bin/ditto --rsrc "$SOURCE_BUNDLE" "$STAGING_BUNDLE"
verify_copy "$STAGING_BUNDLE"

if [[ -d "$TARGET_BUNDLE" ]]; then
  write_journal previous
else
  write_journal absent
fi
TRANSACTION_ACTIVE=1

if [[ -d "$TARGET_BUNDLE" ]]; then
  /bin/mv "$TARGET_BUNDLE" "$PREVIOUS_BUNDLE"
fi
inject_failure after_backup
/bin/mv "$STAGING_BUNDLE" "$TARGET_BUNDLE"
inject_failure after_swap
verify_copy "$TARGET_BUNDLE"
inject_failure after_verify
write_journal committed
inject_failure after_commit

/bin/rm -rf "$PREVIOUS_BUNDLE"
/bin/rm -f "$JOURNAL"
/bin/sync
TRANSACTION_ACTIVE=0
