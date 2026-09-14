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
9. Start, then switch input devices (unplug headset / switch in Sound settings): recording stops, "Recording stopped" notification explains why, menu shows the message, partial file plays.
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

## Known gaps (phase 1.5)

- Input device hot-swap stops the recording instead of continuing. Top
  priority for phase 1.5: the only complaint after a week of daily use.
- A crash mid-recording leaves a WAV with an unfinished header.
- No global hotkey, no input device picker, no launch at login, no app icon.
- Permission denial cannot be detected at start time on this machine; a
  denied tap records silence on the right channel. Use "Recording
  Permissions…" in the menu.
- The keepalive holds the default output device active for the duration of a
  recording (silent; a small power cost on Bluetooth devices).
