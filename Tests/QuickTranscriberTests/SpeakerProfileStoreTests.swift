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
        let profile = StoredSpeakerProfile(displayName: "Alice", embedding: existingEmb, sessionCount: 2)
        store.profiles = [profile]

        var sessionEmb = makeEmbedding(dominant: 0)
        sessionEmb[1] = 0.15
        store.mergeSessionProfiles([(speakerId: profile.id, embedding: sessionEmb, displayName: "Speaker-1")])

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
        let profile = StoredSpeakerProfile(
            displayName: "Alice", embedding: makeEmbedding(dominant: 0),
            lastUsed: oldDate, sessionCount: 1
        )
        store.profiles = [profile]

        store.mergeSessionProfiles([(speakerId: profile.id, embedding: makeEmbedding(dominant: 0), displayName: "Speaker-1")])

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
        let profile = StoredSpeakerProfile(displayName: "Alice", embedding: makeEmbedding(dominant: 0))
        store.profiles = [profile]
        store.mergeSessionProfiles([(speakerId: profile.id, embedding: makeEmbedding(dominant: 0), displayName: "Speaker-1")])
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

    // MARK: - setLocked

    func testSetLockedTrue() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let profile = StoredSpeakerProfile(displayName: "Alice", embedding: [1, 2, 3])
        store.profiles = [profile]
        try store.save()

        try store.setLocked(id: profile.id, locked: true)
        XCTAssertTrue(store.profiles[0].isLocked)

        // Verify persisted
        let store2 = SpeakerProfileStore(directory: dir)
        try store2.load()
        XCTAssertTrue(store2.profiles[0].isLocked)
    }

    func testSetLockedNotFoundThrows() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        XCTAssertThrowsError(try store.setLocked(id: UUID(), locked: true))
    }

    // MARK: - Delete skips locked profiles

    func testDeleteSkipsLockedProfile() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let profile = StoredSpeakerProfile(displayName: "Alice", embedding: [1, 2, 3], isLocked: true)
        store.profiles = [profile]
        try store.save()

        try store.delete(id: profile.id)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].id, profile.id)
    }

    func testDeleteMultipleSkipsLockedProfiles() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let locked = StoredSpeakerProfile(displayName: "Locked", embedding: [1, 2, 3], isLocked: true)
        let unlocked = StoredSpeakerProfile(displayName: "Unlocked", embedding: [4, 5, 6])
        store.profiles = [locked, unlocked]
        try store.save()

        try store.deleteMultiple(ids: Set([locked.id, unlocked.id]))
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].id, locked.id)
    }

    func testDeleteAllSkipsLockedProfiles() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let locked = StoredSpeakerProfile(displayName: "Locked", embedding: [1, 2, 3], isLocked: true)
        let unlocked = StoredSpeakerProfile(displayName: "Unlocked", embedding: [4, 5, 6])
        store.profiles = [locked, unlocked]
        try store.save()

        store.deleteAll()
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].id, locked.id)
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

    // MARK: - Merge by speakerId

    func testMergeByIdMatchesEvenWithDriftedEmbedding() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let profileId = UUID()
        let originalEmbedding = makeEmbedding(dominant: 0)
        store.profiles = [StoredSpeakerProfile(id: profileId, displayName: "Alice", embedding: originalEmbedding)]

        // Very different embedding (cosine similarity < 0.5 with original) but same speakerId
        let driftedEmbedding = makeEmbedding(dominant: 100)
        store.mergeSessionProfiles([(speakerId: profileId, embedding: driftedEmbedding, displayName: "Alice")])

        XCTAssertEqual(store.profiles.count, 1, "Should update existing profile by ID, not create new one")
        XCTAssertEqual(store.profiles[0].sessionCount, 2)
    }

    // MARK: - Cross-contamination prevention (RC1)

    func testMergeDoesNotCrossContaminateNewProfilesInSameBatch() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        // No existing profiles — all speakers are new

        let spk1 = UUID()
        let spk2 = UUID()
        let spk3 = UUID()
        // Three very different embeddings
        let emb1 = makeEmbedding(dominant: 0)
        let emb2 = makeEmbedding(dominant: 50)
        let emb3 = makeEmbedding(dominant: 100)

        store.mergeSessionProfiles([
            (speakerId: spk1, embedding: emb1, displayName: "Speaker-1"),
            (speakerId: spk2, embedding: emb2, displayName: "Speaker-2"),
            (speakerId: spk3, embedding: emb3, displayName: "Speaker-3"),
        ])

        XCTAssertEqual(store.profiles.count, 3,
                        "Each new speaker should create a separate profile, not merge into earlier new profiles")
        let profileNames = Set(store.profiles.map { $0.displayName })
        XCTAssertEqual(profileNames, Set(["Speaker-1", "Speaker-2", "Speaker-3"]))
    }

    func testMergeNewProfilePreservesSessionUUID() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let sessionId = UUID()

        store.mergeSessionProfiles([
            (speakerId: sessionId, embedding: makeEmbedding(dominant: 0), displayName: "Speaker-1"),
        ])

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].id, sessionId,
                        "New profile should use the session speakerId as its UUID")
    }

    func testMergeNewProfilesWithSimilarEmbeddingsNotCrossContaminated() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        // Two speakers with somewhat similar embeddings (but different UUIDs)
        var emb1 = makeEmbedding(dominant: 0)
        var emb2 = makeEmbedding(dominant: 0)
        emb2[1] = 0.3  // slightly different

        let spk1 = UUID()
        let spk2 = UUID()

        store.mergeSessionProfiles([
            (speakerId: spk1, embedding: emb1, displayName: "Speaker-1"),
            (speakerId: spk2, embedding: emb2, displayName: "Speaker-2"),
        ])

        XCTAssertEqual(store.profiles.count, 2,
                        "Similar but distinct session speakers should not be merged within a single batch")
    }

    // MARK: - Single authority: no embedding similarity fallback

    func testMergeSimilarEmbeddingDifferentIdCreatesNewProfile() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let existingId = UUID()
        store.profiles = [StoredSpeakerProfile(id: existingId, displayName: "Alice", embedding: makeEmbedding(dominant: 0))]

        // Same embedding but different UUID → should create new profile, NOT update Alice
        let newId = UUID()
        store.mergeSessionProfiles([(speakerId: newId, embedding: makeEmbedding(dominant: 0), displayName: "Speaker-1")])

        XCTAssertEqual(store.profiles.count, 2,
                       "Similar embedding with different ID should create new profile, not update existing")
        XCTAssertEqual(store.profiles[0].displayName, "Alice")
        XCTAssertEqual(store.profiles[0].sessionCount, 1, "Alice should NOT be updated")
        XCTAssertEqual(store.profiles[1].id, newId)
        XCTAssertEqual(store.profiles[1].displayName, "Speaker-1")
    }

    // MARK: - Fix 4: Locked profile similarity matching in mergeSessionProfiles

    func testMergeSimilarEmbeddingDoesNotMatchLockedProfile() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let lockedId = UUID()
        let embedding = makeEmbedding(dominant: 0)
        store.profiles = [StoredSpeakerProfile(id: lockedId, displayName: "Alice", embedding: embedding, isLocked: true)]

        // New speaker with different UUID but very similar embedding
        let newId = UUID()
        var similarEmbedding = makeEmbedding(dominant: 0)
        similarEmbedding[1] = 0.1
        store.mergeSessionProfiles([(speakerId: newId, embedding: similarEmbedding, displayName: "Speaker-1")])

        XCTAssertEqual(store.profiles.count, 2,
                       "Should NOT merge into locked profile — should create new profile")
        XCTAssertEqual(store.profiles[0].id, lockedId)
        XCTAssertEqual(store.profiles[0].sessionCount, 1, "Locked profile should NOT be updated")
        XCTAssertEqual(store.profiles[1].id, newId)
        XCTAssertEqual(store.profiles[1].displayName, "Speaker-1")
    }

    func testMergeDoesNotMatchUnlockedProfileBySimilarity() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let unlockedId = UUID()
        store.profiles = [StoredSpeakerProfile(id: unlockedId, displayName: "Alice", embedding: makeEmbedding(dominant: 0))]

        // New speaker with similar embedding but different UUID and profile is NOT locked
        let newId = UUID()
        store.mergeSessionProfiles([(speakerId: newId, embedding: makeEmbedding(dominant: 0), displayName: "Speaker-1")])

        XCTAssertEqual(store.profiles.count, 2,
                       "Should NOT match unlocked profile by similarity — should create new profile")
    }

    func testMergeDissimilarEmbeddingDoesNotMatchLockedProfile() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let lockedId = UUID()
        store.profiles = [StoredSpeakerProfile(id: lockedId, displayName: "Alice", embedding: makeEmbedding(dominant: 0), isLocked: true)]

        // New speaker with very different embedding
        let newId = UUID()
        store.mergeSessionProfiles([(speakerId: newId, embedding: makeEmbedding(dominant: 128), displayName: "Speaker-1")])

        XCTAssertEqual(store.profiles.count, 2,
                       "Dissimilar embedding should NOT match locked profile — should create new profile")
    }


    // MARK: - forceDelete

    func testForceDeleteIgnoresLocked() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let id = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: id, displayName: "Alice", embedding: makeEmbedding(dominant: 0), isLocked: true)
        ]
        try store.save()

        try store.forceDelete(id: id)

        XCTAssertTrue(store.profiles.isEmpty, "forceDelete should remove even locked profiles")

        // Verify persistence
        let store2 = SpeakerProfileStore(directory: dir)
        try store2.load()
        XCTAssertTrue(store2.profiles.isEmpty)
    }

    func testForceDeleteThrowsForMissingProfile() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)

        XCTAssertThrowsError(try store.forceDelete(id: UUID())) { error in
            XCTAssertEqual(error as? SpeakerProfileStoreError, .profileNotFound)
        }
    }
}
