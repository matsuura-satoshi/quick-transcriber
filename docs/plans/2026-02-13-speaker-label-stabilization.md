# Speaker Label Stabilization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Stabilize speaker diarization labels by adding temporal smoothing with delayed confirmation, and extending the audio buffer from 10s to 30s.

**Architecture:** Add a `SpeakerLabelTracker` layer between FluidAudio's raw diarization output and segment creation. The tracker requires N consecutive identical labels before confirming a speaker change. During evaluation, segments are created with `speaker: nil`; upon confirmation, pending segments are retroactively updated. The existing rewrite infrastructure in TranscriptionTextView and TranscriptFileWriter handles retroactive text changes automatically (both already have full-rewrite fallback paths when `hasPrefix` check fails).

**Tech Stack:** Swift, WhisperKit, FluidAudio (pyannote community-1 via CoreML)

**Background Research:** See conversation from 2026-02-13 session. Key finding: the diart library (Python) established the standard pattern for streaming speaker diarization — incremental clustering with temporal smoothing. Our approach implements the smoothing concept without requiring FluidAudio to expose speaker embeddings directly.

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `Sources/QuickTranscriber/Engines/SpeakerLabelTracker.swift` | **Create** | New smoothing layer |
| `Tests/QuickTranscriberTests/SpeakerLabelTrackerTests.swift` | **Create** | Tests for tracker |
| `Sources/QuickTranscriber/Engines/TranscriptionUtils.swift:6` | Modify | `let speaker` → `var speaker` |
| `Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift:15` | Modify | `windowDuration` 10→30 |
| `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift` | Modify | Integrate tracker |
| `Tests/QuickTranscriberTests/TranscriptionUtilsTests.swift` | Modify | Add retroactive update tests |

---

## Task 1: Create SpeakerLabelTracker with Tests (TDD)

**Files:**
- Create: `Sources/QuickTranscriber/Engines/SpeakerLabelTracker.swift`
- Create: `Tests/QuickTranscriberTests/SpeakerLabelTrackerTests.swift`

### Step 1: Write the failing tests

Create `Tests/QuickTranscriberTests/SpeakerLabelTrackerTests.swift`:

```swift
import XCTest
@testable import QuickTranscriberLib

final class SpeakerLabelTrackerTests: XCTestCase {

    // MARK: - First speaker is confirmed immediately

    func testFirstSpeakerConfirmedImmediately() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        let result = tracker.processLabel("A")
        XCTAssertEqual(result, "A")
    }

    // MARK: - Same speaker continues

    func testSameSpeakerReturnsSame() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        _ = tracker.processLabel("A")  // confirm A
        let result = tracker.processLabel("A")
        XCTAssertEqual(result, "A")
    }

    // MARK: - Single different label returns nil (pending)

    func testSingleDifferentLabelReturnsPending() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        _ = tracker.processLabel("A")  // confirm A
        let result = tracker.processLabel("B")  // only 1 B, need 2
        XCTAssertNil(result)
    }

    // MARK: - Threshold reached confirms new speaker

    func testThresholdReachedConfirmsNewSpeaker() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        _ = tracker.processLabel("A")  // confirm A
        _ = tracker.processLabel("B")  // pending (1/2)
        let result = tracker.processLabel("B")  // confirmed (2/2)
        XCTAssertEqual(result, "B")
    }

    // MARK: - False alarm: different then back to original

    func testFalseAlarmReturnsToOriginal() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        _ = tracker.processLabel("A")     // confirm A
        _ = tracker.processLabel("B")     // pending
        let result = tracker.processLabel("A")  // back to A
        XCTAssertEqual(result, "A")
    }

    // MARK: - Nil label returns current confirmed speaker

    func testNilLabelReturnsConfirmedSpeaker() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        _ = tracker.processLabel("A")  // confirm A
        let result = tracker.processLabel(nil)
        XCTAssertEqual(result, "A")
    }

    func testNilLabelWithNoConfirmedSpeakerReturnsNil() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        let result = tracker.processLabel(nil)
        XCTAssertNil(result)
    }

    // MARK: - Multiple speaker changes

    func testMultipleSpeakerChanges() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        XCTAssertEqual(tracker.processLabel("A"), "A")   // confirm A
        XCTAssertNil(tracker.processLabel("B"))           // pending
        XCTAssertEqual(tracker.processLabel("B"), "B")    // confirm B
        XCTAssertNil(tracker.processLabel("A"))           // pending
        XCTAssertEqual(tracker.processLabel("A"), "A")    // confirm A
    }

    // MARK: - Threshold of 3

    func testHigherThreshold() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 3)
        XCTAssertEqual(tracker.processLabel("A"), "A")
        XCTAssertNil(tracker.processLabel("B"))   // 1/3
        XCTAssertNil(tracker.processLabel("B"))   // 2/3
        XCTAssertEqual(tracker.processLabel("B"), "B")  // 3/3 confirmed
    }

    // MARK: - Interrupted pending resets count

    func testInterruptedPendingResetsCount() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 3)
        XCTAssertEqual(tracker.processLabel("A"), "A")
        XCTAssertNil(tracker.processLabel("B"))   // 1/3
        XCTAssertNil(tracker.processLabel("C"))   // C resets B count, 1/3 for C
        XCTAssertNil(tracker.processLabel("C"))   // 2/3 for C
        XCTAssertEqual(tracker.processLabel("C"), "C")  // 3/3 confirmed
    }

    // MARK: - Reset clears state

    func testResetClearsState() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
        _ = tracker.processLabel("A")
        tracker.reset()
        // After reset, next label is "first speaker" again
        XCTAssertEqual(tracker.processLabel("B"), "B")
    }

    // MARK: - Threshold of 1 (immediate change)

    func testThresholdOneConfirmsImmediately() {
        let tracker = SpeakerLabelTracker(confirmationThreshold: 1)
        XCTAssertEqual(tracker.processLabel("A"), "A")
        XCTAssertEqual(tracker.processLabel("B"), "B")  // immediate change
    }
}
```

### Step 2: Run tests to verify they fail

Run: `swift test --filter SpeakerLabelTrackerTests 2>&1 | tail -5`

Expected: Compilation error — `SpeakerLabelTracker` not found.

### Step 3: Write the implementation

Create `Sources/QuickTranscriber/Engines/SpeakerLabelTracker.swift`:

```swift
import Foundation

/// Smooths raw speaker labels from the diarizer by requiring N consecutive
/// identical labels before confirming a speaker change.
///
/// During the evaluation period, returns nil so that segments can be created
/// without speaker labels. When confirmed, the caller retroactively updates
/// pending segments.
///
/// Based on the temporal smoothing pattern from diart (Coria et al., 2021).
public final class SpeakerLabelTracker: @unchecked Sendable {
    private let confirmationThreshold: Int
    private var confirmedSpeaker: String?
    private var pendingLabel: String?
    private var pendingCount: Int = 0

    public init(confirmationThreshold: Int = 2) {
        self.confirmationThreshold = max(1, confirmationThreshold)
    }

    /// Process a raw speaker label from the diarizer.
    ///
    /// - Returns: The confirmed speaker label, or nil if a potential speaker
    ///   change is still being evaluated (pending).
    public func processLabel(_ rawLabel: String?) -> String? {
        guard let label = rawLabel else {
            return confirmedSpeaker
        }

        // First speaker: confirm immediately
        if confirmedSpeaker == nil {
            confirmedSpeaker = label
            pendingLabel = nil
            pendingCount = 0
            return label
        }

        // Same as confirmed: reset pending state
        if label == confirmedSpeaker {
            pendingLabel = nil
            pendingCount = 0
            return label
        }

        // Different from confirmed: evaluate
        if label == pendingLabel {
            pendingCount += 1
        } else {
            pendingLabel = label
            pendingCount = 1
        }

        if pendingCount >= confirmationThreshold {
            confirmedSpeaker = label
            pendingLabel = nil
            pendingCount = 0
            return label
        }

        return nil  // Still evaluating
    }

    public func reset() {
        confirmedSpeaker = nil
        pendingLabel = nil
        pendingCount = 0
    }
}
```

### Step 4: Run tests to verify they pass

Run: `swift test --filter SpeakerLabelTrackerTests 2>&1 | tail -5`

Expected: All 11 tests PASS.

### Step 5: Commit

```bash
git add Sources/QuickTranscriber/Engines/SpeakerLabelTracker.swift \
       Tests/QuickTranscriberTests/SpeakerLabelTrackerTests.swift
git commit -m "feat: add SpeakerLabelTracker for temporal smoothing of speaker labels"
```

---

## Task 2: Make ConfirmedSegment.speaker Mutable

**Why:** Retroactive speaker label updates require mutating `speaker` on existing segments in the `confirmedSegments` array. Currently `speaker` is `let`.

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/TranscriptionUtils.swift:6`

### Step 1: Write the failing test

Add to `Tests/QuickTranscriberTests/TranscriptionUtilsTests.swift`:

```swift
func testRetroactiveSpeakerUpdate() {
    // Simulate: segments created without speaker, then retroactively updated
    var segments = [
        ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: "A"),
        ConfirmedSegment(text: "new speaker", precedingSilence: 0.5, speaker: nil),  // pending
        ConfirmedSegment(text: "still talking", precedingSilence: 0.3, speaker: nil), // pending
    ]

    // Before update: pending segments have no label
    let beforeUpdate = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
    XCTAssertEqual(beforeUpdate, "A: Hello new speaker still talking")

    // Retroactive update: confirm speaker B
    for i in 1..<segments.count {
        segments[i].speaker = "B"
    }

    let afterUpdate = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
    XCTAssertEqual(afterUpdate, "A: Hello\nB: new speaker still talking")
}
```

### Step 2: Run test to verify it fails

Run: `swift test --filter TranscriptionUtilsTests/testRetroactiveSpeakerUpdate 2>&1 | tail -5`

Expected: Compilation error — `segments[i].speaker = "B"` fails because `speaker` is `let`.

### Step 3: Change `let` to `var`

In `Sources/QuickTranscriber/Engines/TranscriptionUtils.swift`, line 6:

```swift
// Before:
public let speaker: String?

// After:
public var speaker: String?
```

### Step 4: Run tests to verify all pass

Run: `swift test --filter TranscriptionUtilsTests 2>&1 | tail -5`

Expected: All tests PASS (including the new retroactive update test).

### Step 5: Commit

```bash
git add Sources/QuickTranscriber/Engines/TranscriptionUtils.swift \
       Tests/QuickTranscriberTests/TranscriptionUtilsTests.swift
git commit -m "refactor: make ConfirmedSegment.speaker mutable for retroactive updates"
```

---

## Task 3: Extend Rolling Buffer from 10s to 30s

**Why:** Research shows 10s is at the lower end for stable speaker identification. 15-30s provides substantially better context for FluidAudio's internal VBx clustering. Processing time for 30s audio is ~0.25s (RTFx 122x), well within the 3s chunk cycle.

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift:15`

### Step 1: Change the buffer duration

In `Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift`, line 15:

```swift
// Before:
private let windowDuration: TimeInterval = 10.0

// After:
private let windowDuration: TimeInterval = 30.0
```

Also update the doc comment on line 11-12:

```swift
// Before:
/// Uses a rolling buffer (10-second window) to accumulate audio and diarize

// After:
/// Uses a rolling buffer (30-second window) to accumulate audio and diarize
```

### Step 2: Verify build

Run: `swift build 2>&1 | tail -3`

Expected: Build Succeeded.

### Step 3: Run all existing tests

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`

Expected: All tests PASS.

### Step 4: Commit

```bash
git add Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift
git commit -m "feat: extend diarizer rolling buffer from 10s to 30s for stability"
```

---

## Task 4: Integrate SpeakerLabelTracker into ChunkedWhisperEngine

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift`

### Step 1: Add tracker and pending tracking properties

After line 10 (`private var confirmedSegments: [ConfirmedSegment] = []`), add:

```swift
private let speakerTracker = SpeakerLabelTracker()
private var pendingSegmentStartIndex: Int?
```

### Step 2: Replace speaker label handling in processChunk

Replace lines 169-185 (the segment creation loop and speaker assignment) with the new logic.

The full replacement for lines 136-199 in `processChunk()`:

```swift
        do {
            // Run transcription and diarization in parallel when diarizer is available
            let segments: [TranscribedSegment]
            let rawSpeakerLabel: String?
            if let diarizer, currentParameters.enableSpeakerDiarization {
                async let transcription = transcriber.transcribe(
                    audioArray: chunk,
                    language: currentLanguage,
                    parameters: currentParameters
                )
                async let speakerId = diarizer.identifySpeaker(audioChunk: chunk)
                segments = try await transcription
                rawSpeakerLabel = await speakerId
            } else {
                segments = try await transcriber.transcribe(
                    audioArray: chunk,
                    language: currentLanguage,
                    parameters: currentParameters
                )
                rawSpeakerLabel = nil
            }
            let filtered = segments.filter { segment in
                if TranscriptionUtils.shouldFilterByMetadata(segment) {
                    NSLog("[ChunkedWhisperEngine] Filtered (metadata): \(segment.text) [noSpeech=\(String(format: "%.2f", segment.noSpeechProb)), logprob=\(String(format: "%.2f", segment.avgLogprob))]")
                    return false
                }
                if TranscriptionUtils.shouldFilterSegment(segment.text, language: currentLanguage) {
                    NSLog("[ChunkedWhisperEngine] Filtered (text): \(segment.text)")
                    return false
                }
                return true
            }

            // Speaker label smoothing: require consecutive confirmation before accepting change
            let smoothedSpeaker: String?
            if currentParameters.enableSpeakerDiarization {
                smoothedSpeaker = speakerTracker.processLabel(rawSpeakerLabel)

                // Retroactively update pending segments when speaker is confirmed
                if let speaker = smoothedSpeaker, let startIdx = pendingSegmentStartIndex {
                    for i in startIdx..<confirmedSegments.count {
                        confirmedSegments[i].speaker = speaker
                    }
                    pendingSegmentStartIndex = nil
                    NSLog("[ChunkedWhisperEngine] Retroactively assigned speaker \(speaker) to \(confirmedSegments.count - startIdx) pending segments")
                }
            } else {
                smoothedSpeaker = nil
            }

            for (index, segment) in filtered.enumerated() {
                let precedingSilence: TimeInterval
                if index == 0 {
                    precedingSilence = silenceSinceLastSegment
                } else {
                    precedingSilence = 0
                }
                confirmedSegments.append(ConfirmedSegment(
                    text: segment.text,
                    precedingSilence: precedingSilence,
                    speaker: smoothedSpeaker
                ))
                NSLog("[ChunkedWhisperEngine] Confirmed: \(segment.text) (precedingSilence=\(String(format: "%.1f", precedingSilence))s, speaker=\(smoothedSpeaker ?? "pending"))")
            }

            // Track where pending segments start
            if currentParameters.enableSpeakerDiarization && smoothedSpeaker == nil
                && pendingSegmentStartIndex == nil && !filtered.isEmpty {
                pendingSegmentStartIndex = confirmedSegments.count - filtered.count
            }

            // Reset silence tracker: start with trailing silence from this chunk
            silenceSinceLastSegment = chunkResult.trailingSilenceDuration

            let confirmedText = TranscriptionUtils.joinSegments(
                confirmedSegments,
                language: currentLanguage,
                silenceThreshold: currentParameters.silenceLineBreakThreshold
            )
            onStateChange(TranscriptionState(
                confirmedText: confirmedText,
                unconfirmedText: "",
                isRecording: true
            ))
        } catch {
            NSLog("[ChunkedWhisperEngine] Chunk transcription failed: \(error). Continuing...")
        }
```

**Key differences from original:**
- `speakerLabel` renamed to `rawSpeakerLabel` for clarity
- New `smoothedSpeaker` computed via `speakerTracker.processLabel()`
- Retroactive update block before segment creation
- `pendingSegmentStartIndex` tracking after segment creation
- Log messages reflect "pending" state

### Step 3: Reset tracker state on startTranscription

In `startTranscription()` method, where `confirmedSegments` is cleared, also reset the tracker:

Find the line where `confirmedSegments = []` (or `.removeAll()`) and add:

```swift
confirmedSegments = []
speakerTracker.reset()
pendingSegmentStartIndex = nil
```

### Step 4: Verify build

Run: `swift build 2>&1 | tail -3`

Expected: Build Succeeded.

### Step 5: Run all tests

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`

Expected: All tests PASS.

### Step 6: Commit

```bash
git add Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift
git commit -m "feat: integrate SpeakerLabelTracker for delayed speaker confirmation"
```

---

## Task 5: Integration Test with MockSpeakerDiarizer

**Files:**
- Modify: `Tests/QuickTranscriberTests/ChunkedWhisperEngineTests.swift` (or appropriate test file)

### Step 1: Write integration test

This test verifies the full pipeline: mock diarizer returns unstable labels → tracker smooths them → segments get correct retroactive updates.

Add to the appropriate test file (where `MockSpeakerDiarizer` and `MockChunkTranscriber` are used):

```swift
func testSpeakerLabelSmoothing() async throws {
    // Setup: diarizer returns A, B, B (simulating a real speaker change)
    let mockDiarizer = MockSpeakerDiarizer()
    mockDiarizer.speakerResults = ["A", "B", "B"]

    let tracker = SpeakerLabelTracker(confirmationThreshold: 2)

    // Simulate the engine's logic
    var segments: [ConfirmedSegment] = []
    var pendingStart: Int?

    // Chunk 1: diarizer says "A" (first speaker, confirmed immediately)
    let speaker1 = tracker.processLabel(mockDiarizer.speakerResults[0])
    XCTAssertEqual(speaker1, "A")
    segments.append(ConfirmedSegment(text: "Hello", speaker: speaker1))

    // Chunk 2: diarizer says "B" (pending, not yet confirmed)
    let speaker2 = tracker.processLabel(mockDiarizer.speakerResults[1])
    XCTAssertNil(speaker2)
    segments.append(ConfirmedSegment(text: "New topic", speaker: speaker2))
    pendingStart = 1

    // At this point, joinSegments should show text without speaker change
    let textDuringPending = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
    XCTAssertEqual(textDuringPending, "A: Hello New topic")

    // Chunk 3: diarizer says "B" again (now confirmed!)
    let speaker3 = tracker.processLabel(mockDiarizer.speakerResults[2])
    XCTAssertEqual(speaker3, "B")

    // Retroactive update
    if let start = pendingStart {
        for i in start..<segments.count {
            segments[i].speaker = speaker3
        }
        pendingStart = nil
    }
    segments.append(ConfirmedSegment(text: "More talk", speaker: speaker3))

    // After retroactive update, output should show speaker change
    let textAfterConfirm = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
    XCTAssertEqual(textAfterConfirm, "A: Hello\nB: New topic More talk")
}

func testSpeakerLabelFalseAlarm() async throws {
    let tracker = SpeakerLabelTracker(confirmationThreshold: 2)

    var segments: [ConfirmedSegment] = []
    var pendingStart: Int?

    // Chunk 1: A confirmed
    segments.append(ConfirmedSegment(text: "Hello", speaker: tracker.processLabel("A")))

    // Chunk 2: B pending
    let s2 = tracker.processLabel("B")
    XCTAssertNil(s2)
    segments.append(ConfirmedSegment(text: "glitch", speaker: s2))
    pendingStart = 1

    // Chunk 3: Back to A (false alarm)
    let s3 = tracker.processLabel("A")
    XCTAssertEqual(s3, "A")

    // Retroactive update: pending segments get A (not B)
    if let start = pendingStart {
        for i in start..<segments.count {
            segments[i].speaker = s3
        }
        pendingStart = nil
    }
    segments.append(ConfirmedSegment(text: "continuing", speaker: s3))

    let text = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
    // All segments are speaker A, no speaker change line
    XCTAssertEqual(text, "A: Hello glitch continuing")
}
```

### Step 2: Run integration tests

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`

Expected: All tests PASS.

### Step 3: Commit

```bash
git add Tests/QuickTranscriberTests/
git commit -m "test: add integration tests for speaker label smoothing pipeline"
```

---

## Task 6: Final Verification

### Step 1: Run full test suite

```bash
swift test --filter QuickTranscriberTests 2>&1 | tail -10
```

Expected: All tests PASS.

### Step 2: Build the app

```bash
swift build 2>&1 | tail -3
```

Expected: Build Succeeded.

### Step 3: Review changes

```bash
git diff main --stat
```

Verify only the expected files were changed:
- 2 new files (SpeakerLabelTracker.swift, SpeakerLabelTrackerTests.swift)
- 4 modified files (TranscriptionUtils.swift, SpeakerDiarizer.swift, ChunkedWhisperEngine.swift, test files)

### Step 4: Final commit (if any remaining changes)

Then create PR or merge as appropriate.

---

## Summary of Changes

| Change | Impact | Risk |
|--------|--------|------|
| `SpeakerLabelTracker` (new) | Core smoothing logic | Low — isolated, well-tested |
| `ConfirmedSegment.speaker`: `let` → `var` | Enables retroactive updates | Low — struct semantics unchanged |
| Buffer 10s → 30s | More context for diarizer | Low — ~0.25s extra processing per chunk |
| Engine integration | Connects tracker to pipeline | Medium — main logic change |

## Behavioral Changes

**Before:** Every chunk gets whatever label FluidAudio returns → rapid oscillation (A→B→A→B).

**After:**
1. First speaker confirmed immediately: `"A: Hello"`
2. When diarizer starts saying "B": text appears without label during pending period: `"A: Hello new speaker text"`
3. After 2 consecutive "B" chunks (~6 seconds): retroactive update: `"A: Hello\nB: new speaker text continued"`
4. Brief 1-chunk glitches are suppressed (false alarm returns to original speaker)

**No changes to:**
- TranscriptionTextView (rewrite path handles text changes automatically)
- TranscriptFileWriter (rewrite path handles text changes automatically)
- SettingsView (enableSpeakerDiarization toggle works as before)
- joinSegments logic (handles nil speakers naturally by falling through to inline concatenation)
