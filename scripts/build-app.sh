#!/bin/sh
# Builds Duet.app (release), signs it with Arthur's development certificate, and installs it in
# /Applications. Usage: scripts/build-app.sh [--no-install]
set -e
cd "$(dirname "$0")/.."
swift build -c release --product Duet
app=build/Duet.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/Duet "$app/Contents/MacOS/Duet"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign "${DUET_IDENTITY:-Apple Development: Arthur Scheidel (H7455J5457)}" "$app"
if [ "$1" != "--no-install" ]; then
    pkill -x Duet 2>/dev/null || true
    rm -rf /Applications/Duet.app
    cp -R "$app" /Applications/Duet.app
    echo "Installed /Applications/Duet.app"
fi
