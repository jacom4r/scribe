import Foundation

/// Renders turns to the phase 2 Markdown layout. No timestamps by design.
public struct TranscriptRenderer: Sendable {
    public init() {}

    public func render(turns: [Turn], recordingName: String, duration: TimeInterval) -> String {
        var speakers: [String] = []
        for turn in turns where !speakers.contains(turn.speaker) {
            speakers.append(turn.speaker)
        }

        var out = "# \(Self.title(for: recordingName))\n\n"
        out += "Recording: \(recordingName)\n"
        out += "Duration: \(Self.formatDuration(duration))\n"
        out += "Speakers: \(speakers.isEmpty ? "none" : speakers.joined(separator: ", "))\n"
        for turn in turns {
            out += "\n**\(turn.speaker)**\n\(turn.text)\n"
        }
        return out
    }

    /// "Meeting 2026-09-16 14:30" from a `yyyy-MM-dd HH-mm ...` name;
    /// otherwise "Meeting <name without extension>".
    static func title(for recordingName: String) -> String {
        let base = (recordingName as NSString).deletingPathExtension
        if let m = base.prefixMatch(of: /(\d{4}-\d{2}-\d{2}) (\d{2})-(\d{2})/) {
            return "Meeting \(m.1) \(m.2):\(m.3)"
        }
        return "Meeting \(base)"
    }

    /// `m:ss` under an hour, `h:mm:ss` from an hour up.
    static func formatDuration(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
