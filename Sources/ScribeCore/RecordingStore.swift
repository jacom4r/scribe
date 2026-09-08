import Foundation

/// Decides where recordings go and what they are called.
public struct RecordingStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Music/Scribe/`
    public static func `default`() -> RecordingStore {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        return RecordingStore(directory: music.appendingPathComponent("Scribe", isDirectory: true))
    }

    /// Creates the directory if needed and returns a URL that does not exist yet:
    /// `yyyy-MM-dd HH-mm Recording.wav`, then ` (2)`, ` (3)`, ... on collision.
    public func newRecordingURL(at date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let base = "\(formatter.string(from: date)) Recording"

        var candidate = directory.appendingPathComponent("\(base).wav")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(n)).wav")
            n += 1
        }
        return candidate
    }
}
