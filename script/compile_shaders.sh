#!/usr/bin/env bash
# Compile Shaders/*.metal into Shaders/default.metallib (committed to the repo:
# the CLT-only toolchain has no `metal`, so builds consume the precompiled lib).
# The Metal toolchain ships with Xcode (possibly as the MetalToolchain download
# component); this script finds one across common install locations.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find_developer_dir() {
  for dir in \
    "${DEVELOPER_DIR:-}" \
    "$(xcode-select -p 2>/dev/null || true)" \
    "/Applications/Xcode.app/Contents/Developer" \
    "/Applications/Xcode-beta.app/Contents/Developer"; do
    [[ -n "$dir" ]] || continue
    if DEVELOPER_DIR="$dir" xcrun -find metal >/dev/null 2>&1; then
      echo "$dir"
      return 0
    fi
  done
  return 1
}

if ! DEV_DIR="$(find_developer_dir)"; then
  echo "error: no Metal compiler found. Install Xcode and, if needed, run:" >&2
  echo "  xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

echo "Using Metal toolchain from: $DEV_DIR" >&2
TMP_DIR="$(mktemp -d -t macremote-shaders)"
trap 'rm -rf "$TMP_DIR"' EXIT

AIR_FILES=()
for src in "$ROOT_DIR"/Shaders/*.metal; do
  air="$TMP_DIR/$(basename "${src%.metal}").air"
  DEVELOPER_DIR="$DEV_DIR" xcrun -sdk macosx metal -std=metal3.0 -c "$src" -o "$air"
  AIR_FILES+=("$air")
done

DEVELOPER_DIR="$DEV_DIR" xcrun -sdk macosx metallib "${AIR_FILES[@]}" -o "$ROOT_DIR/Shaders/default.metallib"
echo "Wrote $ROOT_DIR/Shaders/default.metallib — commit it."
