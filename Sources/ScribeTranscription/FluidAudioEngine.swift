import FluidAudio
import Foundation
import ScribeCore

/// The only type in Scribe that touches FluidAudio. Parakeet TDT v2 for
/// English ASR and the offline pyannote community-1 pipeline for diarization,
/// both as CoreML models on the Neural Engine. Models download once to
/// `~/Library/Application Support/FluidAudio/Models/`.
public actor FluidAudioEngine: SpeechEngine {
    private var asr: AsrManager?
    private var diarizerReady = false

    public init() {}

    public func prepare() async throws {
        do {
            if asr == nil {
                let models = try await AsrModels.downloadAndLoad(version: .v2)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                asr = manager
            }
            if !diarizerReady {
                // OfflineDiarizerManager is not Sendable, so it cannot live in
                // actor state and then be handed to its own nonisolated
                // `process`. Prepare a throwaway one here so the download and
                // CoreML compile happen at launch; `diarize` reloads from the
                // on-disk cache per call, which the spike measured at ~0.15 s.
                try await OfflineDiarizerManager(config: .default).prepareModels()
                diarizerReady = true
            }
        } catch {
            throw ScribeError.modelsUnavailable(Self.describe(error))
        }
    }

    public func transcribe(_ track: [Float]) async throws -> [TimedWord] {
        guard let asr else { throw ScribeError.modelsUnavailable("engine not prepared") }
        do {
            var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
            let result = try await asr.transcribe(track, decoderState: &state)
            return buildWordTimings(from: result.tokenTimings ?? []).map {
                TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
            }
        } catch {
            throw ScribeError.transcriptionFailed(Self.describe(error))
        }
    }

    public func diarize(_ track: [Float]) async throws -> DiarizationOutcome {
        guard diarizerReady else { throw ScribeError.modelsUnavailable("engine not prepared") }
        do {
            let diarizer = OfflineDiarizerManager(config: .default)
            try await diarizer.prepareModels()
            let result = try await diarizer.process(audio: track)
            return .segments(result.segments.map {
                SpeakerSegment(
                    speakerID: $0.speakerId,
                    start: TimeInterval($0.startTimeSeconds),
                    end: TimeInterval($0.endTimeSeconds))
            })
        } catch OfflineDiarizationError.noSpeechDetected {
            return .noSpeech
        } catch {
            throw ScribeError.transcriptionFailed(Self.describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
