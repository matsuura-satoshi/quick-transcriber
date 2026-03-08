import XCTest
@testable import QuickTranscriberLib

@MainActor
final class SpeakerStateCoordinatorTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoordinatorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private func makeCoordinator(
        profiles: [StoredSpeakerProfile] = []
    ) -> (SpeakerStateCoordinator, SpeakerProfileStore) {
        let store = SpeakerProfileStore(directory: tmpDir)
        store.profiles = profiles
        let embeddingStore = EmbeddingHistoryStore(directory: tmpDir)
        let coordinator = SpeakerStateCoordinator(
            profileStore: store,
            embeddingHistoryStore: embeddingStore
        )
        return (coordinator, store)
    }

    private func makeEmbedding(dominant: Int, dims: Int = 192) -> [Float] {
        var emb = [Float](repeating: 0, count: dims)
        emb[dominant % dims] = 1.0
        return emb
    }

    // MARK: - Name Generation

    func testGenerateSpeakerNameIncrements() {
        let (coord, _) = makeCoordinator()
        let name1 = coord.generateSpeakerName()
        let name2 = coord.generateSpeakerName()
        XCTAssertEqual(name1, "Speaker-1")
        XCTAssertEqual(name2, "Speaker-2")
    }

    func testGenerateSpeakerNameSkipsExisting() {
        let (coord, _) = makeCoordinator(profiles: [
            StoredSpeakerProfile(displayName: "Speaker-1", embedding: makeEmbedding(dominant: 0))
        ])
        let name = coord.generateSpeakerName()
        XCTAssertEqual(name, "Speaker-2", "Should skip Speaker-1 (used by stored profile)")
    }

    func testNextSpeakerPlaceholder() {
        let (coord, _) = makeCoordinator()
        XCTAssertEqual(coord.nextSpeakerPlaceholder, "Speaker-1")
        _ = coord.generateSpeakerName()
        XCTAssertEqual(coord.nextSpeakerPlaceholder, "Speaker-2")
    }

    // MARK: - Add Manual Speaker

    func testAddManualSpeakerFromProfile() {
        let profileId = UUID()
        let (coord, _) = makeCoordinator(profiles: [
            StoredSpeakerProfile(id: profileId, displayName: "Alice", embedding: makeEmbedding(dominant: 0))
        ])

        coord.addManualSpeaker(fromProfile: profileId)

        XCTAssertEqual(coord.activeSpeakers.count, 1)
        XCTAssertEqual(coord.activeSpeakers[0].id, profileId)
        XCTAssertEqual(coord.activeSpeakers[0].displayName, "Alice")
        XCTAssertEqual(coord.activeSpeakers[0].source, .manual)
        XCTAssertEqual(coord.speakerDisplayNames[profileId.uuidString], "Alice")
    }

    func testAddManualSpeakerFromProfileNoop() {
        let profileId = UUID()
        let (coord, _) = makeCoordinator(profiles: [
            StoredSpeakerProfile(id: profileId, displayName: "Alice", embedding: makeEmbedding(dominant: 0))
        ])

        coord.addManualSpeaker(fromProfile: profileId)
        coord.addManualSpeaker(fromProfile: profileId) // duplicate

        XCTAssertEqual(coord.activeSpeakers.count, 1, "Should not add duplicate")
    }

    func testAddManualSpeakerByDisplayName() {
        let (coord, _) = makeCoordinator()
        coord.addManualSpeaker(displayName: "Bob")

        XCTAssertEqual(coord.activeSpeakers.count, 1)
        XCTAssertEqual(coord.activeSpeakers[0].displayName, "Bob")
    }

    func testAddManualSpeakerEmptyNameGeneratesName() {
        let (coord, _) = makeCoordinator()
        coord.addManualSpeaker(displayName: "")

        XCTAssertEqual(coord.activeSpeakers.count, 1)
        XCTAssertEqual(coord.activeSpeakers[0].displayName, "Speaker-1")
    }

    func testAddManualSpeakerDuplicateNameNoop() {
        let (coord, _) = makeCoordinator()
        coord.addManualSpeaker(displayName: "Bob")
        coord.addManualSpeaker(displayName: "bob") // case-insensitive duplicate

        XCTAssertEqual(coord.activeSpeakers.count, 1, "Should not add case-insensitive duplicate")
    }

    // MARK: - Remove Active Speaker

    func testRemoveActiveSpeakerPreservesHistoricalName() {
        let (coord, _) = makeCoordinator()
        coord.addManualSpeaker(displayName: "Charlie")
        let speakerId = coord.activeSpeakers[0].id

        coord.removeActiveSpeaker(id: speakerId)

        XCTAssertTrue(coord.activeSpeakers.isEmpty)
        XCTAssertEqual(coord.historicalSpeakerNames[speakerId.uuidString], "Charlie")
        XCTAssertTrue(coord.removedSpeakerIds.contains(speakerId))
    }

    func testRemoveActiveSpeakerCleansUpAliases() {
        let (coord, _) = makeCoordinator()
        coord.addManualSpeaker(displayName: "Dave")
        let speakerId = coord.activeSpeakers[0].id
        coord.trackerAliases["tracker-1"] = speakerId

        coord.removeActiveSpeaker(id: speakerId)

        XCTAssertTrue(coord.trackerAliases.isEmpty, "Aliases pointing to removed speaker should be cleaned")
    }

    // MARK: - Clear Active Speakers

    func testClearActiveSpeakersAll() {
        let (coord, _) = makeCoordinator()
        coord.addManualSpeaker(displayName: "A")
        coord.addManualSpeaker(displayName: "B")

        coord.clearActiveSpeakers()

        XCTAssertTrue(coord.activeSpeakers.isEmpty)
    }

    func testClearActiveSpeakersBySource() {
        let profileId = UUID()
        let (coord, _) = makeCoordinator(profiles: [
            StoredSpeakerProfile(id: profileId, displayName: "Manual", embedding: makeEmbedding(dominant: 0))
        ])
        coord.addManualSpeaker(fromProfile: profileId)
        coord.addAutoDetectedSpeaker(speakerId: UUID().uuidString, embedding: nil)

        coord.clearActiveSpeakers(source: .autoDetected)

        XCTAssertEqual(coord.activeSpeakers.count, 1)
        XCTAssertEqual(coord.activeSpeakers[0].source, .manual)
    }

    // MARK: - Auto-Detected Speaker

    func testAddAutoDetectedSpeaker() {
        let (coord, _) = makeCoordinator()
        coord.recordingDiarizationMode = .auto
        let speakerId = UUID().uuidString

        coord.addAutoDetectedSpeaker(speakerId: speakerId, embedding: nil)

        XCTAssertEqual(coord.activeSpeakers.count, 1)
        XCTAssertEqual(coord.activeSpeakers[0].source, .autoDetected)
    }

    func testAutoDetectedSpeakerBlockedInManualMode() {
        let (coord, _) = makeCoordinator()
        coord.recordingDiarizationMode = .manual

        coord.addAutoDetectedSpeaker(speakerId: UUID().uuidString, embedding: nil)

        XCTAssertTrue(coord.activeSpeakers.isEmpty, "Manual mode should block new auto-detected speakers")
    }

    func testAutoDetectedSpeakerBlockedIfRemoved() {
        let (coord, _) = makeCoordinator()
        coord.recordingDiarizationMode = .auto
        let uuid = UUID()
        coord.removedSpeakerIds.insert(uuid)

        coord.addAutoDetectedSpeaker(speakerId: uuid.uuidString, embedding: nil)

        XCTAssertTrue(coord.activeSpeakers.isEmpty, "Removed speakers should not be re-added")
    }

    // MARK: - Rename Active Speaker

    func testRenameActiveSpeaker() {
        let (coord, _) = makeCoordinator()
        coord.addManualSpeaker(displayName: "OldName")
        let id = coord.activeSpeakers[0].id

        coord.renameActiveSpeaker(id: id, displayName: "NewName")

        XCTAssertEqual(coord.activeSpeakers[0].displayName, "NewName")
        XCTAssertEqual(coord.speakerDisplayNames[id.uuidString], "NewName")
    }

    func testRenameActiveSpeakerUpdatesProfile() {
        let profileId = UUID()
        let (coord, store) = makeCoordinator(profiles: [
            StoredSpeakerProfile(id: profileId, displayName: "OldProfile", embedding: makeEmbedding(dominant: 0))
        ])
        coord.addManualSpeaker(fromProfile: profileId)

        coord.renameActiveSpeaker(id: profileId, displayName: "NewProfile")

        XCTAssertEqual(store.profiles[0].displayName, "NewProfile")
    }

    // MARK: - Available Speakers

    func testAvailableSpeakersRespectsMenuOrder() {
        let (coord, _) = makeCoordinator()
        coord.addManualSpeaker(displayName: "A")
        coord.addManualSpeaker(displayName: "B")
        let idA = coord.activeSpeakers[0].id.uuidString
        let idB = coord.activeSpeakers[1].id.uuidString

        // Record selection of B, making it first
        coord.recordSpeakerSelection(idB)

        let speakers = coord.availableSpeakers
        XCTAssertEqual(speakers[0].displayName, "B")
        XCTAssertEqual(speakers[1].displayName, "A")

        // Record selection of A
        coord.recordSpeakerSelection(idA)

        let speakers2 = coord.availableSpeakers
        XCTAssertEqual(speakers2[0].displayName, "A")
        XCTAssertEqual(speakers2[1].displayName, "B")
    }

    func testAvailableSpeakersDeduplicates() {
        let (coord, _) = makeCoordinator()
        let sharedId = UUID()
        coord.activeSpeakers = [
            ActiveSpeaker(id: sharedId, displayName: "Speaker-A", source: .autoDetected),
            ActiveSpeaker(id: sharedId, displayName: "Speaker-B", source: .manual)
        ]

        let speakers = coord.availableSpeakers
        XCTAssertEqual(speakers.count, 1, "Should deduplicate by ID")
        XCTAssertEqual(speakers[0].displayName, "Speaker-A", "First entry wins")
    }

    // MARK: - Speaker Display Names

    func testUpdateSpeakerDisplayNamesIncludesAliases() {
        let (coord, _) = makeCoordinator()
        coord.addManualSpeaker(displayName: "Alice")
        let aliceId = coord.activeSpeakers[0].id
        coord.trackerAliases["tracker-uuid-1"] = aliceId

        coord.updateSpeakerDisplayNames()

        XCTAssertEqual(coord.speakerDisplayNames["tracker-uuid-1"], "Alice")
    }

    func testUpdateSpeakerDisplayNamesIncludesHistorical() {
        let (coord, _) = makeCoordinator()
        coord.historicalSpeakerNames["old-uuid"] = "LegacySpeaker"

        coord.updateSpeakerDisplayNames()

        XCTAssertEqual(coord.speakerDisplayNames["old-uuid"], "LegacySpeaker")
    }

    // MARK: - Reassign Segments

    func testReassignSegment() {
        let (coord, _) = makeCoordinator()
        let speakerA = UUID().uuidString
        let speakerB = UUID().uuidString
        var segments = [
            ConfirmedSegment(text: "Hello", speaker: speakerA, speakerConfidence: 0.8)
        ]

        coord.reassignSegment(at: 0, to: speakerB, segments: &segments)

        XCTAssertEqual(segments[0].speaker, speakerB)
        XCTAssertEqual(segments[0].originalSpeaker, speakerA)
        XCTAssertEqual(segments[0].speakerConfidence, 1.0)
        XCTAssertTrue(segments[0].isUserCorrected)
    }

    func testReassignSpeakerForBlockCoversConsecutiveSegments() {
        let (coord, _) = makeCoordinator()
        let speakerA = UUID().uuidString
        let speakerB = UUID().uuidString
        let speakerC = UUID().uuidString
        var segments = [
            ConfirmedSegment(text: "A1", speaker: speakerA),
            ConfirmedSegment(text: "A2", speaker: speakerA),
            ConfirmedSegment(text: "B1", speaker: speakerB),
        ]

        coord.reassignSpeakerForBlock(segmentIndex: 0, newSpeaker: speakerC, segments: &segments)

        XCTAssertEqual(segments[0].speaker, speakerC)
        XCTAssertEqual(segments[1].speaker, speakerC)
        XCTAssertEqual(segments[2].speaker, speakerB, "Other blocks should not be affected")
    }

    // MARK: - Split Segment

    func testSplitSegment() {
        let (coord, _) = makeCoordinator()
        var segments = [
            ConfirmedSegment(text: "HelloWorld", precedingSilence: 1.0, speaker: "s1")
        ]

        coord.splitSegment(at: 0, offset: 5, segments: &segments)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Hello")
        XCTAssertEqual(segments[0].precedingSilence, 1.0)
        XCTAssertEqual(segments[1].text, "World")
        XCTAssertEqual(segments[1].precedingSilence, 0)
    }

    // MARK: - Reset

    func testResetClearsAllState() {
        let (coord, _) = makeCoordinator()
        coord.addManualSpeaker(displayName: "Test")
        coord.trackerAliases["x"] = UUID()
        coord.removedSpeakerIds.insert(UUID())
        coord.historicalSpeakerNames["y"] = "Z"
        coord.pendingProfileDeletions.insert(UUID())

        coord.reset()

        XCTAssertTrue(coord.activeSpeakers.isEmpty)
        XCTAssertTrue(coord.speakerDisplayNames.isEmpty)
        XCTAssertTrue(coord.trackerAliases.isEmpty)
        XCTAssertTrue(coord.removedSpeakerIds.isEmpty)
        XCTAssertTrue(coord.historicalSpeakerNames.isEmpty)
        XCTAssertTrue(coord.pendingProfileDeletions.isEmpty)
    }

    // MARK: - Delete Speaker

    func testDeleteSpeakerNotRecording() {
        let profileId = UUID()
        let (coord, store) = makeCoordinator(profiles: [
            StoredSpeakerProfile(id: profileId, displayName: "ToDelete", embedding: makeEmbedding(dominant: 0))
        ])
        coord.addManualSpeaker(fromProfile: profileId)

        coord.deleteSpeaker(id: profileId, isRecording: false)

        XCTAssertTrue(coord.activeSpeakers.isEmpty)
        XCTAssertTrue(store.profiles.isEmpty, "Profile should be deleted immediately when not recording")
    }

    func testDeleteSpeakerDuringRecordingDefersProfileDeletion() {
        let profileId = UUID()
        let (coord, store) = makeCoordinator(profiles: [
            StoredSpeakerProfile(id: profileId, displayName: "ToDelete", embedding: makeEmbedding(dominant: 0))
        ])
        coord.addManualSpeaker(fromProfile: profileId)

        coord.deleteSpeaker(id: profileId, isRecording: true)

        XCTAssertTrue(coord.activeSpeakers.isEmpty, "Should remove from active speakers immediately")
        XCTAssertFalse(store.profiles.isEmpty, "Profile deletion should be deferred during recording")
        XCTAssertTrue(coord.pendingProfileDeletions.contains(profileId))
    }

    func testFlushPendingDeletions() {
        let profileId = UUID()
        let (coord, store) = makeCoordinator(profiles: [
            StoredSpeakerProfile(id: profileId, displayName: "Pending", embedding: makeEmbedding(dominant: 0))
        ])
        coord.pendingProfileDeletions.insert(profileId)

        coord.flushPendingDeletions()

        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertTrue(coord.pendingProfileDeletions.isEmpty)
    }

    // MARK: - Link Active Speakers to Profiles

    func testLinkActiveSpeakersToProfiles() {
        let (coord, store) = makeCoordinator()
        let speakerId = UUID()
        coord.activeSpeakers = [
            ActiveSpeaker(id: speakerId, displayName: "NewSpeaker", source: .autoDetected)
        ]
        let segments = [
            ConfirmedSegment(text: "Hello", speaker: speakerId.uuidString, speakerEmbedding: makeEmbedding(dominant: 0))
        ]

        let created = coord.linkActiveSpeakersToProfiles(segments: segments)

        XCTAssertTrue(created, "Should create a new profile")
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].id, speakerId)
        XCTAssertEqual(coord.activeSpeakers[0].speakerProfileId, speakerId)
    }

    // MARK: - Invariant Checker

    func testInvariantCheckerPassesWithValidState() {
        let profileId = UUID()
        let (coord, _) = makeCoordinator(profiles: [
            StoredSpeakerProfile(id: profileId, displayName: "Valid", embedding: makeEmbedding(dominant: 0))
        ])
        coord.addManualSpeaker(fromProfile: profileId)

        let segments = [
            ConfirmedSegment(text: "Hello", speaker: profileId.uuidString)
        ]

        // Should not assert
        coord.verifyInvariants(segments: segments)
    }

    func testInvariantCheckerPassesWithHistoricalNames() {
        let removedId = UUID()
        let (coord, _) = makeCoordinator()
        coord.historicalSpeakerNames[removedId.uuidString] = "Removed"
        coord.updateSpeakerDisplayNames()

        let segments = [
            ConfirmedSegment(text: "Hello", speaker: removedId.uuidString)
        ]

        // Should not assert — historical name covers the segment
        coord.verifyInvariants(segments: segments)
    }

    // MARK: - Bulk Operations

    func testBulkActivateAndDeactivate() {
        let id1 = UUID()
        let id2 = UUID()
        let (coord, _) = makeCoordinator(profiles: [
            StoredSpeakerProfile(id: id1, displayName: "P1", embedding: makeEmbedding(dominant: 0)),
            StoredSpeakerProfile(id: id2, displayName: "P2", embedding: makeEmbedding(dominant: 1)),
        ])

        coord.bulkActivateProfiles(ids: [id1, id2])
        XCTAssertEqual(coord.activeSpeakers.count, 2)

        coord.bulkDeactivateProfiles(ids: Set([id1]))
        XCTAssertEqual(coord.activeSpeakers.count, 1)
        XCTAssertEqual(coord.activeSpeakers[0].speakerProfileId, id2)
    }

    func testAddManualSpeakersByTag() {
        let id1 = UUID()
        let id2 = UUID()
        let (coord, store) = makeCoordinator(profiles: [
            StoredSpeakerProfile(id: id1, displayName: "P1", embedding: makeEmbedding(dominant: 0), tags: ["team-a"]),
            StoredSpeakerProfile(id: id2, displayName: "P2", embedding: makeEmbedding(dominant: 1), tags: ["team-b"]),
        ])

        coord.addManualSpeakersByTag("team-a")

        XCTAssertEqual(coord.activeSpeakers.count, 1)
        XCTAssertEqual(coord.activeSpeakers[0].id, id1)
    }
}
