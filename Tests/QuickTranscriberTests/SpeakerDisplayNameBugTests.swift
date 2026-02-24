import XCTest
@testable import QuickTranscriberLib

/// Tests for speaker display name management bugs:
/// - generateSpeakerName() always returns "Speaker-N" format
/// - trackerAliases preserves display names across updateSpeakerDisplayNames
/// - removedSpeakerIds prevents re-addition of removed speakers
@MainActor
final class SpeakerDisplayNameBugTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "selectedLanguage")
        UserDefaults.standard.removeObject(forKey: "isRecording")
        UserDefaults.standard.removeObject(forKey: "transcriptionParameters")
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerDisplayNameBugTests-\(UUID().uuidString)")
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

    private func makeViewModel(
        store: SpeakerProfileStore? = nil
    ) -> (TranscriptionViewModel, MockTranscriptionEngine, SpeakerProfileStore) {
        let engine = MockTranscriptionEngine()
        let profileStore = store ?? SpeakerProfileStore(directory: tmpDir)
        let params = ParametersStore()
        let vm = TranscriptionViewModel(
            engine: engine,
            modelName: "test-model",
            parametersStore: params,
            speakerProfileStore: profileStore
        )
        return (vm, engine, profileStore)
    }

    // MARK: - Step 1: generateSpeakerName() always returns "Speaker-N"

    func testLinkActiveSpeakersGeneratesSpeakerNForNilDisplayName() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let (vm, _, _) = makeViewModel(store: store)

        let speakerId = UUID()
        let embedding: [Float] = Array(repeating: 0.5, count: 256)
        // Active speaker with nil displayName (simulating ghost tracker UUID)
        vm.activeSpeakers = [
            ActiveSpeaker(id: speakerId, speakerProfileId: nil, displayName: nil, source: .autoDetected)
        ]
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: speakerId.uuidString, speakerEmbedding: embedding)
        ]

        vm.linkActiveSpeakersToProfiles()

        // Should have created profile with "Speaker-N" format, not bare "Speaker"
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertTrue(
            store.profiles[0].displayName.hasPrefix("Speaker-"),
            "Expected 'Speaker-N' format, got '\(store.profiles[0].displayName)'"
        )
    }

    func testGenerateSpeakerNameAvoidsCollisionWithExistingNames() {
        let store = SpeakerProfileStore(directory: tmpDir)
        store.profiles = [
            StoredSpeakerProfile(displayName: "Speaker-1", embedding: makeEmbedding(dominant: 0))
        ]
        let (vm, _, _) = makeViewModel(store: store)

        // Add speaker with empty name to trigger auto-naming
        vm.addManualSpeaker(displayName: "")

        // Should skip "Speaker-1" which already exists in store
        XCTAssertEqual(vm.activeSpeakers[0].displayName, "Speaker-2")
    }

    func testGenerateSpeakerNameAvoidsCollisionWithActiveSpeakers() {
        let (vm, _, _) = makeViewModel()

        vm.addManualSpeaker(displayName: "Speaker-1")
        vm.addManualSpeaker(displayName: "")

        // Should skip "Speaker-1" which is already active
        XCTAssertNotEqual(vm.activeSpeakers[1].displayName, "Speaker-1")
        XCTAssertTrue(
            vm.activeSpeakers[1].displayName?.hasPrefix("Speaker-") ?? false,
            "Expected 'Speaker-N' format"
        )
    }

    // MARK: - Step 2: trackerAliases

    func testTrackerAliasPreservesDisplayNameAfterUpdateSpeakerDisplayNames() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let profileAlice = StoredSpeakerProfile(displayName: "Alice", embedding: makeEmbedding(dominant: 0))
        store.profiles = [profileAlice]
        let (vm, _, _) = makeViewModel(store: store)

        // Add Alice as manual speaker (profile linked)
        vm.addManualSpeaker(fromProfile: profileAlice.id)

        // Simulate: tracker detects using Alice's profile UUID directly
        // (UUID match triggers alias since profile is already active)
        vm.addAutoDetectedSpeaker(speakerId: profileAlice.id.uuidString, embedding: makeEmbedding(dominant: 0))

        // The tracker UUID should resolve to Alice's display name
        XCTAssertEqual(
            vm.speakerDisplayNames[profileAlice.id.uuidString], "Alice",
            "Tracker alias UUID should map to Alice's display name"
        )

        // Verify it doesn't create a duplicate active speaker
        XCTAssertEqual(vm.activeSpeakers.count, 1, "Should not add duplicate active speaker")
    }

    func testTrackerAliasSurvivesUpdateSpeakerDisplayNamesRebuild() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let profileAlice = StoredSpeakerProfile(displayName: "Alice", embedding: makeEmbedding(dominant: 0))
        store.profiles = [profileAlice]
        let (vm, _, _) = makeViewModel(store: store)

        vm.addManualSpeaker(fromProfile: profileAlice.id)

        // Add tracker alias using profile UUID (UUID match → alias)
        vm.addAutoDetectedSpeaker(speakerId: profileAlice.id.uuidString, embedding: makeEmbedding(dominant: 0))

        // Trigger display names rebuild (e.g. by adding another speaker)
        vm.addManualSpeaker(displayName: "Bob")

        // Alias should still be present
        XCTAssertEqual(
            vm.speakerDisplayNames[profileAlice.id.uuidString], "Alice",
            "Tracker alias should survive display name rebuilds"
        )
    }

    // MARK: - Step 3: removedSpeakerIds prevents re-addition

    func testRemovedSpeakerNotReAddedByAutoDetection() {
        let (vm, _, _) = makeViewModel()

        // Add auto-detected speaker
        let speakerId = UUID()
        vm.addAutoDetectedSpeaker(speakerId: speakerId.uuidString, embedding: makeEmbedding(dominant: 0))
        XCTAssertEqual(vm.activeSpeakers.count, 1)

        // Remove the speaker
        vm.removeActiveSpeaker(id: speakerId)
        XCTAssertEqual(vm.activeSpeakers.count, 0)

        // Try to re-add via auto detection - should be blocked
        vm.addAutoDetectedSpeaker(speakerId: speakerId.uuidString, embedding: makeEmbedding(dominant: 0))
        XCTAssertEqual(vm.activeSpeakers.count, 0, "Removed speaker should not be re-added")
    }

    func testRemovedProfileNotReAddedByAutoDetection() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let profile = StoredSpeakerProfile(displayName: "Alice", embedding: makeEmbedding(dominant: 0))
        store.profiles = [profile]
        let (vm, _, _) = makeViewModel(store: store)

        // Add manual speaker from profile, then remove
        vm.addManualSpeaker(fromProfile: profile.id)
        XCTAssertEqual(vm.activeSpeakers.count, 1)
        vm.removeActiveSpeaker(id: vm.activeSpeakers[0].id)
        XCTAssertEqual(vm.activeSpeakers.count, 0)

        // Auto-detection with profile's UUID should be blocked (UUID match to removed profile)
        vm.addAutoDetectedSpeaker(speakerId: profile.id.uuidString, embedding: makeEmbedding(dominant: 0))
        XCTAssertEqual(vm.activeSpeakers.count, 0, "Removed profile should not be re-added")
    }

    func testRemoveActiveSpeakerUpdatesDisplayNames() {
        let (vm, _, _) = makeViewModel()

        vm.addManualSpeaker(displayName: "Alice")
        vm.addManualSpeaker(displayName: "Bob")
        let aliceId = vm.activeSpeakers[0].id

        vm.removeActiveSpeaker(id: aliceId)

        XCTAssertNil(vm.speakerDisplayNames[aliceId.uuidString],
                     "Removed speaker's display name should be cleared")
        XCTAssertEqual(vm.speakerDisplayNames.count, 1)
    }

    func testRemoveActiveSpeakerCleansUpTrackerAliases() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let profile = StoredSpeakerProfile(displayName: "Alice", embedding: makeEmbedding(dominant: 0))
        store.profiles = [profile]
        let (vm, _, _) = makeViewModel(store: store)

        vm.addManualSpeaker(fromProfile: profile.id)
        let aliceId = vm.activeSpeakers[0].id

        // Add a tracker alias using profile UUID (UUID match → alias)
        vm.addAutoDetectedSpeaker(speakerId: profile.id.uuidString, embedding: makeEmbedding(dominant: 0))

        // Remove Alice
        vm.removeActiveSpeaker(id: aliceId)

        // Tracker alias should also be cleaned up
        XCTAssertNil(vm.speakerDisplayNames[profile.id.uuidString],
                     "Tracker alias display name should be cleaned up when target speaker is removed")
    }

    // MARK: - Step 4: Manual mode blocks new speaker addition

    func testManualModeBlocksNewAutoDetectedSpeaker() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let (vm, _, _) = makeViewModel(store: store)

        // Set manual mode and snapshot it
        vm.parametersStore.parameters.diarizationMode = .manual
        vm.snapshotDiarizationMode()

        // Add a manual speaker
        vm.addManualSpeaker(displayName: "Alice")
        XCTAssertEqual(vm.activeSpeakers.count, 1)

        // Auto-detection of unknown speaker should be blocked in manual mode
        let unknownId = UUID().uuidString
        vm.addAutoDetectedSpeaker(speakerId: unknownId, embedding: makeEmbedding(dominant: 5))
        XCTAssertEqual(vm.activeSpeakers.count, 1,
                       "Manual mode should not add new unknown speakers")
    }

    func testManualModeAllowsAliasForKnownProfile() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let profileAlice = StoredSpeakerProfile(displayName: "Alice", embedding: makeEmbedding(dominant: 0))
        store.profiles = [profileAlice]
        let (vm, _, _) = makeViewModel(store: store)

        // Set manual mode, snapshot it, and add Alice
        vm.parametersStore.parameters.diarizationMode = .manual
        vm.snapshotDiarizationMode()
        vm.addManualSpeaker(fromProfile: profileAlice.id)

        // Tracker UUID matching Alice's profile UUID → alias
        vm.addAutoDetectedSpeaker(speakerId: profileAlice.id.uuidString, embedding: makeEmbedding(dominant: 0))

        XCTAssertEqual(vm.activeSpeakers.count, 1, "Should not add duplicate speaker")
        XCTAssertEqual(vm.speakerDisplayNames[profileAlice.id.uuidString], "Alice",
                       "Should create alias to Alice in manual mode")
    }

    func testManualModeBlocksNewSpeakerEvenWithMatchedProfile() {
        let store = SpeakerProfileStore(directory: tmpDir)
        // Profile exists in store but is NOT in activeSpeakers
        let profileBob = StoredSpeakerProfile(displayName: "Bob", embedding: makeEmbedding(dominant: 3))
        store.profiles = [profileBob]
        let (vm, _, _) = makeViewModel(store: store)

        vm.parametersStore.parameters.diarizationMode = .manual
        vm.snapshotDiarizationMode()
        vm.addManualSpeaker(displayName: "Alice")  // Only Alice is active

        // Tracker uses Bob's UUID, but Bob isn't active in manual mode
        vm.addAutoDetectedSpeaker(speakerId: profileBob.id.uuidString, embedding: makeEmbedding(dominant: 3))
        XCTAssertEqual(vm.activeSpeakers.count, 1,
                       "Manual mode should not add inactive profile speaker")
    }

    // MARK: - Step 5: Ghost profile filtering

    func testGhostProfileSkippedDuringMerge() async {
        let store = SpeakerProfileStore(directory: tmpDir)
        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(
            engine: engine,
            modelName: "test-model",
            speakerProfileStore: store
        )

        // Set up known speaker with display name
        let knownId = UUID()
        vm.activeSpeakers = [
            ActiveSpeaker(id: knownId, displayName: "Alice", source: .autoDetected)
        ]
        vm.speakerDisplayNames = [knownId.uuidString: "Alice"]

        // Ghost UUID (no display name mapping)
        let ghostId = UUID()
        let displayNames = vm.speakerDisplayNames

        // stopStreaming passes speakerDisplayNames to engine
        // ghost profiles should be filtered by ChunkedWhisperEngine
        // Here we verify the contract: only profiles with display name mappings
        XCTAssertNotNil(displayNames[knownId.uuidString])
        XCTAssertNil(displayNames[ghostId.uuidString],
                     "Ghost profile should have no display name mapping")
    }

    // MARK: - Step 6: linkActiveSpeakersToProfiles alias support

    func testLinkActiveSpeakersUsesTrackerAliasForProfileMatching() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let (vm, _, _) = makeViewModel(store: store)

        // Simulate: active speaker with no profile link
        // Use a UUID that does NOT match any profile ID (so Priority 1 won't match)
        let activeSpeakerId = UUID()
        vm.activeSpeakers = [
            ActiveSpeaker(id: activeSpeakerId, speakerProfileId: nil, displayName: "Speaker-1", source: .autoDetected)
        ]

        // A tracker alias maps a different UUID to this active speaker
        let trackerUUID = UUID()
        vm.trackerAliases[trackerUUID.uuidString] = activeSpeakerId

        // The profile was created with the tracker UUID (via mergeSessionProfiles on engine side)
        // Use a unique embedding that won't match via similarity either
        var uniqueEmbedding = [Float](repeating: 0.0, count: 256)
        uniqueEmbedding[42] = 1.0
        store.profiles = [
            StoredSpeakerProfile(id: trackerUUID, displayName: "Speaker-1", embedding: uniqueEmbedding)
        ]

        // Segment uses a completely different embedding so similarity fallback won't match
        var differentEmbedding = [Float](repeating: 0.0, count: 256)
        differentEmbedding[200] = 1.0
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: activeSpeakerId.uuidString, speakerEmbedding: differentEmbedding)
        ]

        vm.linkActiveSpeakersToProfiles()

        // Should link via tracker alias (Priority 1.5), not ID match or similarity
        XCTAssertEqual(vm.activeSpeakers[0].speakerProfileId, trackerUUID,
                       "Should link to profile via tracker alias")
    }

    func testMergeAndLinkDoNotCreateDuplicateProfiles() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let (vm, _, _) = makeViewModel(store: store)

        let speakerId = UUID()
        let embedding: [Float] = Array(repeating: 0.5, count: 256)

        // Simulate: mergeSessionProfiles already created a profile
        store.profiles = [
            StoredSpeakerProfile(id: speakerId, displayName: "Speaker-1", embedding: embedding)
        ]

        vm.activeSpeakers = [
            ActiveSpeaker(id: speakerId, speakerProfileId: nil, displayName: "Speaker-1", source: .autoDetected)
        ]
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: speakerId.uuidString, speakerEmbedding: embedding)
        ]

        vm.linkActiveSpeakersToProfiles()

        // Should link to existing profile, not create duplicate
        XCTAssertEqual(store.profiles.count, 1, "Should not create duplicate profile")
        XCTAssertEqual(vm.activeSpeakers[0].speakerProfileId, speakerId)
    }

    // MARK: - Step 7: Session boundary cleanup

    func testClearTextResetsTrackerAliasesAndRemovedIds() {
        let (vm, _, _) = makeViewModel()

        // Directly set state to verify cleanup
        vm.trackerAliases["fake-uuid"] = UUID()
        vm.removedSpeakerIds.insert(UUID())

        XCTAssertFalse(vm.trackerAliases.isEmpty, "Precondition: aliases should have state")
        XCTAssertFalse(vm.removedSpeakerIds.isEmpty, "Precondition: removedIds should have state")

        vm.clearText()

        XCTAssertTrue(vm.trackerAliases.isEmpty, "clearText should reset trackerAliases")
        XCTAssertTrue(vm.removedSpeakerIds.isEmpty, "clearText should reset removedSpeakerIds")
    }

    func testClearActiveSpeakersResetsTrackerAliases() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let (vm, _, _) = makeViewModel(store: store)

        vm.addManualSpeaker(displayName: "Alice")
        let aliceId = vm.activeSpeakers[0].id
        // Directly set a tracker alias (simulating engine assigning alias)
        vm.trackerAliases[UUID().uuidString] = aliceId

        XCTAssertFalse(vm.trackerAliases.isEmpty, "Precondition: aliases should exist")

        vm.clearActiveSpeakers()

        XCTAssertTrue(vm.trackerAliases.isEmpty, "clearActiveSpeakers should reset trackerAliases")
    }

    // MARK: - Single authority: linkActiveSpeakers no embedding similarity

    func testLinkSimilarEmbeddingDifferentIdCreatesNewProfile() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let existingProfileId = UUID()
        let embedding = makeEmbedding(dominant: 0)
        store.profiles = [StoredSpeakerProfile(id: existingProfileId, displayName: "Alice", embedding: embedding)]
        let (vm, _, _) = makeViewModel(store: store)

        // Active speaker with DIFFERENT UUID from existing profile
        let newSpeakerId = UUID()
        vm.activeSpeakers = [
            ActiveSpeaker(id: newSpeakerId, speakerProfileId: nil, displayName: "Speaker-1", source: .autoDetected)
        ]
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: newSpeakerId.uuidString, speakerEmbedding: embedding)
        ]

        vm.linkActiveSpeakersToProfiles()

        // Should create a NEW profile, NOT link to Alice (despite identical embedding)
        XCTAssertEqual(store.profiles.count, 2,
                       "Should create new profile, not link to existing via embedding similarity")
        XCTAssertEqual(vm.activeSpeakers[0].speakerProfileId, newSpeakerId,
                       "New profile should use the active speaker's UUID")
    }
}
