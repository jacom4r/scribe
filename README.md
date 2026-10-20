# Scribe

A macOS menu bar app that records meetings: all system audio plus the default
microphone, saved as one stereo WAV (left = mic, right = system) in
`~/Music/Scribe/`. Fully local. When a recording stops, Scribe transcribes it
on-device (Parakeet TDT v2 via FluidAudio, with speaker diarization on the
system-audio channel) and writes `<same name>.md` next to the WAV: your mic
is `Me`, everyone else is `Speaker N`. Speech models (about 470 MB) download
once on first launch to `~/Library/Application Support/FluidAudio/Models/`.

When Microsoft Teams starts using the microphone, Scribe posts a "Start
Recording" notification; it never starts on its own. When Teams stops, a
recording that Teams was part of stops after a 15 s countdown unless you press
"Continue Recording". Set Scribe's alert style to Persistent in System Settings
→ Notifications so the start prompt stays up while you wait to join.

Requires macOS 14.2 or later on an Apple silicon Mac.

## Install

1. Accept the GitHub invite to this repo, then download the latest
   `Scribe-<version>.zip` from the
   [Releases page](https://github.com/jacom4r/scribe/releases) while signed in.
2. Double-click the zip and drag `Scribe.app` into Applications.
3. Open Scribe. macOS says it cannot verify the developer, because Scribe is
   not signed with a paid Apple certificate. Click Done, then go to System
   Settings → Privacy & Security, scroll to "Scribe was blocked", click
   Open Anyway, and confirm. You only do this once per version.
4. Scribe appears in the menu bar, not the Dock. Allow microphone, system
   audio recording, and notifications when asked. The speech models
   download in the background the first time.

To update, quit Scribe from its menu, replace `Scribe.app` in Applications
with the new one, and repeat step 3 if macOS asks.

## Build and run

```bash
scripts/make-dev-cert.sh   # once: self-signed "Scribe Dev" signing identity
scripts/bundle.sh          # build release, assemble build/Scribe.app, sign, launch
scripts/bundle.sh debug    # same, debug build
```

Always launch from `build/Scribe.app`. The bare binary in `.build/` has no
bundle, so permissions and notifications will not work.

The first `swift build` fetches FluidAudio and takes several minutes.

## Test

```bash
scripts/test.sh             # unit tests (no audio hardware needed)
```

On a Command Line Tools-only install, `swift test` cannot find
Testing.framework; the wrapper adds the search path and rpath and forwards
any arguments, e.g. `scripts/test.sh --filter DownmixTests`.

See `docs/smoke-test.md` for the manual checks that cover actual capture.

## Release

```bash
scripts/release.sh          # build, zip, and publish v<version> to GitHub Releases
scripts/release.sh --draft  # same, as a draft you publish from the web
```

Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in
`Resources/Info.plist` and commit first; the script refuses a dirty tree or a
version that is already released. Releases are signed with the "Scribe Dev"
identity so users' audio permissions survive updates.

## Command line

```bash
swift build
.build/debug/scribe-cli tap                    # create a system audio tap, print its format
.build/debug/scribe-cli devices                # build the mic + tap aggregate, print its layout
.build/debug/scribe-cli record 10 /tmp         # record 10 s to /tmp
.build/debug/scribe-cli transcribe path/to/recording.wav   # write recording.md next to it
```

## Layout

- `Sources/ScribeCore` capture pipeline, recording state machine, transcription pipeline and queue; no UI, no ML dependency
- `Sources/ScribeTranscription` the FluidAudio adapter, the only target that imports it
- `Sources/Scribe` SwiftUI menu bar app
- `Sources/scribe-cli` headless recorder for spikes and smoke tests
- `docs/superpowers/specs` design docs
