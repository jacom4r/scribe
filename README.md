# Scribe

A macOS menu bar app that records meetings: all system audio plus the default
microphone, saved as one stereo WAV (left = mic, right = system) in
`~/Music/Scribe/`. Fully local. Transcription and diarization are planned as
phase 2.

Requires macOS 14.2 or later.

## Build and run

```bash
scripts/make-dev-cert.sh   # once: self-signed "Scribe Dev" signing identity
scripts/bundle.sh          # build release, assemble build/Scribe.app, sign, launch
scripts/bundle.sh debug    # same, debug build
```

Always launch from `build/Scribe.app`. The bare binary in `.build/` has no
bundle, so permissions and notifications will not work.

## Test

```bash
scripts/test.sh             # unit tests (no audio hardware needed)
```

On a Command Line Tools-only install, `swift test` cannot find
Testing.framework; the wrapper adds the search path and rpath and forwards
any arguments, e.g. `scripts/test.sh --filter DownmixTests`.

See `docs/smoke-test.md` for the manual checks that cover actual capture.

## Command line

```bash
swift build
.build/debug/scribe-cli tap                    # create a system audio tap, print its format
.build/debug/scribe-cli devices                # build the mic + tap aggregate, print its layout
.build/debug/scribe-cli record 10 /tmp         # record 10 s to /tmp
```

## Layout

- `Sources/ScribeCore` capture pipeline and recording state machine, no UI
- `Sources/Scribe` SwiftUI menu bar app
- `Sources/scribe-cli` headless recorder for spikes and smoke tests
- `docs/superpowers/specs` design docs
