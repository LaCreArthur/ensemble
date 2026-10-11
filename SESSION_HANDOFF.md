# Session handoff (2026-10-11, Ensemble, ex Duet)

Playbook: ~/workspace/harness/memory/duet/ (test rig, network findings, decisions, test safety).

## Now
- Ensemble runs on both Macs (A receives on LG + built-in, B shares); all 8 user stories verified; master pushed.
- Tune across Macs works from both Macs: A's mic heard B 0.6 ms late, B's mic heard A 2.0 ms late (Macs about 35 cm apart); a 20 ms offset set on A read 19.9 ms. The last tune wins: aligned at B now (A trim 1.5 ms, B 0).
- Arthur on the 0.15 s budget: "very good, i barely see the lag on a youtube video". No adaptive delay.
- Not verified live: the first-use guide on an unpaired Mac (checked as off-screen renders), the Local Network denied state (PolicyDenied per Apple, never seen), Macs without Universal Control (AWDL may stall the router route), LG tune strength 8 to 9 (at the threshold), concealment right after a stream start.

## Next
1. When Arthur has the paid Apple developer account: Developer ID signing, hardened runtime, notarize and staple, a DMG or zip, a download page, an update path.
2. Release test on another pair of Macs: fresh unpaired install (guide live), deny Local Network once, stream health without Universal Control.
3. If cut-outs show there: compare router-only with both routes before touching the 0.15 s budget.

## Do not redo
- Ids stay "duet" (bundle id, Bonjour types, Keychain service, repo). Router channel fix: the Livebox is not ours.
- Two-route send, one-microphone tune, one Volume slider; the AirPlay link and web remote are deleted.

Default effort for the next task: medium (high if cut-outs show on the second pair).

## Open questions
- Which second pair of Macs (ideally without Universal Control) can host the release test?
