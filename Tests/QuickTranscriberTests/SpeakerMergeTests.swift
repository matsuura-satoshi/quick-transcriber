import XCTest
@testable import QuickTranscriberLib

@MainActor
final class SpeakerMergeTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "selectedLanguage")
        UserDefaults.standard.removeObject(forKey: "isRecording")
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerMergeTests-\(UUID().uuidString)")
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
        speakerProfileStore: SpeakerProfileStore? = nil,
        embeddingHistoryStore: EmbeddingHistoryStore? = nil
    ) -> (TranscriptionViewModel, MockTranscriptionEngine) {
        let engine = MockTranscriptionEngine()
        let store = speakerProfileStore ?? SpeakerProfileStore(directory: tmpDir)
        let embStore = embeddingHistoryStore ?? EmbeddingHistoryStore()
        let vm = TranscriptionViewModel(
            engine: engine,
            modelName: "test-model",
            speakerProfileStore: store,
            embeddingHistoryStore: embStore
        )
        return (vm, engine)
    }

    // MARK: - checkNameUniqueness

    func testCheckNameUniqueness_uniqueName_returnsNil() {
        let (vm, _) = makeViewModel()
        vm.activeSpeakers = [
            ActiveSpeaker(displayName: "Alice", source: .manual)
        ]
        let result = vm.checkNameUniqueness(newName: "Bob", forEntity: .active(id: vm.activeSpeakers[0].id))
        XCTAssertNil(result)
    }

    func testCheckNameUniqueness_duplicateActive_returnsMergeRequest() {
        let (vm, _) = makeViewModel()
        let id1 = UUID()
        let id2 = UUID()
        vm.activeSpeakers = [
            ActiveSpeaker(id: id1, displayName: "Alice", source: .manual),
            ActiveSpeaker(id: id2, displayName: "Bob", source: .manual)
        ]
        vm.speakerDisplayNames = [id1.uuidString: "Alice", id2.uuidString: "Bob"]

        let result = vm.checkNameUniqueness(newName: "Bob", forEntity: .active(id: id1))
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.duplicateName, "Bob")
        XCTAssertEqual(result?.sourceEntity, .active(id: id1))
        XCTAssertEqual(result?.targetEntity, .active(id: id2))
    }

    func testCheckNameUniqueness_duplicateRegistered_returnsMergeRequest() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let profileId = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: profileId, displayName: "Bob", embedding: makeEmbedding(dominant: 0))
        ]
        let (vm, _) = makeViewModel(speakerProfileStore: store)
        let activeId = UUID()
        vm.activeSpeakers = [
            ActiveSpeaker(id: activeId, displayName: "Alice", source: .manual)
        ]

        let result = vm.checkNameUniqueness(newName: "Bob", forEntity: .active(id: activeId))
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.duplicateName, "Bob")
        XCTAssertEqual(result?.targetEntity, .registered(id: profileId))
    }

    func testCheckNameUniqueness_caseInsensitive() {
        let (vm, _) = makeViewModel()
        let id1 = UUID()
        let id2 = UUID()
        vm.activeSpeakers = [
            ActiveSpeaker(id: id1, displayName: "Alice", source: .manual),
            ActiveSpeaker(id: id2, displayName: "bob", source: .manual)
        ]
        vm.speakerDisplayNames = [id1.uuidString: "Alice", id2.uuidString: "bob"]

        let result = vm.checkNameUniqueness(newName: "Bob", forEntity: .active(id: id1))
        XCTAssertNotNil(result, "Case-insensitive match should detect 'Bob' vs 'bob'")
    }

    func testCheckNameUniqueness_emptyString_returnsNil() {
        let (vm, _) = makeViewModel()
        vm.activeSpeakers = [
            ActiveSpeaker(displayName: "Alice", source: .manual)
        ]
        let result = vm.checkNameUniqueness(newName: "", forEntity: .active(id: vm.activeSpeakers[0].id))
        XCTAssertNil(result, "Empty name should be exempt from uniqueness check")
    }

    func testCheckNameUniqueness_sameEntity_returnsNil() {
        let (vm, _) = makeViewModel()
        let id = UUID()
        vm.activeSpeakers = [
            ActiveSpeaker(id: id, displayName: "Alice", source: .manual)
        ]
        vm.speakerDisplayNames = [id.uuidString: "Alice"]

        let result = vm.checkNameUniqueness(newName: "Alice", forEntity: .active(id: id))
        XCTAssertNil(result, "Renaming to own name should not trigger conflict")
    }

    func testCheckNameUniqueness_linkedProfile_excludesSelf() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let profileId = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: profileId, displayName: "Alice", embedding: makeEmbedding(dominant: 0))
        ]
        let (vm, _) = makeViewModel(speakerProfileStore: store)
        vm.activeSpeakers = [
            ActiveSpeaker(id: profileId, speakerProfileId: profileId, displayName: "Alice", source: .manual)
        ]

        // Renaming active speaker that's linked to same profile — should not conflict with its own profile
        let result = vm.checkNameUniqueness(newName: "Alice", forEntity: .active(id: profileId))
        XCTAssertNil(result)
    }

    func testCheckNameUniqueness_registeredVsRegistered() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let id1 = UUID()
        let id2 = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: id1, displayName: "Alice", embedding: makeEmbedding(dominant: 0)),
            StoredSpeakerProfile(id: id2, displayName: "Bob", embedding: makeEmbedding(dominant: 1))
        ]
        let (vm, _) = makeViewModel(speakerProfileStore: store)

        let result = vm.checkNameUniqueness(newName: "Bob", forEntity: .registered(id: id1))
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.targetEntity, .registered(id: id2))
    }

    // MARK: - tryRename

    func testTryRenameActiveSpeaker_unique_renamesDirectly() {
        let (vm, _) = makeViewModel()
        let id = UUID()
        vm.activeSpeakers = [
            ActiveSpeaker(id: id, displayName: "Alice", source: .manual)
        ]
        vm.speakerDisplayNames = [id.uuidString: "Alice"]

        vm.tryRenameActiveSpeaker(id: id, displayName: "Bob")

        XCTAssertEqual(vm.activeSpeakers[0].displayName, "Bob")
        XCTAssertNil(vm.pendingMergeRequest)
    }

    func testTryRenameActiveSpeaker_duplicate_setsPendingMergeRequest() {
        let (vm, _) = makeViewModel()
        let id1 = UUID()
        let id2 = UUID()
        vm.activeSpeakers = [
            ActiveSpeaker(id: id1, displayName: "Alice", source: .manual),
            ActiveSpeaker(id: id2, displayName: "Bob", source: .manual)
        ]
        vm.speakerDisplayNames = [id1.uuidString: "Alice", id2.uuidString: "Bob"]

        vm.tryRenameActiveSpeaker(id: id1, displayName: "Bob")

        XCTAssertNotNil(vm.pendingMergeRequest)
        XCTAssertEqual(vm.pendingMergeRequest?.duplicateName, "Bob")
        // Original name should remain unchanged
        XCTAssertEqual(vm.activeSpeakers[0].displayName, "Alice")
    }

    func testTryRenameSpeaker_unique_renamesDirectly() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let id = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: id, displayName: "Alice", embedding: makeEmbedding(dominant: 0))
        ]
        let (vm, _) = makeViewModel(speakerProfileStore: store)

        vm.tryRenameSpeaker(id: id, to: "Bob")

        XCTAssertEqual(vm.speakerProfiles[0].displayName, "Bob")
        XCTAssertNil(vm.pendingMergeRequest)
    }

    func testTryRenameSpeaker_duplicate_setsPendingMergeRequest() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let id1 = UUID()
        let id2 = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: id1, displayName: "Alice", embedding: makeEmbedding(dominant: 0)),
            StoredSpeakerProfile(id: id2, displayName: "Bob", embedding: makeEmbedding(dominant: 1))
        ]
        let (vm, _) = makeViewModel(speakerProfileStore: store)

        vm.tryRenameSpeaker(id: id1, to: "Bob")

        XCTAssertNotNil(vm.pendingMergeRequest)
        XCTAssertEqual(vm.pendingMergeRequest?.duplicateName, "Bob")
        // Original name should remain unchanged
        XCTAssertEqual(vm.speakerProfiles[0].displayName, "Alice")
    }

    // MARK: - cancelMerge

    func testCancelMerge_clearsPendingRequest() {
        let (vm, _) = makeViewModel()
        vm.pendingMergeRequest = SpeakerMergeRequest(
            sourceEntity: .active(id: UUID()),
            targetEntity: .active(id: UUID()),
            duplicateName: "Bob",
            sourceDisplayName: "Alice",
            targetDisplayName: "Bob"
        )

        vm.cancelMerge()

        XCTAssertNil(vm.pendingMergeRequest)
    }

    // MARK: - executeMerge: Survivor determination

    func testExecuteMerge_higherSessionCount_survives() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let idLow = UUID()
        let idHigh = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: idLow, displayName: "Alice", embedding: makeEmbedding(dominant: 0), sessionCount: 2),
            StoredSpeakerProfile(id: idHigh, displayName: "Bob", embedding: makeEmbedding(dominant: 1), sessionCount: 5)
        ]
        let (vm, _) = makeViewModel(speakerProfileStore: store)
        vm.activeSpeakers = [
            ActiveSpeaker(id: idLow, speakerProfileId: idLow, displayName: "Alice", source: .manual),
            ActiveSpeaker(id: idHigh, speakerProfileId: idHigh, displayName: "Bob", source: .manual)
        ]

        let request = SpeakerMergeRequest(
            sourceEntity: .active(id: idLow),
            targetEntity: .active(id: idHigh),
            duplicateName: "Bob",
            sourceDisplayName: "Alice",
            targetDisplayName: "Bob"
        )
        vm.executeMerge(request)

        // Higher sessionCount (idHigh=5) survives; idLow (sessionCount=2) is absorbed
        XCTAssertTrue(store.profiles.contains { $0.id == idHigh })
        XCTAssertFalse(store.profiles.contains { $0.id == idLow })
    }

    func testExecuteMerge_tiedSessionCount_targetSurvives() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let idSource = UUID()
        let idTarget = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: idSource, displayName: "Alice", embedding: makeEmbedding(dominant: 0), sessionCount: 3),
            StoredSpeakerProfile(id: idTarget, displayName: "Bob", embedding: makeEmbedding(dominant: 1), sessionCount: 3)
        ]
        let (vm, _) = makeViewModel(speakerProfileStore: store)
        vm.activeSpeakers = [
            ActiveSpeaker(id: idSource, speakerProfileId: idSource, displayName: "Alice", source: .manual),
            ActiveSpeaker(id: idTarget, speakerProfileId: idTarget, displayName: "Bob", source: .manual)
        ]

        let request = SpeakerMergeRequest(
            sourceEntity: .active(id: idSource),
            targetEntity: .active(id: idTarget),
            duplicateName: "Bob",
            sourceDisplayName: "Alice",
            targetDisplayName: "Bob"
        )
        vm.executeMerge(request)

        // Tied → target survives
        XCTAssertTrue(store.profiles.contains { $0.id == idTarget })
        XCTAssertFalse(store.profiles.contains { $0.id == idSource })
    }

    // MARK: - executeMerge: Segment reassignment

    func testExecuteMerge_reassignsSegments() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let idA = UUID()
        let idB = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: idA, displayName: "Alice", embedding: makeEmbedding(dominant: 0), sessionCount: 1),
            StoredSpeakerProfile(id: idB, displayName: "Bob", embedding: makeEmbedding(dominant: 1), sessionCount: 5)
        ]
        let (vm, _) = makeViewModel(speakerProfileStore: store)
        vm.activeSpeakers = [
            ActiveSpeaker(id: idA, speakerProfileId: idA, displayName: "Alice", source: .manual),
            ActiveSpeaker(id: idB, speakerProfileId: idB, displayName: "Bob", source: .manual)
        ]
        // Set up segments with idA's speaker
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: idA.uuidString),
            ConfirmedSegment(text: "World", speaker: idB.uuidString),
            ConfirmedSegment(text: "Again", speaker: idA.uuidString),
        ]

        let request = SpeakerMergeRequest(
            sourceEntity: .active(id: idA),
            targetEntity: .active(id: idB),
            duplicateName: "Bob",
            sourceDisplayName: "Alice",
            targetDisplayName: "Bob"
        )
        vm.executeMerge(request)

        // idB is survivor (higher sessionCount). All idA segments → idB
        XCTAssertEqual(vm.confirmedSegments[0].speaker, idB.uuidString)
        XCTAssertEqual(vm.confirmedSegments[1].speaker, idB.uuidString)
        XCTAssertEqual(vm.confirmedSegments[2].speaker, idB.uuidString)
    }

    // MARK: - executeMerge: Embedding EMA blending

    func testExecuteMerge_embeddingEMABlending() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let idSurvivor = UUID()
        let idAbsorbed = UUID()
        let embSurvivor = makeEmbedding(dominant: 0)
        let embAbsorbed = makeEmbedding(dominant: 1)
        store.profiles = [
            StoredSpeakerProfile(id: idSurvivor, displayName: "Bob", embedding: embSurvivor, sessionCount: 5),
            StoredSpeakerProfile(id: idAbsorbed, displayName: "Alice", embedding: embAbsorbed, sessionCount: 1)
        ]
        let (vm, _) = makeViewModel(speakerProfileStore: store)
        vm.activeSpeakers = [
            ActiveSpeaker(id: idSurvivor, speakerProfileId: idSurvivor, displayName: "Bob", source: .manual),
            ActiveSpeaker(id: idAbsorbed, speakerProfileId: idAbsorbed, displayName: "Alice", source: .manual)
        ]

        let request = SpeakerMergeRequest(
            sourceEntity: .active(id: idAbsorbed),
            targetEntity: .active(id: idSurvivor),
            duplicateName: "Bob",
            sourceDisplayName: "Alice",
            targetDisplayName: "Bob"
        )
        vm.executeMerge(request)

        // Survivor's embedding should be EMA blend: 0.7 * survivor + 0.3 * absorbed
        let merged = store.profiles.first { $0.id == idSurvivor }!
        let expected0 = 0.7 * embSurvivor[0] + 0.3 * embAbsorbed[0]
        let expected1 = 0.7 * embSurvivor[1] + 0.3 * embAbsorbed[1]
        XCTAssertEqual(merged.embedding[0], expected0, accuracy: 0.001)
        XCTAssertEqual(merged.embedding[1], expected1, accuracy: 0.001)
    }

    // MARK: - executeMerge: Metadata integration

    func testExecuteMerge_sessionCountAdded() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let idA = UUID()
        let idB = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: idA, displayName: "Alice", embedding: makeEmbedding(dominant: 0), sessionCount: 3),
            StoredSpeakerProfile(id: idB, displayName: "Bob", embedding: makeEmbedding(dominant: 1), sessionCount: 5)
        ]
        let (vm, _) = makeViewModel(speakerProfileStore: store)
        vm.activeSpeakers = [
            ActiveSpeaker(id: idA, speakerProfileId: idA, displayName: "Alice", source: .manual),
            ActiveSpeaker(id: idB, speakerProfileId: idB, displayName: "Bob", source: .manual)
        ]

        let request = SpeakerMergeRequest(
            sourceEntity: .active(id: idA),
            targetEntity: .active(id: idB),
            duplicateName: "Bob",
            sourceDisplayName: "Alice",
            targetDisplayName: "Bob"
        )
        vm.executeMerge(request)

        let survivor = store.profiles.first { $0.id == idB }!
        XCTAssertEqual(survivor.sessionCount, 8) // 3 + 5
    }

    func testExecuteMerge_isLockedPropagation() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let idA = UUID()
        let idB = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: idA, displayName: "Alice", embedding: makeEmbedding(dominant: 0), sessionCount: 1, isLocked: true),
            StoredSpeakerProfile(id: idB, displayName: "Bob", embedding: makeEmbedding(dominant: 1), sessionCount: 5, isLocked: false)
        ]
        let (vm, _) = makeViewModel(speakerProfileStore: store)
        vm.activeSpeakers = [
            ActiveSpeaker(id: idA, speakerProfileId: idA, displayName: "Alice", source: .manual),
            ActiveSpeaker(id: idB, speakerProfileId: idB, displayName: "Bob", source: .manual)
        ]

        let request = SpeakerMergeRequest(
            sourceEntity: .active(id: idA),
            targetEntity: .active(id: idB),
            duplicateName: "Bob",
            sourceDisplayName: "Alice",
            targetDisplayName: "Bob"
        )
        vm.executeMerge(request)

        // Absorbed was locked → survivor should be locked (OR logic)
        let survivor = store.profiles.first { $0.id == idB }!
        XCTAssertTrue(survivor.isLocked)
    }

    func testExecuteMerge_tagsUnion() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let idA = UUID()
        let idB = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: idA, displayName: "Alice", embedding: makeEmbedding(dominant: 0), sessionCount: 1, tags: ["team-a", "shared"]),
            StoredSpeakerProfile(id: idB, displayName: "Bob", embedding: makeEmbedding(dominant: 1), sessionCount: 5, tags: ["team-b", "shared"])
        ]
        let (vm, _) = makeViewModel(speakerProfileStore: store)
        vm.activeSpeakers = [
            ActiveSpeaker(id: idA, speakerProfileId: idA, displayName: "Alice", source: .manual),
            ActiveSpeaker(id: idB, speakerProfileId: idB, displayName: "Bob", source: .manual)
        ]

        let request = SpeakerMergeRequest(
            sourceEntity: .active(id: idA),
            targetEntity: .active(id: idB),
            duplicateName: "Bob",
            sourceDisplayName: "Alice",
            targetDisplayName: "Bob"
        )
        vm.executeMerge(request)

        let survivor = store.profiles.first { $0.id == idB }!
        XCTAssertTrue(survivor.tags.contains("team-a"))
        XCTAssertTrue(survivor.tags.contains("team-b"))
        XCTAssertTrue(survivor.tags.contains("shared"))
        // No duplicates
        XCTAssertEqual(survivor.tags.filter { $0 == "shared" }.count, 1)
    }

    // MARK: - executeMerge: Absorbed side cleanup

    func testExecuteMerge_absorbedProfileDeleted() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let idA = UUID()
        let idB = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: idA, displayName: "Alice", embedding: makeEmbedding(dominant: 0), sessionCount: 1),
            StoredSpeakerProfile(id: idB, displayName: "Bob", embedding: makeEmbedding(dominant: 1), sessionCount: 5)
        ]
        let embeddingStore = EmbeddingHistoryStore()
        let (vm, _) = makeViewModel(speakerProfileStore: store, embeddingHistoryStore: embeddingStore)
        vm.activeSpeakers = [
            ActiveSpeaker(id: idA, speakerProfileId: idA, displayName: "Alice", source: .manual),
            ActiveSpeaker(id: idB, speakerProfileId: idB, displayName: "Bob", source: .manual)
        ]

        let request = SpeakerMergeRequest(
            sourceEntity: .active(id: idA),
            targetEntity: .active(id: idB),
            duplicateName: "Bob",
            sourceDisplayName: "Alice",
            targetDisplayName: "Bob"
        )
        vm.executeMerge(request)

        // Absorbed profile deleted
        XCTAssertFalse(store.profiles.contains { $0.id == idA })
        // Absorbed active speaker removed
        XCTAssertFalse(vm.activeSpeakers.contains { $0.id == idA })
        // Survivor remains
        XCTAssertTrue(vm.activeSpeakers.contains { $0.id == idB })
    }

    // MARK: - executeMerge: Active↔Active without profiles

    func testExecuteMerge_activeWithoutProfiles() {
        let (vm, _) = makeViewModel()
        let idA = UUID()
        let idB = UUID()
        vm.activeSpeakers = [
            ActiveSpeaker(id: idA, displayName: "Alice", source: .autoDetected),
            ActiveSpeaker(id: idB, displayName: "Bob", source: .autoDetected)
        ]
        vm.speakerDisplayNames = [idA.uuidString: "Alice", idB.uuidString: "Bob"]
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: idA.uuidString),
        ]

        let request = SpeakerMergeRequest(
            sourceEntity: .active(id: idA),
            targetEntity: .active(id: idB),
            duplicateName: "Bob",
            sourceDisplayName: "Alice",
            targetDisplayName: "Bob"
        )
        vm.executeMerge(request)

        // Source should be removed from active speakers
        XCTAssertFalse(vm.activeSpeakers.contains { $0.id == idA })
        XCTAssertTrue(vm.activeSpeakers.contains { $0.id == idB })
        // Segments reassigned
        XCTAssertEqual(vm.confirmedSegments[0].speaker, idB.uuidString)
    }

    // MARK: - executeMerge: Registered↔Registered (no active speakers)

    func testExecuteMerge_registeredVsRegistered() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let idA = UUID()
        let idB = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: idA, displayName: "Alice", embedding: makeEmbedding(dominant: 0), sessionCount: 2),
            StoredSpeakerProfile(id: idB, displayName: "Bob", embedding: makeEmbedding(dominant: 1), sessionCount: 5)
        ]
        let (vm, _) = makeViewModel(speakerProfileStore: store)

        let request = SpeakerMergeRequest(
            sourceEntity: .registered(id: idA),
            targetEntity: .registered(id: idB),
            duplicateName: "Bob",
            sourceDisplayName: "Alice",
            targetDisplayName: "Bob"
        )
        vm.executeMerge(request)

        XCTAssertFalse(store.profiles.contains { $0.id == idA })
        XCTAssertTrue(store.profiles.contains { $0.id == idB })
        XCTAssertEqual(store.profiles.first { $0.id == idB }?.sessionCount, 7)
    }

    // MARK: - executeMerge: lastUsed takes max

    func testExecuteMerge_lastUsedMax() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let idA = UUID()
        let idB = UUID()
        let earlier = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 2000)
        store.profiles = [
            StoredSpeakerProfile(id: idA, displayName: "Alice", embedding: makeEmbedding(dominant: 0), lastUsed: later, sessionCount: 1),
            StoredSpeakerProfile(id: idB, displayName: "Bob", embedding: makeEmbedding(dominant: 1), lastUsed: earlier, sessionCount: 5)
        ]
        let (vm, _) = makeViewModel(speakerProfileStore: store)
        vm.activeSpeakers = [
            ActiveSpeaker(id: idA, speakerProfileId: idA, displayName: "Alice", source: .manual),
            ActiveSpeaker(id: idB, speakerProfileId: idB, displayName: "Bob", source: .manual)
        ]

        let request = SpeakerMergeRequest(
            sourceEntity: .active(id: idA),
            targetEntity: .active(id: idB),
            duplicateName: "Bob",
            sourceDisplayName: "Alice",
            targetDisplayName: "Bob"
        )
        vm.executeMerge(request)

        let survivor = store.profiles.first { $0.id == idB }!
        XCTAssertEqual(survivor.lastUsed, later)
    }

    // MARK: - executeMerge: trackerAliases remap

    func testExecuteMerge_trackerAliasesRemapped() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let idA = UUID()
        let idB = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: idA, displayName: "Alice", embedding: makeEmbedding(dominant: 0), sessionCount: 1),
            StoredSpeakerProfile(id: idB, displayName: "Bob", embedding: makeEmbedding(dominant: 1), sessionCount: 5)
        ]
        let (vm, _) = makeViewModel(speakerProfileStore: store)
        vm.activeSpeakers = [
            ActiveSpeaker(id: idA, speakerProfileId: idA, displayName: "Alice", source: .manual),
            ActiveSpeaker(id: idB, speakerProfileId: idB, displayName: "Bob", source: .manual)
        ]
        // Simulate a tracker alias pointing to the absorbed speaker
        let trackerUUID = UUID().uuidString
        vm.trackerAliases[trackerUUID] = idA

        let request = SpeakerMergeRequest(
            sourceEntity: .active(id: idA),
            targetEntity: .active(id: idB),
            duplicateName: "Bob",
            sourceDisplayName: "Alice",
            targetDisplayName: "Bob"
        )
        vm.executeMerge(request)

        // Tracker alias should now point to survivor
        XCTAssertEqual(vm.trackerAliases[trackerUUID], idB)
    }

    // MARK: - addManualSpeaker duplicate check

    func testAddManualSpeaker_existingActive_noDuplicate() {
        let (vm, _) = makeViewModel()
        let id = UUID()
        vm.activeSpeakers = [
            ActiveSpeaker(id: id, displayName: "Alice", source: .manual)
        ]
        vm.speakerDisplayNames = [id.uuidString: "Alice"]

        vm.addManualSpeaker(displayName: "Alice")

        // Should set pendingActivationRequest or prevent creation, not add duplicate
        // The exact behavior: should not create a second speaker with same name
        let aliceCount = vm.activeSpeakers.filter { $0.displayName == "Alice" }.count
        XCTAssertEqual(aliceCount, 1, "Should not create duplicate active speaker")
    }

    func testTryRenameActiveSpeaker_emptyName_isIgnored() {
        let (vm, _) = makeViewModel()
        vm.addManualSpeaker(displayName: "Alice")
        let id = vm.activeSpeakers[0].id

        vm.tryRenameActiveSpeaker(id: id, displayName: "")

        XCTAssertEqual(vm.activeSpeakers[0].displayName, "Alice")
        XCTAssertNil(vm.pendingMergeRequest)
    }

    func testTryRenameActiveSpeaker_whitespaceOnlyName_isIgnored() {
        let (vm, _) = makeViewModel()
        vm.addManualSpeaker(displayName: "Alice")
        let id = vm.activeSpeakers[0].id

        vm.tryRenameActiveSpeaker(id: id, displayName: "   ")

        XCTAssertEqual(vm.activeSpeakers[0].displayName, "Alice")
    }

    func testTryRenameSpeaker_emptyName_isIgnored() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let id = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: id, displayName: "Alice", embedding: [Float](repeating: 0.1, count: 256))
        ]
        let (vm, _) = makeViewModel(speakerProfileStore: store)

        vm.tryRenameSpeaker(id: id, to: "")

        XCTAssertEqual(vm.speakerProfiles.first(where: { $0.id == id })?.displayName, "Alice")
        XCTAssertNil(vm.pendingMergeRequest)
    }

    func testTryRenameSpeaker_whitespaceOnlyName_isIgnored() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let id = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: id, displayName: "Alice", embedding: [Float](repeating: 0.1, count: 256))
        ]
        let (vm, _) = makeViewModel(speakerProfileStore: store)

        vm.tryRenameSpeaker(id: id, to: "   ")

        XCTAssertEqual(vm.speakerProfiles.first(where: { $0.id == id })?.displayName, "Alice")
    }

    func testAddManualSpeaker_existingRegistered_activatesExisting() {
        let store = SpeakerProfileStore(directory: tmpDir)
        let profileId = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: profileId, displayName: "Alice", embedding: makeEmbedding(dominant: 0))
        ]
        let (vm, _) = makeViewModel(speakerProfileStore: store)

        vm.addManualSpeaker(displayName: "Alice")

        // Should activate the existing profile rather than creating a new speaker
        let activeWithProfile = vm.activeSpeakers.filter { $0.speakerProfileId == profileId }
        XCTAssertEqual(activeWithProfile.count, 1, "Should activate existing registered profile")
    }
}
