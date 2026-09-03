#!/usr/bin/env bash
# Build Timeslice.app: compile release, stage a .app bundle, ad-hoc codesign.
# A bundle (vs bare `swift run`) gives a stable code identity so global-hotkey behavior and
# any TCC grants persist across rebuilds, plus LSUIElement (menu-bar-only, no Dock icon).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT/dist"
BUILD_CONFIG="${1:-release}"
APP_BINARY="TimesliceApp"
APP_NAME="Timeslice"
EXECUTABLE_NAME="Timeslice"
BUNDLE_ID="com.timeslice.app"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
# Ad-hoc signing by default ("-"): no certs, no keychain prompts, nothing that looks sketchy —
# right for a clean install (a normal, no-rebuild install keeps its Accessibility grant fine).
# Developers who rebuild often can set TIMESLICE_SIGN_IDENTITY="Timeslice Local" (a stable
# self-signed identity) so the grant survives rebuilds; otherwise macOS re-asks after a rebuild.
SIGN_IDENTITY="${TIMESLICE_SIGN_IDENTITY:--}"

echo "Building $APP_BINARY ($BUILD_CONFIG)…"
# TIMESLICE_DEV switches on the developer tools (the feedback list, sync diagnostics). Set
# TIMESLICE_RELEASE=1 to build what a real user would get, with those compiled out entirely.
DEV_FLAGS=()
if [ "${TIMESLICE_RELEASE:-0}" != "1" ]; then
  DEV_FLAGS=(-Xswiftc -DTIMESLICE_DEV)
  echo "  (developer tools ON — set TIMESLICE_RELEASE=1 for a release build)"
fi

# `${arr[@]+"${arr[@]}"}` and not `"${arr[@]}"`: macOS ships bash 3.2, where an EMPTY array under
# `set -u` is an unbound variable and the release build died on it. This form expands to nothing at
# all when the array is empty, rather than to one empty argument.
swift build --package-path "$ROOT" -c "$BUILD_CONFIG" \
  ${DEV_FLAGS[@]+"${DEV_FLAGS[@]}"} --product "$APP_BINARY"
BIN_DIR="$(swift build --package-path "$ROOT" -c "$BUILD_CONFIG" --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_DIR/$APP_BINARY" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"

cp "$ROOT/scripts/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
if [[ -f "$ROOT/scripts/Timeslice.icns" ]]; then
  cp "$ROOT/scripts/Timeslice.icns" "$APP_BUNDLE/Contents/Resources/Timeslice.icns"
fi

echo "Signing ($SIGN_IDENTITY)…"
codesign --force --sign "$SIGN_IDENTITY" \
  --entitlements "$ROOT/scripts/Timeslice.entitlements" \
  "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
echo "Run it with:  open \"$APP_BUNDLE\""
