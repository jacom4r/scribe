# Scribe manual smoke test

Run after any change to `ScribeCore` capture code or the app target. Unit
tests do not cover the audio path, so this is the only check that it works.

**Status:** Completed 2026-09-14 against phase 1 (`phase1-recorder`). All
steps passed; the only issue found is the known input-device hot-swap gap
below (stops instead of continuing), confirmed after a week of daily use.

Setup: `scripts/make-dev-cert.sh` once, then `scripts/bundle.sh debug`.

## CLI capture path

1. Play music. Run `.build/debug/scribe-cli record 10 /tmp` and talk into the mic.
2. `afinfo /tmp/*Recording*.wav | grep "Data format"` shows `2 ch, 48000 Hz, Int16`.
3. Open the file: left channel is voice only, right channel is music only.
4. Run `.build/debug/scribe-cli record 10 /tmp` with NOTHING playing. `afinfo`
   must report a duration of about 10 s (before the keepalive fix this
   produced a 0 s file).

## App

5. Start Recording: icon turns red; reopening the menu shows Stop Recording and a ticking timer.
6. Stop Recording: icon returns to the waveform, "Recording saved" notification names the file, file is in `~/Music/Scribe` and plays with voice left / music right.
7. Open Recordings Folder opens `~/Music/Scribe` in Finder.
8. Start, then Quit Scribe: relaunch and confirm the last file plays to the end.
9. Start, then switch input devices (unplug headset / switch in Sound settings): recording continues with no notification, and the microphone line under the timer changes to the new device. See "Input device hot-swap" below for the full checks.
10. Start, then switch the default OUTPUT device (e.g. connect or disconnect
    headphones, or change it in Sound settings) while audio plays: the
    recording must NOT stop, and the system channel must keep capturing after
    the switch (the keepalive restarts on the new output device).

## Permissions

11. Turn Scribe off under System Settings → Privacy & Security → Screen & System Audio Recording, then Start Recording:
    - If tap creation fails: menu shows "Scribe needs System Audio Recording permission." and "Open System Settings…" opens the right pane.
    - If tap creation succeeds anyway (known Core Audio behavior): the right channel is silent. Use "Recording Permissions…" to re-enable. Detecting this at start time is a phase 1.5 item.
12. Turn the permission back on.

- Rebuilds keep their audio permission only when signed with the "Scribe Dev"
  identity. Run `scripts/make-dev-cert.sh` once and answer the keychain
  prompt; until then `scripts/bundle.sh` signs ad-hoc and macOS re-prompts
  after every rebuild.

## Input device hot-swap

13. Play music continuously (start it before Start Recording and leave it
    playing through Stop). Start recording with AirPods connected and set as
    the default input. Speak, then disconnect the AirPods mid-recording so
    macOS falls back to the built-in mic:
    - The recording must NOT stop. The elapsed timer keeps running.
    - The mic name under the timer changes to "MacBook Pro Microphone".
    - Keep speaking for another 10 s, then Stop.
    - Play the file: speech before AND after the swap must be present on the
      left channel, AND the music before AND after the swap must be present on
      the right channel, with a short seam on both channels where the swap
      happened. This is the 24 kHz to 48 kHz path, so listen for pitch or
      speed artifacts on both channels after the swap — there must be none.
14. The reverse: start on the built-in mic, connect AirPods mid-recording,
    confirm the same — music playing throughout from before Start to after
    Stop, and the right channel still carrying it after the swap.
15. Unplug a USB mic mid-recording, confirm the same — music playing
    throughout from before Start to after Stop, and the right channel still
    carrying it after the swap.
16. For each of the above, note how long the audible seam is on BOTH channels.
    That number is the input to any later decision about padding the gap or
    switching to live sub-device mutation.
17. Start recording, then disconnect the ONLY input device so no replacement
    exists. The recording must stop and save, with the "No microphone is
    available, so the recording was stopped." notification — the phase 1
    behavior.

## Known gaps (phase 1.5)

- An input device swap drops a short window of audio on both channels while the
  aggregate is rebuilt, so a recording with swaps in it is slightly shorter than
  the elapsed time. Padding this was specced and deliberately dropped; see
  `docs/superpowers/specs/2026-09-14-scribe-input-hotswap-design.md`.
- A crash mid-recording leaves a WAV with an unfinished header.
- No global hotkey, no input device picker, no launch at login, no app icon.
- Permission denial cannot be detected at start time on this machine; a
  denied tap records silence on the right channel. Use "Recording
  Permissions…" in the menu.
- The keepalive holds the default output device active for the duration of a
  recording (silent; a small power cost on Bluetooth devices).
