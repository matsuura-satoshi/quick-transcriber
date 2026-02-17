# Phase C-1: Confidence Score Propagation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Propagate cosine similarity from EmbeddingBasedSpeakerTracker through the pipeline to TranscriptionTextView, coloring low-confidence speaker labels gray.

**Architecture:** Add `SpeakerIdentification` struct (label + confidence). Change return types through SpeakerDiarizer protocol → SpeakerLabelTracker → ConfirmedSegment. Pass `[ConfirmedSegment]` to TranscriptionTextView for per-label color rendering.

**Tech Stack:** Swift, SwiftUI, AppKit (NSTextView/NSAttributedString)

---

### Task 1: SpeakerIdentification struct + EmbeddingBasedSpeakerTracker

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift`
- Test: `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift`

**Step 1: Write the failing tests**

Add to `EmbeddingBasedSpeakerTrackerTests.swift`:

```swift
// MARK: - Confidence Score

func testIdentifyReturnsConfidenceForNewSpeaker() {
    let tracker = EmbeddingBasedSpeakerTracker()
    let result = tracker.identify(embedding: makeEmbedding(dominant: 0))
    XCTAssertEqual(result.label, "A")
    XCTAssertEqual(result.confidence, 1.0, accuracy: 0.001)
}

func testIdentifyReturnsConfidenceForMatchedSpeaker() {
    let tracker = EmbeddingBasedSpeakerTracker()
    _ = tracker.identify(embedding: makeEmbedding(dominant: 0))
    var similar = makeEmbedding(dominant: 0)
    similar[1] = 0.15
    let result = tracker.identify(embedding: similar)
    XCTAssertEqual(result.label, "A")
    XCTAssertGreaterThan(result.confidence, 0.5)
    XCTAssertLessThan(result.confidence, 1.0)
}

func testIdentifyReturnsLowConfidenceForForcedAssignment() {
    let tracker = EmbeddingBasedSpeakerTracker(expectedSpeakerCount: 2)
    _ = tracker.identify(embedding: makeEmbedding(dominant: 0))
    _ = tracker.identify(embedding: makeEmbedding(dominant: 1))
    let result = tracker.identify(embedding: makeEmbedding(dominant: 2))
    XCTAssertTrue(result.label == "A" || result.label == "B")
    XCTAssertLessThan(result.confidence, 0.5)
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter EmbeddingBasedSpeakerTrackerTests/testIdentifyReturnsConfidenceForNewSpeaker 2>&1 | tail -5`
Expected: Compilation error (identify() returns String, not SpeakerIdentification)

**Step 3: Implement SpeakerIdentification and update identify()**

In `EmbeddingBasedSpeakerTracker.swift`, add before the class:

```swift
public struct SpeakerIdentification: Sendable, Equatable {
    public let label: String
    public let confidence: Float
}
```

Change `identify(embedding:)` return type from `String` to `SpeakerIdentification`:

```swift
public func identify(embedding: [Float]) -> SpeakerIdentification {
    identifyCount += 1
    maintainProfiles()

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
        return SpeakerIdentification(label: profiles[bestIndex].label, confidence: bestSimilarity)
    }

    if let limit = expectedSpeakerCount, profiles.count >= limit, bestIndex >= 0 {
        profiles[bestIndex].hitCount += 1
        let alpha = updateAlpha
        profiles[bestIndex].embedding = zip(profiles[bestIndex].embedding, embedding).map { old, new in
            (1 - alpha) * old + alpha * new
        }
        return SpeakerIdentification(label: profiles[bestIndex].label, confidence: bestSimilarity)
    }

    if case .registrationGate(let minSeparation) = strategy, bestIndex >= 0 {
        if bestSimilarity >= minSeparation {
            profiles[bestIndex].hitCount += 1
            let alpha = updateAlpha
            profiles[bestIndex].embedding = zip(profiles[bestIndex].embedding, embedding).map { old, new in
                (1 - alpha) * old + alpha * new
            }
            return SpeakerIdentification(label: profiles[bestIndex].label, confidence: bestSimilarity)
        }
    }

    let label = String(UnicodeScalar(UInt8(65 + nextLabelIndex % 26)))
    profiles.append(SpeakerProfile(label: label, embedding: embedding, hitCount: 1))
    nextLabelIndex += 1
    return SpeakerIdentification(label: label, confidence: 1.0)
}
```

**Step 4: Update existing tests to use .label**

All existing tests that do `let label = tracker.identify(...)` need to change to `let label = tracker.identify(...).label`. Apply this to every test in `EmbeddingBasedSpeakerTrackerTests.swift`. For example:

```swift
func testFirstSpeakerGetsLabelA() {
    let tracker = EmbeddingBasedSpeakerTracker()
    let emb = makeEmbedding(dominant: 0)
    let result = tracker.identify(embedding: emb)
    XCTAssertEqual(result.label, "A")
}
```

**Step 5: Run all tracker tests**

Run: `swift test --filter EmbeddingBasedSpeakerTrackerTests 2>&1 | tail -20`
Expected: All tests pass

**Step 6: Commit**

```bash
git add Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift
git commit -m "feat: return SpeakerIdentification with confidence from identify()"
```

---

### Task 2: SpeakerDiarizer protocol + FluidAudioSpeakerDiarizer + DiarizationPacer

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift` (protocol + FluidAudioSpeakerDiarizer)
- Modify: `Sources/QuickTranscriber/Engines/DiarizationPacer.swift`
- Modify: `Tests/QuickTranscriberTests/Mocks/MockSpeakerDiarizer.swift`

**Step 1: Update SpeakerDiarizer protocol**

Change `identifySpeaker` return type:

```swift
public protocol SpeakerDiarizer: AnyObject, Sendable {
    func setup() async throws
    func identifySpeaker(audioChunk: [Float]) async -> SpeakerIdentification?
    func updateExpectedSpeakerCount(_ count: Int?)
    func exportSpeakerProfiles() -> [(label: String, embedding: [Float])]
    func loadSpeakerProfiles(_ profiles: [(label: String, embedding: [Float])])
}
```

**Step 2: Update DiarizationPacer**

Change `lastLabel` to `lastResult`:

```swift
public struct DiarizationPacer {
    public let diarizationChunkDuration: TimeInterval
    public let sampleRate: Int
    public private(set) var samplesSinceLastDiarization: Int = 0
    public var lastResult: SpeakerIdentification?

    // ... init and accumulate unchanged ...

    public mutating func reset() {
        samplesSinceLastDiarization = 0
    }
}
```

**Step 3: Update FluidAudioSpeakerDiarizer.identifySpeaker()**

```swift
public func identifySpeaker(audioChunk: [Float]) async -> SpeakerIdentification? {
    guard let diarizer else { return nil }

    let windowSamples = Int(windowDuration * Double(sampleRate))
    let (currentBuffer, shouldRunDiarization, accumulatedDuration) = lock.withLock {
        rollingBuffer.append(contentsOf: audioChunk)
        if rollingBuffer.count > windowSamples {
            rollingBuffer.removeFirst(rollingBuffer.count - windowSamples)
        }
        let shouldRun = pacer.accumulate(chunkSamples: audioChunk.count)
        let accumulated = Float(pacer.samplesSinceLastDiarization) / Float(sampleRate)
        return (rollingBuffer, shouldRun, accumulated)
    }

    guard shouldRunDiarization else {
        return lock.withLock { pacer.lastResult }
    }

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

        guard let relevant = Self.findRelevantSegment(
            segments: segments,
            bufferDuration: bufferDuration,
            chunkDuration: accumulatedDuration
        ) else {
            lock.withLock { pacer.reset() }
            return lock.withLock { pacer.lastResult }
        }

        let identification = speakerTracker.identify(embedding: relevant.embedding)
        lock.withLock {
            pacer.lastResult = identification
            pacer.reset()
        }
        NSLog("[SpeakerDiarizer] Raw=\(relevant.speakerId) → Tracked=\(identification.label) conf=\(String(format: "%.3f", identification.confidence)) (time=\(String(format: "%.1f", relevant.startTime))-\(String(format: "%.1f", relevant.endTime))s, accumulated=\(String(format: "%.1f", accumulatedDuration))s)")
        return identification
    } catch {
        NSLog("[SpeakerDiarizer] Diarization failed: \(error)")
        lock.withLock { pacer.reset() }
        return lock.withLock { pacer.lastResult }
    }
}
```

**Step 4: Update loadSpeakerProfiles to reset pacer.lastResult**

In `loadSpeakerProfiles`, change `pacer.lastLabel` references:

```swift
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

(No change needed here — DiarizationPacer init already sets lastResult to nil.)

**Step 5: Update MockSpeakerDiarizer**

```swift
final class MockSpeakerDiarizer: SpeakerDiarizer, @unchecked Sendable {
    var setupCalled = false
    var setupError: Error?
    var speakerResults: [SpeakerIdentification?] = []
    private var callIndex = 0

    func setup() async throws {
        setupCalled = true
        if let error = setupError { throw error }
    }

    func identifySpeaker(audioChunk: [Float]) async -> SpeakerIdentification? {
        guard callIndex < speakerResults.count else { return nil }
        let result = speakerResults[callIndex]
        callIndex += 1
        return result
    }

    func updateExpectedSpeakerCount(_ count: Int?) {}

    var exportedProfiles: [(label: String, embedding: [Float])] = []
    var loadedProfiles: [(label: String, embedding: [Float])]?

    func exportSpeakerProfiles() -> [(label: String, embedding: [Float])] {
        exportedProfiles
    }

    func loadSpeakerProfiles(_ profiles: [(label: String, embedding: [Float])]) {
        loadedProfiles = profiles
    }
}
```

**Step 6: Run tests**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -20`
Expected: Compilation errors from ChunkedWhisperEngine (Task 3 needed). This is expected — just verify the tracker and diarizer tests compile.

**Step 7: Commit (even with downstream compilation errors)**

```bash
git add Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift Sources/QuickTranscriber/Engines/DiarizationPacer.swift Tests/QuickTranscriberTests/Mocks/MockSpeakerDiarizer.swift
git commit -m "feat: propagate SpeakerIdentification through SpeakerDiarizer protocol"
```

---

### Task 3: SpeakerLabelTracker + ConfirmedSegment + ChunkedWhisperEngine

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/SpeakerLabelTracker.swift`
- Modify: `Sources/QuickTranscriber/Engines/TranscriptionUtils.swift` (ConfirmedSegment)
- Modify: `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift`
- Modify: `Tests/QuickTranscriberTests/SpeakerLabelTrackerTests.swift`

**Step 1: Write new test for SpeakerLabelTracker with confidence**

Add to `SpeakerLabelTrackerTests.swift`:

```swift
// MARK: - Confidence propagation

func testProcessLabelPassesThroughConfidence() {
    let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
    let result = tracker.processLabel(SpeakerIdentification(label: "A", confidence: 0.85))
    XCTAssertEqual(result?.label, "A")
    XCTAssertEqual(result?.confidence, 0.85)
}

func testProcessLabelConfirmedSpeakerWithNilInputReturnsLastConfidence() {
    let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
    _ = tracker.processLabel(SpeakerIdentification(label: "A", confidence: 0.9))
    let result = tracker.processLabel(nil)
    XCTAssertEqual(result?.label, "A")
    XCTAssertEqual(result?.confidence, 0.9)
}

func testProcessLabelUpdatesConfidenceOnSameSpeaker() {
    let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
    _ = tracker.processLabel(SpeakerIdentification(label: "A", confidence: 0.9))
    let result = tracker.processLabel(SpeakerIdentification(label: "A", confidence: 0.7))
    XCTAssertEqual(result?.label, "A")
    XCTAssertEqual(result?.confidence, 0.7)
}

func testProcessLabelConfirmationUsesLatestConfidence() {
    let tracker = SpeakerLabelTracker(confirmationThreshold: 2)
    _ = tracker.processLabel(SpeakerIdentification(label: "A", confidence: 0.9))
    _ = tracker.processLabel(SpeakerIdentification(label: "B", confidence: 0.6))  // pending
    let result = tracker.processLabel(SpeakerIdentification(label: "B", confidence: 0.75))  // confirmed
    XCTAssertEqual(result?.label, "B")
    XCTAssertEqual(result?.confidence, 0.75)
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter SpeakerLabelTrackerTests/testProcessLabelPassesThroughConfidence 2>&1 | tail -5`
Expected: Compilation error (processLabel takes String?, not SpeakerIdentification?)

**Step 3: Update SpeakerLabelTracker**

```swift
public final class SpeakerLabelTracker: @unchecked Sendable {
    private let confirmationThreshold: Int
    private var confirmedResult: SpeakerIdentification?
    private var pendingLabel: String?
    private var pendingCount: Int = 0

    public init(confirmationThreshold: Int = 2) {
        self.confirmationThreshold = max(1, confirmationThreshold)
    }

    public func processLabel(_ identification: SpeakerIdentification?) -> SpeakerIdentification? {
        guard let id = identification else {
            return confirmedResult
        }

        if confirmedResult == nil {
            confirmedResult = id
            pendingLabel = nil
            pendingCount = 0
            return id
        }

        if id.label == confirmedResult?.label {
            confirmedResult = id
            pendingLabel = nil
            pendingCount = 0
            return id
        }

        if id.label == pendingLabel {
            pendingCount += 1
        } else {
            pendingLabel = id.label
            pendingCount = 1
        }

        if pendingCount >= confirmationThreshold {
            confirmedResult = id
            pendingLabel = nil
            pendingCount = 0
            return id
        }

        return nil
    }

    public func reset() {
        confirmedResult = nil
        pendingLabel = nil
        pendingCount = 0
    }
}
```

**Step 4: Update existing SpeakerLabelTracker tests**

Change all `tracker.processLabel("A")` to `tracker.processLabel(SpeakerIdentification(label: "A", confidence: 0.9))`. Use helper:

Add helper to test class:
```swift
private func id(_ label: String, _ confidence: Float = 0.9) -> SpeakerIdentification {
    SpeakerIdentification(label: label, confidence: confidence)
}
```

Then update all calls: `tracker.processLabel("A")` → `tracker.processLabel(id("A"))`, and result checks like `XCTAssertEqual(result, "A")` → `XCTAssertEqual(result?.label, "A")`.

**Step 5: Update ConfirmedSegment**

In `TranscriptionUtils.swift`:

```swift
public struct ConfirmedSegment: Sendable, Equatable {
    public let text: String
    public let precedingSilence: TimeInterval
    public var speaker: String?
    public var speakerConfidence: Float?

    public init(text: String, precedingSilence: TimeInterval = 0, speaker: String? = nil, speakerConfidence: Float? = nil) {
        self.text = text
        self.precedingSilence = precedingSilence
        self.speaker = speaker
        self.speakerConfidence = speakerConfidence
    }
}
```

**Step 6: Update ChunkedWhisperEngine.processChunk()**

Change the relevant parts:

1. Change `rawSpeakerLabel` type from `String?` to `SpeakerIdentification?`:
```swift
let rawSpeakerResult: SpeakerIdentification?
if let diarizer, currentParameters.enableSpeakerDiarization {
    async let transcription = transcriber.transcribe(...)
    async let speakerId = diarizer.identifySpeaker(audioChunk: chunk)
    segments = try await transcription
    rawSpeakerResult = await speakerId
} else {
    segments = try await transcriber.transcribe(...)
    rawSpeakerResult = nil
}
```

2. Change smoothing:
```swift
let smoothedResult: SpeakerIdentification?
if currentParameters.enableSpeakerDiarization {
    smoothedResult = speakerTracker.processLabel(rawSpeakerResult)

    if let result = smoothedResult, let startIdx = pendingSegmentStartIndex {
        for i in startIdx..<confirmedSegments.count {
            confirmedSegments[i].speaker = result.label
            confirmedSegments[i].speakerConfidence = result.confidence
        }
        pendingSegmentStartIndex = nil
    }
} else {
    smoothedResult = nil
}
```

3. Change segment creation:
```swift
confirmedSegments.append(ConfirmedSegment(
    text: segment.text,
    precedingSilence: precedingSilence,
    speaker: smoothedResult?.label,
    speakerConfidence: smoothedResult?.confidence
))
```

**Step 7: Run all unit tests**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -30`
Expected: All pass (TranscriptionUtilsTests should pass since ConfirmedSegment init is backward compatible)

**Step 8: Commit**

```bash
git add Sources/QuickTranscriber/Engines/SpeakerLabelTracker.swift Sources/QuickTranscriber/Engines/TranscriptionUtils.swift Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift Tests/QuickTranscriberTests/SpeakerLabelTrackerTests.swift
git commit -m "feat: propagate confidence through SpeakerLabelTracker and ConfirmedSegment"
```

---

### Task 4: TranscriptionTextView confidence-based coloring

**Files:**
- Modify: `Sources/QuickTranscriber/Views/TranscriptionTextView.swift`
- Modify: `Sources/QuickTranscriber/Engines/TranscriptionEngine.swift` (TranscriptionState)
- Modify: `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift` (emit segments)
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift`
- Modify: `Sources/QuickTranscriber/Views/ContentView.swift`

**Step 1: Add confirmedSegments to TranscriptionState**

In `TranscriptionEngine.swift`:

```swift
public struct TranscriptionState: Sendable {
    public var confirmedText: String
    public var unconfirmedText: String
    public var isRecording: Bool
    public var confirmedSegments: [ConfirmedSegment]

    public init(confirmedText: String, unconfirmedText: String, isRecording: Bool, confirmedSegments: [ConfirmedSegment] = []) {
        self.confirmedText = confirmedText
        self.unconfirmedText = unconfirmedText
        self.isRecording = isRecording
        self.confirmedSegments = confirmedSegments
    }
}
```

**Step 2: Emit confirmedSegments from ChunkedWhisperEngine**

In `processChunk()`, update the onStateChange call:

```swift
onStateChange(TranscriptionState(
    confirmedText: confirmedText,
    unconfirmedText: "",
    isRecording: true,
    confirmedSegments: confirmedSegments
))
```

**Step 3: Add confirmedSegments to TranscriptionViewModel**

Add published property:

```swift
@Published public var confirmedSegments: [ConfirmedSegment] = []
```

In `startRecording()` state update callback:

```swift
self.confirmedSegments = state.confirmedSegments
```

**Step 4: Update ContentView to pass segments**

```swift
private var transcriptionArea: some View {
    TranscriptionTextView(
        confirmedText: viewModel.confirmedText,
        unconfirmedText: viewModel.unconfirmedText,
        fontSize: viewModel.fontSize,
        confirmedSegments: viewModel.confirmedSegments
    )
    .frame(maxHeight: .infinity)
}
```

**Step 5: Update TranscriptionTextView**

Add property:
```swift
let confirmedSegments: [ConfirmedSegment]
```

Replace `buildAttributedString` to use segments for confidence coloring. Add new method:

```swift
private static let lowConfidenceThreshold: Float = 0.5

static func buildAttributedStringFromSegments(
    _ segments: [ConfirmedSegment],
    language: String,
    silenceThreshold: TimeInterval,
    fontSize: CGFloat,
    unconfirmed: String
) -> NSAttributedString {
    let result = NSMutableAttributedString()
    guard !segments.isEmpty else {
        if !unconfirmed.isEmpty {
            return buildUnconfirmedAttributedString(unconfirmed, fontSize: fontSize)
        }
        return result
    }

    let hasSpeakers = segments.contains { $0.speaker != nil }
    let sentenceEnders: Set<Character> = (language == "ja")
        ? ["。", "！", "？"] : [".", "!", "?"]
    let separator = (language == "ja") ? "" : " "
    let normalAttrs = confirmedAttributes(fontSize: fontSize)

    var currentSpeaker: String? = nil
    var lastChar: Character? = nil

    for (index, segment) in segments.enumerated() {
        guard !segment.text.isEmpty else { continue }

        let isFirst = (result.length == 0)

        if isFirst {
            if hasSpeakers, let speaker = segment.speaker {
                let labelAttrs = speakerLabelAttributes(fontSize: fontSize, confidence: segment.speakerConfidence)
                result.append(NSAttributedString(string: "\(speaker): ", attributes: labelAttrs))
                result.append(NSAttributedString(string: segment.text, attributes: normalAttrs))
                currentSpeaker = speaker
            } else {
                result.append(NSAttributedString(string: segment.text, attributes: normalAttrs))
            }
            lastChar = segment.text.last
            continue
        }

        // Priority 1: Speaker change
        if hasSpeakers, let speaker = segment.speaker, speaker != currentSpeaker {
            let labelAttrs = speakerLabelAttributes(fontSize: fontSize, confidence: segment.speakerConfidence)
            result.append(NSAttributedString(string: "\n", attributes: normalAttrs))
            result.append(NSAttributedString(string: "\(speaker): ", attributes: labelAttrs))
            result.append(NSAttributedString(string: segment.text, attributes: normalAttrs))
            currentSpeaker = speaker
            lastChar = segment.text.last
            continue
        }

        // Priority 2: Silence threshold
        if segment.precedingSilence >= silenceThreshold {
            result.append(NSAttributedString(string: "\n" + segment.text, attributes: normalAttrs))
            lastChar = segment.text.last
            continue
        }

        // Priority 3: Sentence end
        if let last = lastChar, sentenceEnders.contains(last) {
            result.append(NSAttributedString(string: "\n" + segment.text, attributes: normalAttrs))
            lastChar = segment.text.last
            continue
        }

        // Priority 4: Inline
        result.append(NSAttributedString(string: separator + segment.text, attributes: normalAttrs))
        lastChar = segment.text.last
    }

    if !unconfirmed.isEmpty {
        result.append(NSAttributedString(string: "\n", attributes: normalAttrs))
        result.append(buildUnconfirmedAttributedString(unconfirmed, fontSize: fontSize))
    }

    return result
}

private static func speakerLabelAttributes(fontSize: CGFloat, confidence: Float?) -> [NSAttributedString.Key: Any] {
    let color: NSColor
    if let conf = confidence, conf < lowConfidenceThreshold {
        color = .secondaryLabelColor
    } else {
        color = .labelColor
    }
    return [
        .font: NSFont.boldSystemFont(ofSize: fontSize),
        .foregroundColor: color,
        .paragraphStyle: makeParagraphStyle()
    ]
}

private static func buildUnconfirmedAttributedString(_ text: String, fontSize: CGFloat) -> NSAttributedString {
    let italicFont = NSFontManager.shared.convert(
        NSFont.systemFont(ofSize: fontSize),
        toHaveTrait: .italicFontMask
    )
    let attrs: [NSAttributedString.Key: Any] = [
        .font: italicFont,
        .foregroundColor: NSColor.secondaryLabelColor,
        .backgroundColor: NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.3),
        .paragraphStyle: makeParagraphStyle()
    ]
    return NSAttributedString(string: text, attributes: attrs)
}
```

**Step 6: Update updateNSView to use segments**

Add `confirmedSegments` and `currentLanguage` to the view properties and coordinator tracking. The key change is using `buildAttributedStringFromSegments` when segments are available instead of the plain text path.

In `updateNSView`, replace the full-rebuild path:

```swift
func updateNSView(_ scrollView: NSScrollView, context: Context) {
    let coordinator = context.coordinator
    let newConfirmed = confirmedText
    let newUnconfirmed = unconfirmedText
    let oldConfirmed = coordinator.lastConfirmedText
    let oldUnconfirmed = coordinator.lastUnconfirmedText
    let oldFontSize = coordinator.lastFontSize

    guard newConfirmed != oldConfirmed
        || newUnconfirmed != oldUnconfirmed
        || fontSize != oldFontSize else {
        return
    }

    coordinator.lastConfirmedText = newConfirmed
    coordinator.lastUnconfirmedText = newUnconfirmed
    coordinator.lastFontSize = fontSize

    guard let textView = coordinator.textView,
          let textStorage = textView.textStorage else { return }

    let isAtBottom = coordinator.isScrolledToBottom()

    let hasSpeakerConfidence = confirmedSegments.contains { $0.speakerConfidence != nil }

    if hasSpeakerConfidence {
        // Use segment-based rendering for confidence coloring
        let attributed = Self.buildAttributedStringFromSegments(
            confirmedSegments,
            language: language,
            silenceThreshold: silenceThreshold,
            fontSize: fontSize,
            unconfirmed: newUnconfirmed
        )
        textStorage.setAttributedString(attributed)
    } else {
        // No confidence data: use efficient diff-append path
        let canDiffAppend = fontSize == oldFontSize
            && newUnconfirmed.isEmpty
            && oldUnconfirmed.isEmpty
            && newConfirmed.hasPrefix(oldConfirmed)
            && newConfirmed != oldConfirmed

        if canDiffAppend {
            let delta = String(newConfirmed.dropFirst(oldConfirmed.count))
            let attrs = Self.confirmedAttributes(fontSize: fontSize)
            textStorage.append(NSAttributedString(string: delta, attributes: attrs))
        } else {
            let attributed = Self.buildAttributedString(
                confirmed: newConfirmed,
                unconfirmed: newUnconfirmed,
                fontSize: fontSize
            )
            textStorage.setAttributedString(attributed)
        }
    }

    if isAtBottom {
        DispatchQueue.main.async {
            textView.scrollToEndOfDocument(nil)
        }
    }
}
```

Add `language` and `silenceThreshold` properties to the view:

```swift
struct TranscriptionTextView: NSViewRepresentable {
    let confirmedText: String
    let unconfirmedText: String
    let fontSize: CGFloat
    let confirmedSegments: [ConfirmedSegment]
    var language: String = "en"
    var silenceThreshold: TimeInterval = 1.0
    // ...
}
```

Update ContentView to pass these:

```swift
TranscriptionTextView(
    confirmedText: viewModel.confirmedText,
    unconfirmedText: viewModel.unconfirmedText,
    fontSize: viewModel.fontSize,
    confirmedSegments: viewModel.confirmedSegments,
    language: viewModel.currentLanguage.rawValue,
    silenceThreshold: viewModel.currentParameters.silenceLineBreakThreshold
)
```

Add `currentParameters` as a published property or pass through from ParametersStore. The simplest approach: expose `silenceLineBreakThreshold` from `TranscriptionViewModel`:

```swift
public var silenceLineBreakThreshold: TimeInterval {
    parametersStore.parameters.silenceLineBreakThreshold
}
```

**Step 7: Run build**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeds

**Step 8: Commit**

```bash
git add Sources/QuickTranscriber/Views/TranscriptionTextView.swift Sources/QuickTranscriber/Engines/TranscriptionEngine.swift Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift Sources/QuickTranscriber/Views/ContentView.swift
git commit -m "feat: color speaker labels by confidence in TranscriptionTextView"
```

---

### Task 5: Update benchmark tests for SpeakerIdentification

**Files:**
- Modify: Any benchmark test files that reference `identifySpeaker()` or `MockSpeakerDiarizer`

**Step 1: Search for affected benchmark files**

```bash
grep -rn "identifySpeaker\|MockSpeakerDiarizer\|speakerResults\|\.lastLabel" Tests/QuickTranscriberBenchmarks/
```

**Step 2: Update all compilation errors**

Fix any benchmark files that reference the old `String?` return type. The `MockSpeakerDiarizer` is already updated in Task 2. Benchmark tests that set `mockDiarizer.speakerResults = ["A", "B"]` need to change to `mockDiarizer.speakerResults = [SpeakerIdentification(label: "A", confidence: 0.9), ...]`.

**Step 3: Run full test suite**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -20`
Expected: All pass

**Step 4: Commit**

```bash
git add -A
git commit -m "fix: update benchmark tests for SpeakerIdentification type change"
```

---

### Task 6: Final verification + integration test

**Step 1: Run full unit test suite**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -30`
Expected: All pass

**Step 2: Run build**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds

**Step 3: Manual smoke test**

Run: `swift run QuickTranscriber`
- Enable speaker diarization in Settings
- Record with 2 speakers
- Verify speaker labels show in color
- Verify low-confidence labels appear grayed out (may need to observe forced assignments)

**Step 4: Final commit if any cleanup needed**

```bash
git add -A
git commit -m "chore: Phase C-1 confidence score propagation cleanup"
```
