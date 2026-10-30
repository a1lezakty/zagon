#!/bin/sh
# Dev wrapper: everything builds and runs inside a persistent Docker container; nothing is installed on the host.
#   scripts/dev.sh build | test [filter] | build-static | crosscheck [YYYY-MM-DD ...] | run <args> | shell | stop
set -eu
NAME=zagon-dev
IMAGE=swift:6.4.1-bookworm
REPO=$(cd "$(dirname "$0")/.." && pwd)
CLAUDE_PROJECTS=${CLAUDE_PROJECTS:-$HOME/.claude/projects}
SDK_URL=https://download.swift.org/swift-6.4.1-release/static-sdk/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz
SDK_SUM=cef5592d7430ed3c5ae1ddda479849c6f5252bd94a5723db1559f984caf38a7c
MUSL=x86_64-swift-linux-musl
# Shared machine: builds of several checkouts take turns on this lock (skipped when the file does not exist).
LOCK=${ZAGON_BUILD_LOCK:-$REPO/../.build.lock}

ensure() {
  if ! docker inspect "$NAME" >/dev/null 2>&1; then
    docker run -d --name "$NAME" --cpus 2 --memory 2g --memory-swap 2g -e TZ=UTC \
      -v "$REPO:/src" -v "$CLAUDE_PROJECTS:/data/claude:ro" -w /src "$IMAGE" sleep infinity >/dev/null
  fi
  [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = true ] || docker start "$NAME" >/dev/null
}
ensure_sdk() {
  docker exec "$NAME" swift sdk list 2>/dev/null | grep -q static-linux ||
    docker exec "$NAME" swift sdk install "$SDK_URL" --checksum "$SDK_SUM"
}
x() { if [ -e "$LOCK" ]; then flock "$LOCK" docker exec -i -w /src "$NAME" "$@"; else docker exec -i -w /src "$NAME" "$@"; fi; }

cmd=${1:-build}; [ $# -gt 0 ] && shift
ensure
case $cmd in
  build) x swift build -c release "$@" ;;
  test) if [ $# -gt 0 ]; then x swift test --filter "$@"; else x swift test; fi ;;
  build-static)
    ensure_sdk
    x swift build -c release --swift-sdk "$MUSL" -Xlinker -s "$@"
    # Size guard: full Foundation (ICU) in the static binary means +45 MB; use FoundationEssentials / libc instead.
    size=$(x sh -c "stat -c %s \"\$(swift build -c release --swift-sdk $MUSL --show-bin-path)/zagon\"")
    echo "static zagon: $size bytes (limit ${MAX_STATIC_BYTES:=20000000})"
    [ "$size" -le "$MAX_STATIC_BYTES" ] || { echo "error: static binary over the limit (Foundation imported?)" >&2; exit 1; } ;;
  run) x swift run -c release zagon "$@" ;;
  crosscheck)
    # zagon (in the container) vs an independent Python count over the same raw files (on the host, read-only).
    x swift build -c release --product zagon >/dev/null
    BIN=$(x swift build -c release --show-bin-path)/zagon; OUT=.build/crosscheck; mkdir -p "$REPO/$OUT"
    DATA=/tmp/zagon-crosscheck-$(date +%s)  # fresh database each run
    x "$BIN" scan --data-dir "$DATA" --claude-dir /data/claude
    [ $# -gt 0 ] || set -- 2026-10-29 2026-10-20
    rc=0
    for d in "$@"; do
      x "$BIN" day "$d" --json --data-dir "$DATA" > "$REPO/$OUT/$d.json"
      TZ=UTC python3 -I "$REPO/scripts/crosscheck.py" --claude-dir "$CLAUDE_PROJECTS" --day "$d" --zagon-json "$REPO/$OUT/$d.json" || rc=1
    done
    x rm -rf "$DATA"  # built from real transcripts: do not leave it behind
    exit $rc ;;
  shell) docker exec -it -w /src "$NAME" bash ;;
  stop) docker stop "$NAME" >/dev/null ;;
  *) echo "usage: $0 build|test [filter]|build-static|crosscheck [day...]|run <args>|shell|stop" >&2; exit 2 ;;
esac
