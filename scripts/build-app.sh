#!/bin/sh
# Builds Ensemble.app (release, Apple silicon and Intel) with its sound device inside, signs it with
# DUET_IDENTITY (default: Arthur's development certificate), and installs it in /Applications.
# Usage: scripts/build-app.sh [--no-install]
set -e
cd "$(dirname "$0")/.."
identity="${DUET_IDENTITY:-Apple Development: Arthur Scheidel (H7455J5457)}"
swift build -c release --product Ensemble --arch arm64 --arch x86_64
DUET_IDENTITY="$identity" scripts/build-driver.sh
app=build/Ensemble.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/apple/Products/Release/Ensemble "$app/Contents/MacOS/Ensemble"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp -R build/EnsembleDevice.driver "$app/Contents/Resources/"
codesign --force --options runtime --timestamp --entitlements Resources/Ensemble.entitlements --sign "$identity" "$app"
if [ "$1" != "--no-install" ]; then
    pkill -x Ensemble 2>/dev/null || true
    rm -rf /Applications/Ensemble.app
    cp -R "$app" /Applications/Ensemble.app
    echo "Installed /Applications/Ensemble.app"
fi
