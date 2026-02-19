import XCTest
@testable import QuickTranscriberLib

final class MeetingParticipantTests: XCTestCase {

    func testIdUsesProfileIdWhenPresent() {
        let profileId = UUID()
        let p = MeetingParticipant(speakerProfileId: profileId, assignedLabel: "A", displayName: "Alice")
        XCTAssertEqual(p.id, profileId.uuidString)
    }

    func testIdFallsBackToLabelWhenNoProfileId() {
        let p = MeetingParticipant(assignedLabel: "B", displayName: "Bob")
        XCTAssertEqual(p.id, "B")
    }

    func testEquatable() {
        let id = UUID()
        let p1 = MeetingParticipant(speakerProfileId: id, assignedLabel: "A", displayName: "Alice")
        let p2 = MeetingParticipant(speakerProfileId: id, assignedLabel: "A", displayName: "Alice")
        XCTAssertEqual(p1, p2)
    }
}

@MainActor
final class MeetingParticipantViewModelTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "selectedLanguage")
        UserDefaults.standard.removeObject(forKey: "isRecording")
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingTests-\(UUID().uuidString)")
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

    func testAddParticipantFromProfile() {
        let (vm, _, store) = makeViewModel()
        let profile = StoredSpeakerProfile(label: "A", embedding: makeEmbedding(dominant: 0), displayName: "Alice")
        store.profiles = [profile]
        vm.speakerProfiles = store.profiles

        vm.addParticipantFromProfile(profile.id)

        XCTAssertEqual(vm.meetingParticipants.count, 1)
        XCTAssertEqual(vm.meetingParticipants[0].speakerProfileId, profile.id)
        XCTAssertEqual(vm.meetingParticipants[0].displayName, "Alice")
        XCTAssertEqual(vm.meetingParticipants[0].assignedLabel, "A")
    }

    func testAddParticipantFromProfileNoDuplicate() {
        let (vm, _, store) = makeViewModel()
        let profile = StoredSpeakerProfile(label: "A", embedding: makeEmbedding(dominant: 0))
        store.profiles = [profile]

        vm.addParticipantFromProfile(profile.id)
        vm.addParticipantFromProfile(profile.id)

        XCTAssertEqual(vm.meetingParticipants.count, 1)
    }

    func testAddNewParticipant() {
        let (vm, _, _) = makeViewModel()

        vm.addNewParticipant(displayName: "Bob")

        XCTAssertEqual(vm.meetingParticipants.count, 1)
        XCTAssertNil(vm.meetingParticipants[0].speakerProfileId)
        XCTAssertEqual(vm.meetingParticipants[0].displayName, "Bob")
        XCTAssertEqual(vm.meetingParticipants[0].assignedLabel, "A")
        XCTAssertEqual(vm.labelDisplayNames["A"], "Bob")
    }

    func testAddMultipleParticipantsAssignsSequentialLabels() {
        let (vm, _, store) = makeViewModel()
        let profile = StoredSpeakerProfile(label: "X", embedding: makeEmbedding(dominant: 0), displayName: "Alice")
        store.profiles = [profile]

        vm.addParticipantFromProfile(profile.id)
        vm.addNewParticipant(displayName: "Bob")

        XCTAssertEqual(vm.meetingParticipants[0].assignedLabel, "A")
        XCTAssertEqual(vm.meetingParticipants[1].assignedLabel, "B")
    }

    func testRemoveParticipant() {
        let (vm, _, _) = makeViewModel()
        vm.addNewParticipant(displayName: "Alice")
        vm.addNewParticipant(displayName: "Bob")
        XCTAssertEqual(vm.meetingParticipants.count, 2)

        vm.removeParticipant(id: vm.meetingParticipants[0].id)

        XCTAssertEqual(vm.meetingParticipants.count, 1)
        XCTAssertEqual(vm.meetingParticipants[0].displayName, "Bob")
    }

    func testClearParticipants() {
        let (vm, _, _) = makeViewModel()
        vm.addNewParticipant(displayName: "Alice")
        vm.addNewParticipant(displayName: "Bob")

        vm.clearParticipants()

        XCTAssertTrue(vm.meetingParticipants.isEmpty)
    }

    func testClearTextClearsParticipants() {
        let (vm, _, _) = makeViewModel()
        vm.addNewParticipant(displayName: "Alice")

        vm.clearText()

        XCTAssertTrue(vm.meetingParticipants.isEmpty)
    }
}
