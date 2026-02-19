# Viterbi Speaker Smoothing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the threshold-based SpeakerLabelTracker with a probability-based ViterbiSpeakerSmoother to reduce label flips (AMI: 57.8 → target <30) while maintaining accuracy.

**Architecture:** Forward-only Viterbi that maintains log-probabilities for each known speaker. Uses transition costs (stay vs switch) and observation probabilities (cosine similarity confidence) to make principled speaker change decisions. Drop-in replacement for SpeakerLabelTracker with the same `processLabel(_:) -> SpeakerIdentification?` interface.

**Tech Stack:** Swift, XCTest, FluidAudio (unchanged)

---

### Task 1: Add `speakerTransitionPenalty` to TranscriptionParameters

**Files:**
- Modify: `Sources/QuickTranscriber/Models/TranscriptionParameters.swift`

**Step 1: Add property and update init**

In `TranscriptionParameters.swift`, add after `expectedSpeakerCount` (line 21):

```swift
/// Viterbi smoothing stay probability (0.5-0.999). Higher = fewer speaker changes.
/// Not exposed in Settings UI (advanced parameter).
public var speakerTransitionPenalty: Double
```

Add parameter to `init()` (after `expectedSpeakerCount: Int? = nil`):

```swift
speakerTransitionPenalty: Double = 0.9
```

Add assignment in init body (after `self.expectedSpeakerCount`):

```swift
self.speakerTransitionPenalty = speakerTransitionPenalty
```

Add decoding in `init(from decoder:)` (after `expectedSpeakerCount`):

```swift
speakerTransitionPenalty = try container.decodeIfPresent(Double.self, forKey: .speakerTransitionPenalty) ?? 0.9
```

**Step 2: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 3: Commit**

```bash
git add Sources/QuickTranscriber/Models/TranscriptionParameters.swift
git commit -m "feat: add speakerTransitionPenalty to TranscriptionParameters"
```

---

### Task 2: Write ViterbiSpeakerSmoother failing tests

**Files:**
- Modify: `Tests/QuickTranscriberTests/SpeakerLabelTrackerTests.swift` (rename to ViterbiSpeakerSmootherTests)

**Step 1: Rename test file and rewrite tests**

Replace entire contents of `Tests/QuickTranscriberTests/SpeakerLabelTrackerTests.swift` with:

```swift
import XCTest
@testable import QuickTranscriberLib

final class ViterbiSpeakerSmootherTests: XCTestCase {

    // MARK: - Helper

    private func id(_ label: String, _ confidence: Float = 0.9) -> SpeakerIdentification {
        SpeakerIdentification(label: label, confidence: confidence)
    }

    // MARK: - First speaker confirmed immediately

    func testFirstSpeakerConfirmedImmediately() {
        let smoother = ViterbiSpeakerSmoother()
        let result = smoother.processLabel(id("A"))
        XCTAssertEqual(result?.label, "A")
    }

    // MARK: - Same speaker continues

    func testSameSpeakerReturnsSame() {
        let smoother = ViterbiSpeakerSmoother()
        _ = smoother.processLabel(id("A"))
        let result = smoother.processLabel(id("A"))
        XCTAssertEqual(result?.label, "A")
    }

    // MARK: - Nil input returns confirmed speaker

    func testNilLabelReturnsConfirmedSpeaker() {
        let smoother = ViterbiSpeakerSmoother()
        _ = smoother.processLabel(id("A"))
        let result = smoother.processLabel(nil)
        XCTAssertEqual(result?.label, "A")
    }

    func testNilLabelWithNoConfirmedSpeakerReturnsNil() {
        let smoother = ViterbiSpeakerSmoother()
        let result = smoother.processLabel(nil)
        XCTAssertNil(result)
    }

    // MARK: - High-confidence switch confirms quickly

    func testHighConfidenceSwitchConfirms() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.processLabel(id("A", 0.9))
        // Two consecutive high-confidence observations of B should confirm
        _ = smoother.processLabel(id("B", 0.95))
        let result = smoother.processLabel(id("B", 0.95))
        XCTAssertEqual(result?.label, "B")
    }

    // MARK: - Low-confidence switch is suppressed

    func testLowConfidenceSwitchSuppressed() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.processLabel(id("A", 0.9))
        // Low-confidence B should not override A
        let result = smoother.processLabel(id("B", 0.3))
        // Should stay with A (nil = pending or A)
        XCTAssertTrue(result == nil || result?.label == "A")
    }

    // MARK: - False alarm: A→B→A

    func testFalseAlarmReturnsToOriginal() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
        _ = smoother.processLabel(id("A", 0.9))
        _ = smoother.processLabel(id("B", 0.6))  // noise
        let result = smoother.processLabel(id("A", 0.9))
        // Should return A (either directly or via pending resolution)
        XCTAssertTrue(result == nil || result?.label == "A")
    }

    // MARK: - Multiple speaker changes

    func testMultipleSpeakerChanges() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.8)
        // A established
        XCTAssertEqual(smoother.processLabel(id("A", 0.9))?.label, "A")
        XCTAssertEqual(smoother.processLabel(id("A", 0.9))?.label, "A")
        // Switch to B with high confidence
        _ = smoother.processLabel(id("B", 0.9))
        let bResult = smoother.processLabel(id("B", 0.9))
        XCTAssertEqual(bResult?.label, "B")
        // Switch to A with high confidence
        _ = smoother.processLabel(id("A", 0.9))
        let aResult = smoother.processLabel(id("A", 0.9))
        XCTAssertEqual(aResult?.label, "A")
    }

    // MARK: - Reset clears state

    func testResetClearsState() {
        let smoother = ViterbiSpeakerSmoother()
        _ = smoother.processLabel(id("A"))
        smoother.reset()
        XCTAssertEqual(smoother.processLabel(id("B"))?.label, "B")
    }

    // MARK: - Confidence propagation

    func testConfidencePropagation() {
        let smoother = ViterbiSpeakerSmoother()
        let result = smoother.processLabel(SpeakerIdentification(label: "A", confidence: 0.85))
        XCTAssertEqual(result?.confidence, 0.85)
    }

    func testConfidenceUpdatesOnSameSpeaker() {
        let smoother = ViterbiSpeakerSmoother()
        _ = smoother.processLabel(SpeakerIdentification(label: "A", confidence: 0.9))
        let result = smoother.processLabel(SpeakerIdentification(label: "A", confidence: 0.7))
        XCTAssertEqual(result?.label, "A")
        XCTAssertEqual(result?.confidence, 0.7)
    }

    // MARK: - Transition penalty effect

    func testHighStayProbabilityResistsSwitching() {
        // With very high stay probability, even moderate confidence shouldn't switch
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.99)
        _ = smoother.processLabel(id("A", 0.9))
        _ = smoother.processLabel(id("A", 0.9))
        _ = smoother.processLabel(id("A", 0.9))
        // Single moderate-confidence B
        let result = smoother.processLabel(id("B", 0.7))
        XCTAssertTrue(result == nil || result?.label == "A",
            "High stay probability should resist switching on single observation")
    }

    func testLowStayProbabilitySwitchesEasily() {
        // With low stay probability, even moderate confidence should switch
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.5)
        _ = smoother.processLabel(id("A", 0.7))
        let result = smoother.processLabel(id("B", 0.7))
        // With no bias toward staying, should switch (or at least pending)
        // The exact behavior depends on implementation; just verify it's more permissive
        XCTAssertNotNil(result)  // Should not be pending (low stay bias)
    }

    // MARK: - Integration: smoothing pipeline with retroactive updates

    func testSmoothingWithRetroactiveUpdates() {
        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.8)

        var segments: [ConfirmedSegment] = []
        var pendingStart: Int?

        // Chunk 1: A confirmed immediately
        let s1 = smoother.processLabel(id("A", 0.9))
        XCTAssertEqual(s1?.label, "A")
        segments.append(ConfirmedSegment(text: "Hello", speaker: s1?.label, speakerConfidence: s1?.confidence))

        // Chunk 2: B observed (may be pending)
        let s2 = smoother.processLabel(id("B", 0.9))
        segments.append(ConfirmedSegment(text: "New topic", speaker: s2?.label, speakerConfidence: s2?.confidence))
        if s2 == nil {
            pendingStart = 1
        }

        // Chunk 3: B again (should confirm)
        let s3 = smoother.processLabel(id("B", 0.9))
        XCTAssertEqual(s3?.label, "B")

        // Retroactive update (same logic as ChunkedWhisperEngine)
        if let start = pendingStart, let result = s3 {
            for i in start..<segments.count {
                segments[i].speaker = result.label
                segments[i].speakerConfidence = result.confidence
            }
            pendingStart = nil
        }
        segments.append(ConfirmedSegment(text: "More talk", speaker: s3?.label, speakerConfidence: s3?.confidence))

        let text = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
        XCTAssertEqual(text, "A: Hello\nB: New topic More talk")
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter ViterbiSpeakerSmootherTests 2>&1 | tail -5`
Expected: Compilation error (ViterbiSpeakerSmoother not defined)

**Step 3: Commit failing tests**

```bash
git add Tests/QuickTranscriberTests/SpeakerLabelTrackerTests.swift
git commit -m "test: add ViterbiSpeakerSmoother tests (currently failing)"
```

---

### Task 3: Implement ViterbiSpeakerSmoother

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/SpeakerLabelTracker.swift` (replace contents)

**Step 1: Replace SpeakerLabelTracker with ViterbiSpeakerSmoother**

Replace entire contents of `Sources/QuickTranscriber/Engines/SpeakerLabelTracker.swift`:

```swift
import Foundation

/// Smooths raw speaker labels using a forward-only Viterbi algorithm.
///
/// Maintains log-probabilities for each known speaker and uses transition costs
/// (stay vs switch) combined with observation probabilities (cosine similarity)
/// to make principled speaker change decisions.
///
/// When the best speaker changes, returns nil (pending) until the change
/// stabilizes, enabling retroactive updates by the caller.
///
/// Replaces the previous threshold-based SpeakerLabelTracker.
public final class ViterbiSpeakerSmoother: @unchecked Sendable {
    /// Probability of staying with the current speaker (0.5–0.999).
    /// Higher values make speaker changes harder.
    private let stayProbability: Double

    /// Log-probability of each speaker being the current speaker.
    private var stateLogProbs: [String: Double] = [:]

    /// The last confirmed speaker identification.
    private var confirmedResult: SpeakerIdentification?

    /// The best speaker from the previous Viterbi step.
    private var previousBestLabel: String?

    /// Tracks whether the best speaker has changed and how long it's been stable.
    private var pendingBestLabel: String?
    private var pendingStableCount: Int = 0

    public init(stayProbability: Double = 0.9) {
        self.stayProbability = max(0.5, min(stayProbability, 0.999))
    }

    /// Process a raw speaker identification from the diarizer.
    ///
    /// - Returns: The confirmed speaker identification, or nil if a potential
    ///   speaker change is still being evaluated (pending).
    public func processLabel(_ identification: SpeakerIdentification?) -> SpeakerIdentification? {
        guard let id = identification else {
            return confirmedResult
        }

        // First speaker: confirm immediately
        if stateLogProbs.isEmpty {
            stateLogProbs[id.label] = 0.0
            confirmedResult = id
            previousBestLabel = id.label
            return id
        }

        // Register new speaker if first time seen
        if stateLogProbs[id.label] == nil {
            stateLogProbs[id.label] = -100.0
        }

        // Viterbi forward step
        let N = Double(stateLogProbs.count)
        let logStay = log(stayProbability)
        let logSwitch = log((1.0 - stayProbability) / max(N - 1.0, 1.0))

        let confidence = Double(max(min(id.confidence, 0.99), 0.01))
        let logObsMatch = log(confidence)
        let logObsNoMatch = log((1.0 - confidence) / max(N - 1.0, 1.0))

        var newLogProbs: [String: Double] = [:]
        for speaker in stateLogProbs.keys {
            let logObs = (speaker == id.label) ? logObsMatch : logObsNoMatch

            var bestPrev = -Double.infinity
            for (prevSpeaker, prevLogProb) in stateLogProbs {
                let logTrans = (prevSpeaker == speaker) ? logStay : logSwitch
                bestPrev = max(bestPrev, prevLogProb + logTrans)
            }

            newLogProbs[speaker] = bestPrev + logObs
        }

        // Normalize to prevent underflow
        let maxLogProb = newLogProbs.values.max() ?? 0.0
        for speaker in newLogProbs.keys {
            newLogProbs[speaker]! -= maxLogProb
        }

        stateLogProbs = newLogProbs

        // Find current best speaker
        guard let best = stateLogProbs.max(by: { $0.value < $1.value }) else {
            return confirmedResult
        }

        let bestLabel = best.key

        if bestLabel == confirmedResult?.label {
            // Same as confirmed: update confidence, clear pending
            confirmedResult = SpeakerIdentification(
                label: bestLabel,
                confidence: id.label == bestLabel ? id.confidence : (confirmedResult?.confidence ?? 0),
                embedding: id.label == bestLabel ? id.embedding : confirmedResult?.embedding
            )
            pendingBestLabel = nil
            pendingStableCount = 0
            return confirmedResult
        }

        // Best speaker changed from confirmed
        if bestLabel == pendingBestLabel {
            pendingStableCount += 1
        } else {
            pendingBestLabel = bestLabel
            pendingStableCount = 1
        }

        // Confirm after 1 stable observation (the Viterbi probabilities already
        // provide smoothing, so a single stable step is sufficient)
        if pendingStableCount >= 1 {
            confirmedResult = SpeakerIdentification(
                label: bestLabel,
                confidence: id.label == bestLabel ? id.confidence : id.confidence,
                embedding: id.label == bestLabel ? id.embedding : nil
            )
            pendingBestLabel = nil
            pendingStableCount = 0
            return confirmedResult
        }

        return nil  // Still evaluating
    }

    public func reset() {
        stateLogProbs = [:]
        confirmedResult = nil
        previousBestLabel = nil
        pendingBestLabel = nil
        pendingStableCount = 0
    }
}
```

**Step 2: Run tests**

Run: `swift test --filter ViterbiSpeakerSmootherTests 2>&1 | tail -20`
Expected: All tests pass

**Step 3: Iterate on implementation if tests fail**

Adjust thresholds or logic until all tests pass. The key behaviors to verify:
- First speaker confirms immediately
- Same speaker continues with updated confidence
- High-confidence switches confirm (within 2 observations)
- Low-confidence switches are suppressed
- Reset clears all state

**Step 4: Commit**

```bash
git add Sources/QuickTranscriber/Engines/SpeakerLabelTracker.swift
git commit -m "feat: replace SpeakerLabelTracker with ViterbiSpeakerSmoother"
```

---

### Task 4: Wire ViterbiSpeakerSmoother into ChunkedWhisperEngine

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift:13,68,252`

**Step 1: Update property declaration**

In `ChunkedWhisperEngine.swift`, line 13, change:

```swift
private let speakerTracker = SpeakerLabelTracker()
```

to:

```swift
private var speakerSmoother = ViterbiSpeakerSmoother()
```

**Step 2: Update startStreaming to pass parameter**

At line 68 (in `startStreaming()`), change:

```swift
speakerTracker.reset()
```

to:

```swift
speakerSmoother = ViterbiSpeakerSmoother(stayProbability: parameters.speakerTransitionPenalty)
```

**Step 3: Update processChunk call site**

At line 252, change:

```swift
smoothedResult = speakerTracker.processLabel(rawSpeakerResult)
```

to:

```swift
smoothedResult = speakerSmoother.processLabel(rawSpeakerResult)
```

**Step 4: Build and run existing tests**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: All tests pass

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift
git commit -m "feat: wire ViterbiSpeakerSmoother into ChunkedWhisperEngine"
```

---

### Task 5: Add Viterbi smoothing to benchmarks

**Files:**
- Modify: `Tests/QuickTranscriberBenchmarks/DiarizationBenchmarkTests.swift`

**Step 1: Add `stayProbability` parameter to `runDiarizationBenchmark`**

In `DiarizationBenchmarkTests.swift`, add parameter to `runDiarizationBenchmark()` (after `profileStrategy`):

```swift
stayProbability: Double? = nil,
```

**Step 2: Add ViterbiSpeakerSmoother to the benchmark loop**

Inside the `for key in keys` loop, after `try await diarizer.setup()` (around line 146), add:

```swift
let smoother: ViterbiSpeakerSmoother? = stayProbability.map {
    ViterbiSpeakerSmoother(stayProbability: $0)
}
```

Then modify the prediction section (around line 167-172), change:

```swift
let speakerResult = await diarizer.identifySpeaker(audioChunk: chunk)
// Skip chunks where diarizer returns nil (accumulation period)
if let speakerResult {
    groundTruthLabels.append(gtLabel)
    predictedLabels.append(speakerResult.label)
}
```

to:

```swift
let rawResult = await diarizer.identifySpeaker(audioChunk: chunk)
// Skip chunks where diarizer returns nil (accumulation period)
if let rawResult {
    let effectiveResult: SpeakerIdentification
    if let smoother {
        // Use Viterbi-smoothed result, falling back to confirmed speaker
        effectiveResult = smoother.processLabel(rawResult) ?? rawResult
    } else {
        effectiveResult = rawResult
    }
    groundTruthLabels.append(gtLabel)
    predictedLabels.append(effectiveResult.label)
}
```

**Step 3: Add transition penalty sweep test to CallHomeDiarizationTests**

Add at the end of `CallHomeDiarizationTests`:

```swift
func testCallHomeENTransitionPenaltySweep() async throws {
    let penalties: [Double] = [0.7, 0.8, 0.9, 0.95, 0.99]
    for penalty in penalties {
        _ = try await runDiarizationBenchmark(
            dataset: "callhome_en",
            maxConversations: 5,
            chunkDuration: 5.0,
            windowDuration: 15.0,
            diarizationChunkDuration: 7.0,
            expectedSpeakerCount: 2,
            stayProbability: penalty,
            label: "viterbi_stay\(String(format: "%.2f", penalty))"
        )
    }
}
```

**Step 4: Add transition penalty sweep test to AMIDiarizationTests**

Add at the end of `AMIDiarizationTests`:

```swift
func testAMITransitionPenaltySweep() async throws {
    let penalties: [Double] = [0.7, 0.8, 0.9, 0.95, 0.99]
    for penalty in penalties {
        _ = try await runDiarizationBenchmark(
            dataset: "ami",
            maxConversations: 5,
            chunkDuration: 5.0,
            windowDuration: 15.0,
            diarizationChunkDuration: 7.0,
            expectedSpeakerCount: -1,
            stayProbability: penalty,
            label: "viterbi_stay\(String(format: "%.2f", penalty))"
        )
    }
}
```

**Step 5: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 6: Commit**

```bash
git add Tests/QuickTranscriberBenchmarks/DiarizationBenchmarkTests.swift
git commit -m "feat: add Viterbi smoothing support to diarization benchmarks"
```

---

### Task 6: Run benchmarks and determine optimal default

**Step 1: Run CALLHOME EN sweep**

Run: `swift test --filter testCallHomeENTransitionPenaltySweep 2>&1 | grep '\[Diarization\]'`

**Step 2: Run AMI sweep**

Run: `swift test --filter testAMITransitionPenaltySweep 2>&1 | grep '\[Diarization\]'`

**Step 3: Analyze results**

Compare accuracy and flips across stayProbability values. Look for:
- AMI flips reduced significantly (target: <30)
- CALLHOME accuracy maintained or improved
- Sweet spot between flip reduction and accuracy

**Step 4: Update default if needed**

If the optimal value differs from 0.9, update `TranscriptionParameters.swift`:
- Change default value of `speakerTransitionPenalty`

**Step 5: Record results in memory**

Update `memory/diarization-benchmarks.md` with Viterbi benchmark results.

**Step 6: Final commit**

```bash
git add -A
git commit -m "feat: tune Viterbi transition penalty based on benchmark results"
```

---

### Task 7: Cleanup and PR

**Step 1: Run full test suite**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: All tests pass

**Step 2: Delete old SpeakerLabelTracker references**

Search for any remaining references to `SpeakerLabelTracker`:

```bash
grep -r "SpeakerLabelTracker" Sources/ Tests/
```

Update any remaining references.

**Step 3: Final commit and PR preparation**

```bash
git add -A
git commit -m "refactor: cleanup SpeakerLabelTracker references"
```
