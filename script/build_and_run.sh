#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="MacRemote"
BUNDLE_ID="com.macstories.MacRemote"
MIN_SYSTEM_VERSION="26.0"
APP_VERSION="${MACREMOTE_VERSION:-1.0}"
BUILD_VERSION="${MACREMOTE_BUILD_NUMBER:-9}"

usage() {
  cat <<'EOF'
usage: script/build_and_run.sh [run|--build-only|--debug|--logs|--telemetry|--verify]

Build MacRemote from this source checkout. Run installs the app in /Applications
and opens it. Verify installs, opens, and confirms that the process is running.

Options:
  run             Build, install, and open MacRemote. This is the default.
  --build-only    Build and stage dist/MacRemote.app without installing it.
  --debug         Build, then open the staged executable in LLDB.
  --logs          Build, install, open, and stream MacRemote process logs.
  --telemetry     Build, install, open, and stream MacRemote telemetry logs.
  --verify        Build, install, open, and confirm MacRemote is running.
  -h, --help      Show this help without building or changing the app.
EOF
}

case "$MODE" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

export DEVELOPER_DIR="/Library/Developer/CommandLineTools"

# The default (27.0) CLT SDK cannot build this package (missing SwiftUIMacros
# plugin — see docs/design/DESIGN-SPEC.md §8.1). Always pin the 26.5 SDK when
# it is present.
PINNED_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
if [[ -d "$PINNED_SDK" ]]; then
  export SDKROOT="$PINNED_SDK"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
SOURCE_ICON="$ROOT_DIR/Resources/AppIcon.icns"
SOURCE_ICON_CATALOG="$ROOT_DIR/Resources/Assets.car"
SOURCE_CONNECTOR_ICON="$ROOT_DIR/Resources/MacRemoteConnectorIcon.png"
SOURCE_CONNECTOR_ICON_128="$ROOT_DIR/Resources/MacRemoteConnectorIcon128.png"
SOURCE_CONNECTOR_ICON_256="$ROOT_DIR/Resources/MacRemoteConnectorIcon256.png"
SOURCE_CONNECTOR_ICON_64="$ROOT_DIR/Resources/MacRemoteConnectorIcon64.png"
SOURCE_FAVICON_ICO="$ROOT_DIR/Resources/Favicon.ico"
SOURCE_FAVICON_PNG="$ROOT_DIR/Resources/Favicon.png"
STABLE_ADHOC_REQUIREMENT="=designated => identifier \"$BUNDLE_ID\""

cd "$ROOT_DIR"

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
# SwiftPM resource bundle for Bundle.module: Shaders/default.metallib, the MCP
# Apps widget HTML, and Resources/ConnectedAppIcons with its provenance
# manifest. Package.swift lists Resources/ file by file so only the icons reach
# the bundle — the app's own icon and favicon art is copied above.
BUILD_RESOURCE_BUNDLE="$(swift build --show-bin-path)/${APP_NAME}_${APP_NAME}.bundle"
if [[ -d "$BUILD_RESOURCE_BUNDLE" ]]; then
  cp -R "$BUILD_RESOURCE_BUNDLE" "$APP_RESOURCES/"
fi
if [[ -f "$SOURCE_ICON" ]]; then
  cp "$SOURCE_ICON" "$APP_RESOURCES/AppIcon.icns"
fi
# Assets.car holds the layered Liquid Glass icon that CFBundleIconName names;
# AppIcon.icns is the flat fallback. Tools/icon/build_assets.py makes both.
if [[ -f "$SOURCE_ICON_CATALOG" ]]; then
  cp "$SOURCE_ICON_CATALOG" "$APP_RESOURCES/Assets.car"
fi
if [[ -f "$SOURCE_CONNECTOR_ICON" ]]; then
  cp "$SOURCE_CONNECTOR_ICON" "$APP_RESOURCES/MacRemoteConnectorIcon.png"
fi
if [[ -f "$SOURCE_CONNECTOR_ICON_128" ]]; then
  cp "$SOURCE_CONNECTOR_ICON_128" "$APP_RESOURCES/MacRemoteConnectorIcon128.png"
fi
if [[ -f "$SOURCE_CONNECTOR_ICON_256" ]]; then
  cp "$SOURCE_CONNECTOR_ICON_256" "$APP_RESOURCES/MacRemoteConnectorIcon256.png"
fi
if [[ -f "$SOURCE_CONNECTOR_ICON_64" ]]; then
  cp "$SOURCE_CONNECTOR_ICON_64" "$APP_RESOURCES/MacRemoteConnectorIcon64.png"
fi
if [[ -f "$SOURCE_FAVICON_ICO" ]]; then
  cp "$SOURCE_FAVICON_ICO" "$APP_RESOURCES/Favicon.ico"
fi
if [[ -f "$SOURCE_FAVICON_PNG" ]]; then
  cp "$SOURCE_FAVICON_PNG" "$APP_RESOURCES/Favicon.png"
fi

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
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_VERSION</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
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

SIGNING_IDENTITY="${MACREMOTE_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
      | /usr/bin/sed -n 's/.*"\(.*\)".*/\1/p' \
      | /usr/bin/grep -E 'Developer ID Application|Apple Development|Mac Developer|3rd Party Mac Developer Application' \
      | /usr/bin/head -n 1 || true
  )"
fi

if [[ -n "$SIGNING_IDENTITY" && "$SIGNING_IDENTITY" != "-" ]]; then
  if /usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" "$APP_BUNDLE" >/dev/null; then
    echo "Signed $APP_BUNDLE with $SIGNING_IDENTITY" >&2
  else
    echo "warning: could not sign $APP_BUNDLE with $SIGNING_IDENTITY; falling back to stable local signing" >&2
    /usr/bin/codesign --force --deep --sign - --identifier "$BUNDLE_ID" --requirements "$STABLE_ADHOC_REQUIREMENT" "$APP_BUNDLE" >/dev/null
    echo "Signed $APP_BUNDLE with stable local requirement: $STABLE_ADHOC_REQUIREMENT" >&2
  fi
else
  /usr/bin/codesign --force --deep --sign - --identifier "$BUNDLE_ID" --requirements "$STABLE_ADHOC_REQUIREMENT" "$APP_BUNDLE" >/dev/null
  echo "Signed $APP_BUNDLE with stable local requirement: $STABLE_ADHOC_REQUIREMENT" >&2
fi

# The user-facing install lives in /Applications (what Spotlight/Dock resolve
# and what TCC/Full Disk Access grants are keyed to). dist/ is only the build
# product — installing over the same path preserves the permission grants.
# A stale copy in ~/Applications splits TCC grants across two bundles, so
# remove it if present.
# MacRemote's managed Cloudflare helper lives in
# ~/Library/Application Support/MacRemote/CloudflaredHelper/, not in the bundle.
# Replacing the app here never re-downloads it and never deletes it.
INSTALL_BUNDLE="/Applications/$APP_NAME.app"

install_app() {
  rm -rf "$HOME/Applications/$APP_NAME.app"
  "$ROOT_DIR/script/install_app_transaction.sh" "$APP_BUNDLE" "$INSTALL_BUNDLE"
  echo "Installed $INSTALL_BUNDLE" >&2
  # Keep /Applications the ONLY LaunchServices registration. A registered
  # dist copy gives System Settings' FDA "Quit & Reopen" (and any bundle-id
  # launch) an ambiguous target.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$APP_BUNDLE" >/dev/null 2>&1 || true
}

open_app() {
  install_app
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  /usr/bin/open -n "$INSTALL_BUNDLE"
}

verify_running_install() {
  local expected_path="$INSTALL_BUNDLE/Contents/MacOS/$APP_NAME"
  local pid
  local process_path

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    process_path="$(/bin/ps -p "$pid" -o comm= 2>/dev/null || true)"
    if [[ "$process_path" == "$expected_path" ]]; then
      return 0
    fi
  done < <(/usr/bin/pgrep -x "$APP_NAME" || true)

  echo "verification failed: $expected_path is not running" >&2
  return 1
}

case "$MODE" in
  --build-only|build-only|build)
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    verify_running_install
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
