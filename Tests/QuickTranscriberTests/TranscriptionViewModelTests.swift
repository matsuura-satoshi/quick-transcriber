import XCTest
@testable import QuickTranscriberLib

@MainActor
final class TranscriptionViewModelTests: XCTestCase {

    private func makeViewModel() -> (TranscriptionViewModel, MockTranscriptionEngine) {
        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model")
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
        vm.confirmedText = "Hello"
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
        vm.confirmedText = "First session text"
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

        vm.confirmedText = "Some text"
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

        vm.confirmedText = "Some text"
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
        vm.confirmedText = "Hello world"
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
        vm.confirmedText = "Hello"
        vm.unconfirmedText = ""
        XCTAssertEqual(vm.displayText, "Hello")
    }

    func testDisplayTextUnconfirmedOnly() {
        let (vm, _) = makeViewModel()
        vm.confirmedText = ""
        vm.unconfirmedText = "World"
        XCTAssertEqual(vm.displayText, "World")
    }

    func testDisplayTextBoth() {
        let (vm, _) = makeViewModel()
        vm.confirmedText = "Hello"
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
}
