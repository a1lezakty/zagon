#!/bin/bash
# CI: Zagon left alone stays idle. 0.1.2 kept a core busy redrawing its menu bar icon in a loop; here each launch gets
# 60 s alone and must use under 3 s of CPU (5 % of a core): on the runner's empty store (scan timers running), then on
# the sample data (ZAGON_MOCK: both AIs in the menu bar). macOS only, after build-app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
app=$PWD/build/Zagon.app
# no update check, no notification prompt on the runner
defaults write dev.zagon.app SUEnableAutomaticChecks -bool false
defaults write dev.zagon.app macNotify -bool false

quit() {  # none left: a running Zagon would take the next `open` and drop its --env
  pkill -x Zagon || true
  for _ in $(seq 1 10); do pgrep -x Zagon >/dev/null || return 0; sleep 1; done
  echo "Zagon did not quit"; return 1
}
cpu() {  # CPU seconds of the one Zagon process
  local pids
  pids=$(pgrep -x Zagon || true)
  [ "$(echo "$pids" | grep -c .)" -eq 1 ] || { echo "expected one Zagon process, have: ${pids:-none}" >&2; return 1; }
  ps -o time= -p "$pids" | awk -F: '{ t = 0; for (i = 1; i <= NF; i++) t = t * 60 + $i; print t }'
}
idle() {  # <label> [open options…]
  local label=$1 a b
  shift
  quit
  open "$@" "$app"
  sleep 15  # launch and the first scan
  a=$(cpu)
  sleep 60
  b=$(cpu)
  echo "idle cpu $label: $(awk -v a="$a" -v b="$b" 'BEGIN { printf "%.2f", b - a }') s in 60 s"
  awk -v a="$a" -v b="$b" 'BEGIN { exit !(b - a < 3) }' || { echo "Zagon busy while idle ($label)"; return 1; }
}

idle store
idle sample --env ZAGON_MOCK=1
quit
echo "idle cpu: ok"
