import XCTest
@testable import QuickTranscriberLib

@MainActor
final class TranscriptionViewModelTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "selectedLanguage")
        UserDefaults.standard.removeObject(forKey: "isRecording")
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private func makeViewModel(
        withFileWriter: Bool = false
    ) -> (TranscriptionViewModel, MockTranscriptionEngine) {
        let engine = MockTranscriptionEngine()
        let fileWriter = withFileWriter ? TranscriptFileWriter(transcriptsDirectory: tmpDir) : nil
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model", fileWriter: fileWriter)
        return (vm, engine)
    }

    // MARK: - Model Loading

    func testLoadModelSuccess() async {
        let (vm, engine) = makeViewModel()
        XCTAssertEqual(vm.modelState, .notLoaded)

        await vm.loadModel()

        XCTAssertEqual(vm.modelState, .ready)
        XCTAssertTrue(engine.setupCalled)
        XCTAssertEqual(engine.setupModel, "test-model")
    }

    func testLoadModelFailure() async {
        let (vm, engine) = makeViewModel()
        engine.setupError = MockError.setupFailed

        await vm.loadModel()

        if case .error(let message) = vm.modelState {
            XCTAssertTrue(message.contains("Mock setup failed"))
        } else {
            XCTFail("Expected error state, got \(vm.modelState)")
        }
    }

    // MARK: - Recording requires model ready

    func testCannotRecordWithoutModelReady() async {
        let (vm, engine) = makeViewModel()
        // Model not loaded yet
        XCTAssertEqual(vm.modelState, .notLoaded)

        vm.toggleRecording()

        XCTAssertFalse(vm.isRecording)
        XCTAssertFalse(engine.startStreamingCalled)
    }

    func testCanRecordAfterModelReady() async {
        let (vm, engine) = makeViewModel()
        await vm.loadModel()

        vm.toggleRecording()

        // Give async task a moment to start
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(vm.isRecording)
        XCTAssertTrue(engine.startStreamingCalled)
        XCTAssertEqual(engine.startStreamingLanguage, "en")
    }

    // MARK: - Stop promotes unconfirmed to confirmed

    func testStopPromotesUnconfirmedToConfirmed() async {
        let (vm, _) = makeViewModel()
        await vm.loadModel()

        // Simulate having unconfirmed text when stopping
        vm.confirmedSegments = [ConfirmedSegment(text: "Hello")]
        vm.unconfirmedText = "World"

        // Start then stop recording
        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)
        vm.toggleRecording()

        XCTAssertTrue(vm.confirmedText.contains("World"))
        XCTAssertEqual(vm.unconfirmedText, "")
    }

    // MARK: - Session text accumulation

    func testSessionTextAccumulates() async {
        let (vm, _) = makeViewModel()
        await vm.loadModel()

        // First session
        vm.confirmedSegments = [ConfirmedSegment(text: "First session text")]
        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)
        vm.toggleRecording() // stop

        // After stop, previousSessionText should be set
        let afterFirst = vm.confirmedText

        // Second session start
        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)
        vm.toggleRecording() // stop

        // Previous text should still be preserved
        XCTAssertTrue(vm.confirmedText.contains("First session text") || afterFirst.contains("First session text"))
    }

    // MARK: - Clear text

    func testClearText() async {
        let (vm, _) = makeViewModel()
        await vm.loadModel()

        vm.confirmedSegments = [ConfirmedSegment(text: "Some text")]
        vm.unconfirmedText = "More text"

        vm.clearText()

        XCTAssertEqual(vm.confirmedText, "")
        XCTAssertEqual(vm.unconfirmedText, "")
    }

    func testClearTextWhileRecording() async {
        let (vm, _) = makeViewModel()
        await vm.loadModel()

        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(vm.isRecording)

        vm.confirmedSegments = [ConfirmedSegment(text: "Some text")]
        vm.clearText()

        // clearText internally does: stopTranscription (await) + 100ms sleep + startRecording
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(vm.confirmedText, "")
        XCTAssertEqual(vm.unconfirmedText, "")
        XCTAssertTrue(vm.isRecording)
    }

    // MARK: - Language switching

    func testSwitchLanguage() async {
        let (vm, _) = makeViewModel()
        await vm.loadModel()

        XCTAssertEqual(vm.currentLanguage, .english)
        vm.switchLanguage(.japanese)
        XCTAssertEqual(vm.currentLanguage, .japanese)
    }

    func testSwitchLanguageInsertsSeparator() async {
        let (vm, _) = makeViewModel()
        await vm.loadModel()

        // Simulate having previous text
        vm.confirmedSegments = [ConfirmedSegment(text: "Hello world")]
        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)
        vm.toggleRecording() // stop to set previousSessionText

        vm.switchLanguage(.japanese)

        XCTAssertTrue(vm.confirmedText.contains("English → Japanese"))
    }

    func testSwitchLanguageWhileRecordingRestarts() async {
        let (vm, _) = makeViewModel()
        await vm.loadModel()

        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(vm.isRecording)

        vm.switchLanguage(.japanese)

        // switchLanguage internally does: stopTranscription (await) + 100ms sleep + startRecording
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(vm.isRecording)
        XCTAssertEqual(vm.currentLanguage, .japanese)
    }

    // MARK: - Display text

    func testDisplayTextConfirmedOnly() {
        let (vm, _) = makeViewModel()
        vm.confirmedSegments = [ConfirmedSegment(text: "Hello")]
        vm.unconfirmedText = ""
        XCTAssertEqual(vm.displayText, "Hello")
    }

    func testDisplayTextUnconfirmedOnly() {
        let (vm, _) = makeViewModel()
        vm.unconfirmedText = "World"
        XCTAssertEqual(vm.displayText, "World")
    }

    func testDisplayTextBoth() {
        let (vm, _) = makeViewModel()
        vm.confirmedSegments = [ConfirmedSegment(text: "Hello")]
        vm.unconfirmedText = "World"
        XCTAssertEqual(vm.displayText, "Hello\nWorld")
    }

    func testDisplayTextEmpty() {
        let (vm, _) = makeViewModel()
        XCTAssertEqual(vm.displayText, "")
    }

    // MARK: - Font size

    func testIncreaseFontSize() {
        let (vm, _) = makeViewModel()
        let initial = vm.fontSize
        vm.increaseFontSize()
        XCTAssertEqual(vm.fontSize, initial + 1)
    }

    func testDecreaseFontSize() {
        let (vm, _) = makeViewModel()
        let initial = vm.fontSize
        vm.decreaseFontSize()
        XCTAssertEqual(vm.fontSize, initial - 1)
    }

    func testFontSizeUpperBound() {
        let (vm, _) = makeViewModel()
        vm.fontSize = 30
        vm.increaseFontSize()
        XCTAssertEqual(vm.fontSize, 30)
    }

    func testFontSizeLowerBound() {
        let (vm, _) = makeViewModel()
        vm.fontSize = 10
        vm.decreaseFontSize()
        XCTAssertEqual(vm.fontSize, 10)
    }

    // MARK: - Recording error handling

    func testStartRecordingFailureSetsIsRecordingFalse() async {
        let engine = MockTranscriptionEngine()
        engine.startStreamingError = MockError.streamingFailed
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model")

        await vm.loadModel()
        vm.toggleRecording()

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(vm.isRecording)
    }

    // MARK: - State callback integration

    func testStateCallbackUpdatesConfirmedAndUnconfirmed() async {
        let (vm, engine) = makeViewModel()
        await vm.loadModel()

        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)

        engine.simulateStateChange(TranscriptionState(
            confirmedText: "Hello",
            unconfirmedText: "world",
            isRecording: true
        ))

        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(vm.confirmedText, "Hello")
        XCTAssertEqual(vm.unconfirmedText, "world")
    }

    // MARK: - Model state

    func testModelStateTransitions() async {
        let (vm, _) = makeViewModel()
        XCTAssertEqual(vm.modelState, .notLoaded)

        await vm.loadModel()
        XCTAssertEqual(vm.modelState, .ready)
    }

    func testModelLoadingState() async {
        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model")

        XCTAssertEqual(vm.modelState, .notLoaded)
        await vm.loadModel()
        XCTAssertEqual(vm.modelState, .ready)
    }

    // MARK: - File output integration

    private func transcriptFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent != "qt_transcript.md" }) ?? []
    }

    private func currentFileContent() -> String? {
        let url = tmpDir.appendingPathComponent("qt_transcript.md")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func testRecordingStartCreatesTranscriptFile() async {
        let (vm, _) = makeViewModel(withFileWriter: true)
        await vm.loadModel()

        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let files = transcriptFiles()
        XCTAssertEqual(files.count, 1, "Should create one transcript file")

        let content = currentFileContent()
        XCTAssertNotNil(content)
        XCTAssertTrue(content!.contains("language: English"))
    }

    func testStateCallbackUpdatesTranscriptFile() async {
        let (vm, engine) = makeViewModel(withFileWriter: true)
        await vm.loadModel()

        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)

        engine.simulateStateChange(TranscriptionState(
            confirmedText: "Hello world",
            unconfirmedText: "",
            isRecording: true
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        let content = currentFileContent()!
        XCTAssertTrue(content.contains("Hello world"))
    }

    func testStopRecordingEndsFileSession() async {
        let (vm, engine) = makeViewModel(withFileWriter: true)
        await vm.loadModel()

        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)

        engine.simulateStateChange(TranscriptionState(
            confirmedText: "Before stop",
            unconfirmedText: "",
            isRecording: true
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        vm.toggleRecording() // stop
        try? await Task.sleep(nanoseconds: 100_000_000)

        let content = currentFileContent()!
        XCTAssertTrue(content.contains("Before stop"))
    }

    func testClearTextCreatesNewFile() async {
        let (vm, engine) = makeViewModel(withFileWriter: true)
        await vm.loadModel()

        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)

        engine.simulateStateChange(TranscriptionState(
            confirmedText: "Old text",
            unconfirmedText: "",
            isRecording: true
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        vm.clearText()
        // clearText: stop + 100ms sleep + startRecording → new file session
        try? await Task.sleep(nanoseconds: 400_000_000)

        // The file should have been re-created (same minute = same filename, fresh content)
        let content = currentFileContent()!
        XCTAssertFalse(content.contains("Old text"),
                       "After clear, file should not contain old text")
    }

    func testLanguageSwitchContinuesSameFile() async {
        let (vm, engine) = makeViewModel(withFileWriter: true)
        await vm.loadModel()

        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)

        engine.simulateStateChange(TranscriptionState(
            confirmedText: "English text",
            unconfirmedText: "",
            isRecording: true
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        vm.switchLanguage(.japanese)
        // switchLanguage: stop + 100ms sleep + startRecording (same file session)
        try? await Task.sleep(nanoseconds: 400_000_000)

        // Same file should still have the original text + divider
        let files = transcriptFiles()
        XCTAssertEqual(files.count, 1, "Language switch should not create a new file")
    }

    // MARK: - Segment persistence across restarts

    func testRestartRecordingPreservesConfirmedSegments() async {
        let (vm, engine) = makeViewModel()
        await vm.loadModel()

        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let segments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: "A", speakerConfidence: 0.8),
            ConfirmedSegment(text: "world", precedingSilence: 0.5, speaker: "B", speakerConfidence: 0.6),
        ]
        engine.simulateStateChange(TranscriptionState(
            confirmedText: "Hello world",
            unconfirmedText: "partial",
            isRecording: true,
            confirmedSegments: segments
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(vm.confirmedSegments.count, 2)

        // Simulate parameter change triggering restart
        // restartRecording: saveUnconfirmedText → stop → startRecording
        vm.toggleRecording() // stop (saves previousSessionText)
        try? await Task.sleep(nanoseconds: 100_000_000)
        vm.toggleRecording() // start again
        try? await Task.sleep(nanoseconds: 100_000_000)

        // New engine session has no segments yet
        engine.simulateStateChange(TranscriptionState(
            confirmedText: "new text",
            unconfirmedText: "",
            isRecording: true,
            confirmedSegments: [ConfirmedSegment(text: "new text", precedingSilence: 0)]
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Previous segments should be preserved and prepended
        // 2 original + 1 promoted unconfirmed ("partial") + 1 new = 4
        XCTAssertEqual(vm.confirmedSegments.count, 4,
                       "Should have 2 previous + 1 promoted + 1 new segments")
        XCTAssertEqual(vm.confirmedSegments[0].text, "Hello")
        XCTAssertEqual(vm.confirmedSegments[1].text, "world")
        XCTAssertEqual(vm.confirmedSegments[2].text, "partial")
        XCTAssertEqual(vm.confirmedSegments[3].text, "new text")
    }

    func testClearTextClearsConfirmedSegments() async {
        let (vm, engine) = makeViewModel()
        await vm.loadModel()

        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)

        engine.simulateStateChange(TranscriptionState(
            confirmedText: "Some text",
            unconfirmedText: "",
            isRecording: true,
            confirmedSegments: [
                ConfirmedSegment(text: "Some text", precedingSilence: 0, speaker: "A", speakerConfidence: 0.9),
            ]
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(vm.confirmedSegments.count, 1)

        vm.clearText()
        // clearText: stop + 100ms sleep + startRecording
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(vm.confirmedSegments, [],
                       "clearText should clear confirmedSegments")
    }

    func testSwitchLanguageAddsSeparatorSegment() async {
        let (vm, engine) = makeViewModel()
        await vm.loadModel()

        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)

        engine.simulateStateChange(TranscriptionState(
            confirmedText: "English text",
            unconfirmedText: "",
            isRecording: true,
            confirmedSegments: [
                ConfirmedSegment(text: "English text", precedingSilence: 0),
            ]
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        vm.toggleRecording() // stop to set previousSessionText
        try? await Task.sleep(nanoseconds: 100_000_000)

        vm.switchLanguage(.japanese)
        // switchLanguage: stop + 100ms sleep + startRecording
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Should have original segment + separator segment
        XCTAssertGreaterThanOrEqual(vm.confirmedSegments.count, 2,
                                    "Should have original segment + separator")
        let separatorSegment = vm.confirmedSegments.last(where: {
            $0.text.contains("English → Japanese")
        })
        XCTAssertNotNil(separatorSegment, "Should contain language separator segment")
    }

    // MARK: - Speaker Profile Management

    func testSpeakerProfilesInitiallyLoaded() async {
        let (vm, _) = makeViewModel()
        // speakerProfiles should be accessible (may be empty if no profiles saved)
        XCTAssertNotNil(vm.speakerProfiles)
    }

    func testLabelDisplayNamesInitiallyEmpty() async {
        let (vm, _) = makeViewModel()
        XCTAssertNotNil(vm.labelDisplayNames)
    }

    func testRenameSpeakerUpdatesDisplayNames() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMSpeakerTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID()
        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(id: id, label: "A", embedding: [Float](repeating: 0.1, count: 256))]
        try! store.save()

        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model", speakerProfileStore: store)

        vm.renameSpeaker(id: id, to: "Alice")

        XCTAssertEqual(vm.labelDisplayNames["A"], "Alice")
        XCTAssertEqual(vm.speakerProfiles[0].displayName, "Alice")
    }

    func testDeleteSpeakerRemovesProfile() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMSpeakerTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let idA = UUID()
        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [
            StoredSpeakerProfile(id: idA, label: "A", embedding: [Float](repeating: 0.1, count: 256)),
            StoredSpeakerProfile(label: "B", embedding: [Float](repeating: 0.2, count: 256)),
        ]
        try! store.save()

        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model", speakerProfileStore: store)

        vm.deleteSpeaker(id: idA)

        XCTAssertEqual(vm.speakerProfiles.count, 1)
        XCTAssertEqual(vm.speakerProfiles[0].label, "B")
    }

    func testRenameAffectsFileOutput() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMSpeakerFileTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID()
        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(id: id, label: "A", embedding: [Float](repeating: 0.1, count: 256))]
        try! store.save()

        let engine = MockTranscriptionEngine()
        let fileWriter = TranscriptFileWriter(transcriptsDirectory: dir)
        let vm = TranscriptionViewModel(
            engine: engine, modelName: "test-model",
            fileWriter: fileWriter, speakerProfileStore: store
        )
        await vm.loadModel()

        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Simulate segments with speaker
        engine.simulateStateChange(TranscriptionState(
            confirmedText: "A: Hello",
            unconfirmedText: "",
            isRecording: true,
            confirmedSegments: [
                ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: "A", speakerConfidence: 0.8),
            ]
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Rename speaker
        vm.renameSpeaker(id: id, to: "Alice")

        // Next state change should write with resolved name
        engine.simulateStateChange(TranscriptionState(
            confirmedText: "A: Hello world",
            unconfirmedText: "",
            isRecording: true,
            confirmedSegments: [
                ConfirmedSegment(text: "Hello world", precedingSilence: 0, speaker: "A", speakerConfidence: 0.8),
            ]
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        let symlinkURL = dir.appendingPathComponent("qt_transcript.md")
        let content = try! String(contentsOf: symlinkURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Alice: Hello world"),
                      "File output should use display name. Got: \(content)")
    }

    func testDeleteAllSpeakersClearsAll() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMSpeakerTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [
            StoredSpeakerProfile(label: "A", embedding: [Float](repeating: 0.1, count: 256)),
            StoredSpeakerProfile(label: "B", embedding: [Float](repeating: 0.2, count: 256)),
        ]
        try! store.save()

        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model", speakerProfileStore: store)

        vm.deleteAllSpeakers()

        XCTAssertTrue(vm.speakerProfiles.isEmpty)
        XCTAssertTrue(vm.labelDisplayNames.isEmpty)
    }

    func testDirectoryChangeCreatesNewFileWithExistingText() async {
        // Use UserDefaults-based writer (no explicit directory)
        let dir1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMDir1-\(UUID().uuidString)")
        let dir2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMDir2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir1)
            try? FileManager.default.removeItem(at: dir2)
            UserDefaults.standard.removeObject(forKey: "transcriptsDirectory")
        }

        UserDefaults.standard.set(dir1.path, forKey: "transcriptsDirectory")

        let engine = MockTranscriptionEngine()
        let writer = TranscriptFileWriter()
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model", fileWriter: writer)
        await vm.loadModel()

        // Start recording in dir1
        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)

        engine.simulateStateChange(TranscriptionState(
            confirmedText: "Text from dir1",
            unconfirmedText: "",
            isRecording: true
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Stop, change directory, restart
        vm.toggleRecording() // stop
        try? await Task.sleep(nanoseconds: 100_000_000)

        UserDefaults.standard.set(dir2.path, forKey: "transcriptsDirectory")

        vm.toggleRecording() // start → should detect directory change
        try? await Task.sleep(nanoseconds: 200_000_000)

        // dir2 should have a file with the existing text
        let dir2Symlink = dir2.appendingPathComponent("qt_transcript.md")
        let content = try? String(contentsOf: dir2Symlink, encoding: .utf8)
        XCTAssertNotNil(content, "New directory should have a transcript file")
        XCTAssertTrue(content?.contains("Text from dir1") ?? false,
                      "New file should contain existing text as initial content")
    }

    // MARK: - Session Speakers

    func testSessionSpeakersReturnsDetectedSpeakers() async {
        let (vm, _) = makeViewModel()
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: "A"),
            ConfirmedSegment(text: "World", precedingSilence: 0, speaker: "B"),
            ConfirmedSegment(text: "Again", precedingSilence: 0, speaker: "A"),
        ]

        let speakers = vm.sessionSpeakers
        XCTAssertEqual(speakers.count, 2)
        XCTAssertEqual(speakers[0].label, "A")
        XCTAssertEqual(speakers[1].label, "B")
    }

    func testSessionSpeakersEmptyWhenNoSegments() async {
        let (vm, _) = makeViewModel()
        XCTAssertTrue(vm.sessionSpeakers.isEmpty)
    }

    func testSessionSpeakersIncludesDisplayName() async {
        let (vm, _) = makeViewModel()
        vm.labelDisplayNames = ["A": "Alice"]
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: "A"),
        ]

        let speakers = vm.sessionSpeakers
        XCTAssertEqual(speakers[0].displayName, "Alice")
    }

    func testSessionSpeakersIncludesStoredProfileId() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMSessionTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID()
        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(id: id, label: "A", embedding: [Float](repeating: 0.1, count: 256))]

        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model", speakerProfileStore: store)
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: "A"),
        ]

        let speakers = vm.sessionSpeakers
        XCTAssertEqual(speakers[0].storedProfileId, id)
    }

    // MARK: - Rename Session Speaker

    func testRenameSessionSpeakerUpdatesLabelDisplayNames() async {
        let (vm, _) = makeViewModel()
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: "A", speakerConfidence: 0.8),
        ]

        vm.renameSessionSpeaker(label: "A", displayName: "Alice")

        XCTAssertEqual(vm.labelDisplayNames["A"], "Alice")
    }

    func testRenameSessionSpeakerEmptyNameClearsDisplayName() async {
        let (vm, _) = makeViewModel()
        vm.labelDisplayNames = ["A": "Alice"]
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: "A", speakerConfidence: 0.8),
        ]

        vm.renameSessionSpeaker(label: "A", displayName: "")

        XCTAssertNil(vm.labelDisplayNames["A"])
    }

    func testRenameSessionSpeakerUpdatesStoreIfProfileExists() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMRenameTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID()
        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(id: id, label: "A", embedding: [Float](repeating: 0.1, count: 256))]
        try! store.save()

        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model", speakerProfileStore: store)
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: "A", speakerConfidence: 0.8),
        ]

        vm.renameSessionSpeaker(label: "A", displayName: "Alice")

        XCTAssertEqual(vm.speakerProfiles[0].displayName, "Alice")
    }

    // MARK: - Speaker Correction Wiring

    func testReassignSpeakerForBlockCallsCorrectSpeakerAssignment() {
        let emb: [Float] = Array(repeating: 0.1, count: 256)
        let engine = MockTranscriptionEngine()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMCorrectionTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let vm = TranscriptionViewModel(
            engine: engine,
            parametersStore: ParametersStore(),
            speakerProfileStore: SpeakerProfileStore(directory: dir)
        )
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerEmbedding: emb),
            ConfirmedSegment(text: "World", speaker: "A", speakerEmbedding: nil),
        ]

        vm.reassignSpeakerForBlock(segmentIndex: 0, newSpeaker: "B")

        // Both segments should be reassigned
        XCTAssertEqual(vm.confirmedSegments[0].speaker, "B")
        XCTAssertEqual(vm.confirmedSegments[0].isUserCorrected, true)
        XCTAssertEqual(vm.confirmedSegments[1].speaker, "B")
        XCTAssertEqual(vm.confirmedSegments[1].isUserCorrected, true)

        // Only segment with embedding should trigger correction call
        XCTAssertEqual(engine.correctedAssignments.count, 1)
        XCTAssertEqual(engine.correctedAssignments[0].oldLabel, "A")
        XCTAssertEqual(engine.correctedAssignments[0].newLabel, "B")
        XCTAssertEqual(engine.correctedAssignments[0].embedding, emb)
    }

    func testReassignSpeakerForSelectionCallsCorrectSpeakerAssignment() {
        let emb: [Float] = Array(repeating: 0.2, count: 256)
        let engine = MockTranscriptionEngine()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMCorrectionTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let vm = TranscriptionViewModel(
            engine: engine,
            parametersStore: ParametersStore(),
            speakerProfileStore: SpeakerProfileStore(directory: dir)
        )
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8, speakerEmbedding: emb),
            ConfirmedSegment(text: "World", speaker: "B", speakerConfidence: 0.7, speakerEmbedding: emb),
        ]

        // Build a segment map matching "A: Hello\nB: World"
        let (_, segmentMap) = TranscriptionTextView.buildAttributedStringFromSegments(
            vm.confirmedSegments,
            language: "en",
            silenceThreshold: 1.0,
            fontSize: 15.0,
            unconfirmed: ""
        )

        // Select range covering just the first segment
        let firstEntry = segmentMap.entries.first { $0.segmentIndex == 0 }!
        let selectionRange = firstEntry.characterRange

        vm.reassignSpeakerForSelection(
            selectionRange: selectionRange,
            newSpeaker: "C",
            segmentMap: segmentMap
        )

        // First segment should be reassigned
        XCTAssertEqual(vm.confirmedSegments[0].speaker, "C")
        XCTAssertEqual(vm.confirmedSegments[0].isUserCorrected, true)
        // Second segment should be unchanged
        XCTAssertEqual(vm.confirmedSegments[1].speaker, "B")

        // Only first segment correction should be sent to engine
        XCTAssertEqual(engine.correctedAssignments.count, 1)
        XCTAssertEqual(engine.correctedAssignments[0].oldLabel, "A")
        XCTAssertEqual(engine.correctedAssignments[0].newLabel, "C")
    }

    // MARK: - confirmedText as computed property (A-3)

    func testConfirmedTextDerivedFromSegments() {
        let (vm, _) = makeViewModel()
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0),
            ConfirmedSegment(text: "world", precedingSilence: 0.5),
        ]
        // English: space-separated (precedingSilence < threshold)
        XCTAssertEqual(vm.confirmedText, "Hello world")
    }

    func testConfirmedTextReflectsDisplayNames() {
        let (vm, _) = makeViewModel()
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: "A", speakerConfidence: 0.8),
            ConfirmedSegment(text: "World", precedingSilence: 0, speaker: "B", speakerConfidence: 0.7),
        ]
        vm.labelDisplayNames = ["A": "Alice", "B": "Bob"]
        XCTAssertTrue(vm.confirmedText.contains("Alice:"))
        XCTAssertTrue(vm.confirmedText.contains("Bob:"))
    }

    func testConfirmedTextEmptyWhenNoSegments() {
        let (vm, _) = makeViewModel()
        XCTAssertEqual(vm.confirmedText, "")
    }

    func testSaveUnconfirmedAddsSegment() async {
        let (vm, _) = makeViewModel()
        await vm.loadModel()

        vm.confirmedSegments = [ConfirmedSegment(text: "Hello")]
        vm.unconfirmedText = "World"

        // Stop recording to trigger saveUnconfirmedText
        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)
        vm.toggleRecording() // stop

        XCTAssertEqual(vm.unconfirmedText, "")
        XCTAssertTrue(vm.confirmedSegments.contains { $0.text == "World" },
                      "Unconfirmed text should be promoted to a segment")
    }

    func testStateCallbackFallbackCreatesSegment() async {
        let (vm, engine) = makeViewModel()
        await vm.loadModel()

        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Send state with text but no segments (backward compat)
        engine.simulateStateChange(TranscriptionState(
            confirmedText: "Fallback text",
            unconfirmedText: "",
            isRecording: true
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(vm.confirmedSegments.count, 1)
        XCTAssertEqual(vm.confirmedSegments[0].text, "Fallback text")
        XCTAssertEqual(vm.confirmedText, "Fallback text")
    }
}
