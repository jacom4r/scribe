# Teams Meeting Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the Teams desktop app starts using the mic, offer to start recording with a notification; when it stops, stop the recording after a 15 s countdown unless the user presses Continue Recording.

**Architecture:** `ScribeCore` gains a Core Audio monitor that reports one boolean ("Teams holds the mic") and a pure `MeetingDetector` state machine that turns events into effects. The app target owns both, performs the effects (notifications, countdown timer, start/stop through the existing paths), and shows the countdown in the menu.

**Tech Stack:** Swift 6, SwiftPM (tools 6.2, no Xcode project), Core Audio process objects (macOS 14.2+), UserNotifications actions, Swift Testing, SwiftUI `MenuBarExtra`.

**Spec:** `docs/superpowers/specs/2026-10-20-scribe-teams-meeting-detection-design.md`. The spike it rests on is `docs/superpowers/spikes/2026-10-20-teams-mic-detection-spike.md`.

## Global Constraints

- **Minimum macOS 14.2.** Dev machine: macOS 26.6.2, Swift 6.3.2, Command Line Tools only.
- **Run tests with `scripts/test.sh`, never bare `swift test`.** It forwards arguments: `scripts/test.sh --filter MeetingDetectorTests`.
- **Swift Testing, not XCTest.** `@Suite`, `@Test`, `#expect`, `#require`.
- **No new package dependencies.**
- **Teams match:** a process object whose bundle ID has the prefix `com.microsoft.teams2` and whose `kAudioProcessPropertyIsRunningInput` is 1.
- **Countdown is 15 s.**
- **Never start a recording without a user press.** No code path may turn a mic-on event straight into a recording; only `startPressed` may.
- **Never touch the user's default audio devices.**
- **Fixed copy (from the spec):**
  - Start notification: title `Teams meeting detected`, body `Start recording?`, action `Start Recording`.
  - Stop notification: title `Teams meeting ended`, body `Stopping the recording in 15 s`, action `Continue Recording`.
  - Start failure notification: title `Recording didn't start`, body = the error's `userMessage`.
  - Menu during countdown: `Teams meeting ended. Stopping in N s`, then a `Continue Recording` button.

## Review Focus

1. **A stale Start Recording tap after a relaunch** (notification left in Notification Center, Scribe relaunched by the tap before the monitor has read anything) must start only if the first reading says Teams holds the mic. Pinned in Task 2 (`startPressedBeforeFirstReading...`).
2. **Start pressed after Teams already released the mic** (the removal raced the user's click) must do nothing. Pinned in Task 2 (`startPressedWhileMicOffIsIgnored`).
3. **Start from the notification fails** (no mic): no `recordingStarted` ever arrives, and a later Teams mic-off must not begin a countdown or emit anything. Pinned in Task 2 (`failedStartLeavesNothingArmed`).
4. **A transient Core Audio read failure mid-meeting** must not look like Teams releasing the mic, or it starts a countdown. Pinned in Task 1 (`failedReadKeepsLastState`).
5. **A manual stop during the countdown followed by Teams mic activity** must leave no stray stop, countdown, or prompt for the stopped recording. Pinned in Task 2 (`manualStopDuringCountdownCancelsIt`, then mic on posts a fresh prompt).

---

## File Structure

**Create:**
- `Sources/ScribeCore/TeamsMicMonitor.swift` — `AudioProcessInfo`, `TeamsMicMonitor`: polls Core Audio once a second, reports Teams-holds-mic changes on the main queue.
- `Sources/ScribeCore/MeetingDetector.swift` — `MeetingDetector` value type: `Event`, `Effect`, `handle(_:)`.
- `Tests/ScribeCoreTests/TeamsMicMonitorTests.swift`, `Tests/ScribeCoreTests/MeetingDetectorTests.swift`.

**Modify:**
- `Sources/ScribeCore/CoreAudioProperties.swift` — process object list, bundle ID, is-running-input.
- `Sources/Scribe/Notifier.swift` — meeting categories and actions, delegate, fixed-id post/remove, start-failure notification.
- `Sources/Scribe/AppState.swift` — owns monitor and detector, performs effects, countdown.
- `Sources/Scribe/MenuView.swift` — countdown line and Continue Recording.
- `docs/smoke-test.md`, `README.md` — new section, Persistent alert style, known gap.

---

### Task 1: Core Audio process reads and `TeamsMicMonitor`

**Files:**
- Modify: `Sources/ScribeCore/CoreAudioProperties.swift`
- Create: `Sources/ScribeCore/TeamsMicMonitor.swift`
- Test: `Tests/ScribeCoreTests/TeamsMicMonitorTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct AudioProcessInfo: Equatable, Sendable {
      public var bundleID: String
      public var isRunningInput: Bool
      public init(bundleID: String, isRunningInput: Bool)
  }

  public final class TeamsMicMonitor: @unchecked Sendable {
      public static let bundlePrefix = "com.microsoft.teams2"
      /// True if any process matches the prefix and is running input.
      public static func teamsHoldsMic(_ processes: [AudioProcessInfo]) -> Bool
      /// Reads Core Audio; nil when the process list can't be read.
      public static func readCoreAudio() -> Bool?
      public init(interval: TimeInterval = 1,
                  read: @escaping @Sendable () -> Bool? = TeamsMicMonitor.readCoreAudio,
                  onChange: @escaping @MainActor @Sendable (Bool) -> Void)
      public func start()   // polls immediately, then every `interval`
      public func stop()
      func poll()           // internal, for tests: one read, report if changed
  }
  ```
  `onChange` is called on the main queue with the first successful reading, then only when the value changes.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct TeamsMicMonitorTests {
    @Test func matchesTeamsBundlePrefixRunningInput() {
        #expect(TeamsMicMonitor.teamsHoldsMic([
            .init(bundleID: "com.microsoft.teams2.modulehost", isRunningInput: true)]))
        #expect(TeamsMicMonitor.teamsHoldsMic([
            .init(bundleID: "com.microsoft.teams2.helper", isRunningInput: true)]))
    }

    @Test func ignoresOutputOnlyAndOtherApps() {
        #expect(!TeamsMicMonitor.teamsHoldsMic([
            .init(bundleID: "com.microsoft.teams2.helper", isRunningInput: false),
            .init(bundleID: "us.zoom.xos", isRunningInput: true),
            .init(bundleID: "", isRunningInput: true),
            .init(bundleID: "com.jacobmarchionda.scribe", isRunningInput: true)]))
        #expect(!TeamsMicMonitor.teamsHoldsMic([]))
    }

    @Test func reportsFirstReadingThenOnlyChanges() async {
        // read sequence: false, false, true, true, false -> reports [false, true, false]
    }

    @Test func failedReadKeepsLastState() async {
        // read sequence: true, nil, nil, true -> reports [true] only
    }

    @Test func failedFirstReadReportsNothingUntilASuccess() async {
        // read sequence: nil, false -> reports [false]
    }
}
```

The three sequence tests build a monitor with a `read` closure that pops from a lock-protected array, call `poll()` once per element, and use `eventually` (in `TranscriptionQueueTests.swift`) plus the `Log<Bool>` helper to wait for the main-queue reports, then `#expect(log.all == [...])`.

- [ ] **Step 2: Run to verify they fail**

Run: `scripts/test.sh --filter TeamsMicMonitorTests`
Expected: compile failure, `TeamsMicMonitor` not found.

- [ ] **Step 3: Add the Core Audio reads to `CoreAudioProperties.swift`**

In the `CoreAudio` enum, following the existing wrappers' style:
- `static func processObjects() -> [AudioObjectID]?` — `kAudioHardwarePropertyProcessObjectList` on the system object; nil on any non-`noErr` status.
- `static func bundleID(ofProcess: AudioObjectID) -> String` — `kAudioProcessPropertyBundleID` (CFString, retained); `""` on failure.
- `static func isRunningInput(_ process: AudioObjectID) -> Bool` — `kAudioProcessPropertyIsRunningInput` as `UInt32 == 1`; false on failure.

- [ ] **Step 4: Implement `TeamsMicMonitor`**

`readCoreAudio` maps `processObjects()` to `[AudioProcessInfo]` and calls `teamsHoldsMic`; returns nil if `processObjects()` is nil. `start()` uses a `DispatchSourceTimer` on a private serial queue; `poll()` runs on that queue in production and directly in tests, so guard `lastReported: Bool?` with a lock. Reports hop to `DispatchQueue.main` and call `onChange` via `MainActor.assumeIsolated`. `stop()` cancels the timer; `deinit` calls `stop()`.

- [ ] **Step 5: Run to verify they pass**

Run: `scripts/test.sh --filter TeamsMicMonitorTests`
Expected: 5 tests pass. Then `scripts/test.sh`: full suite passes. `readCoreAudio` against live Core Audio is covered by the smoke test in Task 3, not a unit test.

- [ ] **Step 6: Commit**

```bash
git add Sources/ScribeCore/CoreAudioProperties.swift Sources/ScribeCore/TeamsMicMonitor.swift Tests/ScribeCoreTests/TeamsMicMonitorTests.swift
git commit -m "Add a monitor that reports when Teams holds the microphone"
```

---

### Task 2: `MeetingDetector`

**Files:**
- Create: `Sources/ScribeCore/MeetingDetector.swift`
- Test: `Tests/ScribeCoreTests/MeetingDetectorTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct MeetingDetector: Equatable, Sendable {
      public static let stopCountdown: TimeInterval = 15

      public enum Event: Equatable, Sendable {
          case teamsMic(Bool)
          case recordingStarted
          case recordingStopped
          case startPressed
          case continuePressed
          case countdownElapsed
      }

      public enum Effect: Equatable, Sendable {
          case postStartPrompt
          case removeStartPrompt
          case beginCountdown    // post stop notification + start 15 s timer
          case endCountdown      // remove stop notification + cancel timer
          case startRecording
          case stopRecording
      }

      public init()
      public mutating func handle(_ event: Event) -> [Effect]
  }
  ```
  State it keeps (private, names free): Teams mic state as `Bool?` (nil until the first reading), recording, armed, start prompt showing, counting down, start pending until first reading.

**Transition rules** (the spec's Behaviour section, made exact; effects in the order listed):

| Event | Condition | Effects | State after |
|---|---|---|---|
| `teamsMic(x)` | x equals the current mic state | `[]` | unchanged |
| `teamsMic(true)` | start pending (first reading) | `[.startRecording]` | pending cleared |
| `teamsMic(true)` | counting down | `[.endCountdown]` | armed, not counting |
| `teamsMic(true)` | recording | `[]` | armed |
| `teamsMic(true)` | idle | `[.postStartPrompt]` | prompt showing |
| `teamsMic(false)` | start pending | `[]` | pending cleared |
| `teamsMic(false)` | prompt showing | `[.removeStartPrompt]` | prompt not showing |
| `teamsMic(false)` | recording, armed, not counting | `[.beginCountdown]` | counting |
| `teamsMic(false)` | recording, not armed | `[]` | — |
| `recordingStarted` | — | `[.removeStartPrompt]` if prompt showing, else `[]` | recording; armed = mic state is true |
| `recordingStopped` | counting down | `[.endCountdown]` | not recording, not armed, not counting |
| `recordingStopped` | otherwise | `[]` | not recording, not armed |
| `startPressed` | recording | `[]` | — |
| `startPressed` | mic state nil | `[]` | start pending |
| `startPressed` | mic off | `[]` | — |
| `startPressed` | mic on | `[.removeStartPrompt, .startRecording]` | prompt not showing |
| `continuePressed` | counting down | `[.endCountdown]` | not armed, not counting |
| `continuePressed` | otherwise | `[]` | — |
| `countdownElapsed` | counting down | `[.endCountdown, .stopRecording]` | not counting |
| `countdownElapsed` | otherwise (stale timer) | `[]` | — |

`startRecording` never appears except in response to `startPressed` (directly, or deferred through the pending flag).

- [ ] **Step 1: Write the failing tests**

Helper: `func run(_ d: inout MeetingDetector, _ events: MeetingDetector.Event...) -> [MeetingDetector.Effect]` returns the effects of the **last** event only; earlier events set up state.

```swift
@Suite struct MeetingDetectorTests {
    @Test func micOnWhileIdlePostsPrompt()            // [.teamsMic(false), .teamsMic(true)] -> [.postStartPrompt]
    @Test func repeatedMicOnPostsOnce()               // ... .teamsMic(true), .teamsMic(true) -> []
    @Test func ignoringPromptNeverRecords()           // mic on, mic off -> [.removeStartPrompt]; no .startRecording anywhere in the sequence
    @Test func startPressedStartsRecording()          // mic on, .startPressed -> [.removeStartPrompt, .startRecording]
    @Test func startPressedWhileMicOffIsIgnored()     // mic on, mic off, .startPressed -> []
    @Test func startPressedBeforeFirstReadingWaitsForMicOn()  // .startPressed -> []; then .teamsMic(true) -> [.startRecording]
    @Test func startPressedBeforeFirstReadingDroppedIfMicOff() // .startPressed, .teamsMic(false) -> []; then .teamsMic(true) -> [.postStartPrompt]
    @Test func startPressedWhileRecordingIsIgnored()  // mic on, .recordingStarted, .startPressed -> []
    @Test func noPromptWhileRecording()               // mic off, .recordingStarted, mic on -> []
    @Test func manualStartRemovesShowingPrompt()      // mic on, .recordingStarted -> [.removeStartPrompt]
    @Test func micOffWhileArmedBeginsCountdown()      // mic on, .startPressed, .recordingStarted, mic off -> [.beginCountdown]
    @Test func manualRecordingArmsWhenTeamsJoinsLater() // mic off, .recordingStarted, mic on, mic off -> [.beginCountdown]
    @Test func recordingWithoutTeamsNeverAutoStops()  // mic off, .recordingStarted, .countdownElapsed -> []; no .beginCountdown
    @Test func countdownElapsedStopsRecording()       // ...countdown..., .countdownElapsed -> [.endCountdown, .stopRecording]
    @Test func micBackDuringCountdownCancelsIt()      // ...countdown..., mic on -> [.endCountdown]; then mic off -> [.beginCountdown]
    @Test func continueCancelsAndDisarms()            // ...countdown..., .continuePressed -> [.endCountdown]; then .countdownElapsed -> []
    @Test func continueThenTeamsAgainRearms()         // ...countdown..., .continuePressed, mic on, mic off -> [.beginCountdown]
    @Test func manualStopDuringCountdownCancelsIt()   // ...countdown..., .recordingStopped -> [.endCountdown]; then mic on -> [.postStartPrompt]
    @Test func failedStartLeavesNothingArmed()        // mic on, .startPressed (no .recordingStarted), mic off -> []
    @Test func staleCountdownElapsedIsIgnored()       // mic on, .startPressed, .recordingStarted, .countdownElapsed -> []
}
```

"...countdown..." is `.teamsMic(true), .startPressed, .recordingStarted, .teamsMic(false)`.

- [ ] **Step 2: Run to verify they fail**

Run: `scripts/test.sh --filter MeetingDetectorTests`
Expected: compile failure, `MeetingDetector` not found.

- [ ] **Step 3: Implement `MeetingDetector` in `Sources/ScribeCore/MeetingDetector.swift`**

A `switch` on the event implementing the table above. Doc comment on the type: events in, effects out; the caller performs effects and reports their outcomes back as events (`recordingStarted`, `recordingStopped`).

- [ ] **Step 4: Run to verify they pass**

Run: `scripts/test.sh --filter MeetingDetectorTests`
Expected: 20 tests pass. Then `scripts/test.sh`: full suite passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/ScribeCore/MeetingDetector.swift Tests/ScribeCoreTests/MeetingDetectorTests.swift
git commit -m "Add the meeting detector state machine"
```

---

### Task 3: App wiring — notifications, countdown, menu, docs

**Files:**
- Modify: `Sources/Scribe/Notifier.swift`, `Sources/Scribe/AppState.swift`, `Sources/Scribe/MenuView.swift`
- Modify: `docs/smoke-test.md`, `README.md`

**Interfaces:**
- Consumes: `TeamsMicMonitor(onChange:)`, `start()`; `MeetingDetector`, `.handle(_:)`, `MeetingDetector.stopCountdown` (Tasks 1–2).
- Produces (app-internal):
  ```swift
  // Notifier
  enum MeetingAction { case startRecording, continueRecording }
  var onMeetingAction: ((MeetingAction) -> Void)?
  func postMeetingStart()
  func removeMeetingStart()
  func postMeetingEnd()
  func removeMeetingEnd()
  func removeMeetingNotifications()       // both ids, delivered and pending
  func recordingDidNotStart(_ error: ScribeError)

  // AppState
  private(set) var countdownText: String?  // nil unless counting down
  func continueRecording()
  ```

- [ ] **Step 1: Notifier**

`Notifier` becomes an `NSObject` subclass conforming to `UNUserNotificationCenterDelegate`; `init` sets `center.delegate = self` and calls `setNotificationCategories` with two categories:

| Category id | Request id | Action id | Action title |
|---|---|---|---|
| `meeting-start` | `meeting-start` | `start-recording` | `Start Recording` |
| `meeting-end` | `meeting-end` | `continue-recording` | `Continue Recording` |

Actions use `options: []` (the app needn't come forward). Posting reuses the fixed request id so a re-post replaces rather than stacks; removal calls both `removeDeliveredNotifications(withIdentifiers:)` and `removePendingNotificationRequests(withIdentifiers:)`. Copy is in Global Constraints. Delegate methods are `nonisolated`: `didReceive` maps the action id to `MeetingAction` and calls `onMeetingAction` on the main actor (any other action id, including a tap on the body, does nothing); `willPresent` returns `[.banner, .sound]`.

Delegate timing: `AppState` (and so `Notifier`) is created as `ScribeApp`'s `@State` initial value, which runs before `applicationWillFinishLaunching`, early enough for a launch-by-action response. No `AppDelegate` change.

- [ ] **Step 2: AppState**

- Split `toggle()` into `private func startRecording()` and `private func stopRecording()`; `toggle()` calls one of them. `startRecording()` sends `.recordingStarted` on success. `stopRecording()`, `recordingInterrupted`, and `finalizeForTermination` send `.recordingStopped` after the session stops.
- `private var detector = MeetingDetector()` and `private func send(_ event: MeetingDetector.Event)` that calls `detector.handle` and performs each effect in order:
  - `.postStartPrompt` / `.removeStartPrompt` → `notifier.postMeetingStart()` / `removeMeetingStart()`
  - `.beginCountdown` → set a deadline `now + MeetingDetector.stopCountdown`, schedule a one-shot `Timer` in `.common` mode that sends `.countdownElapsed`, `notifier.postMeetingEnd()`, refresh `countdownText`
  - `.endCountdown` → invalidate that timer, clear the deadline and `countdownText`, `notifier.removeMeetingEnd()`
  - `.startRecording` → `startRecording()`; on failure also `notifier.recordingDidNotStart(error)`
  - `.stopRecording` → `stopRecording()`
  Effects may cause nested `send` calls (start/stop report back); that is safe because `handle` has already updated state.
- `init`: `notifier.removeMeetingNotifications()`, set `notifier.onMeetingAction` to send `.startPressed` / `.continuePressed`, then create and `start()` a `TeamsMicMonitor` whose `onChange` sends `.teamsMic(on)`. Keep the monitor in a stored property.
- `tick()` also sets `countdownText = "Teams meeting ended. Stopping in \(n) s"` while a deadline exists, `n` = whole seconds remaining, rounded up, minimum 0. Countdown only runs while recording, so the elapsed timer is always running when it's needed.
- `continueRecording()` sends `.continuePressed`.

- [ ] **Step 3: MenuView**

Inside the `isRecording` branch, after the mic name:

```swift
if let countdown = state.countdownText {
    Text(countdown)
    Button("Continue Recording") { state.continueRecording() }
}
```

- [ ] **Step 4: Build and test**

Run: `swift build --product Scribe` → `Build of product 'Scribe' complete!`, no warnings in `Sources/Scribe`.
Run: `scripts/test.sh` → all tests pass.

- [ ] **Step 5: Docs**

`docs/smoke-test.md`: new section `## Teams meeting detection` after `## Launch at login`, starting with the setup line "System Settings → Notifications → Scribe → alert style **Persistent**", then the spec's six checks, plus:
7. **Stale notification.** Get a start notification, quit Scribe from the menu, leave the waiting room. Relaunch by pressing Start Recording on the notification (or open Scribe and confirm the old notification is gone). Nothing records.

Known gaps gains: "If Scribe's notifications are denied, there is no start prompt; the stop countdown still shows in the menu."

`README.md`: one short paragraph under the feature list on Teams detection and the Persistent alert style.

- [ ] **Step 6: Bundle for the user's smoke run**

Run: `scripts/bundle.sh --no-open` → `Built build/Scribe.app`. Do not launch it or run the smoke checks; they need the user, Teams, and real meetings.

- [ ] **Step 7: Commit**

```bash
git add Sources/Scribe docs/smoke-test.md README.md
git commit -m "Offer to record Teams meetings and stop when they end"
```
