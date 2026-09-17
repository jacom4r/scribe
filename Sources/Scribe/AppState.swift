import AppKit
import Foundation
import Observation
import ScribeCore
import ScribeTranscription

@MainActor
@Observable
final class AppState {
    let session: RecordingSession
    private(set) var lastError: ScribeError?
    private(set) var elapsedText = "0:00"
    /// One line for the menu: preparing, transcribing, or the last failure. Nil when idle.
    private(set) var transcriptionStatus: String?
    private var timer: Timer?
    private let notifier = Notifier()
    private var queue: TranscriptionQueue!

    init(session: RecordingSession = RecordingSession(), engine: any SpeechEngine = FluidAudioEngine()) {
        self.session = session
        session.onInterrupted = { [weak self] error, url in
            self?.recordingInterrupted(error, url: url)
        }
        AppDelegate.terminationHandler = { [weak self] in self?.finalizeForTermination() }
        notifier.requestAuthorization()

        queue = TranscriptionQueue(
            engine: engine,
            onStateChange: { [weak self] state in
                Task { @MainActor in self?.transcriptionStateChanged(state) }
            },
            onJobFinished: { [weak self] wavURL, result in
                Task { @MainActor in self?.transcriptionFinished(wavURL, result) }
            })
        Task { await queue.prepareModels() }
    }

    var isRecording: Bool { session.isRecording }
    var micName: String? { session.micName }
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
        finalizeForTermination()
        NSApp.terminate(nil)
    }

    /// Flushes an in-progress recording to disk before the process goes away.
    /// Runs both from the menu's Quit and from `AppDelegate`'s termination
    /// handler; the guard makes the second call a no-op.
    private func finalizeForTermination() {
        guard session.isRecording else { return }
        _ = try? session.stop()
        stopTimer()
    }

    // MARK: - Recording outcomes

    private func recordingSaved(_ url: URL) {
        notifier.recordingSaved(url)
        enqueueTranscription(url)
    }

    private func recordingInterrupted(_ error: ScribeError, url: URL) {
        stopTimer()
        lastError = error
        notifier.recordingStopped(error)
        enqueueTranscription(url)
    }

    // MARK: - Transcription

    private func enqueueTranscription(_ url: URL) {
        Task { await queue.enqueue(url) }
    }

    private func transcriptionStateChanged(_ state: TranscriptionQueue.State) {
        switch state {
        case .preparingModels:
            transcriptionStatus = "Preparing transcription models…"
        case .idle:
            transcriptionStatus = nil
        case .transcribing(let url):
            transcriptionStatus = "Transcribing \(url.deletingPathExtension().lastPathComponent)…"
        case .failed(let url, let error):
            transcriptionStatus = "\(url.lastPathComponent): \(error.userMessage)"
        }
    }

    private func transcriptionFinished(_ wavURL: URL, _ result: Result<URL, ScribeError>) {
        switch result {
        case .success(let mdURL):
            notifier.transcriptSaved(mdURL)
        case .failure(let error):
            notifier.transcriptionFailed(error)
        }
    }

    // MARK: - Timer

    private func startTimer() {
        tick()
        // `.common` mode, not `Timer.scheduledTimer`'s `.default`: an open
        // NSMenu runs the run loop in event-tracking mode, which would
        // otherwise freeze the elapsed-time label while the menu is showing.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
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
