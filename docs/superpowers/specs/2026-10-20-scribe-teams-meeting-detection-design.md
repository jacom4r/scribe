# Scribe: Teams Meeting Detection

**Date:** 2026-10-20
**Status:** Draft design, pending user approval (builder check done)

## Goal

The user regularly realizes a few minutes into a Teams meeting that they never
pressed Start Recording. Scribe should notice the meeting and ask, so the
recording starts within seconds instead of minutes, and should stop the
recording on its own when the meeting ends unless told otherwise.

Success: on a normal meeting the user gets a notification on the waiting-room
screen, presses Start Recording on it, and never touches Scribe again; the
recording stops and transcribes about 15 s after they leave.

## Non-goals

- Any meeting platform other than the Microsoft Teams desktop app
  (`com.microsoft.teams2`). No Zoom, Meet, Slack, FaceTime, and no Teams in a
  browser.
- Starting a recording without the user's say-so.
- Telling meetings apart (titles, attendees, calendar lookups).
- Naming the recording after the meeting.

## Anti-goals

- **A recording that starts by itself.** If the user ignores the start
  notification, nothing records. Ever.
- **Losing the end of a meeting.** Mute, an AirPods switch, or Teams briefly
  dropping the mic must not end a recording early. The 15 s grace window is the
  safety net.
- **Nagging.** At most one start notification per Teams mic-on stretch; no
  start notification while already recording.

## Decisions already made

| Decision | Choice | Source |
|---|---|---|
| Scope | Teams desktop app only | User |
| Start | Notification with a **Start Recording** button; ignoring it does nothing | User |
| Start timing | As soon as Teams uses the mic, which is the waiting room | User (preferred waiting room; spike confirmed it's available) |
| Stop | Automatic by default, after a **15 s** countdown, with a **Continue Recording** button on the notification | User |
| Signal | A process whose bundle ID starts with `com.microsoft.teams2` has `kAudioProcessPropertyIsRunningInput == 1` | Spike `docs/superpowers/spikes/2026-10-20-teams-mic-detection-spike.md` |
| Mute | Not a special case: Teams keeps the mic open while muted | Spike |

## What the spike established

- `com.microsoft.teams2.modulehost` holds the mic from the waiting room until
  about 2 s after leaving. Joining, muting, and switching to AirPods do not
  interrupt it.
- Teams' WebView helper (`com.microsoft.teams2.helper`) plays join/leave sounds
  and chat media with input off; in one run it also held input for 2 s. Matching
  on the bundle ID prefix covers both.
- One run showed a 5 s mic-on blip that was not a meeting. Short on/off
  sequences are normal input.
- Reading Core Audio process objects needs no permission.

## Behaviour

"Teams mic on" means at least one matching process reports input running.

### Teams mic turns on

- **Not recording:** post the start notification (title "Teams meeting
  detected", body "Start recording?", action **Start Recording**). Pressing it
  starts a recording exactly as the menu's Start Recording does. The recording
  is **armed** for auto-stop.
- **Already recording** (started by hand or from a notification): no
  notification. The recording becomes armed.
- **During a stop countdown:** cancel the countdown, remove its notification,
  keep recording. No new notification. (Covers Teams dropping and re-taking the
  mic, and a quick rejoin.)

### Teams mic turns off

- **An unanswered start notification is still showing:** remove it at once,
  so the user can't start recording a meeting that is already over. If Teams
  takes the mic again, a fresh start notification is posted. *(Design call:
  no delay before removal; a blip costs at most one re-posted notification.)*
- **Recording and armed:** start a 15 s countdown and post the stop
  notification (title "Teams meeting ended", body "Stopping the recording in
  15 s", action **Continue Recording**). The menu shows the countdown (see
  below).
  - Countdown reaches zero: stop exactly as the menu's Stop Recording does
    (saved notification, transcription), remove the stop notification.
  - **Continue Recording** pressed (notification or menu): cancel the
    countdown. The recording is disarmed and runs until the user stops it. If
    Teams takes the mic again later in the same recording, it re-arms.
- **Recording but not armed** (Teams never used the mic during it): nothing.

### Other paths

- The user stops the recording by hand during a countdown: the countdown is
  cancelled and its notification removed; normal stop behaviour.
- The recording is interrupted (no input device) during a countdown: same
  cancel; the existing interruption path runs.
- Quit during a countdown: existing quit behaviour (finalize the recording).
- Scribe launches while Teams already holds the mic (e.g. launch at login
  mid-meeting): treated as a mic-on event, so the start notification appears.
- Pressing Start Recording on the notification when a recording is already
  running (the user started one by hand in the meantime): no-op.
- **Start Recording only works while Teams holds the mic** *(design call)*.
  A press that arrives when the detector believes Teams' mic is off is
  ignored. This covers a stale notification left in Notification Center
  after Scribe quit: tapping it relaunches Scribe, and AppState holds the
  response until the monitor's first reading, then applies this rule. At
  launch Scribe also removes any delivered meeting notifications left from a
  previous run before acting on the first reading.
- Starting from the notification fails: same error handling as the menu
  (`lastError` in the menu) plus a "Recording didn't start" notification with
  the error's `userMessage`, since the user isn't looking at the menu.
- Clicking a notification's body (not its button) does nothing.

### Menu

During a countdown the menu shows, below the timer:

```
Teams meeting ended. Stopping in 12 s
Continue Recording
```

The countdown line ticks with the existing 1 s timer.

There is no on/off switch for detection in this version.

There is no menu entry for a detected-but-unstarted meeting *(design call)*:
the menu's own Start Recording already covers it, because a recording
started by hand while Teams holds the mic is armed for auto-stop.

If the user has denied Scribe notifications, the start prompt never appears
and the stop countdown runs silently (still visible in the menu). This goes
in the smoke test's Known gaps; Scribe does not detect or report the denial.

## Architecture

The repo's pattern holds: decision logic in `ScribeCore` with hardware-free
tests, Core Audio access behind a small type, app wiring in `Sources/Scribe`.

```
Sources/ScribeCore
  TeamsMicMonitor.swift      reads Core Audio process objects; reports Teams mic on/off changes
  MeetingDetector.swift      pure state machine: events in, effects out
  ScribeError.swift          (unchanged unless the builder needs a case)

Sources/Scribe
  AppState.swift             owns monitor + detector, performs effects, countdown timer
  Notifier.swift             categories with actions, notification delegate, remove-by-id
  MenuView.swift             countdown line + Continue Recording
  AppDelegate.swift          sets the notification delegate early enough to receive launch-time responses
```

### MeetingDetector

A value type or class with no Core Audio, notification, or timer code. Inputs
(names are the builder's call):

- Teams mic changed (on/off)
- recording started / stopped (any cause)
- start pressed, continue pressed
- countdown elapsed

Outputs are effects AppState performs: post or remove the start
notification, post or remove the stop notification, start recording, start or
cancel the countdown, stop recording. Every row in **Behaviour** becomes a
unit test.

The countdown's clock lives in AppState (a `Timer` on the main run loop in
`.common` mode, like the elapsed timer); the detector only receives "countdown
elapsed". This keeps tests free of real time.

### TeamsMicMonitor

Enumerates `kAudioHardwarePropertyProcessObjectList`, reads each object's
bundle ID and `kAudioProcessPropertyIsRunningInput`, and reports a single
boolean whenever it changes. Polling once a second on a background queue is
acceptable and is what the spike validated; Core Audio property listeners on
the process list and each process's input flag are also acceptable if the
builder prefers. Either way it reports only changes, delivers them on the main
actor, and reports the initial state once at start.

Scribe's own process uses input while recording; it never matches the Teams
prefix, so no self-filtering is needed.

### Notifications

`Notifier` registers two categories at launch, each with one action:
"meeting-start" → Start Recording, "meeting-end" → Continue Recording. Both
use fixed request identifiers so they can be removed with
`removeDeliveredNotifications(withIdentifiers:)` /
`removePendingNotificationRequests(withIdentifiers:)`. A
`UNUserNotificationCenterDelegate` routes action responses to AppState and
returns `.banner` from `willPresent` so notifications show even if Scribe is
frontmost.

macOS shows a banner's action button on hover and dismisses the banner after
a few seconds. The smoke test tells the user to set Scribe's notification
style to **Persistent** in System Settings → Notifications so the start
prompt stays up during the waiting room. (Builder's call to also mention it
in the README.)

## Testing

- Unit tests for `MeetingDetector` covering every row of **Behaviour**,
  including: blip during countdown cancels it; continue then Teams mic on
  re-arms; manual stop during countdown cancels; mic off with a pending start
  notification removes it; no start notification while recording.
- `TeamsMicMonitor` and notification wiring are covered by the manual smoke
  test (new "Teams meeting detection" section in `docs/smoke-test.md`):
  1. Waiting room → start notification within ~2 s. Ignore it, back out →
     notification disappears, nothing recorded.
  2. Waiting room → Start Recording on the notification → join → AirPods →
     mute/unmute → leave → stop notification and menu countdown → stops at
     15 s, transcript arrives.
  3. Leave, press Continue Recording → recording keeps going; stop by hand.
  4. Leave and rejoin within 15 s → countdown cancels, recording continues.
  5. Start recording by hand, then join a Teams meeting, then leave → no start
     notification; countdown and auto-stop happen.
  6. Record by hand with Teams closed → stop is never automatic.

## Left to the builder

- Type and event names, polling vs listeners, file split within the targets
  above.
- Exact notification copy, as long as it says what happens and when.
- Whether AppState's countdown shares the elapsed timer or has its own.
