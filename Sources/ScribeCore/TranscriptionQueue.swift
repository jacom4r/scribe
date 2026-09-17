import Foundation

/// Runs transcription jobs one at a time in arrival order and reports state.
/// Owns nothing persistent: quitting the app abandons whatever is queued.
public actor TranscriptionQueue {
    public enum State: Equatable, Sendable {
        case preparingModels
        case idle
        case transcribing(URL)
        case failed(URL, ScribeError)
    }

    public typealias StateHandler = @Sendable (State) -> Void
    public typealias JobHandler = @Sendable (URL, Result<URL, ScribeError>) -> Void

    private let engine: any SpeechEngine
    private let pipeline: TranscriptionPipeline
    private let onStateChange: StateHandler
    private let onJobFinished: JobHandler

    private var pending: [URL] = []
    private var draining = false
    private var modelsReady = false
    private var launchPrepare: Task<Void, Never>?

    public private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange(state) } }
    }

    public init(
        engine: any SpeechEngine,
        pipeline: TranscriptionPipeline? = nil,
        onStateChange: @escaping StateHandler,
        onJobFinished: @escaping JobHandler
    ) {
        self.engine = engine
        self.pipeline = pipeline ?? TranscriptionPipeline(engine: engine)
        self.onStateChange = onStateChange
        self.onJobFinished = onJobFinished
    }

    /// Starts the launch-time model download in the background. Failure is
    /// silent here; the next job retries and reports.
    public func prepareModels() {
        guard !modelsReady, launchPrepare == nil else { return }
        state = .preparingModels
        launchPrepare = Task { await self.runLaunchPrepare() }
    }

    private func runLaunchPrepare() async {
        do {
            try await engine.prepare()
            modelsReady = true
        } catch {
            modelsReady = false
        }
        launchPrepare = nil
        if case .preparingModels = state { state = .idle }
    }

    public func enqueue(_ wavURL: URL) {
        pending.append(wavURL)
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    private func drain() async {
        while !pending.isEmpty {
            let url = pending.removeFirst()
            state = .transcribing(url)
            do {
                try await ensureModelsReady()
                let out = try await pipeline.run(url)
                state = .idle
                onJobFinished(url, .success(out))
            } catch {
                let failure = (error as? ScribeError) ?? .transcriptionFailed(String(describing: error))
                state = .failed(url, failure)
                onJobFinished(url, .failure(failure))
            }
        }
        draining = false
    }

    /// Waits for an in-flight launch prepare, then retries inline if needed.
    private func ensureModelsReady() async throws {
        if modelsReady { return }
        if let launchPrepare { await launchPrepare.value }
        if modelsReady { return }
        try await engine.prepare()
        modelsReady = true
    }
}
