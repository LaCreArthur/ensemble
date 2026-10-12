# Ensemble

Ensemble plays your Mac's sound on your other Mac too, in sync. Put two Macs in a room, play music or a
video on one, and hear it from both. It lives in the menu bar.

- Every app's sound, on both Macs at the same time.
- Video stays in sync: players hold the picture back by the same delay as the sound.
- One volume for both Macs: the volume keys on either Mac set it.
- Play, pause and skip tracks from the other Mac's menu or media keys.
- Add more speakers on the sharing Mac (Bluetooth speakers, displays), and tune the sync with the
  microphone.

## Requirements

Two Macs with macOS 26 or later (Apple silicon or Intel), on the same local network.

## Install

1. Download `Ensemble-<version>.dmg` from [Releases](../../releases/latest) and drag Ensemble to
   Applications, on both Macs.
2. Open Ensemble on both Macs. When macOS asks, allow it to find devices on your local network.
3. Click **Pair with …** on one Mac. Both Macs show a code: click **Pair** on each if the codes match.
4. On the Mac whose sound you want on both, turn on **Share this Mac's sound** and play something. When
   macOS asks, allow Ensemble to record this Mac's sound.
5. Click **Install Sound Device…** and type your password. This is what keeps video in sync; the sound
   stops for a second while macOS loads it.

Ensemble opens at login; turn that off in its menu.

## Privacy

The sound and the controls go only to the Mac you paired, on your local network, encrypted with a key
the two Macs made when you paired them (ChaCha20-Poly1305). The key stays in your login keychain. The
microphone is used only while you tune the sync. Once a day Ensemble asks GitHub for its latest version;
it sends nothing else anywhere.

## Uninstall

Quit Ensemble and delete it from Applications. To remove its sound device:

```sh
sudo rm -rf /Library/Audio/Plug-Ins/HAL/EnsembleDevice.driver && sudo killall coreaudiod
```

The pairing is the "Duet pairing" item in Keychain Access.

## How it works

The sharing Mac captures every app's sound with a Core Audio process tap and plays it on its speakers a
fixed delay later, about a quarter of a second. The same frames go to the other Mac over UDP, with clocks
kept in step, so both Macs play each frame at the same moment. Ensemble's sound device (`Driver/`, an
Audio Server plug-in) becomes the Mac's sound output while it shares: it reports that delay as its
latency, so video players hold the picture back to match.

## Build

Needs Xcode 26.

```sh
DUET_IDENTITY="Apple Development: Your Name (TEAMID)" scripts/build-app.sh   # builds and installs in /Applications
scripts/release.sh   # Developer ID signed, notarized DMG in build/
```

`duet-lab` (`swift run duet-lab`) holds the measurement tools used to tune the sync.

## License

MIT
