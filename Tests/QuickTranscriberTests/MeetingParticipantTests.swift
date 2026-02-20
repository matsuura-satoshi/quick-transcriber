import XCTest
@testable import QuickTranscriberLib

final class ActiveSpeakerTests: XCTestCase {

    func testIdIsAlwaysUUID() {
        let profileId = UUID()
        let speaker = ActiveSpeaker(speakerProfileId: profileId, sessionLabel: "A", displayName: "Alice", source: .manual)
        XCTAssertNotEqual(speaker.id, profileId) // id is independent UUID
    }

    func testEquatable() {
        let id = UUID()
        let s1 = ActiveSpeaker(id: id, sessionLabel: "A", displayName: "Alice", source: .manual)
        let s2 = ActiveSpeaker(id: id, sessionLabel: "A", displayName: "Alice", source: .manual)
        XCTAssertEqual(s1, s2)
    }

    func testSourceValues() {
        let manual = ActiveSpeaker(sessionLabel: "A", source: .manual)
        let auto = ActiveSpeaker(sessionLabel: "B", source: .autoDetected)
        XCTAssertEqual(manual.source, .manual)
        XCTAssertEqual(auto.source, .autoDetected)
    }
}

@MainActor
final class ActiveSpeakerViewModelTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "selectedLanguage")
        UserDefaults.standard.removeObject(forKey: "isRecording")
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActiveSpeakerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private func makeEmbedding(dominant dim: Int, dimensions: Int = 256) -> [Float] {
        var v = [Float](repeating: 0.01, count: dimensions)
        v[dim] = 1.0
        return v
    }

    private func makeViewModel() -> (TranscriptionViewModel, MockTranscriptionEngine, SpeakerProfileStore) {
        let engine = MockTranscriptionEngine()
        let store = SpeakerProfileStore(directory: tmpDir)
        let vm = TranscriptionViewModel(
            engine: engine,
            modelName: "test-model",
            speakerProfileStore: store
        )
        return (vm, engine, store)
    }

    func testAddManualSpeakerFromProfile() {
        let (vm, _, store) = makeViewModel()
        let profile = StoredSpeakerProfile(label: "A", embedding: makeEmbedding(dominant: 0), displayName: "Alice")
        store.profiles = [profile]
        vm.speakerProfiles = store.profiles

        vm.addManualSpeaker(fromProfile: profile.id)

        XCTAssertEqual(vm.activeSpeakers.count, 1)
        XCTAssertEqual(vm.activeSpeakers[0].speakerProfileId, profile.id)
        XCTAssertEqual(vm.activeSpeakers[0].displayName, "Alice")
        XCTAssertEqual(vm.activeSpeakers[0].sessionLabel, "A")
        XCTAssertEqual(vm.activeSpeakers[0].source, .manual)
    }

    func testAddManualSpeakerFromProfileNoDuplicate() {
        let (vm, _, store) = makeViewModel()
        let profile = StoredSpeakerProfile(label: "A", embedding: makeEmbedding(dominant: 0))
        store.profiles = [profile]

        vm.addManualSpeaker(fromProfile: profile.id)
        vm.addManualSpeaker(fromProfile: profile.id)

        XCTAssertEqual(vm.activeSpeakers.count, 1)
    }

    func testAddManualSpeakerByName() {
        let (vm, _, _) = makeViewModel()

        vm.addManualSpeaker(displayName: "Bob")

        XCTAssertEqual(vm.activeSpeakers.count, 1)
        XCTAssertNil(vm.activeSpeakers[0].speakerProfileId)
        XCTAssertEqual(vm.activeSpeakers[0].displayName, "Bob")
        XCTAssertEqual(vm.activeSpeakers[0].sessionLabel, "A")
        XCTAssertEqual(vm.activeSpeakers[0].source, .manual)
        XCTAssertEqual(vm.labelDisplayNames["A"], "Bob")
    }

    func testAddMultipleSpeakersAssignsSequentialLabels() {
        let (vm, _, store) = makeViewModel()
        let profile = StoredSpeakerProfile(label: "X", embedding: makeEmbedding(dominant: 0), displayName: "Alice")
        store.profiles = [profile]

        vm.addManualSpeaker(fromProfile: profile.id)
        vm.addManualSpeaker(displayName: "Bob")

        XCTAssertEqual(vm.activeSpeakers[0].sessionLabel, "A")
        XCTAssertEqual(vm.activeSpeakers[1].sessionLabel, "B")
    }

    func testRemoveActiveSpeaker() {
        let (vm, _, _) = makeViewModel()
        vm.addManualSpeaker(displayName: "Alice")
        vm.addManualSpeaker(displayName: "Bob")
        XCTAssertEqual(vm.activeSpeakers.count, 2)

        vm.removeActiveSpeaker(id: vm.activeSpeakers[0].id)

        XCTAssertEqual(vm.activeSpeakers.count, 1)
        XCTAssertEqual(vm.activeSpeakers[0].displayName, "Bob")
    }

    func testClearActiveSpeakers() {
        let (vm, _, _) = makeViewModel()
        vm.addManualSpeaker(displayName: "Alice")
        vm.addManualSpeaker(displayName: "Bob")

        vm.clearActiveSpeakers()

        XCTAssertTrue(vm.activeSpeakers.isEmpty)
    }

    func testClearActiveSpeakersBySource() {
        let (vm, _, _) = makeViewModel()
        vm.addManualSpeaker(displayName: "Alice")
        // Simulate auto-detected speaker via confirmedSegments
        vm.activeSpeakers.append(ActiveSpeaker(
            sessionLabel: "B",
            displayName: "Auto Speaker",
            source: .autoDetected
        ))
        XCTAssertEqual(vm.activeSpeakers.count, 2)

        vm.clearActiveSpeakers(source: .manual)

        XCTAssertEqual(vm.activeSpeakers.count, 1)
        XCTAssertEqual(vm.activeSpeakers[0].source, .autoDetected)
    }

    func testClearTextClearsActiveSpeakers() {
        let (vm, _, _) = makeViewModel()
        vm.addManualSpeaker(displayName: "Alice")

        vm.clearText()

        XCTAssertTrue(vm.activeSpeakers.isEmpty)
    }

    func testAvailableSpeakersFromActiveSpeakers() {
        let (vm, _, _) = makeViewModel()
        vm.addManualSpeaker(displayName: "Alice")
        vm.addManualSpeaker(displayName: "Bob")

        let speakers = vm.availableSpeakers
        XCTAssertEqual(speakers.count, 2)
        XCTAssertEqual(speakers[0].label, "A")
        XCTAssertEqual(speakers[0].displayName, "Alice")
        XCTAssertEqual(speakers[1].label, "B")
        XCTAssertEqual(speakers[1].displayName, "Bob")
    }

    func testRenameActiveSpeaker() {
        let (vm, _, _) = makeViewModel()
        vm.addManualSpeaker(displayName: "Alice")

        vm.renameActiveSpeaker(label: "A", displayName: "Alicia")

        XCTAssertEqual(vm.activeSpeakers[0].displayName, "Alicia")
        XCTAssertEqual(vm.labelDisplayNames["A"], "Alicia")
    }

    // MARK: - Active speaker change auto-restart

    private func makeViewModelWithStore() -> (TranscriptionViewModel, MockTranscriptionEngine, ParametersStore) {
        let engine = MockTranscriptionEngine()
        let store = SpeakerProfileStore(directory: tmpDir)
        let paramsStore = ParametersStore()
        paramsStore.parameters.diarizationMode = .manual
        let vm = TranscriptionViewModel(
            engine: engine,
            modelName: "test-model",
            parametersStore: paramsStore,
            speakerProfileStore: store
        )
        return (vm, engine, paramsStore)
    }

    func testManualSpeakerChangeRestartsDuringManualRecording() async throws {
        let (vm, engine, _) = makeViewModelWithStore()
        await vm.loadModel()
        vm.toggleRecording()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(vm.isRecording)
        let initialCount = engine.startStreamingCallCount
        XCTAssertEqual(initialCount, 1)

        vm.addManualSpeaker(displayName: "Alice")

        // Wait for 500ms debounce + 100ms restart margin
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertEqual(engine.startStreamingCallCount, initialCount + 1)
        XCTAssertTrue(vm.isRecording)
    }

    func testManualSpeakerChangeDoesNotRestartInAutoMode() async throws {
        let (vm, engine, paramsStore) = makeViewModelWithStore()
        paramsStore.parameters.diarizationMode = .auto
        // Wait for parameters debounce to settle
        try await Task.sleep(nanoseconds: 600_000_000)

        await vm.loadModel()
        vm.toggleRecording()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(vm.isRecording)
        let initialCount = engine.startStreamingCallCount

        vm.addManualSpeaker(displayName: "Alice")

        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertEqual(engine.startStreamingCallCount, initialCount)
    }

    func testManualSpeakerChangeDoesNotRestartWhenNotRecording() async throws {
        let (vm, engine, _) = makeViewModelWithStore()
        XCTAssertFalse(vm.isRecording)
        let initialCount = engine.startStreamingCallCount

        vm.addManualSpeaker(displayName: "Alice")

        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertEqual(engine.startStreamingCallCount, initialCount)
    }

    func testAutoDetectedSpeakerDoesNotTriggerRestart() async throws {
        let (vm, engine, _) = makeViewModelWithStore()
        await vm.loadModel()
        vm.toggleRecording()
        try await Task.sleep(nanoseconds: 200_000_000)
        let initialCount = engine.startStreamingCallCount

        // Simulate auto-detected speaker addition (not manual)
        vm.activeSpeakers.append(ActiveSpeaker(
            sessionLabel: "B",
            displayName: nil,
            source: .autoDetected
        ))

        try await Task.sleep(nanoseconds: 800_000_000)

        // Should NOT restart because autoDetected changes are filtered out
        XCTAssertEqual(engine.startStreamingCallCount, initialCount)
    }
}
