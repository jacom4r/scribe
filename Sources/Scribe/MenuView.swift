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

        if state.isRecording {
            Button("Stop Recording") { state.toggle() }
            Text("Recording  \(state.elapsedText)")
            if let micName = state.micName {
                Text(micName)
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
        Button("Quit Scribe") { state.quit() }
            .keyboardShortcut("q")
    }
}
