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

        let speakerIdA = UUID()
        let speakerIdB = UUID()
        let segments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: speakerIdA.uuidString, speakerConfidence: 0.8),
            ConfirmedSegment(text: "world", precedingSilence: 0.5, speaker: speakerIdB.uuidString, speakerConfidence: 0.6),
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

        let speakerId = UUID()
        engine.simulateStateChange(TranscriptionState(
            confirmedText: "Some text",
            unconfirmedText: "",
            isRecording: true,
            confirmedSegments: [
                ConfirmedSegment(text: "Some text", precedingSilence: 0, speaker: speakerId.uuidString, speakerConfidence: 0.9),
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

    func testSpeakerDisplayNamesInitiallyEmpty() async {
        let (vm, _) = makeViewModel()
        XCTAssertTrue(vm.speakerDisplayNames.isEmpty)
    }

    func testRenameSpeakerUpdatesProfiles() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMSpeakerTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID()
        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(id: id, displayName: "Speaker-A", embedding: [Float](repeating: 0.1, count: 256))]
        try! store.save()

        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model", speakerProfileStore: store)

        vm.renameSpeaker(id: id, to: "Alice")

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
            StoredSpeakerProfile(id: idA, displayName: "Alice", embedding: [Float](repeating: 0.1, count: 256)),
            StoredSpeakerProfile(displayName: "Bob", embedding: [Float](repeating: 0.2, count: 256)),
        ]
        try! store.save()

        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model", speakerProfileStore: store)

        vm.deleteSpeaker(id: idA)

        XCTAssertEqual(vm.speakerProfiles.count, 1)
        XCTAssertEqual(vm.speakerProfiles[0].displayName, "Bob")
    }

    func testRenameAffectsFileOutput() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMSpeakerFileTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID()
        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(id: id, displayName: "Speaker-A", embedding: [Float](repeating: 0.1, count: 256))]
        try! store.save()

        let engine = MockTranscriptionEngine()
        let fileWriter = TranscriptFileWriter(transcriptsDirectory: dir)
        let vm = TranscriptionViewModel(
            engine: engine, modelName: "test-model",
            fileWriter: fileWriter, speakerProfileStore: store
        )
        await vm.loadModel()

        // Add speaker so we get display name mapping
        vm.addManualSpeaker(fromProfile: id)
        let speakerId = vm.activeSpeakers[0].id

        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Simulate segments with speaker UUID
        engine.simulateStateChange(TranscriptionState(
            confirmedText: "Hello",
            unconfirmedText: "",
            isRecording: true,
            confirmedSegments: [
                ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: speakerId.uuidString, speakerConfidence: 0.8),
            ]
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Rename speaker
        vm.renameActiveSpeaker(id: speakerId, displayName: "Alice")

        // Next state change should write with resolved name
        engine.simulateStateChange(TranscriptionState(
            confirmedText: "Hello world",
            unconfirmedText: "",
            isRecording: true,
            confirmedSegments: [
                ConfirmedSegment(text: "Hello world", precedingSilence: 0, speaker: speakerId.uuidString, speakerConfidence: 0.8),
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
            StoredSpeakerProfile(displayName: "Alice", embedding: [Float](repeating: 0.1, count: 256)),
            StoredSpeakerProfile(displayName: "Bob", embedding: [Float](repeating: 0.2, count: 256)),
        ]
        try! store.save()

        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model", speakerProfileStore: store)

        vm.deleteAllSpeakers()

        XCTAssertTrue(vm.speakerProfiles.isEmpty)
        XCTAssertTrue(vm.speakerDisplayNames.isEmpty)
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

    // MARK: - Available Speakers from Active Speakers

    func testAvailableSpeakersFromActiveSpeakers() async {
        let (vm, _) = makeViewModel()
        vm.addManualSpeaker(displayName: "Alice")
        vm.addManualSpeaker(displayName: "Bob")

        let speakers = vm.availableSpeakers
        XCTAssertEqual(speakers.count, 2)
        XCTAssertEqual(speakers[0].displayName, "Alice")
        XCTAssertEqual(speakers[1].displayName, "Bob")
    }

    func testAvailableSpeakersEmptyWhenNoActiveSpeakers() async {
        let (vm, _) = makeViewModel()
        XCTAssertTrue(vm.availableSpeakers.isEmpty)
    }

    // MARK: - Speaker Menu Order

    func testRecordSpeakerSelectionMovesIdToFront() async {
        let (vm, _) = makeViewModel()
        vm.addManualSpeaker(displayName: "Alice")
        vm.addManualSpeaker(displayName: "Bob")
        vm.addManualSpeaker(displayName: "Carol")

        let idA = vm.activeSpeakers[0].id.uuidString
        let idB = vm.activeSpeakers[1].id.uuidString
        let idC = vm.activeSpeakers[2].id.uuidString

        vm.recordSpeakerSelection(idC)
        XCTAssertEqual(vm.speakerMenuOrder, [idC])

        vm.recordSpeakerSelection(idA)
        XCTAssertEqual(vm.speakerMenuOrder, [idA, idC])

        vm.recordSpeakerSelection(idC)
        XCTAssertEqual(vm.speakerMenuOrder, [idC, idA])
    }

    func testAvailableSpeakersSortedByMenuOrder() async {
        let (vm, _) = makeViewModel()
        vm.addManualSpeaker(displayName: "Alice")
        vm.addManualSpeaker(displayName: "Bob")
        vm.addManualSpeaker(displayName: "Carol")

        let idA = vm.activeSpeakers[0].id.uuidString
        let idB = vm.activeSpeakers[1].id.uuidString
        let idC = vm.activeSpeakers[2].id.uuidString

        // Default: registration order
        XCTAssertEqual(vm.availableSpeakers.map(\.displayName), ["Alice", "Bob", "Carol"])

        vm.recordSpeakerSelection(idC)
        // C first, then remaining in registration order
        XCTAssertEqual(vm.availableSpeakers.map(\.displayName), ["Carol", "Alice", "Bob"])

        vm.recordSpeakerSelection(idB)
        // B, C first, then remaining
        XCTAssertEqual(vm.availableSpeakers.map(\.displayName), ["Bob", "Carol", "Alice"])
    }

    func testAvailableSpeakersIgnoresStaleMenuOrder() async {
        let (vm, _) = makeViewModel()
        vm.addManualSpeaker(displayName: "Alice")
        let idA = vm.activeSpeakers[0].id.uuidString
        vm.speakerMenuOrder = ["nonexistent-uuid", idA]
        XCTAssertEqual(vm.availableSpeakers.map(\.displayName), ["Alice"])
    }

    func testReassignSpeakerForBlockRecordsSpeakerSelection() {
        let (vm, _) = makeViewModel()
        vm.addManualSpeaker(displayName: "Alice")
        vm.addManualSpeaker(displayName: "Bob")
        let idA = vm.activeSpeakers[0].id.uuidString
        let idB = vm.activeSpeakers[1].id.uuidString
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: idA),
            ConfirmedSegment(text: "World", speaker: idA),
        ]
        vm.reassignSpeakerForBlock(segmentIndex: 0, newSpeaker: idB)
        XCTAssertEqual(vm.speakerMenuOrder.first, idB)
    }

    func testReassignSpeakerForSelectionRecordsSpeakerSelection() {
        let (vm, _) = makeViewModel()
        vm.addManualSpeaker(displayName: "Alice")
        vm.addManualSpeaker(displayName: "Bob")
        let idA = vm.activeSpeakers[0].id.uuidString
        let idB = vm.activeSpeakers[1].id.uuidString
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: idA),
        ]
        let map = SegmentCharacterMap(entries: [
            SegmentCharacterMap.Entry(segmentIndex: 0, characterRange: NSRange(location: 0, length: 5), labelRange: nil)
        ])
        vm.reassignSpeakerForSelection(selectionRange: NSRange(location: 0, length: 5), newSpeaker: idB, segmentMap: map)
        XCTAssertEqual(vm.speakerMenuOrder.first, idB)
    }

    // MARK: - Rename Active Speaker

    func testRenameActiveSpeakerUpdatesSpeakerDisplayNames() async {
        let (vm, _) = makeViewModel()
        vm.addManualSpeaker(displayName: "Alice")
        let speakerId = vm.activeSpeakers[0].id

        vm.renameActiveSpeaker(id: speakerId, displayName: "Alicia")

        XCTAssertEqual(vm.activeSpeakers[0].displayName, "Alicia")
        XCTAssertEqual(vm.speakerDisplayNames[speakerId.uuidString], "Alicia")
    }

    func testRenameActiveSpeakerEmptyNameClearsDisplayName() async {
        let (vm, _) = makeViewModel()
        vm.addManualSpeaker(displayName: "Alice")
        let speakerId = vm.activeSpeakers[0].id

        vm.renameActiveSpeaker(id: speakerId, displayName: "")

        XCTAssertNil(vm.activeSpeakers[0].displayName)
        XCTAssertNil(vm.speakerDisplayNames[speakerId.uuidString])
    }

    func testRenameActiveSpeakerUpdatesStoreIfProfileExists() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMRenameTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let profileId = UUID()
        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(id: profileId, displayName: "Speaker-A", embedding: [Float](repeating: 0.1, count: 256))]
        try! store.save()

        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model", speakerProfileStore: store)

        // Add active speaker from profile
        vm.addManualSpeaker(fromProfile: profileId)
        let speakerId = vm.activeSpeakers[0].id

        vm.renameActiveSpeaker(id: speakerId, displayName: "Alice")

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

        let oldSpeakerId = UUID()
        let newSpeakerId = UUID()
        let vm = TranscriptionViewModel(
            engine: engine,
            parametersStore: ParametersStore(),
            speakerProfileStore: SpeakerProfileStore(directory: dir)
        )
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: oldSpeakerId.uuidString, speakerEmbedding: emb),
            ConfirmedSegment(text: "World", speaker: oldSpeakerId.uuidString, speakerEmbedding: nil),
        ]

        vm.reassignSpeakerForBlock(segmentIndex: 0, newSpeaker: newSpeakerId.uuidString)

        // Both segments should be reassigned
        XCTAssertEqual(vm.confirmedSegments[0].speaker, newSpeakerId.uuidString)
        XCTAssertEqual(vm.confirmedSegments[0].isUserCorrected, true)
        XCTAssertEqual(vm.confirmedSegments[1].speaker, newSpeakerId.uuidString)
        XCTAssertEqual(vm.confirmedSegments[1].isUserCorrected, true)

        // Only segment with embedding should trigger correction call
        XCTAssertEqual(engine.correctedAssignments.count, 1)
        XCTAssertEqual(engine.correctedAssignments[0].oldId, oldSpeakerId)
        XCTAssertEqual(engine.correctedAssignments[0].newId, newSpeakerId)
        XCTAssertEqual(engine.correctedAssignments[0].embedding, emb)
    }

    func testReassignSpeakerForSelectionCallsCorrectSpeakerAssignment() {
        let emb: [Float] = Array(repeating: 0.2, count: 256)
        let engine = MockTranscriptionEngine()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMCorrectionTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let speakerIdA = UUID()
        let speakerIdB = UUID()
        let speakerIdC = UUID()
        let vm = TranscriptionViewModel(
            engine: engine,
            parametersStore: ParametersStore(),
            speakerProfileStore: SpeakerProfileStore(directory: dir)
        )
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: speakerIdA.uuidString, speakerConfidence: 0.8, speakerEmbedding: emb),
            ConfirmedSegment(text: "World", speaker: speakerIdB.uuidString, speakerConfidence: 0.7, speakerEmbedding: emb),
        ]

        // Build a segment map
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
            newSpeaker: speakerIdC.uuidString,
            segmentMap: segmentMap
        )

        // First segment should be reassigned
        XCTAssertEqual(vm.confirmedSegments[0].speaker, speakerIdC.uuidString)
        XCTAssertEqual(vm.confirmedSegments[0].isUserCorrected, true)
        // Second segment should be unchanged
        XCTAssertEqual(vm.confirmedSegments[1].speaker, speakerIdB.uuidString)

        // Only first segment correction should be sent to engine
        XCTAssertEqual(engine.correctedAssignments.count, 1)
        XCTAssertEqual(engine.correctedAssignments[0].oldId, speakerIdA)
        XCTAssertEqual(engine.correctedAssignments[0].newId, speakerIdC)
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
        let speakerIdA = UUID()
        let speakerIdB = UUID()
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: speakerIdA.uuidString, speakerConfidence: 0.8),
            ConfirmedSegment(text: "World", precedingSilence: 0, speaker: speakerIdB.uuidString, speakerConfidence: 0.7),
        ]
        vm.speakerDisplayNames = [speakerIdA.uuidString: "Alice", speakerIdB.uuidString: "Bob"]
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

    // MARK: - Registered Speakers For Menu

    func testAddAndReassignBlockAddsActiveSpeakerAndReassigns() {
        let profileId = UUID()
        let store = SpeakerProfileStore(directory: tmpDir)
        store.profiles = [
            StoredSpeakerProfile(id: profileId, displayName: "Alice", embedding: Array(repeating: 0.1, count: 256))
        ]
        let vm = TranscriptionViewModel(engine: MockTranscriptionEngine(), modelName: "test-model", speakerProfileStore: store)
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: "old-speaker"),
            ConfirmedSegment(text: "World", speaker: "old-speaker")
        ]

        vm.addAndReassignBlock(profileId: profileId, segmentIndex: 0)

        // Should have added an active speaker
        XCTAssertEqual(vm.activeSpeakers.count, 1)
        XCTAssertEqual(vm.activeSpeakers[0].speakerProfileId, profileId)
        // Segments in the block should be reassigned to the new speaker's UUID
        let newSpeakerIdStr = vm.activeSpeakers[0].id.uuidString
        XCTAssertEqual(vm.confirmedSegments[0].speaker, newSpeakerIdStr)
        XCTAssertEqual(vm.confirmedSegments[1].speaker, newSpeakerIdStr)
    }

    // MARK: - Active Profile IDs

    func testActiveProfileIdsReturnsProfileIdsFromActiveSpeakers() {
        let (vm, _) = makeViewModel()
        let id1 = UUID()
        let id2 = UUID()
        vm.activeSpeakers = [
            ActiveSpeaker(speakerProfileId: id1, source: .manual),
            ActiveSpeaker(source: .autoDetected),  // no profileId
            ActiveSpeaker(speakerProfileId: id2, source: .manual),
        ]
        XCTAssertEqual(vm.activeProfileIds, Set([id1, id2]))
    }

    func testActiveProfileIdsEmptyWhenNoActiveSpeakers() {
        let (vm, _) = makeViewModel()
        XCTAssertTrue(vm.activeProfileIds.isEmpty)
    }

    // MARK: - Deactivate Speaker by Profile ID

    func testDeactivateSpeakerRemovesMatchingActiveSpeaker() {
        let profileId = UUID()
        let store = SpeakerProfileStore(directory: tmpDir)
        store.profiles = [
            StoredSpeakerProfile(id: profileId, displayName: "Speaker-A", embedding: Array(repeating: 0.1, count: 256))
        ]
        let vm = TranscriptionViewModel(engine: MockTranscriptionEngine(), modelName: "test-model", speakerProfileStore: store)
        vm.activeSpeakers = [
            ActiveSpeaker(speakerProfileId: profileId, source: .manual),
            ActiveSpeaker(source: .autoDetected),
        ]

        vm.deactivateSpeaker(profileId: profileId)

        XCTAssertEqual(vm.activeSpeakers.count, 1)
        XCTAssertEqual(vm.activeSpeakers[0].source, .autoDetected)
    }

    func testDeactivateSpeakerNoOpForNonexistentProfileId() {
        let (vm, _) = makeViewModel()
        vm.activeSpeakers = [
            ActiveSpeaker(source: .manual),
        ]

        vm.deactivateSpeaker(profileId: UUID())

        XCTAssertEqual(vm.activeSpeakers.count, 1)
    }

    // MARK: - Bulk Activate Profiles

    func testBulkActivateProfilesAddsMultipleSpeakers() {
        let id1 = UUID()
        let id2 = UUID()
        let store = SpeakerProfileStore(directory: tmpDir)
        store.profiles = [
            StoredSpeakerProfile(id: id1, displayName: "Alice", embedding: Array(repeating: 0.1, count: 256)),
            StoredSpeakerProfile(id: id2, displayName: "Bob", embedding: Array(repeating: 0.2, count: 256)),
        ]
        let vm = TranscriptionViewModel(engine: MockTranscriptionEngine(), modelName: "test-model", speakerProfileStore: store)

        vm.bulkActivateProfiles(ids: [id1, id2])

        XCTAssertEqual(vm.activeSpeakers.count, 2)
        XCTAssertEqual(Set(vm.activeSpeakers.compactMap { $0.speakerProfileId }), Set([id1, id2]))
    }

    func testBulkActivateProfilesSkipsAlreadyActive() {
        let id1 = UUID()
        let id2 = UUID()
        let store = SpeakerProfileStore(directory: tmpDir)
        store.profiles = [
            StoredSpeakerProfile(id: id1, displayName: "Alice", embedding: Array(repeating: 0.1, count: 256)),
            StoredSpeakerProfile(id: id2, displayName: "Bob", embedding: Array(repeating: 0.2, count: 256)),
        ]
        let vm = TranscriptionViewModel(engine: MockTranscriptionEngine(), modelName: "test-model", speakerProfileStore: store)
        vm.addManualSpeaker(fromProfile: id1)  // already active

        vm.bulkActivateProfiles(ids: [id1, id2])

        XCTAssertEqual(vm.activeSpeakers.count, 2)  // id1 not duplicated
    }

    // MARK: - Bulk Deactivate Profiles

    func testBulkDeactivateProfilesRemovesMatchingSpeakers() {
        let id1 = UUID()
        let id2 = UUID()
        let store = SpeakerProfileStore(directory: tmpDir)
        store.profiles = [
            StoredSpeakerProfile(id: id1, displayName: "Alice", embedding: Array(repeating: 0.1, count: 256)),
            StoredSpeakerProfile(id: id2, displayName: "Bob", embedding: Array(repeating: 0.2, count: 256)),
        ]
        let vm = TranscriptionViewModel(engine: MockTranscriptionEngine(), modelName: "test-model", speakerProfileStore: store)
        vm.addManualSpeaker(fromProfile: id1)
        vm.addManualSpeaker(fromProfile: id2)
        vm.activeSpeakers.append(ActiveSpeaker(source: .autoDetected))

        vm.bulkDeactivateProfiles(ids: Set([id1, id2]))

        XCTAssertEqual(vm.activeSpeakers.count, 1)
        XCTAssertEqual(vm.activeSpeakers[0].source, .autoDetected)
    }

    // MARK: - Delete Speakers (bulk)

    func testDeleteSpeakersRemovesProfilesAndActiveSpeakers() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let store = SpeakerProfileStore(directory: tmpDir)
        store.profiles = [
            StoredSpeakerProfile(id: id1, displayName: "Alice", embedding: Array(repeating: 0.1, count: 256)),
            StoredSpeakerProfile(id: id2, displayName: "Bob", embedding: Array(repeating: 0.2, count: 256)),
            StoredSpeakerProfile(id: id3, displayName: "Carol", embedding: Array(repeating: 0.3, count: 256)),
        ]
        try! store.save()
        let vm = TranscriptionViewModel(engine: MockTranscriptionEngine(), modelName: "test-model", speakerProfileStore: store)
        vm.addManualSpeaker(fromProfile: id1)

        vm.deleteSpeakers(ids: Set([id1, id2]))

        XCTAssertEqual(vm.speakerProfiles.count, 1)
        XCTAssertEqual(vm.speakerProfiles[0].id, id3)
        XCTAssertTrue(vm.activeSpeakers.isEmpty)
    }

    // MARK: - Set Locked

    func testSetLockedUpdatesProfile() {
        let id = UUID()
        let store = SpeakerProfileStore(directory: tmpDir)
        store.profiles = [
            StoredSpeakerProfile(id: id, displayName: "Alice", embedding: Array(repeating: 0.1, count: 256)),
        ]
        try! store.save()
        let vm = TranscriptionViewModel(engine: MockTranscriptionEngine(), modelName: "test-model", speakerProfileStore: store)

        vm.setLocked(id: id, locked: true)

        XCTAssertTrue(vm.speakerProfiles.first?.isLocked == true)
    }

    // MARK: - Active Speaker Dedup (profile ID as active ID)

    func testAddManualSpeakerFromProfileUsesProfileIdAsActiveId() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMDedupTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let profileId = UUID()
        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(id: profileId, displayName: "Alice", embedding: [Float](repeating: 0.1, count: 256))]
        try! store.save()

        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model", speakerProfileStore: store)

        vm.addManualSpeaker(fromProfile: profileId)

        XCTAssertEqual(vm.activeSpeakers.count, 1)
        XCTAssertEqual(vm.activeSpeakers[0].id, profileId, "ActiveSpeaker.id should equal profile UUID")
        XCTAssertEqual(vm.activeSpeakers[0].speakerProfileId, profileId)
    }

    func testAutoDetectedSpeakerNameAvoidsExistingNames() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMDedupTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let profileId = UUID()
        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(id: profileId, displayName: "Speaker-1", embedding: [Float](repeating: 0.9, count: 256))]
        try! store.save()

        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model", speakerProfileStore: store)
        await vm.loadModel()

        // Add "Speaker-1" profile as active speaker
        vm.addManualSpeaker(fromProfile: profileId)

        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Simulate a completely different speaker (different embedding, won't match any profile)
        let newSpeakerId = UUID()
        var differentEmbedding = [Float](repeating: 0.0, count: 256)
        differentEmbedding[128] = 1.0
        engine.simulateStateChange(TranscriptionState(
            confirmedText: "Test",
            unconfirmedText: "",
            isRecording: true,
            confirmedSegments: [
                ConfirmedSegment(text: "Test", speaker: newSpeakerId.uuidString, speakerEmbedding: differentEmbedding)
            ]
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(vm.activeSpeakers.count, 2)
        let newSpeaker = vm.activeSpeakers.first(where: { $0.id == newSpeakerId })
        XCTAssertNotNil(newSpeaker)
        XCTAssertNotEqual(newSpeaker?.displayName, "Speaker-1", "Auto name should not conflict with existing")
    }

    func testAutoDetectedSpeakerDoesNotDuplicateExistingProfile() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMDedupTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let profileId = UUID()
        let embedding = [Float](repeating: 0.1, count: 256)
        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(id: profileId, displayName: "Alice", embedding: embedding)]
        try! store.save()

        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model", speakerProfileStore: store)
        await vm.loadModel()

        // Manually activate the profile
        vm.addManualSpeaker(fromProfile: profileId)
        XCTAssertEqual(vm.activeSpeakers.count, 1)

        // Start recording and simulate a segment with the profile's UUID
        // (tracker uses stored profile ID in manual mode)
        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)

        engine.simulateStateChange(TranscriptionState(
            confirmedText: "Hello",
            unconfirmedText: "",
            isRecording: true,
            confirmedSegments: [
                ConfirmedSegment(text: "Hello", speaker: profileId.uuidString, speakerEmbedding: embedding)
            ]
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Should NOT duplicate — profile already active, UUID match creates alias
        XCTAssertEqual(vm.activeSpeakers.count, 1, "Should not duplicate speaker when profile already active")
        // The profile UUID should map to Alice's display name
        XCTAssertEqual(vm.speakerDisplayNames[profileId.uuidString], "Alice")
    }

    // MARK: - Manual Mode Tracker ID Dedup Integration

    func testManualModeTrackerIdMatchesActiveSpeaker() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMDedupInteg-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let profileId = UUID()
        let embedding = [Float](repeating: 0.1, count: 256)
        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(id: profileId, displayName: "Alice", embedding: embedding)]
        try! store.save()

        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model", speakerProfileStore: store)
        await vm.loadModel()

        vm.addManualSpeaker(fromProfile: profileId)

        // After Task 1 fix, ActiveSpeaker.id == profileId
        XCTAssertEqual(vm.activeSpeakers[0].id, profileId)

        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // In manual mode, the tracker uses stored.id (= profileId) as speakerId.
        // So segments arrive with speaker == profileId.uuidString.
        // The dedup check $0.id.uuidString == speakerId should match.
        engine.simulateStateChange(TranscriptionState(
            confirmedText: "Hello",
            unconfirmedText: "",
            isRecording: true,
            confirmedSegments: [
                ConfirmedSegment(text: "Hello", speaker: profileId.uuidString, speakerEmbedding: embedding)
            ]
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(vm.activeSpeakers.count, 1, "Manual speaker should not be duplicated when tracker uses same ID")
        XCTAssertEqual(vm.speakerDisplayNames[profileId.uuidString], "Alice")
    }

    // MARK: - Delete cleanup (RC4 - data integrity)

    func testDeleteSpeakerCleansUpDisplayNamesAndActiveSpeakers() {
        let id = UUID()
        let store = SpeakerProfileStore(directory: tmpDir)
        store.profiles = [
            StoredSpeakerProfile(id: id, displayName: "Alice", embedding: Array(repeating: 0.1, count: 256)),
        ]
        try! store.save()
        let vm = TranscriptionViewModel(engine: MockTranscriptionEngine(), modelName: "test-model", speakerProfileStore: store)
        vm.addManualSpeaker(fromProfile: id)
        XCTAssertFalse(vm.speakerDisplayNames.isEmpty)
        XCTAssertFalse(vm.activeSpeakers.isEmpty)

        vm.deleteSpeaker(id: id)

        XCTAssertTrue(vm.speakerDisplayNames.isEmpty, "displayNames should be cleaned up on single delete")
        XCTAssertTrue(vm.activeSpeakers.isEmpty, "activeSpeakers should be cleaned up on single delete")
    }

    func testDeleteSpeakersCleansUpDisplayNames() {
        let id1 = UUID()
        let id2 = UUID()
        let store = SpeakerProfileStore(directory: tmpDir)
        store.profiles = [
            StoredSpeakerProfile(id: id1, displayName: "Alice", embedding: Array(repeating: 0.1, count: 256)),
            StoredSpeakerProfile(id: id2, displayName: "Bob", embedding: Array(repeating: 0.2, count: 256)),
        ]
        try! store.save()
        let vm = TranscriptionViewModel(engine: MockTranscriptionEngine(), modelName: "test-model", speakerProfileStore: store)
        vm.addManualSpeaker(fromProfile: id1)
        vm.addManualSpeaker(fromProfile: id2)

        vm.deleteSpeakers(ids: Set([id1]))

        XCTAssertEqual(vm.speakerDisplayNames.count, 1, "Only remaining speaker should have displayName")
        XCTAssertNotNil(vm.speakerDisplayNames[id2.uuidString])
    }

    func testDeleteAllSpeakersCleansUpEmbeddingHistory() {
        let embHistDir = tmpDir.appendingPathComponent("emb-hist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: embHistDir, withIntermediateDirectories: true)
        let embeddingHistoryStore = EmbeddingHistoryStore(directory: embHistDir)
        embeddingHistoryStore.appendSession(entries: [
            EmbeddingHistoryEntry(speakerProfileId: UUID(), label: "A", sessionDate: Date(),
                                 embeddings: [HistoricalEmbedding(embedding: Array(repeating: 0.1, count: 256), confirmed: true)])
        ])

        let store = SpeakerProfileStore(directory: tmpDir)
        store.profiles = [
            StoredSpeakerProfile(displayName: "Alice", embedding: Array(repeating: 0.1, count: 256)),
        ]
        try! store.save()

        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(
            engine: engine, modelName: "test-model",
            speakerProfileStore: store, embeddingHistoryStore: embeddingHistoryStore
        )

        vm.deleteAllSpeakers()

        let remaining = try! embeddingHistoryStore.loadAll()
        XCTAssertTrue(remaining.isEmpty, "Embedding history should be cleared on deleteAll")
    }

    func testDeleteSpeakerCleansUpEmbeddingHistory() {
        let embHistDir = tmpDir.appendingPathComponent("emb-hist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: embHistDir, withIntermediateDirectories: true)
        let embeddingHistoryStore = EmbeddingHistoryStore(directory: embHistDir)
        let idA = UUID()
        let idB = UUID()
        embeddingHistoryStore.appendSession(entries: [
            EmbeddingHistoryEntry(speakerProfileId: idA, label: "A", sessionDate: Date(),
                                 embeddings: [HistoricalEmbedding(embedding: Array(repeating: 0.1, count: 256), confirmed: true)]),
            EmbeddingHistoryEntry(speakerProfileId: idB, label: "B", sessionDate: Date(),
                                 embeddings: [HistoricalEmbedding(embedding: Array(repeating: 0.2, count: 256), confirmed: true)]),
        ])

        let store = SpeakerProfileStore(directory: tmpDir)
        store.profiles = [
            StoredSpeakerProfile(id: idA, displayName: "Alice", embedding: Array(repeating: 0.1, count: 256)),
            StoredSpeakerProfile(id: idB, displayName: "Bob", embedding: Array(repeating: 0.2, count: 256)),
        ]
        try! store.save()

        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(
            engine: engine, modelName: "test-model",
            speakerProfileStore: store, embeddingHistoryStore: embeddingHistoryStore
        )

        vm.deleteSpeaker(id: idA)

        let remaining = try! embeddingHistoryStore.loadAll()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].speakerProfileId, idB, "Only deleted speaker's history should be removed")
    }

    // MARK: - preExistingProfileIds (RC3 fix)

    func testPreExistingProfileIdsInitiallyEmpty() {
        let (vm, _) = makeViewModel()
        XCTAssertTrue(vm.preExistingProfileIds.isEmpty)
    }

    // MARK: - linkActiveSpeakersToProfiles (RC2 fix)

    func testLinkActiveSpeakersMatchesByIdFirst() {
        let profileId = UUID()
        let store = SpeakerProfileStore(directory: tmpDir)
        store.profiles = [
            StoredSpeakerProfile(id: profileId, displayName: "Alice", embedding: Array(repeating: 0.1, count: 256))
        ]
        try! store.save()
        let vm = TranscriptionViewModel(engine: MockTranscriptionEngine(), modelName: "test-model", speakerProfileStore: store)

        // Active speaker has the same UUID as the profile (session UUID == profile ID from RC2 fix)
        vm.activeSpeakers = [
            ActiveSpeaker(id: profileId, speakerProfileId: nil, displayName: "Speaker-1", source: .autoDetected)
        ]
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: profileId.uuidString, speakerEmbedding: Array(repeating: 0.1, count: 256))
        ]

        vm.linkActiveSpeakersToProfiles()

        XCTAssertEqual(vm.activeSpeakers[0].speakerProfileId, profileId,
                        "Should match by ID first without needing embedding similarity")
    }

    func testLinkActiveSpeakersCreatesProfileForUnlinked() {
        let store = SpeakerProfileStore(directory: tmpDir)
        try! store.save()
        let vm = TranscriptionViewModel(engine: MockTranscriptionEngine(), modelName: "test-model", speakerProfileStore: store)

        let speakerId = UUID()
        let embedding: [Float] = Array(repeating: 0.5, count: 256)
        vm.activeSpeakers = [
            ActiveSpeaker(id: speakerId, speakerProfileId: nil, displayName: "Speaker-1", source: .autoDetected)
        ]
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: speakerId.uuidString, speakerEmbedding: embedding)
        ]

        vm.linkActiveSpeakersToProfiles()

        XCTAssertEqual(vm.activeSpeakers[0].speakerProfileId, speakerId,
                        "Should create a new profile for unlinked speaker and link it")
        XCTAssertEqual(store.profiles.count, 1, "Should have created one new profile")
        XCTAssertEqual(store.profiles[0].id, speakerId)
        XCTAssertEqual(store.profiles[0].displayName, "Speaker-1")
    }

    func testLinkActiveSpeakersSavesAndUpdatesProfiles() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let profileId = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: profileId, displayName: "Alice", embedding: Array(repeating: 0.1, count: 256))
        ]
        try! store.save()
        let vm = TranscriptionViewModel(engine: MockTranscriptionEngine(), modelName: "test-model", speakerProfileStore: store)

        let newSpeakerId = UUID()
        vm.activeSpeakers = [
            ActiveSpeaker(id: newSpeakerId, speakerProfileId: nil, displayName: "Speaker-2", source: .autoDetected)
        ]
        // Use orthogonal embedding to avoid similarity match
        var differentEmb = Array(repeating: Float(0.0), count: 256)
        differentEmb[128] = 1.0
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Test", speaker: newSpeakerId.uuidString, speakerEmbedding: differentEmb)
        ]

        vm.linkActiveSpeakersToProfiles()

        // Should persist new profile
        XCTAssertEqual(vm.speakerProfiles.count, 2, "speakerProfiles should be refreshed")
        // Verify persisted
        let store2 = SpeakerProfileStore(directory: tmpDir)
        try! store2.load()
        XCTAssertEqual(store2.profiles.count, 2, "New profile should be persisted to disk")
    }

    // MARK: - Single authority refactoring

    func testModeSwitchMidSessionUsesSnapshotMode() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let vm = TranscriptionViewModel(
            engine: MockTranscriptionEngine(), modelName: "test-model",
            speakerProfileStore: store
        )

        // Set manual mode and snapshot it
        vm.parametersStore.parameters.diarizationMode = .manual
        vm.snapshotDiarizationMode()

        // Switch to auto mode AFTER snapshot
        vm.parametersStore.parameters.diarizationMode = .auto

        // addAutoDetectedSpeaker should still use the snapshot (manual),
        // blocking new speaker addition
        let speakerId = UUID().uuidString
        vm.addAutoDetectedSpeaker(speakerId: speakerId, embedding: nil)

        XCTAssertEqual(vm.activeSpeakers.count, 0,
                       "Should use snapshot mode (manual), not current mode (auto)")
    }

    func testManualModeNoSpeakersPassesEmptyArray() async throws {
        let engine = MockTranscriptionEngine()
        let store = SpeakerProfileStore(directory: tmpDir)
        let vm = TranscriptionViewModel(
            engine: engine, modelName: "test-model",
            speakerProfileStore: store
        )

        // Prepare engine so service.isReady = true
        await vm.loadModel()

        // Manual mode with no active speakers
        vm.parametersStore.parameters.diarizationMode = .manual
        vm.parametersStore.parameters.enableSpeakerDiarization = true

        vm.toggleRecording()

        // Wait for the async Task in startRecording to execute
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(engine.startStreamingCalled, "Engine should have been called")
        // Key assertion: empty array, NOT nil
        XCTAssertNotNil(engine.startStreamingParticipantProfiles,
                        "Manual mode should pass empty array, not nil")
        XCTAssertEqual(engine.startStreamingParticipantProfiles?.count, 0,
                        "Manual mode with no speakers should pass empty array")
    }

    func testAutoDetectedSpeakerWithMatchingProfileIdLinksDirectly() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let profileId = UUID()
        store.profiles = [StoredSpeakerProfile(id: profileId, displayName: "Alice", embedding: makeEmbedding(dominant: 0))]
        let vm = TranscriptionViewModel(
            engine: MockTranscriptionEngine(), modelName: "test-model",
            speakerProfileStore: store
        )

        // Tracker uses the stored profile's UUID directly
        vm.addAutoDetectedSpeaker(speakerId: profileId.uuidString, embedding: makeEmbedding(dominant: 0))

        XCTAssertEqual(vm.activeSpeakers.count, 1)
        XCTAssertEqual(vm.activeSpeakers[0].speakerProfileId, profileId,
                       "Should link to profile by UUID match")
        XCTAssertEqual(vm.activeSpeakers[0].displayName, "Alice")
    }

    func testAutoDetectedSpeakerSimilarEmbeddingDifferentIdDoesNotLink() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let profileId = UUID()
        store.profiles = [StoredSpeakerProfile(id: profileId, displayName: "Alice", embedding: makeEmbedding(dominant: 0))]
        let vm = TranscriptionViewModel(
            engine: MockTranscriptionEngine(), modelName: "test-model",
            speakerProfileStore: store
        )

        // Tracker uses a DIFFERENT UUID but with similar embedding
        let newTrackerId = UUID()
        vm.addAutoDetectedSpeaker(speakerId: newTrackerId.uuidString, embedding: makeEmbedding(dominant: 0))

        // Should NOT link to Alice's profile (different UUID)
        XCTAssertEqual(vm.activeSpeakers.count, 1)
        XCTAssertNil(vm.activeSpeakers[0].speakerProfileId,
                     "Should NOT link via embedding similarity — UUID mismatch")
    }

    // MARK: - Fix 1: historicalSpeakerNames

    func testRemovedSpeakerDisplayNamePreservedInHistory() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let vm = TranscriptionViewModel(
            engine: MockTranscriptionEngine(), modelName: "test-model",
            speakerProfileStore: store
        )
        let speakerId = UUID()
        vm.activeSpeakers = [
            ActiveSpeaker(id: speakerId, displayName: "Alice", source: .autoDetected)
        ]
        vm.speakerDisplayNames = [speakerId.uuidString: "Alice"]

        vm.removeActiveSpeaker(id: speakerId)

        // After removal, the display name should still be available as fallback
        XCTAssertEqual(vm.speakerDisplayNames[speakerId.uuidString], "Alice",
                       "Removed speaker's display name should be preserved via historicalSpeakerNames")
    }

    func testClearTextResetsHistoricalSpeakerNames() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let vm = TranscriptionViewModel(
            engine: MockTranscriptionEngine(), modelName: "test-model",
            speakerProfileStore: store
        )
        let speakerId = UUID()
        vm.activeSpeakers = [
            ActiveSpeaker(id: speakerId, displayName: "Alice", source: .autoDetected)
        ]
        vm.speakerDisplayNames = [speakerId.uuidString: "Alice"]
        vm.removeActiveSpeaker(id: speakerId)
        // historicalSpeakerNames should have "Alice"
        XCTAssertEqual(vm.speakerDisplayNames[speakerId.uuidString], "Alice")

        vm.clearText()

        // After clearText, historical names should be gone too
        XCTAssertTrue(vm.speakerDisplayNames.isEmpty,
                      "clearText should reset historicalSpeakerNames")
    }

    // MARK: - Fix 2: restartRecording passes speakerDisplayNames

    func testRestartRecordingPassesSpeakerDisplayNames() async {
        let engine = MockTranscriptionEngine()
        let store = SpeakerProfileStore(directory: tmpDir)
        let vm = TranscriptionViewModel(
            engine: engine, modelName: "test-model",
            speakerProfileStore: store
        )
        await vm.loadModel()

        // Set up active speaker with display name
        let speakerId = UUID()
        vm.activeSpeakers = [
            ActiveSpeaker(id: speakerId, displayName: "Alice", source: .manual)
        ]
        vm.speakerDisplayNames = [speakerId.uuidString: "Alice"]

        // Start recording
        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(engine.startStreamingCalled)

        // Trigger restart by simulating parameter change
        engine.stopStreamingSpeakerDisplayNames = nil  // reset
        vm.restartRecording()
        try? await Task.sleep(nanoseconds: 300_000_000)

        // stopStreaming should have been called with the display names
        XCTAssertNotNil(engine.stopStreamingSpeakerDisplayNames,
                        "restartRecording should pass speakerDisplayNames to stopTranscription")
        XCTAssertEqual(engine.stopStreamingSpeakerDisplayNames?[speakerId.uuidString], "Alice")
    }

    // MARK: - Fix 3: Deferred profile deletion during recording

    func testDeleteSpeakerDuringRecordingDefersProfileDeletion() async {
        let id = UUID()
        let store = SpeakerProfileStore(directory: tmpDir)
        store.profiles = [
            StoredSpeakerProfile(id: id, displayName: "Alice", embedding: Array(repeating: 0.1, count: 256)),
        ]
        try! store.save()
        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(
            engine: engine, modelName: "test-model",
            speakerProfileStore: store
        )
        await vm.loadModel()

        vm.addManualSpeaker(fromProfile: id)
        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(vm.isRecording)

        // Delete during recording
        vm.deleteSpeaker(id: id)

        // UI should reflect removal immediately
        XCTAssertTrue(vm.activeSpeakers.isEmpty,
                      "Active speakers should be cleaned up immediately")
        // But the profile should still exist in the store (deferred)
        XCTAssertEqual(store.profiles.count, 1,
                       "Profile deletion should be deferred during recording")
    }

    func testDeferredDeletionExecutedOnStop() async {
        let id = UUID()
        let store = SpeakerProfileStore(directory: tmpDir)
        store.profiles = [
            StoredSpeakerProfile(id: id, displayName: "Alice", embedding: Array(repeating: 0.1, count: 256)),
        ]
        try! store.save()
        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(
            engine: engine, modelName: "test-model",
            speakerProfileStore: store
        )
        await vm.loadModel()

        vm.addManualSpeaker(fromProfile: id)
        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Delete during recording
        vm.deleteSpeaker(id: id)
        XCTAssertEqual(store.profiles.count, 1, "Deferred — not yet deleted")

        // Stop recording
        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Now the deferred deletion should have been flushed
        XCTAssertEqual(store.profiles.count, 0,
                       "Deferred deletion should be flushed after stop")
    }

    func testClearTextResetsPendingDeletions() async {
        let id = UUID()
        let store = SpeakerProfileStore(directory: tmpDir)
        store.profiles = [
            StoredSpeakerProfile(id: id, displayName: "Alice", embedding: Array(repeating: 0.1, count: 256)),
        ]
        try! store.save()
        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(
            engine: engine, modelName: "test-model",
            speakerProfileStore: store
        )
        await vm.loadModel()

        vm.addManualSpeaker(fromProfile: id)
        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 200_000_000)

        vm.deleteSpeaker(id: id)
        XCTAssertTrue(vm.pendingProfileDeletions.contains(id))

        vm.clearText()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(vm.pendingProfileDeletions.isEmpty,
                      "clearText should reset pendingProfileDeletions")
    }

    // MARK: - Fix 4: Locked profile similarity matching in linkActiveSpeakersToProfiles

    func testLinkActiveSpeakersMatchesLockedProfileBySimilarity() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let lockedProfileId = UUID()
        let embedding = makeEmbedding(dominant: 0)
        store.profiles = [
            StoredSpeakerProfile(id: lockedProfileId, displayName: "Alice", embedding: embedding, isLocked: true)
        ]
        try! store.save()
        let vm = TranscriptionViewModel(
            engine: MockTranscriptionEngine(), modelName: "test-model",
            speakerProfileStore: store
        )

        // Auto-detected speaker with different UUID but very similar embedding
        let trackerId = UUID()
        var similarEmbedding = makeEmbedding(dominant: 0)
        similarEmbedding[1] = 0.1  // slightly different but still very similar
        vm.activeSpeakers = [
            ActiveSpeaker(id: trackerId, speakerProfileId: nil, displayName: "Speaker-1", source: .autoDetected)
        ]
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: trackerId.uuidString, speakerEmbedding: similarEmbedding)
        ]

        vm.linkActiveSpeakersToProfiles()

        XCTAssertEqual(vm.activeSpeakers[0].speakerProfileId, lockedProfileId,
                       "Should match locked profile by embedding similarity")
    }

    func testLinkActiveSpeakersDoesNotMatchUnlockedProfileBySimilarity() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let unlockedProfileId = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: unlockedProfileId, displayName: "Alice", embedding: makeEmbedding(dominant: 0))
        ]
        try! store.save()
        let vm = TranscriptionViewModel(
            engine: MockTranscriptionEngine(), modelName: "test-model",
            speakerProfileStore: store
        )

        // Auto-detected speaker with different UUID but very similar embedding
        let trackerId = UUID()
        vm.activeSpeakers = [
            ActiveSpeaker(id: trackerId, speakerProfileId: nil, displayName: "Speaker-1", source: .autoDetected)
        ]
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: trackerId.uuidString, speakerEmbedding: makeEmbedding(dominant: 0))
        ]

        vm.linkActiveSpeakersToProfiles()

        // Should NOT match by similarity — profile is not locked
        XCTAssertNotEqual(vm.activeSpeakers[0].speakerProfileId, unlockedProfileId,
                          "Should NOT match unlocked profile by similarity")
    }

    func testLinkActiveSpeakersDissimilarEmbeddingDoesNotMatchLockedProfile() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let lockedProfileId = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: lockedProfileId, displayName: "Alice", embedding: makeEmbedding(dominant: 0), isLocked: true)
        ]
        try! store.save()
        let vm = TranscriptionViewModel(
            engine: MockTranscriptionEngine(), modelName: "test-model",
            speakerProfileStore: store
        )

        // Auto-detected speaker with very different embedding
        let trackerId = UUID()
        vm.activeSpeakers = [
            ActiveSpeaker(id: trackerId, speakerProfileId: nil, displayName: "Speaker-1", source: .autoDetected)
        ]
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: trackerId.uuidString, speakerEmbedding: makeEmbedding(dominant: 128))
        ]

        vm.linkActiveSpeakersToProfiles()

        // Should NOT match — embedding too different even though profile is locked
        XCTAssertNotEqual(vm.activeSpeakers[0].speakerProfileId, lockedProfileId,
                          "Dissimilar embedding should not match locked profile")
    }

}

private func makeEmbedding(dominant dim: Int, dimensions: Int = 256) -> [Float] {
    var v = [Float](repeating: 0.01, count: dimensions)
    v[dim] = 1.0
    return v
}
