#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="MacRemote"
BUNDLE_ID="com.macstories.MacRemote"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
SOURCE_ICON="$ROOT_DIR/Resources/AppIcon.icns"
STABLE_ADHOC_REQUIREMENT="=designated => identifier \"$BUNDLE_ID\""

cd "$ROOT_DIR"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
if [[ -f "$SOURCE_ICON" ]]; then
  cp "$SOURCE_ICON" "$APP_RESOURCES/AppIcon.icns"
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
  <key>CFBundleIconFile</key>
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

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
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
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--build-only|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
