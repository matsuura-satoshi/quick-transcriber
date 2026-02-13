import XCTest
@testable import QuickTranscriberLib

final class TranscriptFileWriterTests: XCTestCase {

    private var tmpDir: URL!
    private let symlinkName = "qt_transcript.md"

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptFileWriterTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: "transcriptsDirectory")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        UserDefaults.standard.removeObject(forKey: "transcriptsDirectory")
        super.tearDown()
    }

    private func makeWriter() -> TranscriptFileWriter {
        TranscriptFileWriter(transcriptsDirectory: tmpDir)
    }

    private func sessionFiles() -> [URL] {
        try! FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent != symlinkName }
    }

    private var symlinkURL: URL {
        tmpDir.appendingPathComponent(symlinkName)
    }

    // MARK: - startSession

    func testStartSessionCreatesFileWithFrontmatter() {
        let writer = makeWriter()
        writer.startSession(language: .english, initialText: "")

        let files = sessionFiles()
        XCTAssertEqual(files.count, 1)

        let content = try! String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("---\n"))
        XCTAssertTrue(content.contains("language: English"))
        XCTAssertTrue(content.contains("---\n"), "Should have closing frontmatter delimiter")

        writer.endSession()
    }

    func testStartSessionCreatesFileWithInitialText() {
        let writer = makeWriter()
        writer.startSession(language: .japanese, initialText: "Hello world")

        let files = sessionFiles()
        let content = try! String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(content.contains("language: Japanese"))
        XCTAssertTrue(content.hasSuffix("Hello world"))

        writer.endSession()
    }

    func testStartSessionFilenameFormat() {
        let writer = makeWriter()
        writer.startSession(language: .english, initialText: "")

        let files = sessionFiles()
        let filename = files[0].deletingPathExtension().lastPathComponent
        // Format: YYYY-MM-DD_HHmm_qt_transcript
        let regex = try! NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}_\\d{4}_qt_transcript$")
        let range = NSRange(filename.startIndex..., in: filename)
        XCTAssertNotNil(regex.firstMatch(in: filename, range: range),
                        "Filename '\(filename)' should match YYYY-MM-DD_HHmm_qt_transcript format")

        writer.endSession()
    }

    // MARK: - Symlink

    func testStartSessionCreatesSymlink() {
        let writer = makeWriter()
        writer.startSession(language: .english, initialText: "")

        let fm = FileManager.default
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: symlinkURL.path, isDirectory: &isDir))

        let dest = try! fm.destinationOfSymbolicLink(atPath: symlinkURL.path)
        XCTAssertTrue(dest.hasSuffix("_qt_transcript.md"))

        writer.endSession()
    }

    func testSymlinkPointsToLatestSession() {
        let writer = makeWriter()
        writer.startSession(language: .english, initialText: "First")
        writer.endSession()

        Thread.sleep(forTimeInterval: 0.01)

        writer.startSession(language: .japanese, initialText: "Second")

        let content = try! String(contentsOf: symlinkURL, encoding: .utf8)
        XCTAssertTrue(content.contains("language: Japanese"))
        XCTAssertTrue(content.contains("Second"))

        writer.endSession()
    }

    // MARK: - updateText delta append

    func testUpdateTextAppendsDelta() {
        let writer = makeWriter()
        writer.startSession(language: .english, initialText: "")

        writer.updateText("Hello")
        writer.updateText("Hello world")

        let content = try! String(contentsOf: symlinkURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Hello world"))
        let afterFrontmatter = content.components(separatedBy: "---\n").last!
        XCTAssertEqual(afterFrontmatter.trimmingCharacters(in: .newlines), "Hello world")

        writer.endSession()
    }

    // MARK: - updateText rewrite on prefix mismatch

    func testUpdateTextRewritesOnPrefixMismatch() {
        let writer = makeWriter()
        writer.startSession(language: .english, initialText: "")

        writer.updateText("Hello world")
        writer.updateText("Completely different text")

        let content = try! String(contentsOf: symlinkURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Completely different text"))
        XCTAssertFalse(content.contains("Hello world"))

        writer.endSession()
    }

    // MARK: - endSession

    func testEndSessionClosesFile() {
        let writer = makeWriter()
        writer.startSession(language: .english, initialText: "")
        writer.updateText("Some text")
        writer.endSession()

        writer.updateText("Should be ignored")

        let content = try! String(contentsOf: symlinkURL, encoding: .utf8)
        XCTAssertFalse(content.contains("Should be ignored"))
        XCTAssertTrue(content.contains("Some text"))
    }

    // MARK: - Multiple sessions

    func testMultipleSessionsSymlinkPointsToLatest() {
        let writer = makeWriter()

        writer.startSession(language: .english, initialText: "Session 1")
        writer.updateText("Session 1 text")
        writer.endSession()

        writer.startSession(language: .japanese, initialText: "Session 2")
        writer.updateText("Session 2 text")
        writer.endSession()

        let content = try! String(contentsOf: symlinkURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Session 2 text"))
        XCTAssertTrue(content.contains("language: Japanese"))
    }

    // MARK: - Edge cases

    func testUpdateTextWithEmptyString() {
        let writer = makeWriter()
        writer.startSession(language: .english, initialText: "")

        writer.updateText("")

        let content = try! String(contentsOf: symlinkURL, encoding: .utf8)
        XCTAssertTrue(content.contains("---"))

        writer.endSession()
    }

    func testUpdateTextWithoutStartSessionIsIgnored() {
        let writer = makeWriter()
        writer.updateText("Should be ignored")

        let files = try! FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 0)
    }

    // MARK: - UserDefaults directory

    func testUsesUserDefaultsDirectoryWhenNoExplicitDirectory() {
        let customDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CustomTranscripts-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: customDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: customDir) }

        UserDefaults.standard.set(customDir.path, forKey: "transcriptsDirectory")

        let writer = TranscriptFileWriter()
        writer.startSession(language: .english, initialText: "Custom dir test")

        let symlinkPath = customDir.appendingPathComponent(symlinkName)
        let content = try! String(contentsOf: symlinkPath, encoding: .utf8)
        XCTAssertTrue(content.contains("Custom dir test"))

        writer.endSession()
    }

    // MARK: - Directory change detection

    func testHasDirectoryChangedReturnsFalseWhenUnchanged() {
        let writer = makeWriter()
        writer.startSession(language: .english, initialText: "")
        XCTAssertFalse(writer.hasDirectoryChanged)
        writer.endSession()
    }

    func testHasDirectoryChangedReturnsFalseWhenNoSession() {
        let writer = makeWriter()
        XCTAssertFalse(writer.hasDirectoryChanged)
    }

    func testHasDirectoryChangedReturnsTrueAfterUserDefaultsChange() {
        // Writer without explicit directory → reads UserDefaults
        let writer = TranscriptFileWriter()
        let dir1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dir1-\(UUID().uuidString)")
        let dir2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dir2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir1)
            try? FileManager.default.removeItem(at: dir2)
        }

        UserDefaults.standard.set(dir1.path, forKey: "transcriptsDirectory")
        writer.startSession(language: .english, initialText: "In dir1")
        XCTAssertFalse(writer.hasDirectoryChanged)

        // Change UserDefaults while session is active
        UserDefaults.standard.set(dir2.path, forKey: "transcriptsDirectory")
        XCTAssertTrue(writer.hasDirectoryChanged)

        writer.endSession()
    }

    func testExplicitDirectoryOverridesUserDefaults() {
        let customDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CustomTranscripts-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: customDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: customDir) }

        UserDefaults.standard.set(customDir.path, forKey: "transcriptsDirectory")

        // Explicit tmpDir should win over UserDefaults
        let writer = makeWriter()
        writer.startSession(language: .english, initialText: "Explicit dir test")

        let files = sessionFiles()
        XCTAssertEqual(files.count, 1)

        // customDir should have no files
        let customFiles = try! FileManager.default.contentsOfDirectory(
            at: customDir, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(customFiles.count, 0)

        writer.endSession()
    }
}
