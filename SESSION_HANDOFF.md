# Session handoff (2026-10-12, Ensemble, ex Duet)

Playbook: ~/workspace/harness/memory/duet/ (test rig, network findings, audio findings, decisions, test safety).

## Now
- Ensemble runs on both Macs (A shares on built-in + LG, Tribit Bluetooth speaker available; B receives); all 8 user stories verified; master pushed.
- Bluetooth (ab8ee3a): every output but the main one plays on its own device, because the HAL aggregate hid a delay on the main output (95 ms with the Tribit). Verified by A's tune: B read 13.8 ms with the Tribit ticked (old LG offset, corrected), then -0.1 ms unticked. Trims now A 0, B 12.3 ms; Tribit lag 168 ms (takes 0.28 s); delay 0.28 s with it, 0.16 s without.
- B still runs the 21:50 build (old engine). It interoperates (protocol unchanged) and plays on its built-in only, so nothing is wrong there; install ab8ee3a when Remote Login is on, after reading B's stored `lags` (their meaning changed: now "after the device's reported latency").
- Tune across Macs works from both Macs (verified before the Bluetooth change; the last tune wins).
- Arthur on the 0.15 s budget: "very good, i barely see the lag on a youtube video". No adaptive delay.
- Not verified live: the first-use guide on an unpaired Mac (checked as off-screen renders), the Local Network denied state (PolicyDenied per Apple, never seen), Macs without Universal Control (AWDL may stall the router route), LG tune strength 8 to 9 (at the threshold), concealment right after a stream start.

## Next
1. When Arthur has the paid Apple developer account: Developer ID signing, hardened runtime, notarize and staple, a DMG or zip, a download page, an update path.
2. Release test on another pair of Macs: fresh unpaired install (guide live), deny Local Network once, stream health without Universal Control.
3. If cut-outs show there: compare router-only with both routes before touching the 0.15 s budget.

## Do not redo
- One aggregate for several outputs: it delays the main output by an amount no property shows.
- Ids stay "duet" (bundle id, Bonjour types, Keychain service, repo). Router channel fix: the Livebox is not ours.
- Two-route send, one-microphone tune, one Volume slider; the AirPlay link and web remote are deleted.

Default effort for the next task: medium (high if cut-outs show on the second pair).

## Open questions
- Which second pair of Macs (ideally without Universal Control) can host the release test?
