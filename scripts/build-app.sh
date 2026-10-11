#!/bin/sh
# Builds Ensemble.app (release), signs it with Arthur's development certificate, and installs it in
# /Applications. Usage: scripts/build-app.sh [--no-install]
set -e
cd "$(dirname "$0")/.."
swift build -c release --product Ensemble
app=build/Ensemble.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/Ensemble "$app/Contents/MacOS/Ensemble"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign "${DUET_IDENTITY:-Apple Development: Arthur Scheidel (H7455J5457)}" "$app"
if [ "$1" != "--no-install" ]; then
    pkill -x Ensemble 2>/dev/null || true
    rm -rf /Applications/Ensemble.app
    cp -R "$app" /Applications/Ensemble.app
    echo "Installed /Applications/Ensemble.app"
fi
