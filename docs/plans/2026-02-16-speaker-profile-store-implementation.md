# SpeakerProfileStore Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Persist speaker embedding profiles across sessions so known speakers are recognized immediately without warm-up.

**Architecture:** Add `SpeakerProfileStore` (persistence layer) + `StoredSpeakerProfile` (data model). Extend `EmbeddingBasedSpeakerTracker` with export/load. Extend `SpeakerDiarizer` protocol with profile export/load. Wire into `ChunkedWhisperEngine` to load on start, save on stop.

**Tech Stack:** Swift, Foundation (JSONEncoder/Decoder, FileManager)

**Worktree:** `.worktrees/feature/speaker-profile-store/`

**Test command:** `swift test --filter QuickTranscriberTests --package-path /Users/ayaya/DISK/nextcloud/code/swift/quick-transcriber/.worktrees/feature/speaker-profile-store`

---

### Task 1: StoredSpeakerProfile Data Model

**Files:**
- Create: `Sources/QuickTranscriber/Models/StoredSpeakerProfile.swift`
- Test: `Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift`

**Step 1: Write the failing test**

Create `Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift`:

```swift
import XCTest
@testable import QuickTranscriberLib

final class SpeakerProfileStoreTests: XCTestCase {

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
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter SpeakerProfileStoreTests --package-path /Users/ayaya/DISK/nextcloud/code/swift/quick-transcriber/.worktrees/feature/speaker-profile-store`
Expected: FAIL — `StoredSpeakerProfile` not found

**Step 3: Write minimal implementation**

Create `Sources/QuickTranscriber/Models/StoredSpeakerProfile.swift`:

```swift
import Foundation

public struct StoredSpeakerProfile: Codable, Equatable, Sendable {
    public let id: UUID
    public var label: String
    public var embedding: [Float]
    public var lastUsed: Date
    public var sessionCount: Int

    public init(id: UUID = UUID(), label: String, embedding: [Float], lastUsed: Date = Date(), sessionCount: Int = 1) {
        self.id = id
        self.label = label
        self.embedding = embedding
        self.lastUsed = lastUsed
        self.sessionCount = sessionCount
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter SpeakerProfileStoreTests --package-path /Users/ayaya/DISK/nextcloud/code/swift/quick-transcriber/.worktrees/feature/speaker-profile-store`
Expected: PASS

**Step 5: Commit**

```bash
git -C .worktrees/feature/speaker-profile-store add Sources/QuickTranscriber/Models/StoredSpeakerProfile.swift Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift
git -C .worktrees/feature/speaker-profile-store commit -m "feat: add StoredSpeakerProfile data model"
```

---

### Task 2: SpeakerProfileStore — Save and Load

**Files:**
- Create: `Sources/QuickTranscriber/Models/SpeakerProfileStore.swift`
- Modify: `Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift`

**Step 1: Write the failing tests**

Append to `SpeakerProfileStoreTests.swift`:

```swift
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
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter SpeakerProfileStoreTests --package-path /Users/ayaya/DISK/nextcloud/code/swift/quick-transcriber/.worktrees/feature/speaker-profile-store`
Expected: FAIL — `SpeakerProfileStore` not found

**Step 3: Write minimal implementation**

Create `Sources/QuickTranscriber/Models/SpeakerProfileStore.swift`:

```swift
import Foundation

public final class SpeakerProfileStore {
    private let fileURL: URL
    public var profiles: [StoredSpeakerProfile] = []

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("QuickTranscriber")
        self.fileURL = dir.appendingPathComponent("speakers.json")
    }

    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            profiles = []
            return
        }
        let data = try Data(contentsOf: fileURL)
        profiles = try JSONDecoder().decode([StoredSpeakerProfile].self, from: data)
    }

    public func save() throws {
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: fileURL, options: .atomic)
    }

    public func deleteAll() {
        profiles = []
        try? FileManager.default.removeItem(at: fileURL)
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter SpeakerProfileStoreTests --package-path /Users/ayaya/DISK/nextcloud/code/swift/quick-transcriber/.worktrees/feature/speaker-profile-store`
Expected: PASS

**Step 5: Commit**

```bash
git -C .worktrees/feature/speaker-profile-store add Sources/QuickTranscriber/Models/SpeakerProfileStore.swift Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift
git -C .worktrees/feature/speaker-profile-store commit -m "feat: add SpeakerProfileStore save/load"
```

---

### Task 3: SpeakerProfileStore — Merge Strategy

**Files:**
- Modify: `Sources/QuickTranscriber/Models/SpeakerProfileStore.swift`
- Modify: `Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift`

**Step 1: Write the failing tests**

Append to `SpeakerProfileStoreTests.swift`:

```swift
    func testMergeMatchingProfileUpdatesExisting() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        let existingEmb = makeEmbedding(dominant: 0)
        store.profiles = [StoredSpeakerProfile(label: "A", embedding: existingEmb, sessionCount: 2)]

        // Session profile very similar to existing (same dominant dimension)
        var sessionEmb = makeEmbedding(dominant: 0)
        sessionEmb[1] = 0.15  // slight variation
        store.mergeSessionProfiles([("A", sessionEmb)])

        XCTAssertEqual(store.profiles.count, 1, "Should update, not add")
        XCTAssertEqual(store.profiles[0].label, "A")
        XCTAssertEqual(store.profiles[0].sessionCount, 3)
        // Embedding should have moved toward sessionEmb
        XCTAssertNotEqual(store.profiles[0].embedding, existingEmb)
    }

    func testMergeNewProfileAddsToStore() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(label: "A", embedding: makeEmbedding(dominant: 0))]

        // Completely different speaker
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
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter SpeakerProfileStoreTests --package-path /Users/ayaya/DISK/nextcloud/code/swift/quick-transcriber/.worktrees/feature/speaker-profile-store`
Expected: FAIL — `mergeSessionProfiles` method not found

**Step 3: Write minimal implementation**

Add to `SpeakerProfileStore`:

```swift
    private let mergeThreshold: Float = 0.5
    private let updateAlpha: Float = 0.3

    public func mergeSessionProfiles(_ sessionProfiles: [(label: String, embedding: [Float])]) {
        for (label, embedding) in sessionProfiles {
            var bestIndex = -1
            var bestSimilarity: Float = -1

            for (i, stored) in profiles.enumerated() {
                let sim = EmbeddingBasedSpeakerTracker.cosineSimilarity(embedding, stored.embedding)
                if sim > bestSimilarity {
                    bestSimilarity = sim
                    bestIndex = i
                }
            }

            if bestIndex >= 0 && bestSimilarity >= mergeThreshold {
                // Update existing profile
                let alpha = updateAlpha
                profiles[bestIndex].embedding = zip(profiles[bestIndex].embedding, embedding).map { old, new in
                    (1 - alpha) * old + alpha * new
                }
                profiles[bestIndex].lastUsed = Date()
                profiles[bestIndex].sessionCount += 1
            } else {
                // Add new profile
                profiles.append(StoredSpeakerProfile(label: label, embedding: embedding))
            }
        }
    }
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter SpeakerProfileStoreTests --package-path /Users/ayaya/DISK/nextcloud/code/swift/quick-transcriber/.worktrees/feature/speaker-profile-store`
Expected: PASS

**Step 5: Commit**

```bash
git -C .worktrees/feature/speaker-profile-store add Sources/QuickTranscriber/Models/SpeakerProfileStore.swift Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift
git -C .worktrees/feature/speaker-profile-store commit -m "feat: add SpeakerProfileStore merge strategy"
```

---

### Task 4: EmbeddingBasedSpeakerTracker — Export and Load

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift`
- Modify: `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift`

**Step 1: Write the failing tests**

Append to `EmbeddingBasedSpeakerTrackerTests.swift`:

```swift
    // MARK: - Export / Load Profiles

    func testExportProfilesReturnsRegisteredSpeakers() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        _ = tracker.identify(embedding: embA)
        _ = tracker.identify(embedding: embB)

        let exported = tracker.exportProfiles()
        XCTAssertEqual(exported.count, 2)
        XCTAssertEqual(exported[0].label, "A")
        XCTAssertEqual(exported[1].label, "B")
    }

    func testLoadProfilesInitializesTracker() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        tracker.loadProfiles([
            (label: "A", embedding: embA),
            (label: "B", embedding: embB)
        ])

        // Identify with embedding similar to A
        let label = tracker.identify(embedding: embA)
        XCTAssertEqual(label, "A")
    }

    func testLoadProfilesNextLabelContinuesFromLoaded() {
        let tracker = EmbeddingBasedSpeakerTracker()
        tracker.loadProfiles([
            (label: "A", embedding: makeEmbedding(dominant: 0)),
            (label: "B", embedding: makeEmbedding(dominant: 1))
        ])

        // Register a completely new speaker
        let label = tracker.identify(embedding: makeEmbedding(dominant: 2))
        XCTAssertEqual(label, "C", "New speaker should get next label after loaded profiles")
    }

    func testLoadProfilesClearsExistingState() {
        let tracker = EmbeddingBasedSpeakerTracker()
        _ = tracker.identify(embedding: makeEmbedding(dominant: 0))  // registers A
        _ = tracker.identify(embedding: makeEmbedding(dominant: 1))  // registers B

        // Load only one profile
        tracker.loadProfiles([
            (label: "X", embedding: makeEmbedding(dominant: 2))
        ])

        let exported = tracker.exportProfiles()
        XCTAssertEqual(exported.count, 1)
        XCTAssertEqual(exported[0].label, "X")
    }
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter EmbeddingBasedSpeakerTrackerTests --package-path /Users/ayaya/DISK/nextcloud/code/swift/quick-transcriber/.worktrees/feature/speaker-profile-store`
Expected: FAIL — `exportProfiles` and `loadProfiles` not found

**Step 3: Write minimal implementation**

Add to `EmbeddingBasedSpeakerTracker` (after `reset()`):

```swift
    public func exportProfiles() -> [(label: String, embedding: [Float])] {
        profiles.map { ($0.label, $0.embedding) }
    }

    public func loadProfiles(_ loadedProfiles: [(label: String, embedding: [Float])]) {
        profiles = loadedProfiles.map { SpeakerProfile(label: $0.label, embedding: $0.embedding) }
        nextLabelIndex = loadedProfiles.count
    }
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter EmbeddingBasedSpeakerTrackerTests --package-path /Users/ayaya/DISK/nextcloud/code/swift/quick-transcriber/.worktrees/feature/speaker-profile-store`
Expected: PASS

**Step 5: Commit**

```bash
git -C .worktrees/feature/speaker-profile-store add Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift
git -C .worktrees/feature/speaker-profile-store commit -m "feat: add export/load to EmbeddingBasedSpeakerTracker"
```

---

### Task 5: SpeakerDiarizer Protocol + FluidAudioSpeakerDiarizer

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift` (protocol + implementation)
- Modify: `Tests/QuickTranscriberTests/Mocks/MockSpeakerDiarizer.swift`

**Step 1: Update protocol**

Add to `SpeakerDiarizer` protocol in `SpeakerDiarizer.swift`:

```swift
public protocol SpeakerDiarizer: AnyObject, Sendable {
    func setup() async throws
    func identifySpeaker(audioChunk: [Float]) async -> String?
    func updateExpectedSpeakerCount(_ count: Int?)
    func exportSpeakerProfiles() -> [(label: String, embedding: [Float])]
    func loadSpeakerProfiles(_ profiles: [(label: String, embedding: [Float])])
}
```

**Step 2: Implement in FluidAudioSpeakerDiarizer**

Add to `FluidAudioSpeakerDiarizer`:

```swift
    public func exportSpeakerProfiles() -> [(label: String, embedding: [Float])] {
        speakerTracker.exportProfiles()
    }

    public func loadSpeakerProfiles(_ profiles: [(label: String, embedding: [Float])]) {
        speakerTracker.loadProfiles(profiles)
        lock.withLock {
            rollingBuffer = []
            pacer = DiarizationPacer(
                diarizationChunkDuration: pacer.diarizationChunkDuration,
                sampleRate: sampleRate
            )
        }
    }
```

**Step 3: Update MockSpeakerDiarizer**

Add to `MockSpeakerDiarizer`:

```swift
    var exportedProfiles: [(label: String, embedding: [Float])] = []
    var loadedProfiles: [(label: String, embedding: [Float])]?

    func exportSpeakerProfiles() -> [(label: String, embedding: [Float])] {
        exportedProfiles
    }

    func loadSpeakerProfiles(_ profiles: [(label: String, embedding: [Float])]) {
        loadedProfiles = profiles
    }
```

**Step 4: Run all tests to verify nothing broke**

Run: `swift test --filter QuickTranscriberTests --package-path /Users/ayaya/DISK/nextcloud/code/swift/quick-transcriber/.worktrees/feature/speaker-profile-store`
Expected: ALL PASS (224+ tests)

**Step 5: Commit**

```bash
git -C .worktrees/feature/speaker-profile-store add Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift Tests/QuickTranscriberTests/Mocks/MockSpeakerDiarizer.swift
git -C .worktrees/feature/speaker-profile-store commit -m "feat: add profile export/load to SpeakerDiarizer protocol"
```

---

### Task 6: ChunkedWhisperEngine Integration

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift`
- Modify: `Tests/QuickTranscriberTests/ChunkedWhisperEngineTests.swift`

**Step 1: Write the failing test**

Add to `ChunkedWhisperEngineTests.swift`:

```swift
    func testStopStreamingExportsSpeakerProfiles() async throws {
        let mockDiarizer = MockSpeakerDiarizer()
        mockDiarizer.exportedProfiles = [("A", [Float](repeating: 0.1, count: 256))]
        let store = SpeakerProfileStore(directory: makeTempDirectory())
        let engine = ChunkedWhisperEngine(
            audioCaptureService: MockAudioCaptureService(),
            transcriber: MockChunkTranscriber(),
            diarizer: mockDiarizer,
            speakerProfileStore: store
        )

        var params = TranscriptionParameters.default
        params.enableSpeakerDiarization = true
        try await engine.startStreaming(language: "en", parameters: params, onStateChange: { _ in })
        await engine.stopStreaming()

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].label, "A")
    }

    func testStartStreamingLoadsSpeakerProfiles() async throws {
        let mockDiarizer = MockSpeakerDiarizer()
        let dir = makeTempDirectory()
        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(label: "A", embedding: [Float](repeating: 0.1, count: 256))]
        try store.save()

        // Create new store instance (simulating app restart)
        let store2 = SpeakerProfileStore(directory: dir)
        try store2.load()

        let engine = ChunkedWhisperEngine(
            audioCaptureService: MockAudioCaptureService(),
            transcriber: MockChunkTranscriber(),
            diarizer: mockDiarizer,
            speakerProfileStore: store2
        )

        var params = TranscriptionParameters.default
        params.enableSpeakerDiarization = true
        try await engine.startStreaming(language: "en", parameters: params, onStateChange: { _ in })

        XCTAssertNotNil(mockDiarizer.loadedProfiles)
        XCTAssertEqual(mockDiarizer.loadedProfiles?.count, 1)
        XCTAssertEqual(mockDiarizer.loadedProfiles?.first?.label, "A")

        await engine.stopStreaming()
    }
```

Note: This test requires adding a `makeTempDirectory()` helper to the test file if not already present. Also add `@testable import QuickTranscriberLib` if not present.

**Step 2: Run tests to verify they fail**

Run: `swift test --filter ChunkedWhisperEngineTests --package-path /Users/ayaya/DISK/nextcloud/code/swift/quick-transcriber/.worktrees/feature/speaker-profile-store`
Expected: FAIL — `ChunkedWhisperEngine` initializer does not accept `speakerProfileStore`

**Step 3: Write minimal implementation**

Modify `ChunkedWhisperEngine`:

1. Add property: `private let speakerProfileStore: SpeakerProfileStore?`
2. Update init to accept `speakerProfileStore: SpeakerProfileStore? = nil`
3. In `startStreaming()`, after `diarizer?.updateExpectedSpeakerCount(...)`, add:

```swift
if let diarizer, parameters.enableSpeakerDiarization, let store = speakerProfileStore {
    let profiles = store.profiles.map { ($0.label, $0.embedding) }
    if !profiles.isEmpty {
        diarizer.loadSpeakerProfiles(profiles)
        NSLog("[ChunkedWhisperEngine] Loaded \(profiles.count) speaker profiles from store")
    }
}
```

4. In `stopStreaming()`, after `accumulator.reset()`, add:

```swift
if let diarizer, currentParameters.enableSpeakerDiarization, let store = speakerProfileStore {
    let sessionProfiles = diarizer.exportSpeakerProfiles()
    if !sessionProfiles.isEmpty {
        store.mergeSessionProfiles(sessionProfiles)
        try? store.save()
        NSLog("[ChunkedWhisperEngine] Saved \(sessionProfiles.count) speaker profiles to store")
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter ChunkedWhisperEngineTests --package-path /Users/ayaya/DISK/nextcloud/code/swift/quick-transcriber/.worktrees/feature/speaker-profile-store`
Expected: PASS

**Step 5: Commit**

```bash
git -C .worktrees/feature/speaker-profile-store add Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift Tests/QuickTranscriberTests/ChunkedWhisperEngineTests.swift
git -C .worktrees/feature/speaker-profile-store commit -m "feat: wire SpeakerProfileStore into ChunkedWhisperEngine"
```

---

### Task 7: TranscriptionViewModel Integration

**Files:**
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift`

**Step 1: Add SpeakerProfileStore to ViewModel**

In `TranscriptionViewModel.__init__`:
1. Add `private let speakerProfileStore: SpeakerProfileStore`
2. Create and load the store: `self.speakerProfileStore = SpeakerProfileStore()` then `try? speakerProfileStore.load()`
3. Pass it to `ChunkedWhisperEngine`:

```swift
let resolvedEngine = engine ?? ChunkedWhisperEngine(
    diarizer: diarizer ?? FluidAudioSpeakerDiarizer(),
    speakerProfileStore: speakerProfileStore
)
```

**Step 2: Run all tests**

Run: `swift test --filter QuickTranscriberTests --package-path /Users/ayaya/DISK/nextcloud/code/swift/quick-transcriber/.worktrees/feature/speaker-profile-store`
Expected: ALL PASS

**Step 3: Commit**

```bash
git -C .worktrees/feature/speaker-profile-store add Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift
git -C .worktrees/feature/speaker-profile-store commit -m "feat: wire SpeakerProfileStore into TranscriptionViewModel"
```

---

### Task 8: Full Integration Test + All Tests Green

**Step 1: Run all unit tests**

Run: `swift test --filter QuickTranscriberTests --package-path /Users/ayaya/DISK/nextcloud/code/swift/quick-transcriber/.worktrees/feature/speaker-profile-store`
Expected: ALL PASS

**Step 2: Run build check**

Run: `swift build --package-path /Users/ayaya/DISK/nextcloud/code/swift/quick-transcriber/.worktrees/feature/speaker-profile-store`
Expected: Build succeeded

**Step 3: Final commit if any fixups needed, then use `superpowers:finishing-a-development-branch`**
