import Foundation
import ScribeCore
import UserNotifications

/// Posts the two notifications Scribe sends: saved, and stopped-by-error.
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

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}
