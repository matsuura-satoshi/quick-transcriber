import XCTest
@testable import QuickTranscriberLib

final class SpeakerProfileStoreTests: XCTestCase {

    private func makeTempDirectory() -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerProfileStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeEmbedding(dominant dim: Int, dimensions: Int = 256) -> [Float] {
        var v = [Float](repeating: 0.01, count: dimensions)
        v[dim] = 1.0
        return v
    }

    func testStoredSpeakerProfileCodable() throws {
        let profile = StoredSpeakerProfile(
            id: UUID(),
            label: "A",
            embedding: [Float](repeating: 0.1, count: 256),
            lastUsed: Date(),
            sessionCount: 3
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(StoredSpeakerProfile.self, from: data)
        XCTAssertEqual(profile.id, decoded.id)
        XCTAssertEqual(profile.label, decoded.label)
        XCTAssertEqual(profile.embedding, decoded.embedding)
        XCTAssertEqual(profile.sessionCount, decoded.sessionCount)
    }

    func testDisplayNameCodable() throws {
        let profile = StoredSpeakerProfile(
            label: "A",
            embedding: [Float](repeating: 0.1, count: 256),
            displayName: "Alice"
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(StoredSpeakerProfile.self, from: data)
        XCTAssertEqual(decoded.displayName, "Alice")
    }

    func testDisplayNameNilByDefault() {
        let profile = StoredSpeakerProfile(
            label: "A",
            embedding: [Float](repeating: 0.1, count: 256)
        )
        XCTAssertNil(profile.displayName)
    }

    func testDisplayNameBackwardCompatibility() throws {
        // JSON without displayName field should decode fine
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","label":"B","embedding":[0.1],"lastUsed":0,"sessionCount":2}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(StoredSpeakerProfile.self, from: data)
        XCTAssertEqual(decoded.label, "B")
        XCTAssertNil(decoded.displayName)
    }

    func testSaveAndLoad() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store1 = SpeakerProfileStore(directory: dir)
        let profile = StoredSpeakerProfile(label: "A", embedding: makeEmbedding(dominant: 0))
        store1.profiles = [profile]
        try store1.save()

        let store2 = SpeakerProfileStore(directory: dir)
        try store2.load()
        XCTAssertEqual(store2.profiles.count, 1)
        XCTAssertEqual(store2.profiles[0].label, "A")
        XCTAssertEqual(store2.profiles[0].embedding, profile.embedding)
    }

    func testLoadFromNonexistentFileReturnsEmpty() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        try store.load()
        XCTAssertTrue(store.profiles.isEmpty)
    }

    func testMergeMatchingProfileUpdatesExisting() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let existingEmb = makeEmbedding(dominant: 0)
        store.profiles = [StoredSpeakerProfile(label: "A", embedding: existingEmb, sessionCount: 2)]

        var sessionEmb = makeEmbedding(dominant: 0)
        sessionEmb[1] = 0.15
        store.mergeSessionProfiles([("A", sessionEmb)])

        XCTAssertEqual(store.profiles.count, 1, "Should update, not add")
        XCTAssertEqual(store.profiles[0].label, "A")
        XCTAssertEqual(store.profiles[0].sessionCount, 3)
        XCTAssertNotEqual(store.profiles[0].embedding, existingEmb)
    }

    func testMergeNewProfileAddsToStore() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(label: "A", embedding: makeEmbedding(dominant: 0))]

        store.mergeSessionProfiles([("B", makeEmbedding(dominant: 1))])

        XCTAssertEqual(store.profiles.count, 2)
        XCTAssertEqual(store.profiles[1].label, "B")
        XCTAssertEqual(store.profiles[1].sessionCount, 1)
    }

    func testMergeUpdatesLastUsed() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let oldDate = Date.distantPast
        store.profiles = [StoredSpeakerProfile(
            label: "A", embedding: makeEmbedding(dominant: 0),
            lastUsed: oldDate, sessionCount: 1
        )]

        store.mergeSessionProfiles([("A", makeEmbedding(dominant: 0))])

        XCTAssertGreaterThan(store.profiles[0].lastUsed, oldDate)
    }

    func testMergeEmptySessionDoesNothing() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(label: "A", embedding: makeEmbedding(dominant: 0))]

        store.mergeSessionProfiles([])
        XCTAssertEqual(store.profiles.count, 1)
    }

    // MARK: - Rename

    func testRenameUpdatesDisplayName() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let id = UUID()
        store.profiles = [StoredSpeakerProfile(id: id, label: "A", embedding: makeEmbedding(dominant: 0))]
        try store.save()

        try store.rename(id: id, to: "Alice")

        XCTAssertEqual(store.profiles[0].displayName, "Alice")
        // Verify persisted
        let store2 = SpeakerProfileStore(directory: dir)
        try store2.load()
        XCTAssertEqual(store2.profiles[0].displayName, "Alice")
    }

    func testRenameNonExistentIdThrows() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(label: "A", embedding: makeEmbedding(dominant: 0))]

        XCTAssertThrowsError(try store.rename(id: UUID(), to: "Bob"))
    }

    // MARK: - Delete

    func testDeleteRemovesProfile() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let id = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: id, label: "A", embedding: makeEmbedding(dominant: 0)),
            StoredSpeakerProfile(label: "B", embedding: makeEmbedding(dominant: 1)),
        ]
        try store.save()

        try store.delete(id: id)

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].label, "B")
        // Verify persisted
        let store2 = SpeakerProfileStore(directory: dir)
        try store2.load()
        XCTAssertEqual(store2.profiles.count, 1)
    }

    func testDeleteNonExistentIdThrows() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(label: "A", embedding: makeEmbedding(dominant: 0))]

        XCTAssertThrowsError(try store.delete(id: UUID()))
    }

    // MARK: - Display Name Resolution

    func testDisplayNameForLabelWithDisplayName() {
        let store = SpeakerProfileStore(directory: makeTempDirectory())
        store.profiles = [
            StoredSpeakerProfile(label: "A", embedding: makeEmbedding(dominant: 0), displayName: "Alice"),
        ]
        XCTAssertEqual(store.displayName(for: "A"), "Alice")
    }

    func testDisplayNameForLabelWithoutDisplayName() {
        let store = SpeakerProfileStore(directory: makeTempDirectory())
        store.profiles = [
            StoredSpeakerProfile(label: "A", embedding: makeEmbedding(dominant: 0)),
        ]
        XCTAssertEqual(store.displayName(for: "A"), "A")
    }

    func testDisplayNameForUnknownLabel() {
        let store = SpeakerProfileStore(directory: makeTempDirectory())
        store.profiles = []
        XCTAssertEqual(store.displayName(for: "Z"), "Z")
    }

    func testLabelDisplayNames() {
        let store = SpeakerProfileStore(directory: makeTempDirectory())
        store.profiles = [
            StoredSpeakerProfile(label: "A", embedding: makeEmbedding(dominant: 0), displayName: "Alice"),
            StoredSpeakerProfile(label: "B", embedding: makeEmbedding(dominant: 1)),
        ]
        let names = store.labelDisplayNames
        XCTAssertEqual(names["A"], "Alice")
        XCTAssertEqual(names["B"], "B")
    }
}
