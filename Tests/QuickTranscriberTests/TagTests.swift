import XCTest
@testable import QuickTranscriberLib

final class TagTests: XCTestCase {

    private func makeTempDirectory() -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TagTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeEmbedding(dominant dim: Int, dimensions: Int = 256) -> [Float] {
        var v = [Float](repeating: 0.01, count: dimensions)
        v[dim] = 1.0
        return v
    }

    // MARK: - StoredSpeakerProfile Tags

    func testTagsDefaultsToEmpty() {
        let profile = StoredSpeakerProfile(label: "A", embedding: makeEmbedding(dominant: 0))
        XCTAssertEqual(profile.tags, [])
    }

    func testTagsCodable() throws {
        let profile = StoredSpeakerProfile(
            label: "A",
            embedding: makeEmbedding(dominant: 0),
            tags: ["team-alpha", "eng"]
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(StoredSpeakerProfile.self, from: data)
        XCTAssertEqual(decoded.tags, ["team-alpha", "eng"])
    }

    func testTagsBackwardCompatibility() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","label":"A","embedding":[0.1],"lastUsed":0,"sessionCount":1}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(StoredSpeakerProfile.self, from: data)
        XCTAssertEqual(decoded.tags, [])
    }

    // MARK: - SpeakerProfileStore Tag Operations

    func testAddTag() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let id = UUID()
        store.profiles = [StoredSpeakerProfile(id: id, label: "A", embedding: makeEmbedding(dominant: 0))]
        try store.save()

        try store.addTag("team-alpha", to: id)

        XCTAssertEqual(store.profiles[0].tags, ["team-alpha"])
        // Verify persisted
        let store2 = SpeakerProfileStore(directory: dir)
        try store2.load()
        XCTAssertEqual(store2.profiles[0].tags, ["team-alpha"])
    }

    func testAddDuplicateTagIgnored() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let id = UUID()
        store.profiles = [StoredSpeakerProfile(id: id, label: "A", embedding: makeEmbedding(dominant: 0), tags: ["eng"])]
        try store.save()

        try store.addTag("eng", to: id)

        XCTAssertEqual(store.profiles[0].tags, ["eng"])
    }

    func testAddEmptyTagIgnored() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let id = UUID()
        store.profiles = [StoredSpeakerProfile(id: id, label: "A", embedding: makeEmbedding(dominant: 0))]
        try store.save()

        try store.addTag("  ", to: id)

        XCTAssertEqual(store.profiles[0].tags, [])
    }

    func testRemoveTag() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let id = UUID()
        store.profiles = [StoredSpeakerProfile(id: id, label: "A", embedding: makeEmbedding(dominant: 0), tags: ["eng", "team-alpha"])]
        try store.save()

        try store.removeTag("eng", from: id)

        XCTAssertEqual(store.profiles[0].tags, ["team-alpha"])
    }

    func testAddTagToNonExistentProfileThrows() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        XCTAssertThrowsError(try store.addTag("eng", to: UUID()))
    }

    func testAllTags() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [
            StoredSpeakerProfile(label: "A", embedding: makeEmbedding(dominant: 0), tags: ["eng", "team-alpha"]),
            StoredSpeakerProfile(label: "B", embedding: makeEmbedding(dominant: 1), tags: ["team-alpha", "mgmt"]),
        ]

        let tags = store.allTags
        XCTAssertEqual(tags, ["eng", "mgmt", "team-alpha"])
    }

    func testProfilesWithTag() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [
            StoredSpeakerProfile(label: "A", embedding: makeEmbedding(dominant: 0), tags: ["eng"]),
            StoredSpeakerProfile(label: "B", embedding: makeEmbedding(dominant: 1), tags: ["mgmt"]),
            StoredSpeakerProfile(label: "C", embedding: makeEmbedding(dominant: 2), tags: ["eng"]),
        ]

        let result = store.profiles(withTag: "eng")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map { $0.label }, ["A", "C"])
    }

    func testProfilesMatchingSearch() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [
            StoredSpeakerProfile(label: "A", embedding: makeEmbedding(dominant: 0), displayName: "Alice", tags: ["eng"]),
            StoredSpeakerProfile(label: "B", embedding: makeEmbedding(dominant: 1), displayName: "Bob"),
            StoredSpeakerProfile(label: "C", embedding: makeEmbedding(dominant: 2), tags: ["eng"]),
        ]

        // Search by displayName
        XCTAssertEqual(store.profiles(matching: "alice").count, 1)
        // Search by label
        XCTAssertEqual(store.profiles(matching: "B").count, 1)
        // Search by tag
        XCTAssertEqual(store.profiles(matching: "eng").count, 2)
        // Empty search returns all
        XCTAssertEqual(store.profiles(matching: "").count, 3)
    }
}

@MainActor
final class TagViewModelTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "selectedLanguage")
        UserDefaults.standard.removeObject(forKey: "isRecording")
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TagVMTests-\(UUID().uuidString)")
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

    private func makeViewModel() -> (TranscriptionViewModel, SpeakerProfileStore) {
        let engine = MockTranscriptionEngine()
        let store = SpeakerProfileStore(directory: tmpDir)
        let vm = TranscriptionViewModel(
            engine: engine,
            modelName: "test-model",
            speakerProfileStore: store
        )
        return (vm, store)
    }

    func testAddAndRemoveTag() {
        let (vm, store) = makeViewModel()
        let id = UUID()
        store.profiles = [StoredSpeakerProfile(id: id, label: "A", embedding: makeEmbedding(dominant: 0))]
        try? store.save()
        vm.speakerProfiles = store.profiles

        vm.addTag("eng", to: id)
        XCTAssertEqual(vm.speakerProfiles[0].tags, ["eng"])

        vm.removeTag("eng", from: id)
        XCTAssertEqual(vm.speakerProfiles[0].tags, [])
    }

    func testAddParticipantsByTag() {
        let (vm, store) = makeViewModel()
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: id1, label: "A", embedding: makeEmbedding(dominant: 0), displayName: "Alice", tags: ["team"]),
            StoredSpeakerProfile(id: id2, label: "B", embedding: makeEmbedding(dominant: 1), displayName: "Bob", tags: ["team"]),
            StoredSpeakerProfile(id: id3, label: "C", embedding: makeEmbedding(dominant: 2), displayName: "Charlie"),
        ]
        try? store.save()
        vm.speakerProfiles = store.profiles

        vm.addParticipantsByTag("team")

        XCTAssertEqual(vm.meetingParticipants.count, 2)
        XCTAssertEqual(Set(vm.meetingParticipants.map { $0.displayName }), Set(["Alice", "Bob"]))
    }

    func testAddParticipantsByTagSkipsDuplicates() {
        let (vm, store) = makeViewModel()
        let id1 = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: id1, label: "A", embedding: makeEmbedding(dominant: 0), tags: ["team"]),
        ]
        try? store.save()
        vm.speakerProfiles = store.profiles

        vm.addParticipantFromProfile(id1)
        vm.addParticipantsByTag("team")

        XCTAssertEqual(vm.meetingParticipants.count, 1)
    }

    func testAllTags() {
        let (vm, store) = makeViewModel()
        store.profiles = [
            StoredSpeakerProfile(label: "A", embedding: makeEmbedding(dominant: 0), tags: ["eng", "team"]),
            StoredSpeakerProfile(label: "B", embedding: makeEmbedding(dominant: 1), tags: ["mgmt"]),
        ]
        vm.speakerProfiles = store.profiles

        XCTAssertEqual(vm.allTags, ["eng", "mgmt", "team"])
    }
}
