import AppKit
import Foundation
import Observation
import ScribeCore

@MainActor
@Observable
final class AppState {
    let session: RecordingSession

    init(session: RecordingSession = RecordingSession()) {
        self.session = session
    }

    var isRecording: Bool { session.isRecording }
    var recordingsDirectory: URL { session.store.directory }

    func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(recordingsDirectory)
    }

    func quit() {
        NSApp.terminate(nil)
    }
}
