#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/script"
# shellcheck source=app_metadata.sh
source "$SCRIPT_DIR/app_metadata.sh"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$EXECUTABLE_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ENTITLEMENTS_PATH="$ROOT_DIR/Resources/AirTranslate.entitlements"
DEBUG_ENTITLEMENTS_PATH="$ROOT_DIR/Resources/AirTranslate.debug.entitlements"
# Stable identity keeps macOS privacy grants (system audio, speech) across rebuilds.
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-AirTranslate Dev}"

case "$MODE" in
  --debug|debug)
    ENTITLEMENTS_PATH="$DEBUG_ENTITLEMENTS_PATH"
    ;;
esac

cd "$ROOT_DIR"

pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$EXECUTABLE_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
mkdir -p "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"

"$SCRIPT_DIR/write_info_plist.sh" "$INFO_PLIST" local

# Self-signed identities are listed as untrusted, so search without -v and match the label by prefix.
SIGN_IDENTITY_HASH="$(/usr/bin/security find-identity -p codesigning 2>/dev/null |
  /usr/bin/awk -v name="$CODE_SIGN_IDENTITY" 'index($0, "\"" name) { print $2; exit }')"
if [[ -z "$SIGN_IDENTITY_HASH" ]]; then
  echo "error: code signing identity \"$CODE_SIGN_IDENTITY\" not found in keychain." >&2
  echo "Create it once: Keychain Access → Certificate Assistant → Create a Certificate…" >&2
  echo "  Name: $CODE_SIGN_IDENTITY, Identity Type: Self Signed Root, Certificate Type: Code Signing" >&2
  echo "Or pass CODE_SIGN_IDENTITY=<name> to use another identity." >&2
  exit 1
fi

/usr/bin/codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS_PATH" --timestamp=none --sign "$SIGN_IDENTITY_HASH" "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  --reset-permissions|reset-permissions)
    /usr/bin/tccutil reset ScreenCapture "$BUNDLE_ID" || true
    /usr/bin/tccutil reset AudioCapture "$BUNDLE_ID" || true
    /usr/bin/tccutil reset Microphone "$BUNDLE_ID" || true
    /usr/bin/tccutil reset SpeechRecognition "$BUNDLE_ID" || true
    echo "Reset AirTranslate privacy grants. Relaunch and approve Screen Recording, System Audio Recording, Microphone (when selected), and Speech Recognition once."
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$EXECUTABLE_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$EXECUTABLE_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--reset-permissions]" >&2
    exit 2
    ;;
esac
