#!/bin/sh
# Builds build/EnsembleDevice.driver (Ensemble's sound device, an Audio Server plug-in) and signs it.
# The app carries it and installs it on request; build-app.sh runs this.
set -e
cd "$(dirname "$0")/.."
driver=build/EnsembleDevice.driver
rm -rf "$driver"
mkdir -p "$driver/Contents/MacOS"
cp Driver/Info.plist "$driver/Contents/Info.plist"
clang -O2 -Wall -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=14.2 -framework CoreAudio -framework CoreFoundation \
    -o "$driver/Contents/MacOS/EnsembleDevice" Driver/EnsembleDevice.c
codesign --force --options runtime --timestamp --sign "${ENSEMBLE_IDENTITY:-Apple Development: Arthur Scheidel (H7455J5457)}" "$driver"
echo "Built $driver"
