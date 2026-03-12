# Audio Auto-Normalization Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add real-time AGC (Automatic Gain Control) to the audio pipeline so quiet microphone input is automatically boosted before VAD, improving transcription reliability.

**Architecture:** A new `AudioLevelNormalizer` struct applies per-buffer peak-based gain normalization between audio capture and VAD. It uses a decaying peak tracker with EMA-smoothed gain to avoid abrupt volume changes. Integrated into `ChunkedWhisperEngine` as a property alongside the existing `VADChunkAccumulator`.

**Tech Stack:** Swift, XCTest

**Spec:** `docs/superpowers/specs/2026-03-13-audio-auto-normalization-design.md`

---

## Chunk 1: AudioLevelNormalizer + Constants

### Task 1: Add Constants.AudioNormalization

**Files:**
- Modify: `Sources/QuickTranscriber/Constants.swift:3-51`

- [ ] **Step 1: Add AudioNormalization enum to Constants**

Add after the `VAD` enum (line 17):

```swift
    public enum AudioNormalization {
        public static let targetPeak: Float = 0.5
        public static let minGain: Float = 1.0
        public static let maxGain: Float = 10.0
        public static let windowDuration: TimeInterval = 1.0
        public static let attackCoefficient: Float = 0.1
        public static let releaseCoefficient: Float = 0.01
    }
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 3: Commit**

```bash
git add Sources/QuickTranscriber/Constants.swift
git commit -m "feat: add AudioNormalization constants"
```

### Task 2: Create AudioLevelNormalizer with tests (TDD)

**Files:**
- Create: `Sources/QuickTranscriber/Audio/AudioLevelNormalizer.swift`
- Create: `Tests/QuickTranscriberTests/AudioLevelNormalizerTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/QuickTranscriberTests/AudioLevelNormalizerTests.swift`:

```swift
import XCTest
@testable import QuickTranscriberLib

final class AudioLevelNormalizerTests: XCTestCase {
    private let sampleRate: Double = 16000.0

    /// Helper: create a constant-amplitude buffer.
    private func makeBuffer(amplitude: Float, duration: TimeInterval) -> [Float] {
        [Float](repeating: amplitude, count: Int(duration * sampleRate))
    }

    // MARK: - Initial State

    func testInitialGainIsOne() {
        let normalizer = AudioLevelNormalizer()
        XCTAssertEqual(normalizer.currentGain, 1.0)
    }

    // MARK: - Quiet Input Boost

    func testQuietInputIsBoosted() {
        var normalizer = AudioLevelNormalizer()
        // Feed several buffers of quiet audio to let AGC adapt
        let quietBuffer = makeBuffer(amplitude: 0.005, duration: 0.1)
        var output: [Float] = []
        for _ in 0..<20 {
            output = normalizer.normalize(quietBuffer)
        }
        // After adaptation, output peak should be higher than input
        let outputPeak = output.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(outputPeak, 0.005, "Quiet input should be boosted")
    }

    // MARK: - Loud Input Not Attenuated

    func testLoudInputNotAttenuated() {
        var normalizer = AudioLevelNormalizer()
        let loudBuffer = makeBuffer(amplitude: 0.6, duration: 0.1)
        var output: [Float] = []
        for _ in 0..<20 {
            output = normalizer.normalize(loudBuffer)
        }
        // gain-up only: loud input (peak > targetPeak) should not be reduced
        let outputPeak = output.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThanOrEqual(outputPeak, 0.6, "Loud input should not be attenuated")
    }

    // MARK: - Max Gain Limit

    func testMaxGainIsRespected() {
        var normalizer = AudioLevelNormalizer()
        // Very quiet input: targetPeak(0.5) / 0.001 = 500x, should be clamped to maxGain(10x)
        let veryQuietBuffer = makeBuffer(amplitude: 0.001, duration: 0.1)
        var output: [Float] = []
        for _ in 0..<50 {
            output = normalizer.normalize(veryQuietBuffer)
        }
        let outputPeak = output.map { abs($0) }.max() ?? 0
        // With maxGain=10, output should be at most 0.001 * 10 = 0.01
        XCTAssertLessThanOrEqual(outputPeak, 0.001 * Constants.AudioNormalization.maxGain + 0.001,
                                  "Output should respect max gain limit")
    }

    // MARK: - Clipping Protection

    func testOutputIsClampedToUnitRange() {
        var normalizer = AudioLevelNormalizer()
        // amplitude 0.15, with maxGain=10 → 1.5, should be clamped to 1.0
        let buffer = makeBuffer(amplitude: 0.15, duration: 0.1)
        for _ in 0..<50 {
            let output = normalizer.normalize(buffer)
            let maxVal = output.map { abs($0) }.max() ?? 0
            XCTAssertLessThanOrEqual(maxVal, 1.0, "Output must be clamped to [-1.0, 1.0]")
        }
    }

    // MARK: - Zero / Silent Input

    func testSilentInputReturnsZeros() {
        var normalizer = AudioLevelNormalizer()
        let silentBuffer = makeBuffer(amplitude: 0.0, duration: 0.1)
        let output = normalizer.normalize(silentBuffer)
        let maxVal = output.map { abs($0) }.max() ?? 0
        XCTAssertEqual(maxVal, 0.0, "Silent input should remain silent")
    }

    // MARK: - Decaying Peak Tracker

    func testPeakDecaysOverTime() {
        var normalizer = AudioLevelNormalizer()
        // Feed a loud buffer to set a high peak
        let loudBuffer = makeBuffer(amplitude: 0.5, duration: 0.1)
        _ = normalizer.normalize(loudBuffer)
        let peakAfterLoud = normalizer.runningPeak

        // Feed many quiet buffers to let peak decay
        let quietBuffer = makeBuffer(amplitude: 0.001, duration: 0.1)
        for _ in 0..<30 {
            _ = normalizer.normalize(quietBuffer)
        }
        let peakAfterDecay = normalizer.runningPeak

        XCTAssertLessThan(peakAfterDecay, peakAfterLoud, "Peak should decay over time")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AudioLevelNormalizerTests 2>&1 | tail -10`
Expected: Compilation error — `AudioLevelNormalizer` not defined

- [ ] **Step 3: Implement AudioLevelNormalizer**

Create `Sources/QuickTranscriber/Audio/AudioLevelNormalizer.swift`:

```swift
import Foundation

public struct AudioLevelNormalizer: Sendable {
    public private(set) var runningPeak: Float = 0.0
    public private(set) var currentGain: Float = 1.0

    private let targetPeak: Float
    private let minGain: Float
    private let maxGain: Float
    private let windowDuration: TimeInterval
    private let attackCoefficient: Float
    private let releaseCoefficient: Float
    private let sampleRate: Double

    public init(
        targetPeak: Float = Constants.AudioNormalization.targetPeak,
        minGain: Float = Constants.AudioNormalization.minGain,
        maxGain: Float = Constants.AudioNormalization.maxGain,
        windowDuration: TimeInterval = Constants.AudioNormalization.windowDuration,
        attackCoefficient: Float = Constants.AudioNormalization.attackCoefficient,
        releaseCoefficient: Float = Constants.AudioNormalization.releaseCoefficient,
        sampleRate: Double = Constants.Audio.sampleRate
    ) {
        self.targetPeak = targetPeak
        self.minGain = minGain
        self.maxGain = maxGain
        self.windowDuration = windowDuration
        self.attackCoefficient = attackCoefficient
        self.releaseCoefficient = releaseCoefficient
        self.sampleRate = sampleRate
    }

    public mutating func normalize(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }

        // Update decaying peak tracker
        let bufferPeak = samples.map { abs($0) }.max() ?? 0
        let bufferDuration = TimeInterval(samples.count) / sampleRate
        if bufferPeak > runningPeak {
            runningPeak = bufferPeak
        } else {
            let decayFactor = Float(pow(0.01, bufferDuration / windowDuration))
            runningPeak = runningPeak * decayFactor
        }

        // Calculate and smooth gain
        let rawGain: Float
        if runningPeak < 1e-6 {
            rawGain = 1.0
        } else {
            rawGain = min(max(targetPeak / runningPeak, minGain), maxGain)
        }

        if rawGain < currentGain {
            currentGain += (rawGain - currentGain) * attackCoefficient
        } else {
            currentGain += (rawGain - currentGain) * releaseCoefficient
        }

        // Apply gain and clamp
        return samples.map { sample in
            min(max(sample * currentGain, -1.0), 1.0)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AudioLevelNormalizerTests 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Audio/AudioLevelNormalizer.swift \
       Tests/QuickTranscriberTests/AudioLevelNormalizerTests.swift
git commit -m "feat: add AudioLevelNormalizer with decaying peak AGC"
```

---

## Chunk 2: Pipeline Integration

### Task 3: Integrate normalizer into ChunkedWhisperEngine

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift:9,64,116-124`

- [ ] **Step 1: Add normalizer property**

In `ChunkedWhisperEngine`, add after line 9 (`private var accumulator`):

```swift
    private var normalizer = AudioLevelNormalizer()
```

- [ ] **Step 2: Reset normalizer in startStreaming**

In `startStreaming()`, add after line 71 (accumulator initialization):

```swift
        normalizer = AudioLevelNormalizer()
```

- [ ] **Step 3: Apply normalization before VAD**

In the streaming loop (lines 116-124), change:

```swift
        streamingTask = Task { [weak self] in
            for await samples in bufferStream {
                guard let self, self._isStreaming else { break }

                if let chunkResult = self.accumulator.appendBuffer(samples) {
                    await self.processChunk(chunkResult, onStateChange: onStateChange)
                }
            }
        }
```

to:

```swift
        streamingTask = Task { [weak self] in
            var bufferCount = 0
            for await samples in bufferStream {
                guard let self, self._isStreaming else { break }

                let normalizedSamples = self.normalizer.normalize(samples)
                bufferCount += 1
                // Log gain state every ~10 seconds (100ms buffers × 100 = 10s)
                if bufferCount % 100 == 0 {
                    NSLog("[AudioLevelNormalizer] gain=%.2f runningPeak=%.4f", self.normalizer.currentGain, self.normalizer.runningPeak)
                }

                if let chunkResult = self.accumulator.appendBuffer(normalizedSamples) {
                    await self.processChunk(chunkResult, onStateChange: onStateChange)
                }
            }
        }
```

- [ ] **Step 4: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 5: Run all existing tests to verify no regression**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -15`
Expected: All existing tests pass

- [ ] **Step 6: Commit**

```bash
git add Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift
git commit -m "feat: integrate AudioLevelNormalizer into audio pipeline"
```

### Task 4: Add integration test for normalization + VAD

**Files:**
- Modify: `Tests/QuickTranscriberTests/AudioLevelNormalizerTests.swift`

- [ ] **Step 1: Add integration test**

Append to `AudioLevelNormalizerTests`:

```swift
    // MARK: - Integration: Normalization + VAD

    func testNormalizedQuietAudioTriggersVAD() {
        var normalizer = AudioLevelNormalizer()
        var accumulator = VADChunkAccumulator()

        // Quiet speech that would NOT trigger VAD directly (0.005 < onset 0.02)
        let quietSpeech = makeBuffer(amplitude: 0.005, duration: 0.1)
        let silence = makeBuffer(amplitude: 0.0, duration: 0.1)

        // Feed quiet speech through normalizer → accumulator
        var chunkEmitted = false
        // Warm up the normalizer
        for _ in 0..<20 {
            let normalized = normalizer.normalize(quietSpeech)
            _ = accumulator.appendBuffer(normalized)
        }
        // Feed speech then silence to trigger utterance boundary
        for _ in 0..<30 {
            let normalized = normalizer.normalize(quietSpeech)
            _ = accumulator.appendBuffer(normalized)
        }
        for _ in 0..<10 {
            let normalized = normalizer.normalize(silence)
            if accumulator.appendBuffer(normalized) != nil {
                chunkEmitted = true
            }
        }
        // Also try flush
        if accumulator.flush() != nil {
            chunkEmitted = true
        }

        XCTAssertTrue(chunkEmitted,
            "Quiet audio (0.005) should trigger VAD after normalization boosts it above onset threshold (0.02)")
    }

    func testUnnormalizedQuietAudioDoesNotTriggerVAD() {
        var accumulator = VADChunkAccumulator()

        // Same quiet speech WITHOUT normalization — should NOT trigger VAD
        let quietSpeech = makeBuffer(amplitude: 0.005, duration: 0.1)
        let silence = makeBuffer(amplitude: 0.0, duration: 0.1)

        var chunkEmitted = false
        for _ in 0..<50 {
            if accumulator.appendBuffer(quietSpeech) != nil {
                chunkEmitted = true
            }
        }
        for _ in 0..<10 {
            if accumulator.appendBuffer(silence) != nil {
                chunkEmitted = true
            }
        }
        if accumulator.flush() != nil {
            chunkEmitted = true
        }

        XCTAssertFalse(chunkEmitted,
            "Without normalization, quiet audio (0.005) should NOT trigger VAD onset threshold (0.02)")
    }
```

- [ ] **Step 2: Run integration tests**

Run: `swift test --filter AudioLevelNormalizerTests 2>&1 | tail -15`
Expected: All tests pass (including new integration tests)

- [ ] **Step 3: Run full test suite**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -15`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add Tests/QuickTranscriberTests/AudioLevelNormalizerTests.swift
git commit -m "test: add normalization + VAD integration tests"
```
