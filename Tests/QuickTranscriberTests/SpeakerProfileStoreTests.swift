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
}
