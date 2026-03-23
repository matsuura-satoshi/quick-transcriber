import Foundation

public final class TranscriptFileWriter {

    private static let userDefaultsKey = "transcriptsDirectory"
    private static let symlinkName = "qt_transcript.md"
    private static let fileSuffix = "_qt_transcript"

    private let explicitDirectory: URL?
    private var fileHandle: FileHandle?
    private var currentFileURL: URL?
    private var currentSessionDirectory: URL?
    private var lastWrittenText: String = ""
    private var frontmatter: String = ""

    public init(transcriptsDirectory: URL? = nil) {
        self.explicitDirectory = transcriptsDirectory
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("QuickTranscriber")
    }

    public var resolvedDirectory: URL {
        if let explicit = explicitDirectory {
            return explicit
        }
        if let saved = UserDefaults.standard.string(forKey: Self.userDefaultsKey), !saved.isEmpty {
            return URL(fileURLWithPath: saved)
        }
        return Self.defaultDirectory
    }

    public var hasDirectoryChanged: Bool {
        guard let current = currentSessionDirectory else { return false }
        return resolvedDirectory.standardizedFileURL != current.standardizedFileURL
    }

    public func startSession(language: Language, initialText: String, datePrefix: String? = nil) {
        let fm = FileManager.default
        let dir = resolvedDirectory
        currentSessionDirectory = dir

        // Ensure directory exists
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Generate filename: YYYY-MM-DD_HHmm_qt_transcript.md
        let prefix: String
        if let datePrefix {
            prefix = datePrefix
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HHmm"
            prefix = formatter.string(from: Date())
        }
        let filename = prefix + Self.fileSuffix + ".md"
        let fileURL = dir.appendingPathComponent(filename)

        // Build frontmatter
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        isoFormatter.timeZone = .current
        let dateString = isoFormatter.string(from: Date())
        frontmatter = "---\ndate: \(dateString)\nlanguage: \(language.displayName)\n---\n\n"

        // Write initial content
        var content = frontmatter
        if !initialText.isEmpty {
            content += initialText
        }
        lastWrittenText = initialText

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            currentFileURL = fileURL
            fileHandle = try FileHandle(forWritingTo: fileURL)
            fileHandle?.seekToEndOfFile()
        } catch {
            NSLog("[QuickTranscriber] TranscriptFileWriter: failed to create file: \(error)")
            return
        }

        // Update symlink
        let symlinkURL = dir.appendingPathComponent(Self.symlinkName)
        updateSymlink(at: symlinkURL, to: fileURL)
    }

    public func updateText(_ newText: String) {
        guard let fileHandle = fileHandle, let fileURL = currentFileURL else { return }

        if newText == lastWrittenText { return }

        if newText.hasPrefix(lastWrittenText) {
            // Delta append
            let delta = String(newText.dropFirst(lastWrittenText.count))
            if let data = delta.data(using: .utf8) {
                do {
                    try fileHandle.write(contentsOf: data)
                    try fileHandle.synchronize()
                } catch {
                    NSLog("[QuickTranscriber] TranscriptFileWriter: write error: \(error)")
                }
            }
        } else {
            // Prefix mismatch — rewrite file preserving frontmatter
            let content = frontmatter + newText
            do {
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
                // Reopen file handle at end
                self.fileHandle?.closeFile()
                self.fileHandle = try FileHandle(forWritingTo: fileURL)
                self.fileHandle?.seekToEndOfFile()
            } catch {
                NSLog("[QuickTranscriber] TranscriptFileWriter: rewrite error: \(error)")
            }
        }

        lastWrittenText = newText
    }

    public func endSession() {
        fileHandle?.closeFile()
        fileHandle = nil
        currentFileURL = nil
        currentSessionDirectory = nil
        lastWrittenText = ""
        frontmatter = ""
    }

    deinit {
        endSession()
    }

    private func updateSymlink(at symlinkURL: URL, to target: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: symlinkURL)
        do {
            try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: target)
        } catch {
            NSLog("[QuickTranscriber] TranscriptFileWriter: symlink error: \(error)")
        }
    }
}
