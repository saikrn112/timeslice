#!/usr/bin/env bash
# One-shot installer for Timeslice.
#
#   ./scripts/install.sh
#
# Builds Timeslice.app, installs it to /Applications, and launches it. Ad-hoc code signing, so
# it runs without any prompts. The only manual step is a one-time macOS Accessibility toggle for
# the global hotkeys (see the end).
#
# Requirements: Xcode Command Line Tools (`swift`).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SRC="$ROOT/dist/Timeslice.app"
APP_DST="/Applications/Timeslice.app"

say() { printf "\033[1;34m▸ %s\033[0m\n" "$1"; }

say "Building Timeslice.app (ad-hoc signed)…"
# Force ad-hoc signing regardless of any local signing certs — keeps a friend's install clean.
TIMESLICE_SIGN_IDENTITY="-" "$ROOT/scripts/build_native_app.sh" release

say "Installing to ${APP_DST}…"
pkill -f "Timeslice.app/Contents/MacOS/Timeslice" 2>/dev/null || true
sleep 1
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
# Clear the quarantine flag so Gatekeeper doesn't nag on first open of a locally-built app.
xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true

say "Launching…"
open "$APP_DST"

cat <<'DONE'

✅ Timeslice installed to /Applications and launched. Look for the ⏱ icon in the menu bar.

One-time setup for the global hotkey (fn+⌘+⇧+\ to switch tasks from any app):
  System Settings → Privacy & Security → Accessibility → enable "Timeslice".

That's it. Everything else (tracking, metrics, the popover) works without any permission.

Note for developers: this uses ad-hoc signing, so macOS re-asks for the Accessibility
permission after you REBUILD and reinstall. A normal install (no rebuilds) keeps the grant.
DONE
