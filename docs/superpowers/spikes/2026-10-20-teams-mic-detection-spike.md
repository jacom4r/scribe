# Spike: can Scribe tell when a Teams meeting starts and ends?

**Date:** 2026-10-20 · **Machine:** Apple M5 Pro, macOS 26.6.2, Swift 6.3.2 CLT · **Teams:** new Teams, `com.microsoft.teams2` 26261.303.5165.1465 · **Status:** answered, yes

Throwaway investigation for the meeting-detection design. No repo code was changed. Scratch code and both raw
logs live in
`/private/tmp/claude-502/-Users-jacob-marchionda-Documents-scribe/b711ee2c-5f31-409a-998b-b055e689ffd2/scratchpad/micprobe/`
(`probe.swift`, `log-run1.txt`, `log.txt`).

## The question

Is "a Teams process is using the microphone" a usable meeting signal? Specifically: which process carries it,
does it turn on in the pre-join waiting room, and does it survive muting and an input device change mid-call?

## Method

A standalone Swift executable that polls Core Audio twice a second. For every object in
`kAudioHardwarePropertyProcessObjectList` it reads `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID`,
`kAudioProcessPropertyIsRunningInput` and `kAudioProcessPropertyIsRunningOutput`, and prints a line on every
change. No permission prompt was needed to read these properties. A sanity run with `afplay` showed the output flag
flipping for the `afplay` process.

The user then ran Teams meetings by hand with the probe running.

## Results

### Run 2: the user's normal workflow, with timestamps

| User's time (±few s) | Probe | |
|---|---|---|
| 13:57:10 open waiting room | 13:57:10.2 `com.microsoft.teams2.modulehost` input=true | Mic turns on in the waiting room |
| 13:58:10 put AirPods in | 13:58:05–13:58:12 modulehost output flickers; input stays true | Device change does not drop input |
| 13:58:30 join | 13:58:31–13:58:42 `com.microsoft.teams2.helper` output (join sound); input stays true | Joining changes nothing |
| 13:59:00 leave | 13:59:01.8 modulehost input=false | Off within ~2 s of leaving |

### Run 1: untimed, exploratory

- 13:45:15–13:45:20: modulehost input on for 5.2 s, then off; `com.microsoft.teams2.helper` (WebView) input on for
  2.1 s at the same moment. The user doesn't remember exactly what they did here; most likely the waiting room was
  opened differently or backed out of. The run 2 waiting room held the mic continuously.
- 13:46:04–13:47:41: modulehost input on continuously for 97 s, through a mute/unmute in the middle. **Muting
  does not release the mic**, consistent with Teams' "you're talking while muted" warning.
- Teams' WebView helper played sound several times (join/leave sounds, chat media) with input false throughout.
  Playback alone never sets input.

## Conclusions for the design

1. **Signal:** any process object whose bundle ID starts with `com.microsoft.teams2` reports
   `IsRunningInput == 1`. In practice it is `com.microsoft.teams2.modulehost`; the prefix also covers the WebView
   helper, which held input briefly in run 1.
2. **Start** fires in the waiting room (what the user wanted), within the probe's 0.5 s sampling.
3. **End** fires within about 2 s of leaving.
4. Mute and an AirPods switch do not end it. Teams media playback does not start it.
5. Short blips (run 1's 5 s) happen. A design must tolerate an on→off→on sequence a few seconds apart.
6. Reading the process list needs no TCC permission and costs a handful of property reads per poll.
