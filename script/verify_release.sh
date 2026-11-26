#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MacRemote"
BUNDLE_ID="com.macstories.MacRemote"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_VERSION=""
EXPECTED_BUILD=""
EXPECTED_REVISION=""
MODE="distribution"
export DEVELOPER_DIR="/Library/Developer/CommandLineTools"

usage() {
  cat <<'EOF'
usage: script/verify_release.sh [options] <MacRemote.app|MacRemote.zip>

Validate the complete MacRemote release bundle, including version metadata,
required resources, nested code, hardened runtime, signing, and (for a
distribution artifact) Gatekeeper acceptance plus a stapled notarization ticket.

Options:
  --mode <distribution|signed|local>
                               Distribution is the default. Signed validates a
                               Developer ID bundle before notarization. Local
                               accepts a development or ad-hoc identity.
  --version <version>          Require CFBundleShortVersionString.
  --build-number <number>      Require CFBundleVersion.
  --revision <git-sha>         Require MacRemoteSourceRevision.
  -h, --help                   Show this help.
EOF
}

fail() {
  echo "release verification failed: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ $# -ge 2 ]] || fail "--mode requires a value"
      MODE="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || fail "--version requires a value"
      EXPECTED_VERSION="$2"
      shift 2
      ;;
    --build-number)
      [[ $# -ge 2 ]] || fail "--build-number requires a value"
      EXPECTED_BUILD="$2"
      shift 2
      ;;
    --revision)
      [[ $# -ge 2 ]] || fail "--revision requires a value"
      EXPECTED_REVISION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      fail "unknown option: $1"
      ;;
    *)
      [[ -z "${ARTIFACT:-}" ]] || fail "provide exactly one app or zip"
      ARTIFACT="$1"
      shift
      ;;
  esac
done

[[ "$MODE" == "distribution" || "$MODE" == "signed" || "$MODE" == "local" ]] \
  || fail "mode must be distribution, signed, or local"
[[ -n "${ARTIFACT:-}" ]] || fail "provide a MacRemote app or zip"
[[ -e "$ARTIFACT" ]] || fail "artifact does not exist: $ARTIFACT"

TEMP_DIR=""
cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    /bin/rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT

if [[ "$ARTIFACT" == *.zip ]]; then
  TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/MacRemote-verify.XXXXXX")"
  ARCHIVE_ENTRIES="$TEMP_DIR/archive-entries.txt"
  /usr/bin/python3 "$ROOT_DIR/script/validate_release_zip.py" "$ARTIFACT" >"$ARCHIVE_ENTRIES" \
    || exit 1

  archive_has_entry() {
    /usr/bin/grep -F -x -q -- "$1" "$ARCHIVE_ENTRIES"
  }

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || fail "zip contains an empty archive entry"
    if [[ "$entry" == /* || "$entry" == *\\* || "$entry" == *"//"* ]]; then
      fail "zip contains an unsafe archive path: $entry"
    fi
    if [[ "/$entry/" == *"/../"* || "/$entry/" == *"/./"* ]]; then
      fail "zip contains an unsafe archive path: $entry"
    fi

    if [[ "$entry" == "MacRemote.app/" || "$entry" == MacRemote.app/* ]]; then
      continue
    fi
    if [[ "$entry" == "__MACOSX/" ]]; then
      continue
    fi
    if [[ "$entry" == __MACOSX/MacRemote.app/* ]]; then
      metadata_relative="${entry#__MACOSX/}"
      if [[ "$metadata_relative" == */ ]]; then
        archive_has_entry "$metadata_relative" \
          || fail "zip contains unmatched ditto metadata: $entry"
        continue
      fi

      metadata_name="${metadata_relative##*/}"
      [[ "$metadata_name" == ._* ]] \
        || fail "zip contains unexpected ditto metadata: $entry"
      metadata_parent="${metadata_relative%/*}"
      metadata_counterpart_name="${metadata_name#._}"
      metadata_counterpart="$metadata_parent/$metadata_counterpart_name"
      if archive_has_entry "$metadata_counterpart" || archive_has_entry "$metadata_counterpart/"; then
        continue
      fi
      fail "zip contains unmatched ditto metadata: $entry"
    fi
    fail "zip contains an unexpected archive entry: $entry"
  done <"$ARCHIVE_ENTRIES"

  /usr/bin/ditto -x -k "$ARTIFACT" "$TEMP_DIR"
  if /usr/bin/find "$TEMP_DIR" -type l -print -quit | /usr/bin/grep -q .; then
    fail "zip contains a symbolic link"
  fi
  UNEXPECTED_EXTRACTED_ENTRY="$(/usr/bin/find "$TEMP_DIR" -mindepth 1 -maxdepth 1 ! -name "$APP_NAME.app" ! -name 'archive-entries.txt' -print -quit)"
  [[ -z "$UNEXPECTED_EXTRACTED_ENTRY" ]] \
    || fail "zip extracted an unexpected top-level entry"
  APP_BUNDLE="$TEMP_DIR/$APP_NAME.app"
  [[ -d "$APP_BUNDLE" ]] || fail "zip does not contain $APP_NAME.app at its root"
  TOP_LEVEL_APP_COUNT="$(/usr/bin/find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d -name '*.app' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  [[ "$TOP_LEVEL_APP_COUNT" == "1" ]] || fail "zip must contain exactly one top-level app"
else
  APP_BUNDLE="$ARTIFACT"
fi

[[ "$APP_BUNDLE" == *.app && -d "$APP_BUNDLE/Contents" ]] || fail "artifact is not an app bundle"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
APP_RESOURCES="$APP_BUNDLE/Contents/Resources"
RESOURCE_BUNDLE="$APP_RESOURCES/${APP_NAME}_${APP_NAME}.bundle"

[[ -f "$INFO_PLIST" ]] || fail "Info.plist is missing"
[[ -x "$APP_BINARY" ]] || fail "main executable is missing or not executable"
[[ -d "$RESOURCE_BUNDLE" ]] || fail "SwiftPM resource bundle is missing"

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST" 2>/dev/null || true
}

[[ "$(plist_value CFBundleExecutable)" == "$APP_NAME" ]] || fail "CFBundleExecutable is not $APP_NAME"
[[ "$(plist_value CFBundleIdentifier)" == "$BUNDLE_ID" ]] || fail "unexpected bundle identifier"
[[ "$(plist_value CFBundlePackageType)" == "APPL" ]] || fail "CFBundlePackageType is not APPL"
[[ "$(plist_value LSMinimumSystemVersion)" == "26.0" ]] || fail "minimum system version is not 26.0"
[[ "$(plist_value CFBundleIconName)" == "AppIcon" ]] || fail "CFBundleIconName is not AppIcon, so macOS would draw the flat fallback icon"
[[ "$(plist_value MacRemoteBuildConfiguration)" == "release" ]] || fail "bundle was not staged from a release build"

VERSION="$(plist_value CFBundleShortVersionString)"
BUILD_NUMBER="$(plist_value CFBundleVersion)"
REVISION="$(plist_value MacRemoteSourceRevision)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?([.-][0-9A-Za-z.-]+)?$ ]] || fail "invalid or missing app version"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || fail "invalid or missing build number"
[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || fail "invalid or missing source revision"
[[ -z "$EXPECTED_VERSION" || "$VERSION" == "$EXPECTED_VERSION" ]] || fail "expected version $EXPECTED_VERSION, found $VERSION"
[[ -z "$EXPECTED_BUILD" || "$BUILD_NUMBER" == "$EXPECTED_BUILD" ]] || fail "expected build $EXPECTED_BUILD, found $BUILD_NUMBER"
[[ -z "$EXPECTED_REVISION" || "$REVISION" == "$EXPECTED_REVISION" ]] || fail "expected revision $EXPECTED_REVISION, found $REVISION"

for resource in \
  AppIcon.icns \
  Assets.car \
  Favicon.ico \
  Favicon.png \
  MacRemoteConnectorIcon.png \
  MacRemoteConnectorIcon128.png \
  MacRemoteConnectorIcon256.png \
  MacRemoteConnectorIcon64.png; do
  [[ -s "$APP_RESOURCES/$resource" ]] || fail "required resource is missing or empty: $resource"
done
/usr/bin/grep -q 'Permission is hereby granted' "$APP_RESOURCES/LICENSE" 2>/dev/null \
  || fail "the MIT license notice is missing from Contents/Resources/LICENSE"

for module_resource in \
  default.metallib \
  MacRemoteWidget.html \
  Skills/macremote/SKILL.md \
  ConnectedAppIcons/MANIFEST.json \
  ConnectedAppIcons/THIRD-PARTY-NOTICES.md; do
  [[ -s "$RESOURCE_BUNDLE/Contents/Resources/$module_resource" ]] \
    || fail "required module resource is missing or empty: $module_resource"
done

if /usr/bin/find "$APP_BUNDLE" -type f -name cloudflared -print -quit | /usr/bin/grep -q .; then
  fail "the app-managed cloudflared helper must not be bundled"
fi
if /usr/bin/find "$APP_BUNDLE" -name '.DS_Store' -print -quit | /usr/bin/grep -q .; then
  fail "bundle contains .DS_Store"
fi

/usr/bin/file "$APP_BINARY" | /usr/bin/grep -q 'Mach-O' || fail "main executable is not Mach-O code"
ARCHITECTURES="$(/usr/bin/lipo -archs "$APP_BINARY")"
[[ "$ARCHITECTURES" == *arm64* ]] || fail "main executable is missing its arm64 slice"
[[ "$ARCHITECTURES" == *x86_64* ]] || fail "main executable is missing its x86_64 slice"
for architecture in arm64 x86_64; do
  BUILD_VERSION_LOAD_COMMAND="$(/usr/bin/vtool -arch "$architecture" -show-build "$APP_BINARY" 2>/dev/null)"
  printf '%s\n' "$BUILD_VERSION_LOAD_COMMAND" | /usr/bin/grep -Eq '^[[:space:]]*platform MACOS$' \
    || fail "$architecture slice does not target macOS"
  printf '%s\n' "$BUILD_VERSION_LOAD_COMMAND" | /usr/bin/grep -Eq '^[[:space:]]*minos 26\.0$' \
    || fail "$architecture slice does not have a 26.0 deployment target"
done

/usr/bin/codesign --verify --strict --verbose=4 "$RESOURCE_BUNDLE" >/dev/null 2>&1 \
  || fail "resource bundle signature is invalid"
/usr/bin/codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE" >/dev/null 2>&1 \
  || fail "app or nested-code signature is invalid"
SIGNING_DETAILS="$(/usr/bin/codesign -dvvv "$APP_BUNDLE" 2>&1)"
printf '%s\n' "$SIGNING_DETAILS" | /usr/bin/grep -Eq 'flags=.*[(,]runtime[,)]' \
  || fail "hardened runtime is not enabled"

if [[ "$MODE" == "distribution" || "$MODE" == "signed" ]]; then
  printf '%s\n' "$SIGNING_DETAILS" | /usr/bin/grep -q '^Authority=Developer ID Application:' \
    || fail "distribution bundle is not signed with Developer ID Application"
fi
if [[ "$MODE" == "distribution" ]]; then
  /usr/bin/xcrun stapler validate "$APP_BUNDLE" >/dev/null 2>&1 \
    || fail "notarization ticket is not stapled"
  /usr/sbin/spctl --assess --type execute --verbose=4 "$APP_BUNDLE" >/dev/null 2>&1 \
    || fail "Gatekeeper does not accept the app"
fi

echo "Verified $APP_NAME $VERSION ($BUILD_NUMBER), revision $REVISION, architectures: $ARCHITECTURES, mode: $MODE"
