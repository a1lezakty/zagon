#!/bin/bash
# Release files of Zagon.app in build/: Zagon.dmg (manual install), Zagon.zip (the Sparkle update, EdDSA-signed with
# the private key in env SPARKLE_ED_PRIVATE_KEY) and appcast.xml with that one update. macOS only.
# Usage: scripts/release-mac.sh <version> <build>   e.g. 0.1.0 and the CI run number (it must grow from release to release)
set -euo pipefail
cd "$(dirname "$0")/.."
version=${1:-}; build=${2:-}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $build =~ ^[0-9]+$ ]] || { echo "usage: $0 <x.y.z> <build number>" >&2; exit 2; }
[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ] || { echo "SPARKLE_ED_PRIVATE_KEY is not set" >&2; exit 2; }
key=${SPARKLE_ED_PRIVATE_KEY//[$'\r\n\t ']/}
repo=https://github.com/a1lezakty/zagon

scripts/build-app.sh "$version" "$build"
rm -f build/Zagon.zip build/appcast.xml
ditto -c -k --keepParent build/Zagon.app build/Zagon.zip

# sign_update comes with the Sparkle package SwiftPM resolved for the build (the version pinned in Package.swift).
sign=$(find .build/artifacts -path '*/bin/sign_update' -type f | head -1)
[ -n "$sign" ] || { echo "sign_update not found under .build/artifacts" >&2; exit 1; }
signature=$(printf '%s\n' "$key" | "$sign" --ed-key-file - -p build/Zagon.zip)
printf '%s\n' "$key" | "$sign" --verify --ed-key-file - build/Zagon.zip "$signature"
length=$(stat -f %z build/Zagon.zip)

# The signature must also hold for the public key the app ships, or installed copies would refuse the update.
check=$(mktemp -d)/check.swift
cat > "$check" <<'SWIFT'
import CryptoKit
import Foundation
let a = CommandLine.arguments
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: a[1])!)
guard key.isValidSignature(Data(base64Encoded: a[2])!, for: try Data(contentsOf: URL(fileURLWithPath: a[3]))) else {
    print("Zagon.zip signature does not match SUPublicEDKey in Info.plist"); exit(1)
}
SWIFT
swift "$check" "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' build/Zagon.app/Contents/Info.plist)" "$signature" build/Zagon.zip
rm -rf "$(dirname "$check")"

cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Zagon</title>
    <link>$repo</link>
    <item>
      <title>Zagon $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$repo/releases/tag/v$version</sparkle:releaseNotesLink>
      <enclosure url="$repo/releases/download/v$version/Zagon.zip" length="$length" type="application/octet-stream" sparkle:edSignature="$signature"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout build/appcast.xml
echo "release files in build/: Zagon.dmg, Zagon.zip ($length bytes, signed), appcast.xml ($version, $build)"
