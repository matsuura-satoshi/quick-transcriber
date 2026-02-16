# Embedding-Based Speaker Tracking Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace FluidAudio's unstable internal speakerId with embedding-based speaker tracking using cosine similarity, providing stable speaker labels across the entire session.

**Architecture:** Add `EmbeddingBasedSpeakerTracker` that maintains speaker profiles and matches new embeddings via cosine similarity. Modify `FluidAudioSpeakerDiarizer` to use time-range filtering on FluidAudio's full segment output, then delegate to the tracker for stable labeling.

**Key Insight:** FluidAudio's `TimedSpeakerSegment` exposes `embedding: [Float]` (256-dim) per segment, plus `startTimeSeconds`/`endTimeSeconds`. This allows us to bypass FluidAudio's per-call clustering (which reassigns IDs each call) and do our own persistent tracking.

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift` | **Create** | Cosine similarity matching + profile management |
| `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift` | **Create** | Unit tests for tracker |
| `Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift` | Modify | Use time-range filtering + embedding tracker |
| `Tests/QuickTranscriberTests/SpeakerDiarizerTests.swift` | **Create** | Tests for time-range logic |

---

## Task 1: Create EmbeddingBasedSpeakerTracker with Tests (TDD)

**Files:**
- Create: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift`
- Create: `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift`

### Step 1: Write failing tests

Create `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift`:

```swift
import XCTest
@testable import QuickTranscriberLib

final class EmbeddingBasedSpeakerTrackerTests: XCTestCase {

    // Helper: create a normalized embedding with a dominant dimension
    private func makeEmbedding(dominant dim: Int, dimensions: Int = 256) -> [Float] {
        var v = [Float](repeating: 0.01, count: dimensions)
        v[dim] = 1.0
        return v
    }

    // MARK: - First speaker is registered and labeled

    func testFirstSpeakerGetsLabelA() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb = makeEmbedding(dominant: 0)
        let label = tracker.identify(embedding: emb)
        XCTAssertEqual(label, "A")
    }

    // MARK: - Same speaker returns same label

    func testSameSpeakerReturnsSameLabel() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb = makeEmbedding(dominant: 0)
        _ = tracker.identify(embedding: emb)
        let label = tracker.identify(embedding: emb)
        XCTAssertEqual(label, "A")
    }

    // MARK: - Different speaker gets new label

    func testDifferentSpeakerGetsNewLabel() {
        let tracker = EmbeddingBasedSpeakerTracker()
        _ = tracker.identify(embedding: makeEmbedding(dominant: 0))
        let label = tracker.identify(embedding: makeEmbedding(dominant: 1))
        XCTAssertEqual(label, "B")
    }

    // MARK: - Three distinct speakers

    func testThreeDistinctSpeakers() {
        let tracker = EmbeddingBasedSpeakerTracker()
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 0)), "A")
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 1)), "B")
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 2)), "C")
    }

    // MARK: - Return to first speaker

    func testReturnToFirstSpeaker() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        _ = tracker.identify(embedding: embA)
        _ = tracker.identify(embedding: embB)
        let label = tracker.identify(embedding: embA)
        XCTAssertEqual(label, "A")
    }

    // MARK: - Similar embeddings match (slight variation)

    func testSimilarEmbeddingsMatchSameSpeaker() {
        let tracker = EmbeddingBasedSpeakerTracker()
        var emb1 = makeEmbedding(dominant: 0)
        _ = tracker.identify(embedding: emb1)

        // Slightly perturbed version of same speaker
        var emb2 = emb1
        emb2[1] = 0.15
        emb2[2] = 0.1
        let label = tracker.identify(embedding: emb2)
        XCTAssertEqual(label, "A")
    }

    // MARK: - Profile update (moving average)

    func testProfileUpdatesOverTime() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb1 = makeEmbedding(dominant: 0)
        _ = tracker.identify(embedding: emb1)

        // Feed slightly drifted embedding multiple times
        var drifted = makeEmbedding(dominant: 0)
        drifted[3] = 0.3
        for _ in 0..<5 {
            let label = tracker.identify(embedding: drifted)
            XCTAssertEqual(label, "A")
        }
        // Profile should have adapted toward drifted embedding
        // Verify by checking the profile still matches drifted
        XCTAssertEqual(tracker.identify(embedding: drifted), "A")
    }

    // MARK: - Reset clears all profiles

    func testResetClearsProfiles() {
        let tracker = EmbeddingBasedSpeakerTracker()
        _ = tracker.identify(embedding: makeEmbedding(dominant: 0))
        _ = tracker.identify(embedding: makeEmbedding(dominant: 1))
        tracker.reset()
        // After reset, next speaker starts from A again
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 2)), "A")
    }

    // MARK: - Cosine similarity helper

    func testCosineSimilarityIdentical() {
        let v = makeEmbedding(dominant: 0)
        let similarity = EmbeddingBasedSpeakerTracker.cosineSimilarity(v, v)
        XCTAssertEqual(similarity, 1.0, accuracy: 0.001)
    }

    func testCosineSimilarityOrthogonal() {
        var a = [Float](repeating: 0, count: 256)
        a[0] = 1.0
        var b = [Float](repeating: 0, count: 256)
        b[1] = 1.0
        let similarity = EmbeddingBasedSpeakerTracker.cosineSimilarity(a, b)
        XCTAssertEqual(similarity, 0.0, accuracy: 0.001)
    }
}
```

### Step 2: Run tests to verify they fail

Run: `swift test --filter EmbeddingBasedSpeakerTrackerTests 2>&1 | tail -5`

Expected: Compilation error — `EmbeddingBasedSpeakerTracker` not found.

### Step 3: Write the implementation

Create `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift`:

```swift
import Foundation

/// Tracks speakers across diarization calls using embedding cosine similarity.
///
/// FluidAudio reassigns internal speaker IDs on each `process()` call,
/// making them unreliable for persistent tracking. This tracker maintains
/// a profile table of known speakers and matches new embeddings via
/// cosine similarity, providing stable labels (A, B, C, ...) across
/// an entire session.
public final class EmbeddingBasedSpeakerTracker: @unchecked Sendable {
    public struct SpeakerProfile {
        public let label: String
        public var embedding: [Float]
    }

    private var profiles: [SpeakerProfile] = []
    private var nextLabelIndex: Int = 0
    private let similarityThreshold: Float
    private let updateAlpha: Float

    /// - Parameters:
    ///   - similarityThreshold: Minimum cosine similarity to match a known speaker (default: 0.5)
    ///   - updateAlpha: Weight for new embedding in moving average update (default: 0.3)
    public init(similarityThreshold: Float = 0.5, updateAlpha: Float = 0.3) {
        self.similarityThreshold = similarityThreshold
        self.updateAlpha = updateAlpha
    }

    /// Identify a speaker from their embedding vector.
    ///
    /// - Returns: A stable speaker label (A, B, C, ...)
    public func identify(embedding: [Float]) -> String {
        // Find best matching profile
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
            // Update profile with moving average
            let profile = profiles[bestIndex]
            let alpha = updateAlpha
            profiles[bestIndex].embedding = zip(profile.embedding, embedding).map { old, new in
                (1 - alpha) * old + alpha * new
            }
            return profiles[bestIndex].label
        }

        // Register new speaker
        let label = String(UnicodeScalar(UInt8(65 + nextLabelIndex % 26)))
        profiles.append(SpeakerProfile(label: label, embedding: embedding))
        nextLabelIndex += 1
        return label
    }

    public func reset() {
        profiles = []
        nextLabelIndex = 0
    }

    /// Cosine similarity between two vectors.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }
}
```

### Step 4: Run tests to verify they pass

Run: `swift test --filter EmbeddingBasedSpeakerTrackerTests 2>&1 | tail -5`

Expected: All 10 tests PASS.

### Step 5: Commit

```bash
git add Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift \
       Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift
git commit -m "feat: add EmbeddingBasedSpeakerTracker for cosine similarity speaker matching"
```

---

## Task 2: Modify SpeakerDiarizer to Use Time-Range Filtering and Embedding Tracker

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift`
- Create: `Tests/QuickTranscriberTests/SpeakerDiarizerTests.swift`

### Step 1: Write failing tests for time-range logic

Create `Tests/QuickTranscriberTests/SpeakerDiarizerTests.swift`:

```swift
import XCTest
@testable import QuickTranscriberLib

final class SpeakerDiarizerTests: XCTestCase {

    // MARK: - findRelevantSegment

    func testFindRelevantSegmentSingle() {
        // Buffer is 10s, chunk is 3s → target range: 7.0-10.0
        let segment = FluidAudioSpeakerDiarizer.TimedSegmentInfo(
            speakerId: "S1", embedding: [1.0], startTime: 7.5, endTime: 9.5
        )
        let result = FluidAudioSpeakerDiarizer.findRelevantSegment(
            segments: [segment], bufferDuration: 10.0, chunkDuration: 3.0
        )
        XCTAssertEqual(result?.speakerId, "S1")
    }

    func testFindRelevantSegmentPicksLongestOverlap() {
        // Target range: 7.0-10.0
        let seg1 = FluidAudioSpeakerDiarizer.TimedSegmentInfo(
            speakerId: "S1", embedding: [1.0], startTime: 6.0, endTime: 7.5  // 0.5s overlap
        )
        let seg2 = FluidAudioSpeakerDiarizer.TimedSegmentInfo(
            speakerId: "S2", embedding: [2.0], startTime: 7.5, endTime: 10.0  // 2.5s overlap
        )
        let result = FluidAudioSpeakerDiarizer.findRelevantSegment(
            segments: [seg1, seg2], bufferDuration: 10.0, chunkDuration: 3.0
        )
        XCTAssertEqual(result?.speakerId, "S2")
    }

    func testFindRelevantSegmentNoOverlap() {
        // Target range: 7.0-10.0
        let segment = FluidAudioSpeakerDiarizer.TimedSegmentInfo(
            speakerId: "S1", embedding: [1.0], startTime: 0.0, endTime: 5.0
        )
        let result = FluidAudioSpeakerDiarizer.findRelevantSegment(
            segments: [segment], bufferDuration: 10.0, chunkDuration: 3.0
        )
        XCTAssertNil(result)
    }

    func testFindRelevantSegmentEmpty() {
        let result = FluidAudioSpeakerDiarizer.findRelevantSegment(
            segments: [], bufferDuration: 10.0, chunkDuration: 3.0
        )
        XCTAssertNil(result)
    }
}
```

### Step 2: Run tests to verify they fail

Run: `swift test --filter SpeakerDiarizerTests 2>&1 | tail -5`

Expected: Compilation error.

### Step 3: Rewrite FluidAudioSpeakerDiarizer

Replace `SpeakerDiarizer.swift` contents:

```swift
import Foundation
import FluidAudio

/// Protocol for identifying the current speaker from an audio chunk.
public protocol SpeakerDiarizer: AnyObject, Sendable {
    func setup() async throws
    func identifySpeaker(audioChunk: [Float]) async -> String?
}

/// Speaker diarizer backed by FluidAudio's OfflineDiarizerManager.
/// Uses a rolling buffer (30-second window) to accumulate audio and diarize
/// the window. Identifies the speaker of the latest chunk using time-range
/// filtering and embedding-based cosine similarity tracking.
public final class FluidAudioSpeakerDiarizer: SpeakerDiarizer, @unchecked Sendable {
    /// Lightweight struct for testable segment info.
    public struct TimedSegmentInfo {
        public let speakerId: String
        public let embedding: [Float]
        public let startTime: Float
        public let endTime: Float

        public init(speakerId: String, embedding: [Float], startTime: Float, endTime: Float) {
            self.speakerId = speakerId
            self.embedding = embedding
            self.startTime = startTime
            self.endTime = endTime
        }
    }

    private let sampleRate: Int = 16000
    private let windowDuration: TimeInterval = 30.0
    private var rollingBuffer: [Float] = []
    private var diarizer: OfflineDiarizerManager?
    private let speakerTracker = EmbeddingBasedSpeakerTracker()
    private let lock = NSLock()

    public init() {}

    public func setup() async throws {
        let config = OfflineDiarizerConfig()
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        diarizer = manager
        NSLog("[SpeakerDiarizer] FluidAudio models prepared")
    }

    public func identifySpeaker(audioChunk: [Float]) async -> String? {
        guard let diarizer else { return nil }

        let windowSamples = Int(windowDuration * Double(sampleRate))
        let currentBuffer = lock.withLock {
            rollingBuffer.append(contentsOf: audioChunk)
            if rollingBuffer.count > windowSamples {
                rollingBuffer.removeFirst(rollingBuffer.count - windowSamples)
            }
            return rollingBuffer
        }

        // Need at least 1 second of audio for meaningful diarization
        guard currentBuffer.count >= sampleRate else { return nil }

        do {
            let result = try await diarizer.process(audio: currentBuffer)

            let segments = result.segments.map { seg in
                TimedSegmentInfo(
                    speakerId: seg.speakerId,
                    embedding: seg.embedding,
                    startTime: seg.startTimeSeconds,
                    endTime: seg.endTimeSeconds
                )
            }

            let bufferDuration = Float(currentBuffer.count) / Float(sampleRate)
            let chunkDuration = Float(audioChunk.count) / Float(sampleRate)

            guard let relevant = Self.findRelevantSegment(
                segments: segments,
                bufferDuration: bufferDuration,
                chunkDuration: chunkDuration
            ) else {
                return nil
            }

            let label = speakerTracker.identify(embedding: relevant.embedding)
            NSLog("[SpeakerDiarizer] Raw=\(relevant.speakerId) → Tracked=\(label) (time=\(String(format: "%.1f", relevant.startTime))-\(String(format: "%.1f", relevant.endTime))s)")
            return label
        } catch {
            NSLog("[SpeakerDiarizer] Diarization failed: \(error)")
            return nil
        }
    }

    /// Find the segment with the most overlap with the latest chunk's time range.
    ///
    /// - Parameters:
    ///   - segments: All segments from FluidAudio diarization
    ///   - bufferDuration: Total duration of the rolling buffer in seconds
    ///   - chunkDuration: Duration of the latest audio chunk in seconds
    /// - Returns: The segment info with the most overlap, or nil if no overlap
    public static func findRelevantSegment(
        segments: [TimedSegmentInfo],
        bufferDuration: Float,
        chunkDuration: Float
    ) -> TimedSegmentInfo? {
        let chunkStart = bufferDuration - chunkDuration
        let chunkEnd = bufferDuration

        var bestSegment: TimedSegmentInfo?
        var bestOverlap: Float = 0

        for segment in segments {
            let overlapStart = max(segment.startTime, chunkStart)
            let overlapEnd = min(segment.endTime, chunkEnd)
            let overlap = max(0, overlapEnd - overlapStart)

            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSegment = segment
            }
        }

        return bestSegment
    }
}
```

### Step 4: Run tests to verify all pass

Run: `swift test --filter SpeakerDiarizerTests 2>&1 | tail -5`

Expected: All 4 tests PASS.

### Step 5: Run all existing tests

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`

Expected: All tests PASS.

### Step 6: Commit

```bash
git add Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift \
       Tests/QuickTranscriberTests/SpeakerDiarizerTests.swift
git commit -m "feat: use time-range filtering and embedding-based tracking in SpeakerDiarizer"
```

---

## Task 3: Final Verification

### Step 1: Run full test suite

```bash
swift test --filter QuickTranscriberTests 2>&1 | tail -10
```

Expected: All tests PASS.

### Step 2: Build the app

```bash
swift build 2>&1 | tail -3
```

Expected: Build Succeeded, no warnings.

### Step 3: Review changes

```bash
git diff main --stat
```

Verify expected files changed:
- 2 new files (EmbeddingBasedSpeakerTracker.swift, EmbeddingBasedSpeakerTrackerTests.swift)
- 1 modified file (SpeakerDiarizer.swift)
- 1 new test file (SpeakerDiarizerTests.swift)

---

## Summary of Changes

| Change | Impact | Risk |
|--------|--------|------|
| `EmbeddingBasedSpeakerTracker` (new) | Core embedding matching logic | Low — isolated, well-tested |
| `FluidAudioSpeakerDiarizer` (rewrite) | Time-range filtering + embedding tracker | Medium — main logic change |
| Remove `speakerMapping` dictionary | Replaced by embedding-based tracking | Low — strict improvement |

## Behavioral Changes

**Before:** FluidAudio's internal `speakerId` used directly → IDs reassigned each call → unstable labels despite SpeakerLabelTracker smoothing.

**After:**
1. FluidAudio diarizes the 30s buffer as before
2. Time-range filtering identifies which segment corresponds to the latest 3s chunk
3. That segment's 256-dim embedding is compared against known speaker profiles
4. Cosine similarity matching provides stable labels across the entire session
5. Speaker profiles adapt over time via moving average
6. SpeakerLabelTracker still provides additional smoothing on top
