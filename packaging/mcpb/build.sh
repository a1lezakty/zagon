#!/bin/bash
# MCPB bundles of `zagon mcp` (one-click MCP extensions, e.g. for Claude Desktop) and server.json for the MCP Registry,
# from the release files: zagon-mcp-macos.mcpb (the universal CLI), zagon-mcp-linux-x86_64.mcpb,
# zagon-mcp-linux-aarch64.mcpb, server.json (the macOS bundle with its sha256). Needs jq, zip, unzip, and an x86_64
# Linux host: the tools list is asked from zagon-linux-x86_64 itself, so it always matches the release.
# Usage: packaging/mcpb/build.sh <dir with the release files> <version>
set -euo pipefail
dir=$(cd "$1" && pwd); version=$2
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)

# initialize + tools/list against an empty data dir; the answer must carry this version.
mkdir -p "$work/home"
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"mcpb-build","version":"0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' |
  HOME=$work/home ZAGON_DIR=$work/home/.zagon "$dir/zagon-linux-x86_64" mcp --no-scan > "$work/answers"
jq -se --arg v "$version" '.[0].result.serverInfo.version == $v' "$work/answers" > /dev/null ||
  { echo "build.sh: zagon mcp does not answer with version $version" >&2; exit 1; }
tools=$(jq -sc '[.[1].result.tools[] | {name, description}]' "$work/answers")
[ "$(jq length <<< "$tools")" -gt 0 ] || { echo "build.sh: zagon mcp lists no tools" >&2; exit 1; }

for p in macos/zagon-macos-universal/darwin linux-x86_64/zagon-linux-x86_64/linux linux-aarch64/zagon-linux-aarch64/linux; do
  IFS=/ read -r name bin os <<< "$p"
  s=$work/$name; out=$dir/zagon-mcp-$name.mcpb
  mkdir -p "$s/server"
  install -m 755 "$dir/$bin" "$s/server/zagon"
  jq --arg v "$version" --arg os "$os" --argjson tools "$tools" \
    '.version = $v | .compatibility.platforms = [$os] | .tools = $tools' "$here/manifest.json" > "$s/manifest.json"
  (cd "$s" && zip -q -X -r "$work/$name.mcpb" manifest.json server) && mv -f "$work/$name.mcpb" "$out"
  # The bundle: exactly the manifest and an executable server/zagon, the one the manifest starts.
  [ "$(unzip -Z1 "$out" | sort | tr '\n' ' ')" = "manifest.json server/ server/zagon " ] &&
    [[ $(unzip -Z "$out" server/zagon) == -rwxr-xr-x* ]] &&
    unzip -p "$out" manifest.json | jq -e --arg v "$version" --arg os "$os" '.manifest_version == "0.3" and .version == $v
      and .server.type == "binary" and .server.entry_point == "server/zagon"
      and .server.mcp_config.command == "${__dirname}/server/zagon" and .server.mcp_config.args == ["mcp"]
      and .compatibility.platforms == [$os] and (.tools | length > 0)' > /dev/null ||
    { echo "build.sh: $out is not a valid bundle" >&2; exit 1; }
  echo "$out: $(jq length <<< "$tools") tools, $os"
done

sha=$(sha256sum "$dir/zagon-mcp-macos.mcpb" | cut -d' ' -f1)
jq --arg v "$version" --arg sha "$sha" \
  '.version = $v | .packages[0].identifier = "https://github.com/a1lezakty/zagon/releases/download/v\($v)/zagon-mcp-macos.mcpb"
   | .packages[0].fileSha256 = $sha' "$here/server.json" > "$dir/server.json"
echo "$dir/server.json: $version, zagon-mcp-macos.mcpb $sha"
