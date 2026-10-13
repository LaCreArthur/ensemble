# Session handoff (2026-10-13, Ensemble, ex Duet)

Playbook: ~/workspace/harness/memory/duet/ (test rig, network findings, audio findings, decisions, test safety).

## Now
- v1.0.1 released in the private repo (https://github.com/LaCreArthur/ensemble/releases/tag/v1.0.1; v1.0 had the older guide): universal app, Developer ID signed, hardened runtime, DMG notarized and stapled by `scripts/release.sh`. README and MIT license written for going public.
- The app carries its sound device and installs it with an admin prompt (driver version 2). Arthur installed the notarized download on A, installed the device from the menu: "works".
- Positioning (Arthur): all your speakers on one Mac first, the other Mac optional. Setup guide (opens at first launch, then from "Setup Guide…" in the menu): 1 sound device, 2 play on all your speakers + recording permission, 3 add your other Mac (optional) + local network + pair; each step shows until done; footer: menu bar icon, source link. Seen on A with a test copy whose driver version differs; step 3 open was not seen.
- Menu offers "Get Ensemble x.y…" when GitHub's latest release is newer (404 while the repo is private, so nothing shows).
- Video sync, steady delay and always-running capture as before (872110f, a85224c, dff6275). B runs ab8ee3a, no driver.
- Not verified live: IO after sleep, browsers following a latency change mid-play, the guide on an unpaired Mac, Local Network denied, Macs without Universal Control.

## Next
1. Arthur's go to make the repo public (`gh repo edit LaCreArthur/ensemble --visibility public --accept-visibility-change-consequences`). History holds no secret (checked: only a LAN address default and a deleted key's name).
2. B: install the v1.0 DMG (Arthur downloads it from the release), click Install Sound Device in the menu, check B shares in sync.
3. Release test on another pair of Macs: fresh unpaired install (guide steps 1 to 4), deny Local Network once, stream health without Universal Control, re-measure the capture path (`duet-lab device-path --device Ensemble`).
4. Next release: bump CFBundleShortVersionString and CFBundleVersion by editing the lines (PlistBuddy rewrites the whole file), and the driver's CFBundleVersion if the driver changed; `scripts/release.sh`; `gh release create v<version> build/Ensemble.dmg` (the README's download button links releases/latest/download/Ensemble.dmg).
5. Parked: groups of 3+ Macs (pairing becomes a group key, the sharer streams to every member, the delay covers the slowest). Arthur has no third Mac to test with (2026-10-13); open risk: Wi-Fi load on the 0.15 s budget.

## Do not redo
- One aggregate for several outputs: it delays the main output by an amount no property shows.
- Ids stay "duet" (bundle id, Bonjour types); the pairing keychain service is "Ensemble pairing" since 1.0.2 (test builds wrote "Duet pairing" with another signature, and reading it made the released app ask for the login password); the repo is LaCreArthur/ensemble since 2026-10-13 (GitHub redirects the old name, so v1.0.1 copies still find updates; never create a new repo named duet). Router channel fix: the Livebox is not ours.
- Two-route send, one-microphone tune, one Volume slider; the AirPlay link and web remote are deleted.
- On-demand capture with the device as system output: it loses the start of every sound after a quiet spell.

Default effort for the next task: medium.

## Open questions
- Which second pair of Macs (ideally without Universal Control) can host the release test?
- Public or not, and when (Arthur).
