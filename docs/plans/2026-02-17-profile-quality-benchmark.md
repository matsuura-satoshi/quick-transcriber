# Phase 2b: Profile Quality Benchmark Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Benchmark multiple profile maintenance strategies in EmbeddingBasedSpeakerTracker to find the best approach for reducing speaker over-detection.

**Architecture:** Add ProfileStrategy enum and hitCount tracking to EmbeddingBasedSpeakerTracker, pass strategy through FluidAudioSpeakerDiarizer, and add benchmark test cases for each strategy × dataset combination.

**Tech Stack:** Swift, XCTest, FluidAudio, existing diarization benchmark infrastructure

---

### Task 1: Add hitCount to SpeakerProfile and ProfileStrategy enum

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift:11-14`
- Test: `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift`

**Step 1: Write the failing test**

Add to `EmbeddingBasedSpeakerTrackerTests.swift` at the end, before the closing `}`:

```swift
// MARK: - Profile Strategy

func testProfileStrategyNoneIsDefault() {
    let tracker = EmbeddingBasedSpeakerTracker()
    // Default strategy should behave identically to current behavior
    XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 0)), "A")
    XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 1)), "B")
    XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 2)), "C")
}

func testHitCountIncrementsOnMatch() {
    let tracker = EmbeddingBasedSpeakerTracker()
    let emb = makeEmbedding(dominant: 0)
    _ = tracker.identify(embedding: emb)  // Register A
    _ = tracker.identify(embedding: emb)  // Match A
    _ = tracker.identify(embedding: emb)  // Match A

    let profiles = tracker.exportProfiles()
    XCTAssertEqual(profiles.count, 1)
    XCTAssertEqual(profiles[0].hitCount, 3)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter EmbeddingBasedSpeakerTrackerTests/testHitCountIncrementsOnMatch 2>&1 | tail -5`
Expected: FAIL — `exportProfiles()` doesn't return hitCount

**Step 3: Write minimal implementation**

In `EmbeddingBasedSpeakerTracker.swift`:

1. Add `ProfileStrategy` enum before the class:

```swift
public enum ProfileStrategy: Sendable {
    case none
    case culling(interval: Int, minHits: Int)
    case merging(interval: Int, threshold: Float)
    case registrationGate(minSeparation: Float)
    case combined(cullInterval: Int, minHits: Int, mergeThreshold: Float)
}
```

2. Add `hitCount` to `SpeakerProfile`:

```swift
public struct SpeakerProfile {
    public let label: String
    public var embedding: [Float]
    public var hitCount: Int
}
```

3. Add `strategy` and `identifyCount` properties:

```swift
private let strategy: ProfileStrategy
private var identifyCount: Int = 0
```

4. Update `init` to accept strategy:

```swift
public init(similarityThreshold: Float = 0.5, updateAlpha: Float = 0.3,
            expectedSpeakerCount: Int? = nil, strategy: ProfileStrategy = .none) {
    self.similarityThreshold = similarityThreshold
    self.updateAlpha = updateAlpha
    self.expectedSpeakerCount = expectedSpeakerCount
    self.strategy = strategy
}
```

5. Update `identify()` — add `hitCount` tracking in match branches (lines 47-53 and 57-63), and increment `identifyCount`:

```swift
public func identify(embedding: [Float]) -> String {
    identifyCount += 1

    var bestIndex = -1
    var bestSimilarity: Float = -1

    for (i, profile) in profiles.enumerated() {
        let sim = Self.cosineSimilarity(embedding, profile.embedding)
        if sim > bestSimilarity {
            bestSimilarity = sim
            bestIndex = i
        }
    }

    if bestIndex >= 0 && bestSimilarity >= similarityThreshold {
        profiles[bestIndex].hitCount += 1
        let alpha = updateAlpha
        profiles[bestIndex].embedding = zip(profiles[bestIndex].embedding, embedding).map { old, new in
            (1 - alpha) * old + alpha * new
        }
        return profiles[bestIndex].label
    }

    // At capacity: assign to most similar existing speaker
    if let limit = expectedSpeakerCount, profiles.count >= limit, bestIndex >= 0 {
        profiles[bestIndex].hitCount += 1
        let alpha = updateAlpha
        profiles[bestIndex].embedding = zip(profiles[bestIndex].embedding, embedding).map { old, new in
            (1 - alpha) * old + alpha * new
        }
        return profiles[bestIndex].label
    }

    // Register new speaker
    let label = String(UnicodeScalar(UInt8(65 + nextLabelIndex % 26)))
    profiles.append(SpeakerProfile(label: label, embedding: embedding, hitCount: 1))
    nextLabelIndex += 1
    return label
}
```

6. Update `exportProfiles()` to include hitCount:

```swift
public func exportProfiles() -> [(label: String, embedding: [Float], hitCount: Int)] {
    profiles.map { ($0.label, $0.embedding, $0.hitCount) }
}
```

7. Update `loadProfiles()` to accept hitCount:

```swift
public func loadProfiles(_ loadedProfiles: [(label: String, embedding: [Float])]) {
    profiles = loadedProfiles.map { SpeakerProfile(label: $0.label, embedding: $0.embedding, hitCount: 0) }
    nextLabelIndex = loadedProfiles.count
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter EmbeddingBasedSpeakerTrackerTests 2>&1 | tail -5`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift \
      Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift
git commit -m "feat: add ProfileStrategy enum and hitCount tracking"
```

---

### Task 2: Implement culling strategy

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift`
- Test: `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift`

**Step 1: Write the failing test**

```swift
func testCullingRemovesLowHitProfiles() {
    // interval=5: maintenance runs after every 5 identify() calls
    // minHits=2: profiles with hitCount < 2 are removed
    let tracker = EmbeddingBasedSpeakerTracker(strategy: .culling(interval: 5, minHits: 2))

    // Register A (hit 1), match A twice more (hits = 3)
    let embA = makeEmbedding(dominant: 0)
    _ = tracker.identify(embedding: embA)
    _ = tracker.identify(embedding: embA)
    _ = tracker.identify(embedding: embA)

    // Register B (hit 1) — low quality, only seen once
    _ = tracker.identify(embedding: makeEmbedding(dominant: 1))

    // 5th call triggers maintenance: B has hitCount=1 < minHits=2, should be culled
    _ = tracker.identify(embedding: embA) // A hit 4, triggers maintenance

    let profiles = tracker.exportProfiles()
    XCTAssertEqual(profiles.count, 1, "B should have been culled")
    XCTAssertEqual(profiles[0].label, "A")
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter EmbeddingBasedSpeakerTrackerTests/testCullingRemovesLowHitProfiles 2>&1 | tail -5`
Expected: FAIL — profiles.count == 2 (culling not implemented)

**Step 3: Write minimal implementation**

Add `maintainProfiles()` method to `EmbeddingBasedSpeakerTracker`, and call it at the end of `identify()`:

```swift
private func maintainProfiles() {
    switch strategy {
    case .none:
        break
    case .culling(let interval, let minHits):
        guard identifyCount % interval == 0 else { return }
        profiles.removeAll { $0.hitCount < minHits }
    case .merging, .registrationGate, .combined:
        break // Implemented in later tasks
    }
}
```

Add this call at the very end of `identify()`, before the return statements — actually, add it at the start, right after `identifyCount += 1`, so it runs before the current identification:

No — maintenance should run AFTER identification. Add it as follows: at the end of `identify()`, refactor to capture the result then call maintain:

Actually simplest: call `maintainProfiles()` at the beginning of `identify()`, after incrementing `identifyCount`. This way maintenance happens before the current identification, which is cleaner (you identify against already-cleaned profiles).

```swift
public func identify(embedding: [Float]) -> String {
    identifyCount += 1
    maintainProfiles()
    // ... rest of identify
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter EmbeddingBasedSpeakerTrackerTests 2>&1 | tail -5`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift \
      Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift
git commit -m "feat: implement culling strategy for profile maintenance"
```

---

### Task 3: Implement merging strategy

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift`
- Test: `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift`

**Step 1: Write the failing test**

```swift
func testMergingCombinesSimilarProfiles() {
    // Two profiles that are very similar should merge into one
    let tracker = EmbeddingBasedSpeakerTracker(
        similarityThreshold: 0.3,  // Low threshold so both register
        strategy: .merging(interval: 5, threshold: 0.7)
    )

    // Register A with dominant dim 0
    let embA = makeEmbedding(dominant: 0)
    _ = tracker.identify(embedding: embA)

    // Register B with slightly different embedding (still similar to A)
    var embSimilar = makeEmbedding(dominant: 0)
    embSimilar[1] = 0.3
    _ = tracker.identify(embedding: embSimilar)

    // Register C with completely different embedding
    _ = tracker.identify(embedding: makeEmbedding(dominant: 5))

    // Pad to reach interval=5
    _ = tracker.identify(embedding: embA)
    _ = tracker.identify(embedding: embA) // 5th call triggers merge

    let profiles = tracker.exportProfiles()
    // A and B should have been merged (similarity > 0.7), C remains
    XCTAssertEqual(profiles.count, 2, "Similar profiles A and B should have merged")
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter EmbeddingBasedSpeakerTrackerTests/testMergingCombinesSimilarProfiles 2>&1 | tail -5`
Expected: FAIL — profiles.count == 3

**Step 3: Write minimal implementation**

Add merging case to `maintainProfiles()`:

```swift
case .merging(let interval, let threshold):
    guard identifyCount % interval == 0 else { return }
    mergeProfiles(threshold: threshold)
```

Add `mergeProfiles()` method:

```swift
private func mergeProfiles(threshold: Float) {
    var i = 0
    while i < profiles.count {
        var j = i + 1
        while j < profiles.count {
            let sim = Self.cosineSimilarity(profiles[i].embedding, profiles[j].embedding)
            if sim >= threshold {
                // Merge j into i (keep higher hitCount as primary)
                let (keep, remove) = profiles[i].hitCount >= profiles[j].hitCount ? (i, j) : (j, i)
                let alpha = updateAlpha
                profiles[keep].embedding = zip(profiles[keep].embedding, profiles[remove].embedding).map { a, b in
                    (1 - alpha) * a + alpha * b
                }
                profiles[keep].hitCount += profiles[remove].hitCount
                profiles.remove(at: remove)
                if remove < keep { i = max(0, i - 1) }
                // Don't increment j — new element at j needs checking
            } else {
                j += 1
            }
        }
        i += 1
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter EmbeddingBasedSpeakerTrackerTests 2>&1 | tail -5`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift \
      Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift
git commit -m "feat: implement merging strategy for profile maintenance"
```

---

### Task 4: Implement registrationGate strategy

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift`
- Test: `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift`

**Step 1: Write the failing test**

```swift
func testRegistrationGateBlocksSimilarNewSpeaker() {
    // minSeparation=0.3: new speaker must have max similarity < 0.3 to all existing to register
    let tracker = EmbeddingBasedSpeakerTracker(
        similarityThreshold: 0.5,
        strategy: .registrationGate(minSeparation: 0.3)
    )

    // Register A
    _ = tracker.identify(embedding: makeEmbedding(dominant: 0))

    // This embedding is somewhat similar to A (similarity > 0.3 due to shared small values)
    // but below similarityThreshold (0.5), so without gate it would register as B
    var embSimilar = makeEmbedding(dominant: 0)
    embSimilar[1] = 0.5
    embSimilar[2] = 0.5
    let label = tracker.identify(embedding: embSimilar)

    // With gate: should assign to A instead of creating B
    XCTAssertEqual(label, "A", "Should be gated to existing speaker A")
    XCTAssertEqual(tracker.exportProfiles().count, 1)
}

func testRegistrationGateAllowsTrulyDifferentSpeaker() {
    let tracker = EmbeddingBasedSpeakerTracker(
        similarityThreshold: 0.5,
        strategy: .registrationGate(minSeparation: 0.3)
    )

    // Register A with dim 0
    _ = tracker.identify(embedding: makeEmbedding(dominant: 0))

    // Completely different embedding (orthogonal) — should pass the gate
    _ = tracker.identify(embedding: makeEmbedding(dominant: 100))

    XCTAssertEqual(tracker.exportProfiles().count, 2)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter EmbeddingBasedSpeakerTrackerTests/testRegistrationGateBlocksSimilarNewSpeaker 2>&1 | tail -5`
Expected: FAIL — label == "B"

**Step 3: Write minimal implementation**

The registrationGate modifies the registration logic in `identify()`, not `maintainProfiles()`. Add a check before "Register new speaker":

```swift
// Registration gate: only register if sufficiently different from all existing profiles
if case .registrationGate(let minSeparation) = strategy, bestIndex >= 0 {
    if bestSimilarity >= minSeparation {
        profiles[bestIndex].hitCount += 1
        let alpha = updateAlpha
        profiles[bestIndex].embedding = zip(profiles[bestIndex].embedding, embedding).map { old, new in
            (1 - alpha) * old + alpha * new
        }
        return profiles[bestIndex].label
    }
}

// Register new speaker
let label = String(UnicodeScalar(UInt8(65 + nextLabelIndex % 26)))
profiles.append(SpeakerProfile(label: label, embedding: embedding, hitCount: 1))
nextLabelIndex += 1
return label
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter EmbeddingBasedSpeakerTrackerTests 2>&1 | tail -5`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift \
      Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift
git commit -m "feat: implement registrationGate strategy"
```

---

### Task 5: Implement combined strategy

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift`
- Test: `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift`

**Step 1: Write the failing test**

```swift
func testCombinedStrategyCullsThenMerges() {
    let tracker = EmbeddingBasedSpeakerTracker(
        similarityThreshold: 0.3,
        strategy: .combined(cullInterval: 5, minHits: 2, mergeThreshold: 0.7)
    )

    // A: 3 hits
    let embA = makeEmbedding(dominant: 0)
    _ = tracker.identify(embedding: embA)
    _ = tracker.identify(embedding: embA)
    _ = tracker.identify(embedding: embA)

    // B: 1 hit (will be culled)
    _ = tracker.identify(embedding: makeEmbedding(dominant: 1))

    // 5th call triggers maintenance
    _ = tracker.identify(embedding: embA)

    let profiles = tracker.exportProfiles()
    XCTAssertEqual(profiles.count, 1, "B should have been culled")
    XCTAssertEqual(profiles[0].label, "A")
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter EmbeddingBasedSpeakerTrackerTests/testCombinedStrategyCullsThenMerges 2>&1 | tail -5`
Expected: FAIL

**Step 3: Write minimal implementation**

Add combined case to `maintainProfiles()`:

```swift
case .combined(let cullInterval, let minHits, let mergeThreshold):
    guard identifyCount % cullInterval == 0 else { return }
    profiles.removeAll { $0.hitCount < minHits }
    mergeProfiles(threshold: mergeThreshold)
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter EmbeddingBasedSpeakerTrackerTests 2>&1 | tail -5`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift \
      Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift
git commit -m "feat: implement combined (culling + merging) strategy"
```

---

### Task 6: Add profileStrategy to FluidAudioSpeakerDiarizer

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift:45-62`

**Step 1: No test needed** — FluidAudioSpeakerDiarizer delegates to EmbeddingBasedSpeakerTracker, which is already tested. This is a passthrough parameter.

**Step 2: Add strategy parameter to FluidAudioSpeakerDiarizer.init**

```swift
public init(
    similarityThreshold: Float = 0.5,
    updateAlpha: Float = 0.3,
    windowDuration: TimeInterval = 15.0,
    diarizationChunkDuration: TimeInterval = 7.0,
    expectedSpeakerCount: Int? = nil,
    profileStrategy: ProfileStrategy = .none
) {
    self.windowDuration = windowDuration
    self.speakerTracker = EmbeddingBasedSpeakerTracker(
        similarityThreshold: similarityThreshold,
        updateAlpha: updateAlpha,
        expectedSpeakerCount: expectedSpeakerCount,
        strategy: profileStrategy
    )
    self.pacer = DiarizationPacer(
        diarizationChunkDuration: diarizationChunkDuration,
        sampleRate: 16000
    )
}
```

**Step 3: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift
git commit -m "feat: pass profileStrategy through FluidAudioSpeakerDiarizer"
```

---

### Task 7: Add profileStrategy to runDiarizationBenchmark

**Files:**
- Modify: `Tests/QuickTranscriberBenchmarks/DiarizationBenchmarkTests.swift:100-110`

**Step 1: Add parameter to runDiarizationBenchmark()**

Add `profileStrategy: ProfileStrategy = .none` parameter and pass to diarizer:

```swift
func runDiarizationBenchmark(
    dataset: String,
    maxConversations: Int = 50,
    chunkDuration: Double = 3.0,
    similarityThreshold: Float = 0.5,
    updateAlpha: Float = 0.3,
    windowDuration: TimeInterval = 30.0,
    diarizationChunkDuration: Double? = nil,
    expectedSpeakerCount: Int? = nil,
    profileStrategy: ProfileStrategy = .none,
    label: String = "default"
) async throws -> DiarizationBenchmarkResult {
```

Update the `FluidAudioSpeakerDiarizer` creation (line 137-143) to pass profileStrategy:

```swift
let diarizer = FluidAudioSpeakerDiarizer(
    similarityThreshold: similarityThreshold,
    updateAlpha: updateAlpha,
    windowDuration: windowDuration,
    diarizationChunkDuration: effectiveDiarizationChunkDuration,
    expectedSpeakerCount: effectiveExpectedCount,
    profileStrategy: profileStrategy
)
```

**Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Tests/QuickTranscriberBenchmarks/DiarizationBenchmarkTests.swift
git commit -m "feat: add profileStrategy parameter to benchmark infrastructure"
```

---

### Task 8: Add ProfileStrategyBenchmarkTests

**Files:**
- Create: `Tests/QuickTranscriberBenchmarks/ProfileStrategyBenchmarkTests.swift`

**Step 1: Create benchmark test class**

All tests use app default parameters: chunk 5s, accum 7s, window 15s.
CALLHOME uses expectedSpeakerCount=2. AMI uses expectedSpeakerCount=-1 (ground truth).

```swift
import XCTest
@testable import QuickTranscriberLib

final class ProfileStrategyBenchmarkTests: DiarizationBenchmarkTestBase {

    override var outputPath: String { "/tmp/quicktranscriber_profile_strategy_results.json" }

    // Common parameters matching app defaults
    private let chunk: Double = 5.0
    private let window: TimeInterval = 15.0
    private let accum: Double = 7.0

    // MARK: - Baseline (no strategy)

    func testBaseline_callhome_en() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            label: "baseline_en"
        )
    }

    func testBaseline_callhome_ja() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            label: "baseline_ja"
        )
    }

    func testBaseline_ami() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "ami", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: -1,
            label: "baseline_ami"
        )
    }

    // MARK: - Culling (interval=10, minHits=2)

    func testCull10_2_callhome_en() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .culling(interval: 10, minHits: 2),
            label: "cull_10_2_en"
        )
    }

    func testCull10_2_callhome_ja() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .culling(interval: 10, minHits: 2),
            label: "cull_10_2_ja"
        )
    }

    func testCull10_2_ami() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "ami", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: -1,
            profileStrategy: .culling(interval: 10, minHits: 2),
            label: "cull_10_2_ami"
        )
    }

    // MARK: - Culling (interval=5, minHits=1)

    func testCull5_1_callhome_en() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .culling(interval: 5, minHits: 1),
            label: "cull_5_1_en"
        )
    }

    func testCull5_1_callhome_ja() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .culling(interval: 5, minHits: 1),
            label: "cull_5_1_ja"
        )
    }

    func testCull5_1_ami() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "ami", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: -1,
            profileStrategy: .culling(interval: 5, minHits: 1),
            label: "cull_5_1_ami"
        )
    }

    // MARK: - Merging (interval=10, threshold=0.6)

    func testMerge10_06_callhome_en() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .merging(interval: 10, threshold: 0.6),
            label: "merge_10_06_en"
        )
    }

    func testMerge10_06_callhome_ja() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .merging(interval: 10, threshold: 0.6),
            label: "merge_10_06_ja"
        )
    }

    func testMerge10_06_ami() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "ami", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: -1,
            profileStrategy: .merging(interval: 10, threshold: 0.6),
            label: "merge_10_06_ami"
        )
    }

    // MARK: - Merging (interval=10, threshold=0.7)

    func testMerge10_07_callhome_en() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .merging(interval: 10, threshold: 0.7),
            label: "merge_10_07_en"
        )
    }

    func testMerge10_07_callhome_ja() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .merging(interval: 10, threshold: 0.7),
            label: "merge_10_07_ja"
        )
    }

    func testMerge10_07_ami() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "ami", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: -1,
            profileStrategy: .merging(interval: 10, threshold: 0.7),
            label: "merge_10_07_ami"
        )
    }

    // MARK: - Registration Gate (minSeparation=0.3)

    func testGate03_callhome_en() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .registrationGate(minSeparation: 0.3),
            label: "gate_03_en"
        )
    }

    func testGate03_callhome_ja() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .registrationGate(minSeparation: 0.3),
            label: "gate_03_ja"
        )
    }

    func testGate03_ami() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "ami", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: -1,
            profileStrategy: .registrationGate(minSeparation: 0.3),
            label: "gate_03_ami"
        )
    }

    // MARK: - Registration Gate (minSeparation=0.4)

    func testGate04_callhome_en() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .registrationGate(minSeparation: 0.4),
            label: "gate_04_en"
        )
    }

    func testGate04_callhome_ja() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .registrationGate(minSeparation: 0.4),
            label: "gate_04_ja"
        )
    }

    func testGate04_ami() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "ami", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: -1,
            profileStrategy: .registrationGate(minSeparation: 0.4),
            label: "gate_04_ami"
        )
    }

    // MARK: - Combined (cull 10/2 + merge 0.6)

    func testCombined_callhome_en() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .combined(cullInterval: 10, minHits: 2, mergeThreshold: 0.6),
            label: "combined_en"
        )
    }

    func testCombined_callhome_ja() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .combined(cullInterval: 10, minHits: 2, mergeThreshold: 0.6),
            label: "combined_ja"
        )
    }

    func testCombined_ami() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "ami", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: -1,
            profileStrategy: .combined(cullInterval: 10, minHits: 2, mergeThreshold: 0.6),
            label: "combined_ami"
        )
    }
}
```

**Step 2: Verify build**

Run: `swift build --build-tests 2>&1 | tail -5`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Tests/QuickTranscriberBenchmarks/ProfileStrategyBenchmarkTests.swift
git commit -m "feat: add ProfileStrategyBenchmarkTests (8 strategies × 3 datasets)"
```

---

### Task 9: Run benchmarks and collect results

**Step 1: Clear previous results**

```bash
rm -f /tmp/quicktranscriber_profile_strategy_results.json
```

**Step 2: Run all profile strategy benchmarks**

```bash
swift test --filter ProfileStrategyBenchmarkTests 2>&1 | tee /tmp/profile_strategy_benchmark_log.txt
```

This takes approximately 30-60 minutes (24 test cases, each processing 5 conversations with FluidAudio diarization).

**Step 3: Review results**

```bash
cat /tmp/quicktranscriber_profile_strategy_results.json | python3 -m json.tool
```

Compare strategies by:
- `speakerCountAccuracy` (primary — higher is better)
- `averageChunkAccuracy` (must not regress below 0.70)
- `averageLabelFlips` (lower is better)
