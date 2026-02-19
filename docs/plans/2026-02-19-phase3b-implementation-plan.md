# Phase 3b: Per-Chunk Embedding Storage Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Store per-chunk embeddings throughout the pipeline, enable real-time profile correction when users reassign speaker labels, and persist embedding history across sessions.

**Architecture:** EmbeddingBasedSpeakerTracker switches from moving average to full embedding history with arithmetic mean. Embeddings propagate through SpeakerIdentification → ConfirmedSegment. User corrections flow VM → TranscriptionService → ChunkedWhisperEngine → FluidAudioSpeakerDiarizer → EmbeddingBasedSpeakerTracker, moving embeddings between profiles and triggering recalculation. EmbeddingHistoryStore persists session histories to `embedding_history.json`.

**Tech Stack:** Swift, XCTest, SwiftUI

**Design doc:** `docs/plans/2026-02-19-phase3b-per-chunk-embedding-design.md`

---

### Task 1: EmbeddingBasedSpeakerTracker — Embedding History in identify()

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift`
- Test: `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift`

**Context:**
- Current `SpeakerProfile` at line 24-28: has `label`, `embedding`, `hitCount`
- Current `identify()` at line 54-106: uses moving average `(1-alpha)*old + alpha*new`
- Current `loadProfiles()` at line 158-161: creates profiles with `hitCount: 0`
- The `updateAlpha` param and moving average logic will be replaced by arithmetic mean

**Step 1: Write failing tests**

Add to `EmbeddingBasedSpeakerTrackerTests.swift`:

```swift
// MARK: - Embedding History

func testIdentifyStoresEmbeddingHistory() {
    let tracker = EmbeddingBasedSpeakerTracker()
    let emb1 = makeEmbedding(dominant: 0)
    let emb2 = makeEmbedding(dominant: 0)  // similar, matches A
    _ = tracker.identify(embedding: emb1)
    _ = tracker.identify(embedding: emb2)

    let profiles = tracker.exportProfiles()
    XCTAssertEqual(profiles[0].hitCount, 2)
    // Verify embedding is arithmetic mean (not moving average)
    let expectedAvg = zip(emb1, emb2).map { ($0 + $1) / 2 }
    for i in 0..<expectedAvg.count {
        XCTAssertEqual(profiles[0].embedding[i], expectedAvg[i], accuracy: 0.001)
    }
}

func testIdentifyNewSpeakerHasSingleHistoryEntry() {
    let tracker = EmbeddingBasedSpeakerTracker()
    let emb = makeEmbedding(dominant: 0)
    _ = tracker.identify(embedding: emb)

    let profiles = tracker.exportProfiles()
    XCTAssertEqual(profiles[0].hitCount, 1)
    XCTAssertEqual(profiles[0].embedding, emb)
}

func testLoadProfilesSeedsHistory() {
    let tracker = EmbeddingBasedSpeakerTracker()
    let emb = makeEmbedding(dominant: 0)
    tracker.loadProfiles([("A", emb)])

    // New identification should combine with loaded seed
    var similar = makeEmbedding(dominant: 0)
    similar[1] = 0.15
    _ = tracker.identify(embedding: similar)

    let profiles = tracker.exportProfiles()
    XCTAssertEqual(profiles[0].hitCount, 2)  // seed + new
    // Embedding should be average of seed and new
    let expectedAvg = zip(emb, similar).map { ($0 + $1) / 2 }
    for i in 0..<expectedAvg.count {
        XCTAssertEqual(profiles[0].embedding[i], expectedAvg[i], accuracy: 0.001)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter EmbeddingBasedSpeakerTrackerTests 2>&1 | tail -20`
Expected: FAIL — tests reference arithmetic mean behavior not yet implemented

**Step 3: Implement embedding history**

In `EmbeddingBasedSpeakerTracker.swift`:

1. Add `embeddingHistory` to `SpeakerProfile`:
```swift
public struct SpeakerProfile {
    public let label: String
    public var embedding: [Float]
    public var hitCount: Int
    public var embeddingHistory: [[Float]]
}
```

2. Add helper method:
```swift
private func recalculateEmbedding(at index: Int) {
    let history = profiles[index].embeddingHistory
    guard !history.isEmpty else { return }
    let count = Float(history.count)
    var avg = [Float](repeating: 0, count: history[0].count)
    for emb in history {
        for i in 0..<avg.count {
            avg[i] += emb[i]
        }
    }
    for i in 0..<avg.count {
        avg[i] /= count
    }
    profiles[index].embedding = avg
    profiles[index].hitCount = history.count
}
```

3. Modify `identify()` — replace all three moving average blocks (lines 70-76, 80-86, 90-97) with history-based update:
```swift
// Replace moving average update pattern:
//   profiles[bestIndex].hitCount += 1
//   let alpha = updateAlpha
//   profiles[bestIndex].embedding = zip(...).map { (1 - alpha) * old + alpha * new }
// With:
profiles[bestIndex].embeddingHistory.append(embedding)
recalculateEmbedding(at: bestIndex)
```

4. Modify new speaker registration (line 101-104):
```swift
let label = String(UnicodeScalar(UInt8(65 + nextLabelIndex % 26)))
profiles.append(SpeakerProfile(label: label, embedding: embedding, hitCount: 1, embeddingHistory: [embedding]))
nextLabelIndex += 1
```

5. Modify `loadProfiles()`:
```swift
public func loadProfiles(_ loadedProfiles: [(label: String, embedding: [Float])]) {
    profiles = loadedProfiles.map {
        SpeakerProfile(label: $0.label, embedding: $0.embedding, hitCount: 1, embeddingHistory: [$0.embedding])
    }
    nextLabelIndex = loadedProfiles.count
}
```

6. Modify `reset()`:
```swift
public func reset() {
    profiles = []
    nextLabelIndex = 0
}
```

7. Update `mergeProfiles()` (line 125-147) to use history:
```swift
private func mergeProfiles(threshold: Float) {
    var i = 0
    while i < profiles.count {
        var j = i + 1
        while j < profiles.count {
            let sim = Self.cosineSimilarity(profiles[i].embedding, profiles[j].embedding)
            if sim >= threshold {
                let (keep, remove) = profiles[i].hitCount >= profiles[j].hitCount ? (i, j) : (j, i)
                profiles[keep].embeddingHistory.append(contentsOf: profiles[remove].embeddingHistory)
                recalculateEmbedding(at: keep)
                profiles.remove(at: remove)
                if remove < keep { i = max(0, i - 1) }
            } else {
                j += 1
            }
        }
        i += 1
    }
}
```

8. Remove the `updateAlpha` stored property. Keep the init parameter for backward compatibility but ignore it (or remove from init — check callers first).

**Note:** The `updateAlpha` parameter is used in 3 places:
- `EmbeddingBasedSpeakerTracker.init()` (line 43)
- `FluidAudioSpeakerDiarizer.init()` passes it (line 54-58)
- `SpeakerProfileStore` uses its own `updateAlpha` for merge (line 12) — **leave this unchanged** for now

Keep the init parameter but mark the property as unused (or remove it if all callers can be updated). The `SpeakerProfileStore.mergeSessionProfiles()` still uses moving average for cross-session merging — that's fine, it doesn't have full history yet.

**Step 4: Run tests to verify they pass**

Run: `swift test --filter EmbeddingBasedSpeakerTrackerTests 2>&1 | tail -20`
Expected: ALL PASS

Also run full test suite to check no regressions:
Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -30`

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift
git commit -m "feat: add embedding history to EmbeddingBasedSpeakerTracker, replace moving average with arithmetic mean"
```

---

### Task 2: EmbeddingBasedSpeakerTracker — correctAssignment()

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift`
- Test: `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift`

**Context:**
- After Task 1, profiles have `embeddingHistory: [[Float]]`
- `correctAssignment` matches embedding by value (exact [Float] comparison), moves it between profiles
- If target profile doesn't exist, create it
- If source profile becomes empty after removal, remove it

**Step 1: Write failing tests**

```swift
// MARK: - Correct Assignment

func testCorrectAssignmentMovesEmbeddingBetweenProfiles() {
    let tracker = EmbeddingBasedSpeakerTracker()
    let embA = makeEmbedding(dominant: 0)
    let embB = makeEmbedding(dominant: 1)
    _ = tracker.identify(embedding: embA)  // A
    _ = tracker.identify(embedding: embB)  // B

    // Wrongly identified embedding — move B's embedding to A
    tracker.correctAssignment(embedding: embB, from: "B", to: "A")

    let profiles = tracker.exportProfiles()
    // B should be removed (empty history)
    XCTAssertEqual(profiles.count, 1)
    XCTAssertEqual(profiles[0].label, "A")
    XCTAssertEqual(profiles[0].hitCount, 2)
}

func testCorrectAssignmentRecalculatesProfiles() {
    let tracker = EmbeddingBasedSpeakerTracker()
    let embA1 = makeEmbedding(dominant: 0)
    var embA2 = makeEmbedding(dominant: 0)
    embA2[1] = 0.15  // similar to A
    let embB = makeEmbedding(dominant: 1)
    _ = tracker.identify(embedding: embA1)  // A
    _ = tracker.identify(embedding: embA2)  // A (matched)
    _ = tracker.identify(embedding: embB)   // B

    // Correct: embA2 was actually speaker B
    tracker.correctAssignment(embedding: embA2, from: "A", to: "B")

    let profiles = tracker.exportProfiles()
    let profileA = profiles.first { $0.label == "A" }!
    let profileB = profiles.first { $0.label == "B" }!

    // A should only have embA1
    XCTAssertEqual(profileA.hitCount, 1)
    XCTAssertEqual(profileA.embedding, embA1)

    // B should have embB and embA2, averaged
    XCTAssertEqual(profileB.hitCount, 2)
}

func testCorrectAssignmentToNewSpeaker() {
    let tracker = EmbeddingBasedSpeakerTracker()
    let emb = makeEmbedding(dominant: 0)
    _ = tracker.identify(embedding: emb)  // A

    // Correct to speaker that doesn't exist
    tracker.correctAssignment(embedding: emb, from: "A", to: "Z")

    let profiles = tracker.exportProfiles()
    XCTAssertEqual(profiles.count, 1)
    XCTAssertEqual(profiles[0].label, "Z")
    XCTAssertEqual(profiles[0].embedding, emb)
}

func testCorrectAssignmentWithNonexistentEmbeddingIsNoOp() {
    let tracker = EmbeddingBasedSpeakerTracker()
    let embA = makeEmbedding(dominant: 0)
    _ = tracker.identify(embedding: embA)

    let nonexistent = makeEmbedding(dominant: 5)
    tracker.correctAssignment(embedding: nonexistent, from: "A", to: "B")

    // Should not crash or change anything meaningful
    let profiles = tracker.exportProfiles()
    XCTAssertEqual(profiles.count, 1)
    XCTAssertEqual(profiles[0].label, "A")
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter EmbeddingBasedSpeakerTrackerTests/testCorrectAssignment 2>&1 | tail -20`
Expected: FAIL — `correctAssignment` not defined

**Step 3: Implement correctAssignment**

```swift
/// Move an embedding from one speaker's profile to another.
/// Used when the user corrects a speaker assignment.
/// If the target speaker doesn't exist, a new profile is created.
/// If the source profile becomes empty, it is removed.
public func correctAssignment(embedding: [Float], from oldLabel: String, to newLabel: String) {
    // Remove from old profile
    if let oldIdx = profiles.firstIndex(where: { $0.label == oldLabel }) {
        profiles[oldIdx].embeddingHistory.removeAll { $0 == embedding }
        if profiles[oldIdx].embeddingHistory.isEmpty {
            profiles.remove(at: oldIdx)
        } else {
            recalculateEmbedding(at: oldIdx)
        }
    }

    // Add to new/existing profile
    if let newIdx = profiles.firstIndex(where: { $0.label == newLabel }) {
        profiles[newIdx].embeddingHistory.append(embedding)
        recalculateEmbedding(at: newIdx)
    } else {
        profiles.append(SpeakerProfile(
            label: newLabel,
            embedding: embedding,
            hitCount: 1,
            embeddingHistory: [embedding]
        ))
    }
}
```

**Step 4: Run tests**

Run: `swift test --filter EmbeddingBasedSpeakerTrackerTests 2>&1 | tail -20`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift
git commit -m "feat: add correctAssignment() for real-time speaker correction feedback"
```

---

### Task 3: SpeakerIdentification — Add embedding field

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift` (SpeakerIdentification struct at line 11-14)
- Test: `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift`

**Context:**
- `SpeakerIdentification` currently has `label` and `confidence`
- Add `embedding: [Float]?` so the embedding propagates through the pipeline
- The embedding is populated when diarization actually runs; nil when pacer returns cached result

**Step 1: Write failing test**

```swift
func testIdentifyReturnsSpeakerIdentificationWithEmbedding() {
    let tracker = EmbeddingBasedSpeakerTracker()
    let emb = makeEmbedding(dominant: 0)
    let result = tracker.identify(embedding: emb)
    XCTAssertEqual(result.embedding, emb)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter EmbeddingBasedSpeakerTrackerTests/testIdentifyReturnsSpeakerIdentificationWithEmbedding 2>&1 | tail -10`
Expected: FAIL — `embedding` property not found on `SpeakerIdentification`

**Step 3: Implement**

1. Add `embedding` to `SpeakerIdentification`:
```swift
public struct SpeakerIdentification: Sendable, Equatable {
    public let label: String
    public let confidence: Float
    public let embedding: [Float]?

    public init(label: String, confidence: Float, embedding: [Float]? = nil) {
        self.label = label
        self.confidence = confidence
        self.embedding = embedding
    }
}
```

2. Update `identify()` return statements to include the embedding:
- Line ~76 (matched): `return SpeakerIdentification(label: ..., confidence: bestSimilarity, embedding: embedding)`
- Line ~86 (capacity): `return SpeakerIdentification(label: ..., confidence: bestSimilarity, embedding: embedding)`
- Line ~97 (gate): `return SpeakerIdentification(label: ..., confidence: bestSimilarity, embedding: embedding)`
- Line ~105 (new): `return SpeakerIdentification(label: label, confidence: 1.0, embedding: embedding)`

**Step 4: Run tests**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -30`
Expected: ALL PASS (existing tests use positional init without embedding, default nil)

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift
git commit -m "feat: add embedding field to SpeakerIdentification for pipeline propagation"
```

---

### Task 4: ConfirmedSegment — Add speakerEmbedding field

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/TranscriptionUtils.swift` (ConfirmedSegment at line 3-26)
- Test: `Tests/QuickTranscriberTests/TranscriptionViewModelTests.swift` (verify no regression)

**Context:**
- `ConfirmedSegment` is `Sendable, Equatable`
- `[Float]?` is both Sendable and Equatable
- All existing callers use the named init; adding optional parameter is backward-compatible

**Step 1: Write failing test**

```swift
// In an appropriate test file (e.g., EmbeddingBasedSpeakerTrackerTests or a new section)
func testConfirmedSegmentWithEmbedding() {
    let emb: [Float] = [0.1, 0.2, 0.3]
    let segment = ConfirmedSegment(
        text: "Hello",
        speakerEmbedding: emb
    )
    XCTAssertEqual(segment.speakerEmbedding, emb)
}

func testConfirmedSegmentDefaultNilEmbedding() {
    let segment = ConfirmedSegment(text: "Hello")
    XCTAssertNil(segment.speakerEmbedding)
}
```

**Step 2: Run test to verify it fails**

Expected: FAIL — `speakerEmbedding` not a member of `ConfirmedSegment`

**Step 3: Implement**

Add to `ConfirmedSegment` in `TranscriptionUtils.swift`:
```swift
public struct ConfirmedSegment: Sendable, Equatable {
    public var text: String
    public var precedingSilence: TimeInterval
    public var speaker: String?
    public var speakerConfidence: Float?
    public var isUserCorrected: Bool
    public var originalSpeaker: String?
    public var speakerEmbedding: [Float]?

    public init(
        text: String,
        precedingSilence: TimeInterval = 0,
        speaker: String? = nil,
        speakerConfidence: Float? = nil,
        isUserCorrected: Bool = false,
        originalSpeaker: String? = nil,
        speakerEmbedding: [Float]? = nil
    ) {
        self.text = text
        self.precedingSilence = precedingSilence
        self.speaker = speaker
        self.speakerConfidence = speakerConfidence
        self.isUserCorrected = isUserCorrected
        self.originalSpeaker = originalSpeaker
        self.speakerEmbedding = speakerEmbedding
    }
}
```

**Step 4: Run tests**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -30`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Engines/TranscriptionUtils.swift Tests/
git commit -m "feat: add speakerEmbedding field to ConfirmedSegment"
```

---

### Task 5: SpeakerDiarizer — Propagate embedding + add correctSpeakerAssignment

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift` (protocol at line 5-11, FluidAudioSpeakerDiarizer)
- Test: `Tests/QuickTranscriberTests/SpeakerDiarizerTests.swift`

**Context:**
- `SpeakerDiarizer` protocol defines `identifySpeaker()` returning `SpeakerIdentification?`
- `SpeakerIdentification` now has `embedding: [Float]?` from Task 3
- `FluidAudioSpeakerDiarizer.identifySpeaker()` at line 78-135 calls `speakerTracker.identify(embedding:)` which now returns identification with embedding
- The embedding is only populated when diarization actually runs (not when pacer returns cached)
- `DiarizationPacer.lastResult` stores `SpeakerIdentification?` — cached results have no embedding

**Step 1: Write failing test**

Add to `SpeakerDiarizerTests.swift`:

```swift
func testCorrectSpeakerAssignmentDelegatesToTracker() {
    // Create diarizer and populate it through the tracker
    let diarizer = FluidAudioSpeakerDiarizer()
    // Access the internal tracker indirectly by loading profiles
    let embA = makeEmbedding(dominant: 0)
    let embB = makeEmbedding(dominant: 1)
    diarizer.loadSpeakerProfiles([("A", embA), ("B", embB)])

    // Correct assignment
    diarizer.correctSpeakerAssignment(embedding: embA, from: "A", to: "B")

    // Export and verify
    let profiles = diarizer.exportSpeakerProfiles()
    // A was the only entry for A; should be removed, moved to B
    XCTAssertEqual(profiles.count, 1)
    XCTAssertEqual(profiles[0].label, "B")
}
```

**Step 2: Run test to verify it fails**

Expected: FAIL — `correctSpeakerAssignment` not defined

**Step 3: Implement**

1. Add to `SpeakerDiarizer` protocol:
```swift
public protocol SpeakerDiarizer: AnyObject, Sendable {
    func setup() async throws
    func identifySpeaker(audioChunk: [Float]) async -> SpeakerIdentification?
    func updateExpectedSpeakerCount(_ count: Int?)
    func exportSpeakerProfiles() -> [(label: String, embedding: [Float])]
    func loadSpeakerProfiles(_ profiles: [(label: String, embedding: [Float])])
    func correctSpeakerAssignment(embedding: [Float], from oldLabel: String, to newLabel: String)
}
```

2. Add to `FluidAudioSpeakerDiarizer`:
```swift
public func correctSpeakerAssignment(embedding: [Float], from oldLabel: String, to newLabel: String) {
    speakerTracker.correctAssignment(embedding: embedding, from: oldLabel, to: newLabel)
}
```

3. The embedding propagation through `identifySpeaker()` already works because `speakerTracker.identify()` now returns `SpeakerIdentification` with embedding (from Task 3). The cached result from pacer has `embedding: nil`, which is correct — we only have embedding when diarization actually runs.

**Step 4: Run tests**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -30`
Expected: ALL PASS

Check if there's a mock SpeakerDiarizer in tests that needs updating (the protocol now has a new required method):

Run: `grep -rn "SpeakerDiarizer" Tests/`

If a mock exists, add the method to it.

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift Tests/
git commit -m "feat: add correctSpeakerAssignment to SpeakerDiarizer protocol"
```

---

### Task 6: ChunkedWhisperEngine — Store embedding + correction path

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift`
- Modify: `Sources/QuickTranscriber/Engines/TranscriptionEngine.swift` (protocol)
- Modify: `Sources/QuickTranscriber/Services/TranscriptionService.swift`
- Test: `Tests/QuickTranscriberTests/` (relevant engine tests)

**Context:**
- `processChunk()` at line 170-278: creates ConfirmedSegment with speaker/speakerConfidence
- `rawSpeakerResult` at line 190: SpeakerIdentification from diarizer, now has `.embedding`
- `smoothedResult` at line 221: from SpeakerLabelTracker, may differ from raw
- We store `rawSpeakerResult.embedding` (not smoothedResult's) because it represents this chunk's audio
- `TranscriptionEngine` protocol at TranscriptionEngine.swift line 31-37
- `TranscriptionService` at TranscriptionService.swift line 17-52

**Step 1: Write failing test**

Look for existing ChunkedWhisperEngine tests or integration tests. If mock-based, add a test that verifies embedding propagation.

```swift
func testCorrectSpeakerAssignmentExists() {
    // Verify the method exists on ChunkedWhisperEngine
    let engine = ChunkedWhisperEngine()
    // Should compile — just verifying the API exists
    let emb: [Float] = [0.1]
    engine.correctSpeakerAssignment(embedding: emb, from: "A", to: "B")
}
```

**Step 2: Run test to verify it fails**

Expected: FAIL — method not defined

**Step 3: Implement**

1. Add to `TranscriptionEngine` protocol with default no-op:
```swift
public protocol TranscriptionEngine: AnyObject {
    func setup(model: String) async throws
    func startStreaming(language: String, parameters: TranscriptionParameters, onStateChange: @escaping @Sendable (TranscriptionState) -> Void) async throws
    func stopStreaming() async
    func cleanup()
    var isStreaming: Bool { get async }
    func correctSpeakerAssignment(embedding: [Float], from oldLabel: String, to newLabel: String)
}

extension TranscriptionEngine {
    public func startStreaming(language: String, onStateChange: @escaping @Sendable (TranscriptionState) -> Void) async throws {
        try await startStreaming(language: language, parameters: .default, onStateChange: onStateChange)
    }

    public func correctSpeakerAssignment(embedding: [Float], from oldLabel: String, to newLabel: String) {
        // Default no-op for engines without diarization
    }
}
```

2. Add to `TranscriptionService`:
```swift
public func correctSpeakerAssignment(embedding: [Float], from oldLabel: String, to newLabel: String) {
    engine.correctSpeakerAssignment(embedding: embedding, from: oldLabel, to: newLabel)
}
```

3. Add to `ChunkedWhisperEngine`:
```swift
public func correctSpeakerAssignment(embedding: [Float], from oldLabel: String, to newLabel: String) {
    diarizer?.correctSpeakerAssignment(embedding: embedding, from: oldLabel, to: newLabel)
}
```

4. Modify `processChunk()` — store embedding in ConfirmedSegment. Around line 246-252, change the ConfirmedSegment creation:
```swift
confirmedSegments.append(ConfirmedSegment(
    text: segment.text,
    precedingSilence: precedingSilence,
    speaker: smoothedResult?.label,
    speakerConfidence: smoothedResult?.confidence,
    speakerEmbedding: rawSpeakerResult?.embedding
))
```

Note: `rawSpeakerResult?.embedding` is the embedding from the current diarization run. When pacer returns cached, `rawSpeakerResult` has a SpeakerIdentification with `embedding: nil`. So segments created during pacer-cached periods have nil embedding. This is correct — only segments with actual diarization have embeddings to move.

**Step 4: Run tests**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -30`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift Sources/QuickTranscriber/Engines/TranscriptionEngine.swift Sources/QuickTranscriber/Services/TranscriptionService.swift Tests/
git commit -m "feat: propagate embedding through pipeline and add correction path"
```

---

### Task 7: TranscriptionViewModel — Wire correction to engine

**Files:**
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift`
- Test: `Tests/QuickTranscriberTests/TranscriptionViewModelTests.swift`

**Context:**
- `reassignSpeakerForBlock()` at line 284-307: modifies VM's confirmedSegments directly
- `reassignSpeakerForSelection()` at line 309-367: also modifies segments
- Both need to call `service.correctSpeakerAssignment()` for each segment with an embedding
- The service/engine correction updates the tracker's profiles for future chunk recognition
- No index mapping needed: we pass the embedding value, not indices

**Step 1: Write failing test**

This test needs a mock TranscriptionEngine that tracks correctSpeakerAssignment calls. Check if one already exists in the test suite. If not, create one.

```swift
func testReassignSpeakerForBlockCallsCorrectSpeakerAssignment() {
    // Setup: VM with segments that have embeddings
    let emb: [Float] = Array(repeating: 0.1, count: 256)
    let vm = makeViewModel()  // using mock engine
    vm.confirmedSegments = [
        ConfirmedSegment(text: "Hello", speaker: "A", speakerEmbedding: emb),
        ConfirmedSegment(text: "World", speaker: "A", speakerEmbedding: nil),  // no embedding
    ]
    vm.confirmedText = "A: Hello World"

    vm.reassignSpeakerForBlock(segmentIndex: 0, newSpeaker: "B")

    // Verify segments are updated
    XCTAssertEqual(vm.confirmedSegments[0].speaker, "B")
    XCTAssertEqual(vm.confirmedSegments[0].isUserCorrected, true)
    // Verify correction was called on the engine (via mock)
    // ... depends on mock structure
}
```

**Step 2: Run test to verify it fails**

Expected: FAIL — correction not called

**Step 3: Implement**

Modify `reassignSpeakerForBlock()` to call correction after setting user-corrected flags:

```swift
public func reassignSpeakerForBlock(segmentIndex: Int, newSpeaker: String) {
    guard segmentIndex < confirmedSegments.count else { return }
    let targetSpeaker = confirmedSegments[segmentIndex].speaker

    // Find consecutive block with same speaker
    var startIdx = segmentIndex
    while startIdx > 0 && confirmedSegments[startIdx - 1].speaker == targetSpeaker {
        startIdx -= 1
    }
    var endIdx = segmentIndex
    while endIdx < confirmedSegments.count - 1 && confirmedSegments[endIdx + 1].speaker == targetSpeaker {
        endIdx += 1
    }

    for i in startIdx...endIdx {
        let originalSpeaker = confirmedSegments[i].speaker
        // Correct the tracker's profiles if this segment has an embedding
        if let embedding = confirmedSegments[i].speakerEmbedding, let oldLabel = originalSpeaker {
            service.correctSpeakerAssignment(embedding: embedding, from: oldLabel, to: newSpeaker)
        }
        confirmedSegments[i].originalSpeaker = originalSpeaker
        confirmedSegments[i].speaker = newSpeaker
        confirmedSegments[i].speakerConfidence = 1.0
        confirmedSegments[i].isUserCorrected = true
    }

    regenerateText()
}
```

Similarly update `reassignSpeakerForSelection()` — in the 3 places where it sets `isUserCorrected = true`, add the correction call before:
```swift
if let embedding = confirmedSegments[idx].speakerEmbedding, let oldLabel = originalSpeaker {
    service.correctSpeakerAssignment(embedding: embedding, from: oldLabel, to: newSpeaker)
}
```

**Important:** `service` is `private var service: TranscriptionService`. We need to verify `TranscriptionService` has the `correctSpeakerAssignment` method from Task 6.

**Step 4: Run tests**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -30`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift Tests/
git commit -m "feat: wire speaker correction from VM to engine for real-time profile updates"
```

---

### Task 8: EmbeddingHistoryStore — Persistence layer

**Files:**
- Create: `Sources/QuickTranscriber/Models/EmbeddingHistoryStore.swift`
- Create: `Tests/QuickTranscriberTests/EmbeddingHistoryStoreTests.swift`

**Context:**
- Saves per-session embedding data to `~/QuickTranscriber/embedding_history.json`
- Stores `[EmbeddingHistoryEntry]` where each entry links to a speaker profile UUID
- Separate from `speakers.json` for backward compatibility
- `SpeakerProfileStore` pattern used as reference for file I/O

**Step 1: Write failing tests**

```swift
import XCTest
@testable import QuickTranscriberLib

final class EmbeddingHistoryStoreTests: XCTestCase {

    private func makeTempDirectory() -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmbeddingHistoryStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeEmbedding(dominant dim: Int, dimensions: Int = 256) -> [Float] {
        var v = [Float](repeating: 0.01, count: dimensions)
        v[dim] = 1.0
        return v
    }

    func testAppendAndLoad() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = EmbeddingHistoryStore(directory: dir)
        let entry = EmbeddingHistoryEntry(
            speakerProfileId: UUID(),
            label: "A",
            sessionDate: Date(),
            embeddings: [
                HistoricalEmbedding(embedding: makeEmbedding(dominant: 0), confirmed: true)
            ]
        )
        store.appendSession(entries: [entry])

        let store2 = EmbeddingHistoryStore(directory: dir)
        let loaded = try store2.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].label, "A")
        XCTAssertEqual(loaded[0].embeddings.count, 1)
        XCTAssertTrue(loaded[0].embeddings[0].confirmed)
    }

    func testMultipleSessionsAccumulate() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = EmbeddingHistoryStore(directory: dir)
        let id = UUID()

        store.appendSession(entries: [
            EmbeddingHistoryEntry(speakerProfileId: id, label: "A", sessionDate: Date(),
                                 embeddings: [HistoricalEmbedding(embedding: makeEmbedding(dominant: 0), confirmed: true)])
        ])
        store.appendSession(entries: [
            EmbeddingHistoryEntry(speakerProfileId: id, label: "A", sessionDate: Date(),
                                 embeddings: [HistoricalEmbedding(embedding: makeEmbedding(dominant: 1), confirmed: true)])
        ])

        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 2)
    }

    func testReconstructProfile() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = EmbeddingHistoryStore(directory: dir)
        let id = UUID()
        let emb1 = makeEmbedding(dominant: 0)
        let emb2 = makeEmbedding(dominant: 0)

        store.appendSession(entries: [
            EmbeddingHistoryEntry(speakerProfileId: id, label: "A", sessionDate: Date(),
                                 embeddings: [
                                    HistoricalEmbedding(embedding: emb1, confirmed: true),
                                    HistoricalEmbedding(embedding: emb2, confirmed: true),
                                 ])
        ])

        let reconstructed = try store.reconstructProfile(for: id)
        XCTAssertNotNil(reconstructed)
        // Should be average of emb1 and emb2
        let expected = zip(emb1, emb2).map { ($0 + $1) / 2 }
        for i in 0..<expected.count {
            XCTAssertEqual(reconstructed![i], expected[i], accuracy: 0.001)
        }
    }

    func testReconstructUnknownProfileReturnsNil() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = EmbeddingHistoryStore(directory: dir)
        let result = try store.reconstructProfile(for: UUID())
        XCTAssertNil(result)
    }

    func testLoadFromNonexistentFileReturnsEmpty() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = EmbeddingHistoryStore(directory: dir)
        let loaded = try store.loadAll()
        XCTAssertTrue(loaded.isEmpty)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter EmbeddingHistoryStoreTests 2>&1 | tail -20`
Expected: FAIL — types not defined

**Step 3: Implement**

Create `Sources/QuickTranscriber/Models/EmbeddingHistoryStore.swift`:

```swift
import Foundation

public struct HistoricalEmbedding: Codable, Equatable {
    public let embedding: [Float]
    public let confirmed: Bool

    public init(embedding: [Float], confirmed: Bool) {
        self.embedding = embedding
        self.confirmed = confirmed
    }
}

public struct EmbeddingHistoryEntry: Codable, Equatable {
    public let speakerProfileId: UUID
    public let label: String
    public let sessionDate: Date
    public let embeddings: [HistoricalEmbedding]

    public init(speakerProfileId: UUID, label: String, sessionDate: Date, embeddings: [HistoricalEmbedding]) {
        self.speakerProfileId = speakerProfileId
        self.label = label
        self.sessionDate = sessionDate
        self.embeddings = embeddings
    }
}

public final class EmbeddingHistoryStore {
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("QuickTranscriber")
        self.fileURL = dir.appendingPathComponent("embedding_history.json")
    }

    public func appendSession(entries: [EmbeddingHistoryEntry]) {
        var existing = (try? loadAll()) ?? []
        existing.append(contentsOf: entries)
        do {
            let dir = fileURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let data = try JSONEncoder().encode(existing)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[EmbeddingHistoryStore] Failed to save: \(error)")
        }
    }

    public func loadAll() throws -> [EmbeddingHistoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([EmbeddingHistoryEntry].self, from: data)
    }

    public func reconstructProfile(for profileId: UUID) throws -> [Float]? {
        let entries = try loadAll()
        let matching = entries.filter { $0.speakerProfileId == profileId }
        let confirmedEmbeddings = matching.flatMap { $0.embeddings }
            .filter { $0.confirmed }
            .map { $0.embedding }
        guard !confirmedEmbeddings.isEmpty else { return nil }

        let count = Float(confirmedEmbeddings.count)
        var avg = [Float](repeating: 0, count: confirmedEmbeddings[0].count)
        for emb in confirmedEmbeddings {
            for i in 0..<avg.count {
                avg[i] += emb[i]
            }
        }
        for i in 0..<avg.count {
            avg[i] /= count
        }
        return avg
    }
}
```

**Step 4: Run tests**

Run: `swift test --filter EmbeddingHistoryStoreTests 2>&1 | tail -20`
Expected: ALL PASS

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -30`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Models/EmbeddingHistoryStore.swift Tests/QuickTranscriberTests/EmbeddingHistoryStoreTests.swift
git commit -m "feat: add EmbeddingHistoryStore for per-session embedding persistence"
```

---

### Task 9: Export detailed profiles + save history at session end

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift`
- Modify: `Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift`
- Modify: `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift`
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift` (pass EmbeddingHistoryStore)
- Test: relevant test files

**Context:**
- `EmbeddingBasedSpeakerTracker.exportProfiles()` at line 154-156: returns `(label, embedding, hitCount)`
- Need `exportDetailedProfiles()` that also returns history
- `FluidAudioSpeakerDiarizer.exportSpeakerProfiles()` at line 137-139: wraps tracker export
- `ChunkedWhisperEngine.stopStreaming()` at line 100-143: calls diarizer.exportSpeakerProfiles(), filters corrected, merges to store
- `TranscriptionViewModel.init()` at line 45-87: creates SpeakerProfileStore

**Step 1: Write failing test**

```swift
// In EmbeddingBasedSpeakerTrackerTests
func testExportDetailedProfilesIncludesHistory() {
    let tracker = EmbeddingBasedSpeakerTracker()
    let emb1 = makeEmbedding(dominant: 0)
    let emb2 = makeEmbedding(dominant: 0)  // matches A
    _ = tracker.identify(embedding: emb1)
    _ = tracker.identify(embedding: emb2)

    let detailed = tracker.exportDetailedProfiles()
    XCTAssertEqual(detailed.count, 1)
    XCTAssertEqual(detailed[0].label, "A")
    XCTAssertEqual(detailed[0].embeddingHistory.count, 2)
    XCTAssertEqual(detailed[0].embeddingHistory[0], emb1)
    XCTAssertEqual(detailed[0].embeddingHistory[1], emb2)
}
```

**Step 2: Run test to verify it fails**

Expected: FAIL — `exportDetailedProfiles` not defined

**Step 3: Implement**

1. Add to `EmbeddingBasedSpeakerTracker`:
```swift
public func exportDetailedProfiles() -> [(label: String, embedding: [Float], hitCount: Int, embeddingHistory: [[Float]])] {
    profiles.map { ($0.label, $0.embedding, $0.hitCount, $0.embeddingHistory) }
}
```

2. Add to `SpeakerDiarizer` protocol:
```swift
func exportDetailedSpeakerProfiles() -> [(label: String, embedding: [Float], embeddingHistory: [[Float]])]
```

3. Add to `FluidAudioSpeakerDiarizer`:
```swift
public func exportDetailedSpeakerProfiles() -> [(label: String, embedding: [Float], embeddingHistory: [[Float]])] {
    speakerTracker.exportDetailedProfiles().map { ($0.label, $0.embedding, $0.embeddingHistory) }
}
```

4. Add `embeddingHistoryStore` to `ChunkedWhisperEngine`:
```swift
private let embeddingHistoryStore: EmbeddingHistoryStore?

public init(
    audioCaptureService: AudioCaptureService = AVAudioCaptureService(),
    transcriber: ChunkTranscriber = WhisperKitChunkTranscriber(),
    diarizer: SpeakerDiarizer? = nil,
    speakerProfileStore: SpeakerProfileStore? = nil,
    embeddingHistoryStore: EmbeddingHistoryStore? = nil
) {
    // ... existing ...
    self.embeddingHistoryStore = embeddingHistoryStore
}
```

5. Update `stopStreaming()` — after the existing merge logic, add history saving:
```swift
// After existing merge block in stopStreaming():
if let historyStore = embeddingHistoryStore, let diarizer {
    let detailed = diarizer.exportDetailedSpeakerProfiles()
    let entries = detailed.compactMap { profile -> EmbeddingHistoryEntry? in
        guard !profile.embeddingHistory.isEmpty else { return nil }
        // Match with stored profile to get UUID
        let storedProfile = speakerProfileStore?.profiles.first { $0.label == profile.label }
        let profileId = storedProfile?.id ?? UUID()
        return EmbeddingHistoryEntry(
            speakerProfileId: profileId,
            label: profile.label,
            sessionDate: Date(),
            embeddings: profile.embeddingHistory.map { emb in
                HistoricalEmbedding(embedding: emb, confirmed: true)
            }
        )
    }
    if !entries.isEmpty {
        historyStore.appendSession(entries: entries)
        NSLog("[ChunkedWhisperEngine] Saved \(entries.count) speaker histories")
    }
}
```

6. Update `TranscriptionViewModel.init()` to create and pass EmbeddingHistoryStore:
```swift
let historyStore = EmbeddingHistoryStore()

let resolvedEngine = engine ?? ChunkedWhisperEngine(
    diarizer: diarizer ?? FluidAudioSpeakerDiarizer(),
    speakerProfileStore: profileStore,
    embeddingHistoryStore: historyStore
)
```

**Step 4: Run tests**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -30`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift Tests/
git commit -m "feat: save per-session embedding history on session end"
```

---

### Task 10: Verification and cleanup

**Files:** All modified files

**Step 1: Run full test suite**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -40`
Expected: ALL PASS, no regressions

**Step 2: Build the app**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeds

**Step 3: Verify backward compatibility**

- `speakers.json` format is unchanged (no new fields added to StoredSpeakerProfile)
- `embedding_history.json` is new — no existing data to migrate
- `ConfirmedSegment` new field has default nil — all existing code unaffected
- `SpeakerIdentification` new field has default nil — all existing code unaffected

**Step 4: Commit any cleanup**

If any cleanup needed after running tests.

**Step 5: Final commit (if needed)**

```bash
git add -A
git commit -m "chore: Phase 3b cleanup and verification"
```
