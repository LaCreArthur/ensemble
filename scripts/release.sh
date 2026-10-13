#!/bin/sh
# Builds the release: Ensemble.app signed with Developer ID, in build/Ensemble.dmg, notarized by Apple and
# stapled. The DMG keeps one name for every version, so releases/latest/download/Ensemble.dmg links the
# newest. Needs the Developer ID certificate in the keychain and the notarytool profile "ensemble"
# (xcrun notarytool store-credentials ensemble ...).
# Publish: gh release create v<version> build/Ensemble.dmg
set -e
cd "$(dirname "$0")/.."
DUET_IDENTITY="${DUET_IDENTITY:-Developer ID Application: Arthur Scheidel (P39D6865YD)}"
DUET_IDENTITY="$DUET_IDENTITY" scripts/build-app.sh --no-install
dmg=build/Ensemble.dmg
stage=build/dmg
rm -rf "$stage" "$dmg"
mkdir -p "$stage"
cp -R build/Ensemble.app "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname Ensemble -srcfolder "$stage" -format UDZO -fs APFS "$dmg"
rm -rf "$stage"
codesign --sign "$DUET_IDENTITY" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile ensemble --wait
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
echo "Released $dmg"
