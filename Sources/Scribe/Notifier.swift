import Foundation
import ScribeCore
import UserNotifications

/// What the user pressed on a Teams meeting notification.
enum MeetingAction {
    case startRecording
    case continueRecording
}

/// Posts Scribe's notifications: recording saved or stopped, transcript saved
/// or failed, and the Teams meeting prompts. Also receives the prompts' button
/// presses as the notification center's delegate.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    /// Fixed ids for the meeting prompts: a re-post replaces instead of stacking,
    /// and removal can find them. Each doubles as its category id.
    private static let startID = "meeting-start"
    private static let endID = "meeting-end"
    private static let startActionID = "start-recording"
    private static let continueActionID = "continue-recording"
    /// Called on the main actor when the user presses a meeting notification's button.
    var onMeetingAction: ((MeetingAction) -> Void)?

    override init() {
        super.init()
        center.delegate = self
        // `options: []`: the buttons act in the background, so Scribe needn't come forward.
        let start = UNNotificationAction(identifier: Self.startActionID, title: "Start Recording", options: [])
        let continued = UNNotificationAction(identifier: Self.continueActionID, title: "Continue Recording", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.startID, actions: [start], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.endID, actions: [continued], intentIdentifiers: [], options: []),
        ])
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func recordingSaved(_ url: URL) {
        post(title: "Recording saved", body: url.lastPathComponent)
    }

    func recordingStopped(_ error: ScribeError) {
        post(title: "Recording stopped", body: error.userMessage)
    }

    func transcriptSaved(_ url: URL) {
        post(title: "Transcript saved", body: url.lastPathComponent)
    }

    func transcriptionFailed(_ wavURL: URL, _ error: ScribeError) {
        post(title: "Transcription failed", body: "\(wavURL.lastPathComponent): \(error.userMessage)")
    }

    func recordingDidNotStart(_ error: ScribeError) {
        post(title: "Recording didn't start", body: error.userMessage)
    }

    func postMeetingStart() {
        post(title: "Teams meeting detected", body: "Start recording?", id: Self.startID, category: Self.startID)
    }

    func removeMeetingStart() { remove(Self.startID) }

    func postMeetingEnd() {
        post(title: "Teams meeting ended", body: "Stopping the recording in 15 s", id: Self.endID, category: Self.endID)
    }

    func removeMeetingEnd() { remove(Self.endID) }

    /// Clears both prompts, delivered and pending. Run at launch so a prompt
    /// left over from a previous run can't start a recording for a meeting that is over.
    func removeMeetingNotifications() {
        remove(Self.startID)
        remove(Self.endID)
    }

    private func remove(_ id: String) {
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    private func post(title: String, body: String, id: String = UUID().uuidString, category: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category { content.categoryIdentifier = category }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request)
    }

    // The center calls these off the main thread, so they are `nonisolated`
    // and hop back to the main actor before touching Scribe's state.

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action: MeetingAction
        switch response.actionIdentifier {
        case Self.startActionID: action = .startRecording
        case Self.continueActionID: action = .continueRecording
        default: return  // a tap on the body, or a dismissal
        }
        await MainActor.run { onMeetingAction?(action) }
    }

    /// Show banners even when Scribe is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
