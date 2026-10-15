# How Ensemble keeps time

Ensemble plays a Mac's sound on several speakers and on a second Mac so that you hear one sound, not
an echo, and so that video still matches it. This is what we tried, what we kept, and the numbers
behind each choice. All numbers were measured on two MacBook Pros, a Bluetooth speaker (Tribit) and an
LG display, with the tools in `Sources/DuetLab` (`swift run duet-lab`).

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

While a Mac shares, apps play to Ensemble's sound device (an Audio Server plug-in in `Driver/`), and
Ensemble reads the sound back from a hidden twin of that device on the same clock. From an app's sound
to Ensemble's timeline takes 8.5 ms. The first version captured with a Core Audio process tap on every
app, which needed no install but took 69 ms (85 ms before we cut the buffers to 128 frames) and a
"record this Mac's sound" permission. The device is needed for video sync anyway (section 5), so it now
does both, and the tap is gone.

Each frame in the device carries the sample time it was written for, and a read returns a frame only
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

What we kept: the aggregate holds only the main output and the capture. Every other output runs on its own
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
The other Mac needs no microphone permission. Residual error after a tune: 0.5 to 0.6 ms; a 20 ms offset
set on purpose was measured as 19.9 ms. Moving the microphone 35 cm changes the answer by about 2 ms,
which is the speed of sound, so the last tune sets where the two Macs align.

## 5. Video in sync: a sound device that tells the truth

Every speaker now plays 0.16 to 0.28 s after the app, so video would run ahead. Video players hold the
picture back by the latency the output device reports, so Ensemble installs its own sound device (an
Audio Server plug-in in `Driver/`). While a Mac shares, apps play to it, and it reports the whole delay,
capture path included (8.5 ms measured), as its latency. Players then wait for the sound on their own:
video stayed lip-synced with the Bluetooth speaker ticked. The device exists only while
Ensemble asks for it and goes when Ensemble quits.

## Not done, and why

- Adaptive delay (shrink the budget when Wi-Fi is calm): kept simple for now; the fixed budget works.
- AirPlay speakers as outputs: their 2 s buffer would hold every other speaker and the video back.
  Ideas welcome in the issues.
