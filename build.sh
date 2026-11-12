#!/bin/zsh
# Builds "Atmos Player.app" into ./build; pass --dmg to also make "Atmos Player.dmg"
set -e
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -target arm64-apple-macosx14.0 -o build/atmosplay Sources/*.swift
APP="build/Atmos Player.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/atmosplay "$APP/Contents/MacOS/Atmos Player"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign -s - --force "$APP"
echo "Built $APP"

# Disk image with a drag-to-Applications layout (only with --dmg)
[[ "$1" == "--dmg" ]] || exit 0
STAGE="build/dmg"
rm -rf "$STAGE" "build/Atmos Player.dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Atmos Player" -srcfolder "$STAGE" -ov -format UDZO "build/Atmos Player.dmg" >/dev/null
rm -rf "$STAGE"
echo "Built build/Atmos Player.dmg"
