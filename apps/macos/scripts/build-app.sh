#!/bin/bash
# Build Zagon.app (universal, ad-hoc signed) and Zagon.dmg from the SwiftPM package. macOS only.
# Usage: scripts/build-app.sh [version] [build-number]   → build/Zagon.app, build/Zagon.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
version=${1:-0.1.0}
build=${2:-1}

# One build per architecture, then lipo: `--arch a --arch b` goes through XCBuild, which rejects swiftLanguageMode.
# The rpath finds Sparkle.framework in Contents/Frameworks.
slices=()
for arch in arm64 x86_64; do
  swift build -c release --product Zagon --triple "$arch-apple-macosx13.0" -Xlinker -rpath -Xlinker @executable_path/../Frameworks
  slices+=("$(swift build -c release --triple "$arch-apple-macosx13.0" --show-bin-path)/Zagon")
done

app=build/Zagon.app
rm -rf "$app" build/Zagon.dmg build/rw.dmg build/dmg build/AppIcon.iconset
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create "${slices[@]}" -output "$app/Contents/MacOS/Zagon"
lipo -info "$app/Contents/MacOS/Zagon"

# Sparkle (universal already) next to the build products → Contents/Frameworks. The app is not sandboxed: Sparkle
# installs without its XPC services, so they are left out.
fw=$app/Contents/Frameworks/Sparkle.framework
mkdir -p "$app/Contents/Frameworks"
ditto "$(dirname "${slices[0]}")/Sparkle.framework" "$fw"
rm -rf "$fw/XPCServices" "$fw/Versions/B/XPCServices"

# The CLI the app installs for Claude Code / Codex (hooks, status line, MCP): Contents/Helpers/zagon, universal too.
cli=()
for arch in arm64 x86_64; do
  (cd ../.. && swift build -c release --product zagon --triple "$arch-apple-macosx13.0")
  cli+=("$(cd ../.. && swift build -c release --triple "$arch-apple-macosx13.0" --show-bin-path)/zagon")
done
mkdir -p "$app/Contents/Helpers"
lipo -create "${cli[@]}" -output "$app/Contents/Helpers/zagon"
strip -x "$app/Contents/Helpers/zagon"
codesign --force -s - "$app/Contents/Helpers/zagon"
lipo -info "$app/Contents/Helpers/zagon"
# The app draws its own icon (AppIconView): no image in the repository.
"$app/Contents/MacOS/Zagon" --app-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Zagon</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>dev.zagon.app</string>
  <key>CFBundleName</key><string>Zagon</string>
  <key>CFBundleDisplayName</key><string>Zagon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>https://github.com/a1lezakty/zagon/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>vIO98LBiTe/r01tyS9sF0GoAxcYFD0gUcn8rMKWtzkw=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
# Inside out, no --deep: Sparkle's helpers, the framework, then the app (Sparkle accepts an ad-hoc signed update
# when its EdDSA signature matches SUPublicEDKey).
codesign --force -s - "$fw/Versions/B/Autoupdate"
codesign --force -s - "$fw/Versions/B/Updater.app"
codesign --force -s - "$fw"
codesign --force -s - "$app"
codesign --verify --deep --strict --verbose=2 "$app"

mkdir -p build/dmg
cp -R "$app" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname Zagon -srcfolder build/dmg -ov -format UDRW build/rw.dmg
rm -rf build/dmg
# The volume's icon too, where SetFile (Xcode tools) is around: on the mounted image, as hdiutil does not carry a
# folder's custom-icon flag over to the volume.
if setfile=$(xcrun --find SetFile 2>/dev/null); then
  mnt=$PWD/build/mnt-rw
  hdiutil attach build/rw.dmg -nobrowse -noautoopen -mountpoint "$mnt" >/dev/null
  cp "$app/Contents/Resources/AppIcon.icns" "$mnt/.VolumeIcon.icns"
  "$setfile" -a C "$mnt"
  hdiutil detach "$mnt" >/dev/null
fi
hdiutil convert build/rw.dmg -format UDZO -ov -o build/Zagon.dmg
rm -f build/rw.dmg
echo "built $app and build/Zagon.dmg ($version, $build)"
