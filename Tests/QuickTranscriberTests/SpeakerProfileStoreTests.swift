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
            displayName: "Alice",
            embedding: [Float](repeating: 0.1, count: 256),
            lastUsed: Date(),
            sessionCount: 3
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(StoredSpeakerProfile.self, from: data)
        XCTAssertEqual(profile.id, decoded.id)
        XCTAssertEqual(profile.displayName, decoded.displayName)
        XCTAssertEqual(profile.embedding, decoded.embedding)
        XCTAssertEqual(profile.sessionCount, decoded.sessionCount)
    }

    func testDisplayNameCodable() throws {
        let profile = StoredSpeakerProfile(
            displayName: "Alice",
            embedding: [Float](repeating: 0.1, count: 256)
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(StoredSpeakerProfile.self, from: data)
        XCTAssertEqual(decoded.displayName, "Alice")
    }

    func testSaveAndLoad() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store1 = SpeakerProfileStore(directory: dir)
        let profile = StoredSpeakerProfile(displayName: "Alice", embedding: makeEmbedding(dominant: 0))
        store1.profiles = [profile]
        try store1.save()

        let store2 = SpeakerProfileStore(directory: dir)
        try store2.load()
        XCTAssertEqual(store2.profiles.count, 1)
        XCTAssertEqual(store2.profiles[0].displayName, "Alice")
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
        store.profiles = [StoredSpeakerProfile(displayName: "Alice", embedding: existingEmb, sessionCount: 2)]

        var sessionEmb = makeEmbedding(dominant: 0)
        sessionEmb[1] = 0.15
        store.mergeSessionProfiles([(speakerId: UUID(), embedding: sessionEmb, displayName: "Speaker-1")])

        XCTAssertEqual(store.profiles.count, 1, "Should update, not add")
        XCTAssertEqual(store.profiles[0].displayName, "Alice")
        XCTAssertEqual(store.profiles[0].sessionCount, 3)
        XCTAssertNotEqual(store.profiles[0].embedding, existingEmb)
    }

    func testMergeNewProfileAddsToStore() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(displayName: "Alice", embedding: makeEmbedding(dominant: 0))]

        store.mergeSessionProfiles([(speakerId: UUID(), embedding: makeEmbedding(dominant: 1), displayName: "Speaker-2")])

        XCTAssertEqual(store.profiles.count, 2)
        XCTAssertEqual(store.profiles[1].displayName, "Speaker-2")
        XCTAssertEqual(store.profiles[1].sessionCount, 1)
    }

    func testMergeUpdatesLastUsed() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let oldDate = Date.distantPast
        store.profiles = [StoredSpeakerProfile(
            displayName: "Alice", embedding: makeEmbedding(dominant: 0),
            lastUsed: oldDate, sessionCount: 1
        )]

        store.mergeSessionProfiles([(speakerId: UUID(), embedding: makeEmbedding(dominant: 0), displayName: "Speaker-1")])

        XCTAssertGreaterThan(store.profiles[0].lastUsed, oldDate)
    }

    func testMergeEmptySessionDoesNothing() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(displayName: "Alice", embedding: makeEmbedding(dominant: 0))]

        store.mergeSessionProfiles([])
        XCTAssertEqual(store.profiles.count, 1)
    }

    func testMergeMatchingProfilePreservesExistingDisplayName() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(displayName: "Alice", embedding: makeEmbedding(dominant: 0))]
        store.mergeSessionProfiles([(speakerId: UUID(), embedding: makeEmbedding(dominant: 0), displayName: "Speaker-1")])
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].displayName, "Alice", "Should preserve user-set displayName")
    }

    // MARK: - Rename

    func testRenameUpdatesDisplayName() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let id = UUID()
        store.profiles = [StoredSpeakerProfile(id: id, displayName: "Alice", embedding: makeEmbedding(dominant: 0))]
        try store.save()

        try store.rename(id: id, to: "Bob")

        XCTAssertEqual(store.profiles[0].displayName, "Bob")
        // Verify persisted
        let store2 = SpeakerProfileStore(directory: dir)
        try store2.load()
        XCTAssertEqual(store2.profiles[0].displayName, "Bob")
    }

    func testRenameNonExistentIdThrows() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(displayName: "Alice", embedding: makeEmbedding(dominant: 0))]

        XCTAssertThrowsError(try store.rename(id: UUID(), to: "Bob"))
    }

    // MARK: - Delete

    func testDeleteRemovesProfile() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let id = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: id, displayName: "Alice", embedding: makeEmbedding(dominant: 0)),
            StoredSpeakerProfile(displayName: "Bob", embedding: makeEmbedding(dominant: 1)),
        ]
        try store.save()

        try store.delete(id: id)

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].displayName, "Bob")
        // Verify persisted
        let store2 = SpeakerProfileStore(directory: dir)
        try store2.load()
        XCTAssertEqual(store2.profiles.count, 1)
    }

    func testDeleteNonExistentIdThrows() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(displayName: "Alice", embedding: makeEmbedding(dominant: 0))]

        XCTAssertThrowsError(try store.delete(id: UUID()))
    }

    // MARK: - Delete Multiple

    func testDeleteMultipleRemovesMatchingProfiles() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: id1, displayName: "Alice", embedding: makeEmbedding(dominant: 0)),
            StoredSpeakerProfile(id: id2, displayName: "Bob", embedding: makeEmbedding(dominant: 1)),
            StoredSpeakerProfile(id: id3, displayName: "Carol", embedding: makeEmbedding(dominant: 2)),
        ]
        try store.save()

        try store.deleteMultiple(ids: Set([id1, id3]))

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].id, id2)
        // Verify persisted
        let store2 = SpeakerProfileStore(directory: dir)
        try store2.load()
        XCTAssertEqual(store2.profiles.count, 1)
    }

    func testDeleteMultipleEmptySetDoesNothing() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [
            StoredSpeakerProfile(displayName: "Alice", embedding: makeEmbedding(dominant: 0)),
        ]
        try store.save()

        try store.deleteMultiple(ids: Set())

        XCTAssertEqual(store.profiles.count, 1)
    }

    // MARK: - isLocked

    func testIsLockedDefaultsToFalse() {
        let profile = StoredSpeakerProfile(displayName: "Test", embedding: [1, 2, 3])
        XCTAssertFalse(profile.isLocked)
    }

    func testIsLockedCanBeSetToTrue() {
        var profile = StoredSpeakerProfile(displayName: "Test", embedding: [1, 2, 3])
        profile.isLocked = true
        XCTAssertTrue(profile.isLocked)
    }

    func testIsLockedBackwardsCompatibleDecoding() throws {
        // JSON without isLocked field (existing data)
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","displayName":"Old","embedding":[1,2,3],"lastUsed":0,"sessionCount":1,"tags":[]}
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(StoredSpeakerProfile.self, from: json)
        XCTAssertFalse(profile.isLocked)
    }

    func testDeleteMultipleIgnoresNonexistentIds() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let id1 = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: id1, displayName: "Alice", embedding: makeEmbedding(dominant: 0)),
        ]
        try store.save()

        try store.deleteMultiple(ids: Set([UUID(), UUID()]))

        XCTAssertEqual(store.profiles.count, 1)
    }
}
