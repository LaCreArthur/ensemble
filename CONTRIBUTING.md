# Contributing to Ensemble

Ensemble is about timing: sound on several speakers and two Macs, heard as one, with video in step.
Most of it can only be checked on real Macs and real speakers, so the most useful help is a report
from a setup we have not tried.

## Report your setup

Open a [setup report](../../issues/new?template=setup_report.yml), whether it works or not: your Macs,
macOS version, the speakers you ticked, and what you heard and saw. Setups we most want: Intel Macs,
Macs without Universal Control (not signed in to the same Apple Account, or older models), busy Wi-Fi,
AirPods and other Bluetooth speakers, USB and HDMI audio.

## Report a bug

Use the [bug report](../../issues/new?template=bug_report.yml). The app's log helps most:

```sh
/usr/bin/log show --last 10m --predicate 'subsystem == "com.lacrearthur.duet"' > ensemble.log
```

## Change the code

1. Open an issue first for anything bigger than a small fix, so we agree on the design before you
   spend time on it. Each change has to be tested on real Macs, so small and focused is best.
2. Build with Xcode 26 on macOS 26:

   ```sh
   swift build                     # app and tools
   DUET_IDENTITY="Apple Development: Your Name (TEAMID)" scripts/build-app.sh   # signed app in /Applications
   ```

3. Measure what you changed. `swift run duet-lab` holds the tools used to tune the sync (delay of each
   output, capture path, first frame after silence). Put the numbers before and after in the pull request.
4. Match the code around you: plain Swift, no new dependencies, comments that say why.

Ideas that need a hand are labeled [help wanted](../../labels/help%20wanted).

Ids in the code still say "duet" (bundle id, Bonjour types, Keychain item): they keep existing pairings
and permissions working, so they stay.
