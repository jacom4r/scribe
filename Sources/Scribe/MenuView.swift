import ScribeCore
import SwiftUI

struct MenuView: View {
    let state: AppState

    var body: some View {
        if let error = state.lastError {
            Text(error.userMessage)
            if error == .permissionDenied {
                Button("Open System Settings…") { state.openPrivacySettings() }
            }
            Divider()
        }

        if !state.notificationsAllowed {
            Text("Notifications are off")
            Button("Turn On Notifications…") { state.openNotificationSettings() }
            Divider()
        }

        if state.isRecording {
            Button("Stop Recording") { state.toggle() }
            Text("Recording  \(state.elapsedText)")
            if let micName = state.micName {
                Text(micName)
            }
            if let countdown = state.countdownText {
                Text(countdown)
                Button("Continue Recording") { state.continueRecording() }
            }
        } else {
            Button("Start Recording") { state.toggle() }
        }

        if let status = state.transcriptionStatus {
            Text(status)
        }

        Divider()
        Button("Open Recordings Folder") { state.openRecordingsFolder() }
        Button("Choose Recordings Folder…") { state.chooseRecordingsFolder() }
        Button("Recording Permissions…") { state.openPrivacySettings() }
        Toggle("Record Teams Meetings Automatically", isOn: Binding(
            get: { state.autoStartsMeetings },
            set: { state.setAutoStartsMeetings($0) }))
        Toggle("Launch at Login", isOn: Binding(
            get: { state.launchesAtLogin },
            set: { state.setLaunchesAtLogin($0) }))
        Button("Quit Scribe") { state.quit() }
            .keyboardShortcut("q")
    }
}
