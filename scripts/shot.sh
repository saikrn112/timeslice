#!/bin/bash
# Screenshot a tab of the built-from-source app.
#
# Why this exists: four rounds of Planner redesign were done blind, on the belief that macOS UI "can't
# be screenshotted". That is only true without the Screen Recording grant — with it,
# `screencapture -l <windowID>` captures a named window even when it isn't frontmost. So the loop is:
# build, launch with TIMESLICE_DEMO_TAB, capture, look, change something.
#
# Usage: scripts/shot.sh [tab] [out.png] [width] [height]
set -euo pipefail
TAB="${1:-planner}"
OUT="${2:-/tmp/timeslice-$TAB.png}"
W="${3:-720}"
H="${4:-920}"
cd "$(dirname "$0")/.."

swift build

pkill -f "\.build/.*/TimesliceApp" 2>/dev/null || true
sleep 0.4

# Against a COPY of the database. The app syncs and can write on launch, and a screenshot must not be
# able to change your data. WAL sidecars have to come along or the copy is missing recent commits.
SRC="$HOME/Library/Application Support/Timeslice/timeslice.db"
SHOT_DB="/tmp/timeslice-shot/timeslice.db"
mkdir -p /tmp/timeslice-shot
if [ -f "$SRC" ]; then
  cp "$SRC" "$SHOT_DB"
  [ -f "$SRC-wal" ] && cp "$SRC-wal" "$SHOT_DB-wal"
  [ -f "$SRC-shm" ] && cp "$SRC-shm" "$SHOT_DB-shm"
fi

TIMESLICE_DEMO_TAB="$TAB" TIMESLICE_WINDOW_SIZE="${W}x${H}" \
  TIMESLICE_PLANNER_UNIT="${PLANNER_UNIT:-week}" \
  TIMESLICE_OPEN_WINDOW=1 TIMESLICE_DB_PATH="$SHOT_DB" TIMESLICE_SANDBOX_ROLE=shot \
  ./.build/debug/TimesliceApp >/tmp/shot-app.log 2>&1 &
APP_PID=$!
trap 'kill $APP_PID 2>/dev/null || true' EXIT

# Wait for THIS process's window, not any Timeslice window — the installed copy is usually running too,
# and capturing its window silently returns a screenshot of the previous build.
ID=""
for _ in $(seq 1 40); do
  ID=$(./.build/debug/TimesliceWindowID "$APP_PID" 2>/dev/null | head -1 || true)
  [ -n "$ID" ] && break
  sleep 0.5
done
if [ -z "$ID" ]; then
  echo "no window from pid $APP_PID; app log:" >&2
  tail -20 /tmp/shot-app.log >&2
  exit 1
fi

sleep 1.5                      # let the first data load and the charts settle
rm -f "$OUT"
screencapture -x -o -l "$ID" "$OUT"
echo "$OUT"
