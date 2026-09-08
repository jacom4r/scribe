import AppKit
import Foundation
import Observation
import ScribeCore

@MainActor
@Observable
final class AppState {
    let session: RecordingSession
    private(set) var lastError: ScribeError?
    private(set) var elapsedText = "0:00"
    private var timer: Timer?
    private let notifier = Notifier()

    init(session: RecordingSession = RecordingSession()) {
        self.session = session
        session.onInterrupted = { [weak self] error, url in
            self?.recordingInterrupted(error, url: url)
        }
        notifier.requestAuthorization()
    }

    var isRecording: Bool { session.isRecording }
    var recordingsDirectory: URL { session.store.directory }

    /// Start if idle, stop if recording. Errors land in `lastError`.
    func toggle() {
        do {
            if session.isRecording {
                let url = try session.stop()
                stopTimer()
                recordingSaved(url)
            } else {
                lastError = nil
                try session.start()
                startTimer()
            }
        } catch {
            stopTimer()
            lastError = (error as? ScribeError) ?? .writeFailed(OSStatus((error as NSError).code))
        }
    }

    func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(recordingsDirectory)
    }

    /// System Settings → Privacy & Security → Screen & System Audio Recording.
    func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }

    func quit() {
        if session.isRecording {
            _ = try? session.stop()
            stopTimer()
        }
        NSApp.terminate(nil)
    }

    // MARK: - Hooks Task 11 fills in

    private func recordingSaved(_ url: URL) {
        notifier.recordingSaved(url)
    }

    private func recordingInterrupted(_ error: ScribeError, url: URL) {
        stopTimer()
        lastError = error
        notifier.recordingStopped(error)
    }

    // MARK: - Timer

    private func startTimer() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        elapsedText = "0:00"
    }

    private func tick() {
        elapsedText = formatElapsed(session.elapsed())
    }
}
