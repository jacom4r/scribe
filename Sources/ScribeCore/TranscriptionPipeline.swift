import Foundation

/// One WAV in, one Markdown transcript out, next to it. Pure orchestration:
/// the engine, the reader, the assembler and the renderer are all injectable.
public struct TranscriptionPipeline: Sendable {
    public typealias Reader = @Sendable (URL) throws -> ChannelTracks

    private let engine: any SpeechEngine
    private let read: Reader
    private let assembler: TurnAssembler
    private let renderer: TranscriptRenderer

    public init(
        engine: any SpeechEngine,
        read: @escaping Reader = ChannelReader.read,
        assembler: TurnAssembler = TurnAssembler(),
        renderer: TranscriptRenderer = TranscriptRenderer()
    ) {
        self.engine = engine
        self.read = read
        self.assembler = assembler
        self.renderer = renderer
    }

    /// `<wav basename>.md` in the WAV's directory.
    public static func transcriptURL(for wavURL: URL) -> URL {
        wavURL.deletingPathExtension().appendingPathExtension("md")
    }

    /// Writes the transcript and returns its URL. Throws `ScribeError` only;
    /// nothing is written on failure.
    public func run(_ wavURL: URL) async throws -> URL {
        do {
            let tracks = try read(wavURL)

            let me = try await engine.transcribe(tracks.left).map { word in
                var w = word
                w.speaker = "Me"
                return w
            }

            var them = try await engine.transcribe(tracks.right)
            if !them.isEmpty {
                let segments: [SpeakerSegment]
                switch try await engine.diarize(tracks.right) {
                case .segments(let s): segments = s
                case .noSpeech: segments = []
                }
                them = Self.label(them, with: segments)
            }

            let turns = assembler.assemble(me + them)
            let markdown = renderer.render(
                turns: turns, recordingName: wavURL.lastPathComponent, duration: tracks.duration)
            let outURL = Self.transcriptURL(for: wavURL)
            try Data(markdown.utf8).write(to: outURL, options: .atomic)
            return outURL
        } catch let error as ScribeError {
            throw error
        } catch {
            throw ScribeError.transcriptionFailed(String(describing: error))
        }
    }

    /// Gives every right-channel word a "Speaker N" label. N is by first
    /// appearance of the engine's speaker id in time. A word takes the segment
    /// it overlaps most, else the segment whose midpoint is nearest. With no
    /// segments at all every word is "Speaker 1": the words came from somebody.
    static func label(_ words: [TimedWord], with segments: [SpeakerSegment]) -> [TimedWord] {
        guard !segments.isEmpty else {
            return words.map { word in
                var w = word
                w.speaker = "Speaker 1"
                return w
            }
        }

        let ordered = segments.sorted { $0.start < $1.start }
        var names: [String: String] = [:]
        for segment in ordered where names[segment.speakerID] == nil {
            names[segment.speakerID] = "Speaker \(names.count + 1)"
        }

        return words.map { word in
            var best: (id: String, overlap: TimeInterval)?
            for segment in ordered {
                let overlap = min(word.end, segment.end) - max(word.start, segment.start)
                if overlap > 0, overlap > (best?.overlap ?? 0) {
                    best = (segment.speakerID, overlap)
                }
            }
            let id: String
            if let best {
                id = best.id
            } else {
                let mid = (word.start + word.end) / 2
                id = ordered.min {
                    abs(($0.start + $0.end) / 2 - mid) < abs(($1.start + $1.end) / 2 - mid)
                }!.speakerID
            }
            var w = word
            w.speaker = names[id]!
            return w
        }
    }
}
