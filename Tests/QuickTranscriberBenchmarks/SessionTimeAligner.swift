import Foundation

/// Aligns Zoom absolute timestamps to audio-relative time for a real session.
/// Audio t=0 is the QT recording start, taken from qt_transcript.md frontmatter `date:`.
public enum SessionTimeAligner {
    public enum AlignError: Error, Equatable {
        case dateNotFound
        case dateUnparseable(String)
    }

    private static let dateLinePattern = #/(?m)^date:\s*(?<iso>\S+)\s*$/#
    private static let timePattern = #/T(?<h>\d{2}):(?<m>\d{2}):(?<s>\d{2})/#

    /// Extract the `date:` frontmatter value and return its seconds-of-day
    /// (hour*3600 + minute*60 + second) in the timestamp's own zone offset.
    public static func qtStartSecondsOfDay(fromFrontmatter markdown: String) throws -> Double {
        // Find `date: <ISO8601>` on its own line.
        guard let m = try? dateLinePattern.firstMatch(in: markdown) else {
            throw AlignError.dateNotFound
        }
        let iso = String(m.output.iso)
        // Parse HH:MM:SS out of the ISO string (e.g. 2026-04-21T09:44:23+09:00).
        guard let t = try? timePattern.firstMatch(in: iso),
              let h = Int(t.output.h), let mm = Int(t.output.m), let s = Int(t.output.s) else {
            throw AlignError.dateUnparseable(iso)
        }
        return Double(h * 3600 + mm * 60 + s)
    }
}
