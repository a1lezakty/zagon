#!/bin/bash
# CI: Zagon.app opened the way a person opens it shows its window, also when opened again while it runs; the DMG
# shows the app with its icon. Screenshots go to build/snapshots/launch-*.png. macOS only, after build-app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
app=$PWD/build/Zagon.app
shots=build/snapshots
mkdir -p "$shots"
# no update check, no notification prompt on the runner
defaults write dev.zagon.app SUEnableAutomaticChecks -bool false
defaults write dev.zagon.app macNotify -bool false

# Zagon's normal windows on screen (layer 0), as the window server lists them.
cat > build/windows.swift <<'SWIFT'
import CoreGraphics
let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
print(all.filter { $0[kCGWindowOwnerName as String] as? String == "Zagon" && $0[kCGWindowLayer as String] as? Int == 0 }.count)
SWIFT
swiftc -O build/windows.swift -o build/windows
wait_windows() {  # <count>: up to 30 s
  for _ in $(seq 1 30); do [ "$(build/windows)" = "$1" ] && return 0; sleep 1; done
  echo "expected $1 Zagon window(s), have $(build/windows)"; return 1
}
shot() { screencapture -x "$shots/launch-$1.png" || echo "screencapture failed: $1"; }
in20() { perl -e 'alarm 20; exec @ARGV' "$@"; }  # an Apple Events permission prompt would wait forever

open "$app"
wait_windows 1
shot first
# opened again while it runs: still one window, in front
open "$app"
sleep 3
wait_windows 1
# the window closed by the user, then Zagon opened again: the window comes back. Closing needs accessibility for
# System Events; where the runner does not allow it, this part is skipped.
if in20 osascript -e 'tell application "System Events" to tell process "Zagon" to click button 1 of window 1' 2>/dev/null \
    && wait_windows 0; then
  open "$app"
  wait_windows 1
  shot reopen
  echo "reopen: ok"
else
  echo "reopen: skipped (no accessibility for System Events)"
fi
kill "$(pgrep -x Zagon)"

# the DMG in Finder: the app's icon, the volume's icon flag
mnt=$PWD/build/mnt
hdiutil attach build/Zagon.dmg -nobrowse -noautoopen -mountpoint "$mnt" >/dev/null
echo "volume attributes (C = custom icon): $("$(xcrun --find GetFileInfo)" -a "$mnt" 2>&1 || true)"
open "$mnt"
sleep 3
shot dmg
hdiutil detach -force "$mnt" >/dev/null
echo "launch check: ok"
