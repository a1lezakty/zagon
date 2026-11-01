#!/bin/bash
# Formula/zagon.rb and Casks/zagon.rb for the tap, from the templates here and a release's SHA256SUMS.
# Usage: packaging/homebrew/render.sh <version> <SHA256SUMS> <out dir>
set -euo pipefail
version=$1; sums=$2; out=$3
here=$(dirname "$0")
mkdir -p "$out/Formula" "$out/Casks"
# @SHA256:<file>@ → the file's sum; a file missing from SHA256SUMS leaves its field, and the check below fails.
script=$(awk '{ n = $2; sub(/^\*/, "", n); gsub(/[.]/, "\\.", n); printf "s/@SHA256:%s@/%s/g;", n, $1 }' "$sums")
sed -e "$script" -e "s/@VERSION@/$version/g" "$here/zagon.rb" > "$out/Formula/zagon.rb"
sed -e "$script" -e "s/@VERSION@/$version/g" "$here/zagon-cask.rb" > "$out/Casks/zagon.rb"
if grep -nE '@(VERSION|SHA256:[^@]*)@' "$out/Formula/zagon.rb" "$out/Casks/zagon.rb"; then
  echo "render.sh: fields left unfilled (a file missing from $sums?)" >&2; exit 1
fi
