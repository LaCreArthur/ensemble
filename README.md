<p align="center"><img src="docs/icon.png" width="128" alt="Ensemble icon"></p>
<h1 align="center">Ensemble</h1>

<p align="center">
  <b>All your speakers and your other Mac, as one. Video stays lip-synced.</b><br>
  Built-in speakers, Bluetooth, displays, a second Mac: one sound, one volume, from the menu bar.<br>
  Free and open source. No account, no tracking.
</p>

<p align="center">
  <a href="https://github.com/LaCreArthur/ensemble/releases/latest/download/Ensemble.dmg"><img src="https://img.shields.io/badge/Download_for_macOS-0A84FF?style=for-the-badge&logo=apple&logoColor=white" alt="Download for macOS" height="40"></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white" alt="macOS 26 or later">
  <img src="https://img.shields.io/badge/Apple_silicon_and_Intel-universal-3a3a3c" alt="Universal app">
  <img src="https://img.shields.io/badge/notarized-Developer_ID-3a3a3c" alt="Notarized by Apple">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-30D49B" alt="MIT license"></a>
</p>

## Why Ensemble

- **Video stays lip-synced**, even with Bluetooth speakers.
- **Your other Mac plays along**, at the same moment, with its media keys.
- **One volume**: the keys on either Mac move every speaker.
- **0.16 s** from app to every speaker (AirPlay: about 2 s). Both Macs within 2 ms. [How](docs/DESIGN.md)
- **Free, open source**, notarized.

## How it compares

| | Ensemble | macOS Multi-Output | [Tutti](https://github.com/BarryBarrywu/tutti) | [FineTune](https://github.com/ronitsingh10/FineTune) | [Airfoil](https://rogueamoeba.com/airfoil/mac/) |
|---|---|---|---|---|---|
| Price | Free | Free | Free, Pro $7.99 | Free | Paid |
| Open source | ✅ | ❌ | ❌ | ✅ | ❌ |
| Several speakers on one Mac | ✅ | ✅ | ✅ | ✅ | ✅ |
| Your other Mac plays along | ✅ | ❌ | ❌ | ❌ | ✅ |
| Video in sync, in any player | ✅ | ? | ? | ? | ? |
| Volume keys move every speaker | ✅ | ❌ | ✅ | ❌ | ? |
| AirPlay, Sonos, phones | ❌ | ? | ❌ | ❌ | ✅ |
| Per-app volume and EQ | ❌ | ❌ | ✅ | ✅ | ? |

? = not measured yet. Need AirPlay or Sonos: Airfoil. Volume and EQ per app: FineTune, Tutti.

## Install

1. Download [Ensemble.dmg](../../releases/latest/download/Ensemble.dmg) and drag it to Applications. Needs macOS 26.
2. Open it: a short guide sets it up. For a second Mac on the same network, install it there too and pair.

## Privacy

Sound goes only to the Mac you paired, on your network, encrypted. The microphone is used only to
tune. Once a day the app checks GitHub for a new version. Nothing else leaves your Mac.

## Uninstall

Delete Ensemble from Applications, then remove its sound device:

```sh
sudo rm -rf /Library/Audio/Plug-Ins/HAL/EnsembleDevice.driver && sudo killall coreaudiod
```

## Build and contribute

`swift build` with Xcode 26. [How it works](docs/DESIGN.md), [CONTRIBUTING.md](CONTRIBUTING.md), and
the most useful help of all: a [setup report](../../issues/new?template=setup_report.yml) from your Macs
and speakers.

## License

MIT
