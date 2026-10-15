# How Ensemble keeps time

Ensemble plays a Mac's sound on several speakers and on a second Mac so that you hear one sound, not
an echo, and so that video still matches it. This is what we tried, what we kept, and the numbers
behind each choice. All numbers were measured on two MacBook Pros, a Bluetooth speaker (Tribit) and an
LG display, with the tools in `Sources/EnsembleLab` (`swift run ensemble-lab`).

## Results

| | measured |
|---|---|
| From an app's sound to every speaker, built-in + display + other Mac | 0.16 s |
| Same, with a Bluetooth speaker ticked (the speaker alone takes 0.28 s) | 0.28 s |
| The two Macs, after a microphone tune | within 0.5 to 2 ms where you tune |
| Video against the sound, Bluetooth speaker ticked | in sync (the picture waits) |
| CPU while sharing and idle | about 0.3 % |

For comparison, AirPlay buffers about 2 seconds, and Snapcast's default end-to-end buffer is 1 second.

## 1. Capture every app: our own sound device, not a process tap

While a Mac shares, apps play to Ensemble's sound device (an Audio Server plug-in in `Driver/`), which
writes the sound to memory it shares with Ensemble under a random name only Ensemble is told. From an
app's sound to Ensemble's timeline takes about 8 ms. Our first device also had a hidden input twin that
Ensemble read: macOS showed the microphone indicator whenever music played, and sharing asked for the
microphone. The first version captured with a Core Audio process tap on every
app, which needed no install but took 69 ms (85 ms before we cut the buffers to 128 frames) and a
"record this Mac's sound" permission. The device is needed for video sync anyway (section 5), so it now
does both, and the tap is gone.

The device's clock is the host clock, so Ensemble follows it on the main output's clock with the same
resampler as the other outputs (section 2). Each frame in the device carries the sample time it was written for, and a read returns a frame only
if that time matches, else silence: a late or missing frame is never replaced by one from a lap
before. The capture runs all the time while a Mac shares, with sleep still allowed. We tried starting
it only when an app plays: it lost about 0.46 s at the start of every sound after a quiet spell. With
the capture running, an app that starts 0.15 s before its first sound keeps it.

## 2. Several outputs on one Mac: not one aggregate device

The obvious way, and the one macOS's Multi-Output Device and most apps use, is one aggregate device that
holds every output. We built that first. It hides a delay: to keep the others aligned, the aggregate holds
back its main output, by about 95 ms with the Bluetooth speaker added and about 13 ms with the display,
and no property reports it. Any timing built on top (the second Mac, video) was off by that unknown
amount, and changed whenever you ticked a speaker.

What we kept: the aggregate holds only the main output. Every other output runs on its own
device and follows the main output's clock through a resampler (a PI loop that trims the playback rate).
With the Bluetooth speaker ticked, the other Mac now measured 13.8 ms off before the tune and is aligned
after it; unticked, -0.1 ms.

The slowest output sets the shared delay: a Bluetooth speaker reports 112 ms but takes 279 ms, so
Ensemble measures what it can and lets you tune the rest with the microphone.

## 3. The second Mac: our own link, not AirPlay

The first version sent the sound to the other Mac over AirPlay 2. AirPlay's fixed buffer of about 2 s
makes video unwatchable, so Ensemble runs on both Macs and streams over its own link: UDP, encrypted
with ChaCha20-Poly1305 under a key the two Macs agree when you pair, with the clocks kept in step.

Wi-Fi was the hard part. While the direct Mac-to-Mac link (AWDL) is active, the radio visits another
channel every 512 TU, so the router path stalls about 90 ms twice a second; when Universal Control
rebuilds its link, both paths stall up to 150 ms. We tried a 0.1 s budget: cut-outs. What we kept: every
packet goes on both paths at once and the first copy wins, inside a 0.15 s budget, which held in daily use.
The budget stays even while the other Mac sleeps, so the delay never jumps when it wakes.

## 4. Lining up the two Macs: one microphone

Each Mac's speakers have their own hidden delay, so Ensemble measures what you hear: one microphone, on
the Mac where you click, times both Macs as heard there (as Apple TV's audio sync does with an iPhone).
The tune uses the microphone only on the Mac where you click. Residual error after a tune: 0.5 to 0.6 ms; a 20 ms offset
set on purpose was measured as 19.9 ms. Moving the microphone 35 cm changes the answer by about 2 ms,
which is the speed of sound, so the last tune sets where the two Macs align.

## 5. Video in sync: a sound device that tells the truth

Every speaker now plays 0.16 to 0.28 s after the app, so video would run ahead. Video players hold the
picture back by the latency the output device reports, so Ensemble installs its own sound device (an
Audio Server plug-in in `Driver/`). While a Mac shares, apps play to it, and it reports the whole delay,
capture path included (8 ms measured), as its latency. Players then wait for the sound on their own:
video stayed lip-synced with the Bluetooth speaker ticked. The device exists only while
Ensemble asks for it and goes when Ensemble quits.

## 6. Which Mac shares: the newest music, not any sound

Like AirPods, the Mac where music or a video starts takes over, and the other Mac pauses its own. Our
first signal was "an app is playing sound" from Core Audio, but a paused browser tab keeps its output
open and plays silence, so two Macs paused each other. A level meter on the sound fixed that, but it
waited 2 s and needed a recording permission. What we kept: macOS's Now Playing, the same state
Control Center shows. A notification sound or a game is not media, so it does not take over. Since
macOS 15.4 only Apple-signed programs may read Now Playing, so Ensemble reads it through a small
script run by macOS's own `osascript`. The pause is sent with a reply: a command sent without one
reached whichever app was now playing when it arrived, about 350 ms later, which was sometimes
Ensemble itself.

## Not done, and why

- Adaptive delay (shrink the 0.15 s budget when Wi-Fi is calm): the worst lateness we logged in 45
  minutes was 78 ms, but Universal Control stalls reach 150 ms. A day of logs decides whether it is
  worth a rare cut-out.
- AirPlay speakers as outputs: their 2 s buffer would hold every other speaker and the video back.
  Ideas welcome in the issues.
