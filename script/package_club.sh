#!/usr/bin/env bash
set -euo pipefail

# Builds the one ZIP that Club members download. Run it after
# script/package_release.sh has produced the notarized app.
#
# The ZIP unpacks to a folder named "MacRemote <version>":
#   MacRemote.app      the notarized app, ready to drag to Applications
#   Club Guide.md      docs/CLUB_BETA.md
#   Release Notes.md   docs/releases/<version>.md
#   Source/            this repository at the commit the app was built from
#
# docs/CLUB_BETA.md describes this layout to members. Change both together.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="1.1"
OUTPUT_DIR="$ROOT_DIR/dist/release"

usage() {
  cat <<'EOF'
usage: script/package_club.sh [--version <version>] [--output-dir <directory>]

Wraps the notarized release ZIP, the Club guide, the release notes, and the
source into MacRemote-<version>.zip, the single file Club members download.
Requires a clean checkout at the commit the release ZIP was built from.
EOF
}

fail() {
  echo "club packaging failed: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || fail "--version requires a value"
      VERSION="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || fail "--output-dir requires a value"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

RELEASE_ZIP="$OUTPUT_DIR/MacRemote-$VERSION-macos-universal2.zip"
RELEASE_INFO="$RELEASE_ZIP.release-info.txt"
CLUB_ZIP="$OUTPUT_DIR/MacRemote-$VERSION.zip"
GUIDE="$ROOT_DIR/docs/CLUB_BETA.md"
NOTES="$ROOT_DIR/docs/releases/$VERSION.md"

[[ -s "$RELEASE_ZIP" ]] || fail "missing $RELEASE_ZIP; run script/package_release.sh first"
[[ -s "$RELEASE_INFO" ]] || fail "missing $RELEASE_INFO"
[[ -s "$GUIDE" ]] || fail "missing $GUIDE"
[[ -s "$NOTES" ]] || fail "missing $NOTES"
/usr/bin/grep -qx 'notarized=yes' "$RELEASE_INFO" || fail "the release ZIP is not notarized"

# The source in the ZIP must be the source the app was built from.
HEAD_REVISION="$(/usr/bin/git -C "$ROOT_DIR" rev-parse HEAD)"
/usr/bin/grep -qx "source_revision=$HEAD_REVISION" "$RELEASE_INFO" \
  || fail "the release ZIP was not built from the current commit ($HEAD_REVISION)"
[[ -z "$(/usr/bin/git -C "$ROOT_DIR" status --porcelain)" ]] || fail "the checkout has uncommitted changes"

WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/MacRemote-club.XXXXXX")"
trap '/bin/rm -rf "$WORK_DIR"' EXIT
FOLDER="$WORK_DIR/MacRemote $VERSION"
/bin/mkdir -p "$FOLDER"

/usr/bin/ditto -x -k "$RELEASE_ZIP" "$FOLDER"
[[ -d "$FOLDER/MacRemote.app" ]] || fail "the release ZIP does not contain MacRemote.app"

# The two documents sit side by side here, not in docs/ and docs/releases/, so
# their links to each other are rewritten. Any other link to a file in the
# repository would be broken in the folder a member opens, so it is refused.
VERSION="$VERSION" /usr/bin/perl -pe \
  's{\(releases/\Q$ENV{VERSION}\E\.md(#[^)]*)?\)}{"(<Release Notes.md" . ($1 // "") . ">)"}ge' \
  "$GUIDE" >"$FOLDER/Club Guide.md"
/usr/bin/perl -pe 's{\(\.\./CLUB_BETA\.md(#[^)]*)?\)}{"(<Club Guide.md" . ($1 // "") . ">)"}ge' \
  "$NOTES" >"$FOLDER/Release Notes.md"
for document in "$FOLDER/Club Guide.md" "$FOLDER/Release Notes.md"; do
  if BROKEN="$(/usr/bin/grep -nE '\]\([^)<#]' "$document" | /usr/bin/grep -vE '\]\(https?://')"; then
    fail "$(basename "$document") links to a file that is not in the Club folder: $BROKEN"
  fi
done

# A file:// address makes Git send only what this commit needs. Cloning the
# folder by its path copies every object in it, including history that was
# squashed away and never published.
/usr/bin/git clone --quiet --single-branch --no-tags "file://$ROOT_DIR" "$FOLDER/Source"
ORIGIN_URL="$(/usr/bin/git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || true)"
if [[ -n "$ORIGIN_URL" ]]; then
  /usr/bin/git -C "$FOLDER/Source" remote set-url origin "$ORIGIN_URL"
else
  /usr/bin/git -C "$FOLDER/Source" remote remove origin
fi
[[ "$(/usr/bin/git -C "$FOLDER/Source" rev-parse HEAD)" == "$HEAD_REVISION" ]] || fail "the source copy is at the wrong commit"
if /usr/bin/git -C "$FOLDER/Source" fsck --unreachable --no-reflogs 2>/dev/null | /usr/bin/grep -q '^unreachable'; then
  fail "the source copy carries objects that are not part of the published history"
fi

/bin/rm -f "$CLUB_ZIP"
/usr/bin/ditto -c -k --keepParent "$FOLDER" "$CLUB_ZIP"

# Unpack what was just written and check the app the way a member's Mac will.
CHECK_DIR="$WORK_DIR/check"
/bin/mkdir -p "$CHECK_DIR"
/usr/bin/ditto -x -k "$CLUB_ZIP" "$CHECK_DIR"
CHECK_APP="$CHECK_DIR/MacRemote $VERSION/MacRemote.app"
/usr/bin/codesign --verify --deep --strict "$CHECK_APP" || fail "the packaged app's signature is damaged"
/usr/bin/xcrun stapler validate "$CHECK_APP" >/dev/null || fail "the packaged app lost its notarization ticket"
/usr/sbin/spctl -a -vv "$CHECK_APP" 2>&1 | /usr/bin/grep -q 'source=Notarized Developer ID' \
  || fail "Gatekeeper does not accept the packaged app as notarized"

echo "Club package: $CLUB_ZIP"
echo "SHA-256: $(/usr/bin/shasum -a 256 "$CLUB_ZIP" | /usr/bin/awk '{print $1}')"
