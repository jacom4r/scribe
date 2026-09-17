import Foundation
import ScribeCore
import UserNotifications

/// Posts Scribe's notifications: recording saved or stopped, transcript saved or failed.
@MainActor
final class Notifier {
    private let center = UNUserNotificationCenter.current()

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

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}
