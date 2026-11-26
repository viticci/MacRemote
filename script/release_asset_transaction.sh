#!/usr/bin/env bash

# Transaction helpers for publishing a release ZIP and its two sidecars.
# Callers must set RELEASE_TRANSACTION_ACTIVE=0 before installing an EXIT trap.

release_transaction_paths() {
  local output_dir="$1"
  local set_name="$2"
  RELEASE_TRANSACTION_JOURNAL="$output_dir/.$set_name.publish-journal"
  RELEASE_TRANSACTION_BACKUP_DIR="$output_dir/.$set_name.publish-previous"
}

release_transaction_restore() {
  local output_dir="$1"
  local set_name="$2"
  shift 2
  local targets=("$@")
  local index
  local target
  local backup
  local restore_temp

  release_transaction_paths "$output_dir" "$set_name"
  [[ -f "$RELEASE_TRANSACTION_JOURNAL" ]] || return 0
  [[ -d "$RELEASE_TRANSACTION_BACKUP_DIR" ]] \
    || { echo "release transaction recovery failed: backup directory is missing" >&2; return 1; }

  for index in 0 1 2; do
    target="${targets[$index]}"
    backup="$RELEASE_TRANSACTION_BACKUP_DIR/$index"
    if [[ -f "$backup" ]]; then
      restore_temp="$output_dir/.$set_name.restore-$index.$$"
      /bin/rm -f "$restore_temp"
      /bin/ln "$backup" "$restore_temp" || return 1
      /bin/mv -f "$restore_temp" "$target" || return 1
    elif [[ -f "$RELEASE_TRANSACTION_BACKUP_DIR/absent-$index" ]]; then
      /bin/rm -f "$target" || return 1
    else
      echo "release transaction recovery failed: backup marker $index is missing" >&2
      return 1
    fi
  done

  /bin/sync
  /bin/rm -f "$RELEASE_TRANSACTION_JOURNAL"
  /bin/rm -rf "$RELEASE_TRANSACTION_BACKUP_DIR"
  /bin/sync
  RELEASE_TRANSACTION_ACTIVE=0
}

release_transaction_recover_if_needed() {
  local output_dir="$1"
  local set_name="$2"
  shift 2
  local targets=("$@")

  release_transaction_paths "$output_dir" "$set_name"
  if [[ -f "$RELEASE_TRANSACTION_JOURNAL" ]]; then
    release_transaction_restore "$output_dir" "$set_name" "${targets[@]}"
    return
  fi

  # A crash after commit can leave only the no-longer-needed backups.
  if [[ -d "$RELEASE_TRANSACTION_BACKUP_DIR" ]]; then
    /bin/rm -rf "$RELEASE_TRANSACTION_BACKUP_DIR"
  fi
}

release_transaction_publish() {
  local output_dir="$1"
  local set_name="$2"
  shift 2
  local source_0="$1"
  local target_0="$2"
  local source_1="$3"
  local target_1="$4"
  local source_2="$5"
  local target_2="$6"
  local sources=("$source_0" "$source_1" "$source_2")
  local targets=("$target_0" "$target_1" "$target_2")
  local existing_count=0
  local index
  local journal_temp

  release_transaction_recover_if_needed "$output_dir" "$set_name" "${targets[@]}"
  release_transaction_paths "$output_dir" "$set_name"

  for index in 0 1 2; do
    [[ -f "${sources[$index]}" && ! -L "${sources[$index]}" ]] \
      || { echo "release transaction failed: staged asset $index is not a regular file" >&2; return 1; }
    if [[ -e "${targets[$index]}" || -L "${targets[$index]}" ]]; then
      [[ -f "${targets[$index]}" && ! -L "${targets[$index]}" ]] \
        || { echo "release transaction failed: target $index is not a regular file" >&2; return 1; }
      existing_count=$((existing_count + 1))
    fi
  done
  [[ $existing_count -eq 0 || $existing_count -eq 3 ]] \
    || { echo "release transaction failed: existing release set is incomplete" >&2; return 1; }

  /bin/mkdir "$RELEASE_TRANSACTION_BACKUP_DIR" || return 1
  /bin/chmod 700 "$RELEASE_TRANSACTION_BACKUP_DIR"
  for index in 0 1 2; do
    if [[ -f "${targets[$index]}" ]]; then
      /bin/ln "${targets[$index]}" "$RELEASE_TRANSACTION_BACKUP_DIR/$index" || return 1
    else
      /usr/bin/touch "$RELEASE_TRANSACTION_BACKUP_DIR/absent-$index" || return 1
    fi
  done

  journal_temp="$RELEASE_TRANSACTION_JOURNAL.tmp.$$"
  printf 'active\n' >"$journal_temp"
  /bin/chmod 600 "$journal_temp"
  /bin/mv -f "$journal_temp" "$RELEASE_TRANSACTION_JOURNAL"
  /bin/sync
  RELEASE_TRANSACTION_ACTIVE=1

  for index in 0 1 2; do
    /bin/mv -f "${sources[$index]}" "${targets[$index]}" || return 1
    /bin/sync
    if [[ "${MACREMOTE_TEST_SIGNAL_AFTER_PUBLISH_RENAME:-}" == "$((index + 1))" ]]; then
      /bin/kill -TERM $$
    fi
    if [[ "${MACREMOTE_TEST_FAIL_AFTER_PUBLISH_RENAME:-}" == "$((index + 1))" ]]; then
      echo "injected release publication failure after rename $((index + 1))" >&2
      return 97
    fi
  done

  /bin/rm -f "$RELEASE_TRANSACTION_JOURNAL"
  /bin/rm -rf "$RELEASE_TRANSACTION_BACKUP_DIR"
  /bin/sync
  RELEASE_TRANSACTION_ACTIVE=0
}
