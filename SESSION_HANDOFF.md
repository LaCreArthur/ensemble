# Session handoff (2026-10-12, Ensemble, ex Duet)

Playbook: ~/workspace/harness/memory/duet/ (test rig, network findings, audio findings, decisions, test safety).

## Now
- Video sync is live on A (872110f): while A shares, the system output is Ensemble's own sound device (driver in Driver/, installed on A only), which reports capture 0.086 s + delay + speaker latency, so video waits. Arthur: lips "In sync" with the Tribit ticked (0.38 s), volume keys move every speaker.
- Steady delay while paired (a85224c): room for the other Mac stays in the delay (its last lead stored), so the latency does not jump when B sleeps or wakes. A reports 0.25 s without the Tribit.
- Always-running capture (dff6275): while sharing, the tap and the main output run all day with sleeping allowed (no coreaudiod sleep block, 0.3% CPU); other outputs and the stream start within about 15 ms of a sound and stop 5 min after. The engine restarts after a wake or a Core Audio restart.
- B runs ab8ee3a (no driver, no steady delay, old on-demand capture). B was asleep at 09:20 (ssh timed out).
- Not verified live: IO after sleep (restart on wake covers it), the Core Audio restart handler, browsers following a latency change mid-play, the first-use guide on an unpaired Mac, the Local Network denied state, Macs without Universal Control.

## Next
1. B: install the new app and the driver (Arthur types the sudo install on B), then check B shares with video sync and A receives in sync.
2. Arthur runs `sudo killall coreaudiod` once on A while a sound plays: the sound must come back by itself (Core Audio restart handler).
3. When Arthur has the paid Apple developer account: Developer ID signing, hardened runtime, notarize and staple, an in-app driver installer with an admin prompt, a DMG or zip, a download page, an update path.
4. Release test on another pair of Macs: fresh unpaired install, deny Local Network once, stream health without Universal Control, re-measure the capture path (`duet-lab device-path --device Ensemble`).

## Do not redo
- One aggregate for several outputs: it delays the main output by an amount no property shows.
- Ids stay "duet" (bundle id, Bonjour types, Keychain service, repo). Router channel fix: the Livebox is not ours.
- Two-route send, one-microphone tune, one Volume slider; the AirPlay link and web remote are deleted.
- On-demand capture with the device as system output: it loses the start of every sound after a quiet spell.

Default effort for the next task: medium.

## Open questions
- Which second pair of Macs (ideally without Universal Control) can host the release test?
