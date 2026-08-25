#!/usr/bin/env bash
# Run TWO Timeslice instances on this one Mac, syncing through a shared folder.
#
# Why this exists: without it you'd need a second machine to test sync at all. Each instance gets
# its own database via TIMESLICE_DB_PATH and its own device id, so they behave exactly like two
# separate Macs sharing a Dropbox folder.
#
#   ./scripts/sync_sandbox.sh          # launch both
#   ./scripts/sync_sandbox.sh reset    # wipe the sandbox and start fresh
#   ./scripts/sync_sandbox.sh stop     # kill both
#   ./scripts/sync_sandbox.sh status   # what each DB currently holds
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="${TMPDIR:-/tmp}timeslice-sandbox"
SHARED="$SANDBOX/SharedFolder"
A="$SANDBOX/deviceA/timeslice.db"
B="$SANDBOX/deviceB/timeslice.db"

# Kill by BINARY PATH. An earlier version matched TIMESLICE_SANDBOX_ROLE, which never worked:
# that's an environment variable, not part of the command line pkill sees. Old instances therefore
# survived `reset`, deleted-then-republished their files, and generations piled up in the folder.
stop() {
  pkill -f "\.build/debug/TimesliceApp" 2>/dev/null || true
  sleep 1
  echo "stopped"
}

status() {
  for pair in "A:$A" "B:$B"; do
    tag="${pair%%:*}"; db="${pair#*:}"
    if [ -f "$db" ]; then
      printf 'device %s  ' "$tag"
      sqlite3 "$db" "SELECT (SELECT count(*) FROM projects)||' tasks, '||(SELECT count(*) FROM intervals)||' intervals, running='||(SELECT COALESCE((SELECT p.name FROM intervals i JOIN projects p ON p.id=i.project_id WHERE i.running=1),'none'));"
    else
      echo "device $tag  (no database yet)"
    fi
  done
  echo "shared folder:"; ls -1 "$SHARED" 2>/dev/null | sed 's/^/  /' || echo "  (empty)"
}

# `drive` mode syncs the two instances through the REAL Google Drive (shares this Mac's signed-in
# token), so the whole transport is exercised end to end rather than local file I/O.
MODE="${MODE:-folder}"
case "${1:-run}" in
  drive) MODE=drive ;;
  stop) stop; exit 0 ;;
  status) status; exit 0 ;;
  reset) stop; rm -rf "$SANDBOX"; echo "sandbox wiped (dbs + shared folder)"; exit 0 ;;
esac

mkdir -p "$(dirname "$A")" "$(dirname "$B")" "$SHARED"
swift build --package-path "$ROOT" >/dev/null
BIN="$(swift build --package-path "$ROOT" --show-bin-path)/TimesliceApp"

echo "shared folder : $SHARED"
echo "device A db   : $A"
echo "device B db   : $B"
echo
# Distinct DB paths => distinct device ids (minted next to each database).
if [ "$MODE" = "drive" ]; then
  echo "transport    : Google Drive (real)"
  TIMESLICE_SANDBOX_ROLE=A TIMESLICE_DB_PATH="$A" TIMESLICE_SYNC_DRIVE=1 "$BIN" &
  sleep 3
  TIMESLICE_SANDBOX_ROLE=B TIMESLICE_DB_PATH="$B" TIMESLICE_SYNC_DRIVE=1 "$BIN" &
else
  TIMESLICE_SANDBOX_ROLE=A TIMESLICE_DB_PATH="$A" TIMESLICE_SYNC_FOLDER="$SHARED" "$BIN" &
  sleep 2
  TIMESLICE_SANDBOX_ROLE=B TIMESLICE_DB_PATH="$B" TIMESLICE_SYNC_FOLDER="$SHARED" "$BIN" &
fi
echo "both instances launched — two menu-bar timers should appear."
echo "run './scripts/sync_sandbox.sh status' to watch them converge."
