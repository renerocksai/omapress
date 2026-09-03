#!/usr/bin/env bash
# Runs ProcessWatchdog.qml under a bare quickshell against a child that
# ignores SIGTERM, in its own process group, with a grandchild. Needs `qs`
# (quickshell) and a Wayland session, which every Omarchy box has. A
# quickshell config cannot import outside its own folder, so the two files
# are copied into a temporary one.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
marker=$(mktemp)
config=$(mktemp -d)
cleanup() {
  pid=$(cat "$marker" 2>/dev/null || true)
  [[ -n $pid ]] && kill -KILL "$pid" 2>/dev/null || true
  rm -rf "$marker" "$config"
}
trap cleanup EXIT
cp "$here/../ProcessWatchdog.qml" "$here/watchdog-test.qml" "$config/"

export WATCHDOG_MARKER="$marker"
out=$(timeout 25 qs -p "$config/watchdog-test.qml" 2>&1 || true)
grep -E 'timed out:|exited|WATCHDOG|ERROR' <<<"$out" || true

grep -q 'WATCHDOG OK' <<<"$out" || { echo "FAIL: watchdog did not take the tree down" >&2; exit 1; }
echo "watchdog test passed"
