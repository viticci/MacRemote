#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MacRemote"
BUNDLE_ID="com.macstories.MacRemote"
MIN_SYSTEM_VERSION="26.0"
VERSION="1.1.3"
BUILD_NUMBER="13"
SIGNING_IDENTITY="${MACREMOTE_CODESIGN_IDENTITY:-}"
NOTARY_PROFILE="${MACREMOTE_NOTARY_PROFILE:-}"
OUTPUT_DIR=""
LOCAL_SIGNING=0
PRIVATE_BETA=0
ALLOW_DIRTY=0
CLEAN_BUILD=1
export DEVELOPER_DIR="/Library/Developer/CommandLineTools"

usage() {
  cat <<'EOF'
usage: script/package_release.sh [options]

Build, sign, notarize, staple, zip, and verify a MacRemote release. The default
mode is intentionally strict and requires a clean checkout, a Developer ID
Application identity, and a notarytool keychain profile.

Options:
  --version <version>          App version (default: 1.1.3).
  --build-number <number>      Numeric bundle build number (default: 13).
  --identity <identity>        codesign identity (or MACREMOTE_CODESIGN_IDENTITY).
  --notary-profile <profile>   notarytool keychain profile (or MACREMOTE_NOTARY_PROFILE).
  --output-dir <directory>     Artifact directory (default: dist/release).
  --private-beta               Apple Development-signed Club fallback. Requires a clean
                               checkout and an installed Apple Development signing identity.
                               If macOS blocks the first open, use System Settings
                               > Privacy & Security > Open Anyway.
  --local-signing              Build a clearly named local-only zip without notarization.
  --allow-dirty                Allow local validation from a dirty checkout.
  --no-clean                   Reuse SwiftPM build products. The default cleans first.
  -h, --help                   Show this help.

Notarized distribution example:
  MACREMOTE_CODESIGN_IDENTITY='Developer ID Application: Name (TEAMID)' \
  MACREMOTE_NOTARY_PROFILE='MacRemote' script/package_release.sh --version 1.1.3 --build-number 13

Local validation example:
  script/package_release.sh --local-signing --allow-dirty --no-clean

Club fallback when Developer ID is unavailable:
  script/package_release.sh --private-beta
EOF
}

fail() {
  echo "release packaging failed: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || fail "--version requires a value"
      VERSION="$2"
      shift 2
      ;;
    --build-number)
      [[ $# -ge 2 ]] || fail "--build-number requires a value"
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --identity)
      [[ $# -ge 2 ]] || fail "--identity requires a value"
      SIGNING_IDENTITY="$2"
      shift 2
      ;;
    --notary-profile)
      [[ $# -ge 2 ]] || fail "--notary-profile requires a value"
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || fail "--output-dir requires a value"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --local-signing)
      LOCAL_SIGNING=1
      shift
      ;;
    --private-beta)
      PRIVATE_BETA=1
      shift
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    --no-clean)
      CLEAN_BUILD=0
      shift
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

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?([.-][0-9A-Za-z.-]+)?$ ]] || fail "version must use a numeric two- or three-part form"
[[ -z "$BUILD_NUMBER" || "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || fail "build number must be numeric"
[[ $LOCAL_SIGNING -eq 0 || $PRIVATE_BETA -eq 0 ]] || fail "choose only one of --private-beta or --local-signing"
[[ $LOCAL_SIGNING -eq 1 || $ALLOW_DIRTY -eq 0 ]] || fail "--allow-dirty is valid only with --local-signing"

PINNED_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
[[ -d "$DEVELOPER_DIR" ]] || fail "Command Line Tools are not installed"
[[ -d "$PINNED_SDK" ]] || fail "the macOS 26.5 SDK is not installed"
export SDKROOT="$PINNED_SDK"
SWIFT_BIN="$(/usr/bin/xcrun --find swift)"
[[ "$SWIFT_BIN" == "$DEVELOPER_DIR"/* ]] || fail "Swift did not resolve from Command Line Tools"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
SOURCE_REVISION="$(git rev-parse --verify HEAD)"
[[ "$SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]] || fail "could not resolve the source revision"
DIRTY_STATUS="$(git status --porcelain --untracked-files=normal)"

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$ROOT_DIR/dist/release"
elif [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$ROOT_DIR/$OUTPUT_DIR"
fi
/bin/mkdir -p "$OUTPUT_DIR"

ARCHITECTURES="universal2"
NAME_SUFFIX=""
if [[ $PRIVATE_BETA -eq 1 ]]; then
  NAME_SUFFIX="-private-beta"
elif [[ $LOCAL_SIGNING -eq 1 ]]; then
  NAME_SUFFIX="-local"
  if [[ -n "$DIRTY_STATUS" ]]; then
    NAME_SUFFIX="-local-dirty"
  fi
fi
ARTIFACT_BASENAME="$APP_NAME-$VERSION-macos-$ARCHITECTURES$NAME_SUFFIX.zip"
ARTIFACT_PATH="$OUTPUT_DIR/$ARTIFACT_BASENAME"
CHECKSUM_PATH="$ARTIFACT_PATH.sha256"
INFO_PATH="$ARTIFACT_PATH.release-info.txt"
publish_targets=("$ARTIFACT_PATH" "$CHECKSUM_PATH" "$INFO_PATH")
RELEASE_TRANSACTION_ACTIVE=0
# shellcheck source=release_asset_transaction.sh
source "$ROOT_DIR/script/release_asset_transaction.sh"
release_transaction_recover_if_needed \
  "$OUTPUT_DIR" "$ARTIFACT_BASENAME" "${publish_targets[@]}"

if [[ $LOCAL_SIGNING -eq 0 && $PRIVATE_BETA -eq 0 ]]; then
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(
      /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | /usr/bin/sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
        | /usr/bin/head -n 1 || true
    )"
  fi
  [[ "$SIGNING_IDENTITY" == Developer\ ID\ Application:* ]] \
    || fail "install or select a Developer ID Application identity"
  [[ -n "$NOTARY_PROFILE" ]] \
    || fail "provide a notarytool keychain profile with --notary-profile"
else
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(
      /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | /usr/bin/sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
        | /usr/bin/head -n 1 || true
    )"
  fi
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
  fi
  if [[ $PRIVATE_BETA -eq 1 && "$SIGNING_IDENTITY" != Apple\ Development:* ]]; then
    fail "--private-beta requires an Apple Development signing identity"
  fi
fi

if [[ -n "$DIRTY_STATUS" && $ALLOW_DIRTY -eq 0 ]]; then
  fail "checkout is dirty; commit the exact release contents before packaging"
fi

RELEASE_SCRATCH_DIR="$ROOT_DIR/.build/release-package"
if [[ $CLEAN_BUILD -eq 1 ]]; then
  /bin/rm -rf "$RELEASE_SCRATCH_DIR"
fi
"$SWIFT_BIN" build \
  --scratch-path "$RELEASE_SCRATCH_DIR" \
  --configuration release \
  --arch arm64 \
  --arch x86_64
BUILD_DIR="$(
  "$SWIFT_BIN" build \
    --scratch-path "$RELEASE_SCRATCH_DIR" \
    --configuration release \
    --arch arm64 \
    --arch x86_64 \
    --show-bin-path
)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"
BUILD_RESOURCE_BUNDLE="$BUILD_DIR/${APP_NAME}_${APP_NAME}.bundle"
[[ -x "$BUILD_BINARY" ]] || fail "release executable was not built"
[[ -d "$BUILD_RESOURCE_BUNDLE" ]] || fail "release resource bundle was not built"

WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/MacRemote-package.XXXXXX")"
PUBLISH_STAGE_DIR=""
cleanup() {
  local exit_code=$?
  if [[ ${RELEASE_TRANSACTION_ACTIVE:-0} -eq 1 ]]; then
    release_transaction_restore \
      "$OUTPUT_DIR" "$ARTIFACT_BASENAME" "${publish_targets[@]}" \
      || exit_code=1
  else
    release_transaction_recover_if_needed \
      "$OUTPUT_DIR" "$ARTIFACT_BASENAME" "${publish_targets[@]}" \
      || exit_code=1
  fi
  if [[ -n "${PUBLISH_STAGE_DIR:-}" && -d "$PUBLISH_STAGE_DIR" ]]; then
    /bin/rm -rf "$PUBLISH_STAGE_DIR"
  fi
  if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    /bin/rm -rf "$WORK_DIR"
  fi
  return "$exit_code"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

APP_BUNDLE="$WORK_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
/bin/mkdir -p "$APP_MACOS" "$APP_RESOURCES"
/usr/bin/ditto "$BUILD_BINARY" "$APP_BINARY"
/bin/chmod +x "$APP_BINARY"
/usr/bin/ditto "$BUILD_RESOURCE_BUNDLE" "$APP_RESOURCES/${APP_NAME}_${APP_NAME}.bundle"

for resource in \
  AppIcon.icns \
  Assets.car \
  Favicon.ico \
  Favicon.png \
  MacRemoteConnectorIcon.png \
  MacRemoteConnectorIcon128.png \
  MacRemoteConnectorIcon256.png \
  MacRemoteConnectorIcon64.png; do
  [[ -s "$ROOT_DIR/Resources/$resource" ]] || fail "source resource is missing: $resource"
  /usr/bin/ditto "$ROOT_DIR/Resources/$resource" "$APP_RESOURCES/$resource"
done

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>MacRemoteBuildConfiguration</key>
  <string>release</string>
  <key>MacRemoteSourceRevision</key>
  <string>$SOURCE_REVISION</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>MacRemote needs Automation access when approved command-line tools control other apps on this Mac.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>MacRemote needs Calendar access when approved command-line tools read or update calendar data on this Mac.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>MacRemote needs Calendar access when approved command-line tools read or update calendar data on this Mac.</string>
  <key>NSCameraUsageDescription</key>
  <string>MacRemote needs Camera access when approved command-line tools capture or process camera input on this Mac.</string>
  <key>NSContactsUsageDescription</key>
  <string>MacRemote needs Contacts access when approved command-line tools read or update contacts on this Mac.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>MacRemote needs Desktop folder access when approved command-line tools read or write files there.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>MacRemote needs Documents folder access when approved command-line tools read or write files there.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>MacRemote needs Downloads folder access when approved command-line tools read or write files there.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>MacRemote needs local network access when approved command-line tools connect to local devices or services.</string>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>MacRemote needs Location access when approved command-line tools use this Mac's location.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>MacRemote needs Microphone access when approved command-line tools record or process audio input on this Mac.</string>
  <key>NSNetworkVolumesUsageDescription</key>
  <string>MacRemote needs network volume access when approved command-line tools read or write mounted network storage.</string>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>MacRemote needs Photos access when approved command-line tools read or update the photo library on this Mac.</string>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>MacRemote needs Reminders access when approved command-line tools read or edit reminders on this Mac.</string>
  <key>NSRemindersUsageDescription</key>
  <string>MacRemote needs Reminders access when approved command-line tools edit reminders on this Mac.</string>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>MacRemote needs removable volume access when approved command-line tools read or write external storage.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>MacRemote needs Screen Recording access when approved command-line tools inspect or capture the screen.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>MacRemote needs Speech Recognition access when approved command-line tools transcribe speech on this Mac.</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null
/usr/bin/cmp -s "$BUILD_BINARY" "$APP_BINARY" \
  || fail "staged executable does not match the release build product"
if [[ $ALLOW_DIRTY -eq 0 ]]; then
  [[ "$(git rev-parse --verify HEAD)" == "$SOURCE_REVISION" ]] \
    || fail "source revision changed while the release was building"
  [[ -z "$(git status --porcelain --untracked-files=normal)" ]] \
    || fail "checkout changed while the release was building"
fi
/usr/bin/xattr -cr "$APP_BUNDLE"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  SIGN_TIMESTAMP=(--timestamp=none)
else
  SIGN_TIMESTAMP=(--timestamp)
fi
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "${SIGN_TIMESTAMP[@]}" \
  "$APP_RESOURCES/${APP_NAME}_${APP_NAME}.bundle"
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "${SIGN_TIMESTAMP[@]}" \
  --options runtime --identifier "$BUNDLE_ID" "$APP_BUNDLE"

PRE_VERIFY_MODE="signed"
FINAL_VERIFY_MODE="distribution"
if [[ $PRIVATE_BETA -eq 1 ]]; then
  PRE_VERIFY_MODE="private-beta"
  FINAL_VERIFY_MODE="private-beta"
elif [[ $LOCAL_SIGNING -eq 1 ]]; then
  PRE_VERIFY_MODE="local"
  FINAL_VERIFY_MODE="local"
fi

"$ROOT_DIR/script/verify_release.sh" \
  --mode "$PRE_VERIFY_MODE" \
  --version "$VERSION" \
  --build-number "$BUILD_NUMBER" \
  --revision "$SOURCE_REVISION" \
  "$APP_BUNDLE"

PUBLISH_STAGE_DIR="$(/usr/bin/mktemp -d "$OUTPUT_DIR/.MacRemote-release.XXXXXX")"
/bin/chmod 700 "$PUBLISH_STAGE_DIR"
STAGED_ARTIFACT_PATH="$PUBLISH_STAGE_DIR/$ARTIFACT_BASENAME"
STAGED_CHECKSUM_PATH="$STAGED_ARTIFACT_PATH.sha256"
STAGED_INFO_PATH="$STAGED_ARTIFACT_PATH.release-info.txt"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$STAGED_ARTIFACT_PATH"

if [[ $LOCAL_SIGNING -eq 0 && $PRIVATE_BETA -eq 0 ]]; then
  /usr/bin/xcrun notarytool submit "$STAGED_ARTIFACT_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  /usr/bin/xcrun stapler staple "$APP_BUNDLE"
  /usr/bin/xcrun stapler validate "$APP_BUNDLE"
  /bin/rm -f "$STAGED_ARTIFACT_PATH"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$STAGED_ARTIFACT_PATH"
fi

"$ROOT_DIR/script/verify_release.sh" \
  --mode "$FINAL_VERIFY_MODE" \
  --version "$VERSION" \
  --build-number "$BUILD_NUMBER" \
  --revision "$SOURCE_REVISION" \
  "$STAGED_ARTIFACT_PATH"

ARTIFACT_SHA256="$(/usr/bin/shasum -a 256 "$STAGED_ARTIFACT_PATH" | /usr/bin/awk '{print $1}')"
printf '%s  %s\n' "$ARTIFACT_SHA256" "$ARTIFACT_BASENAME" >"$STAGED_CHECKSUM_PATH"
NOTARIZED="no"
DISTRIBUTION_MODE="local"
GATEKEEPER="local-only; Gatekeeper not assessed."
if [[ $PRIVATE_BETA -eq 1 ]]; then
  DISTRIBUTION_MODE="private-beta"
  GATEKEEPER="Attempt to open MacRemote.app. If macOS blocks it, use System Settings > Privacy & Security > Open Anyway."
elif [[ $LOCAL_SIGNING -eq 0 ]]; then
  NOTARIZED="yes"
  DISTRIBUTION_MODE="developer-id"
  GATEKEEPER="automatic"
fi
cat >"$STAGED_INFO_PATH" <<INFO
name=$APP_NAME
version=$VERSION
build=$BUILD_NUMBER
source_revision=$SOURCE_REVISION
architectures=$ARCHITECTURES
signing_identity=$SIGNING_IDENTITY
notarized=$NOTARIZED
distribution_mode=$DISTRIBUTION_MODE
gatekeeper=$GATEKEEPER
sha256=$ARTIFACT_SHA256
artifact=$ARTIFACT_BASENAME
INFO

(
  cd "$PUBLISH_STAGE_DIR"
  /usr/bin/shasum -a 256 -c "$(/usr/bin/basename "$STAGED_CHECKSUM_PATH")" >/dev/null
)

publish_sources=("$STAGED_ARTIFACT_PATH" "$STAGED_CHECKSUM_PATH" "$STAGED_INFO_PATH")
release_transaction_publish \
  "$OUTPUT_DIR" "$ARTIFACT_BASENAME" \
  "${publish_sources[0]}" "${publish_targets[0]}" \
  "${publish_sources[1]}" "${publish_targets[1]}" \
  "${publish_sources[2]}" "${publish_targets[2]}"

echo "Release artifact: $ARTIFACT_PATH"
echo "SHA-256: $ARTIFACT_SHA256"
echo "Checksum file: $CHECKSUM_PATH"
echo "Release info: $INFO_PATH"
