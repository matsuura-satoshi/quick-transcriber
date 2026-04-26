# Parameter Re-Evaluation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute the two-stage benchmark defined in `docs/superpowers/specs/2026-04-24-parameter-re-evaluation-design.md`, producing a recommendation table of parameter values that balances transcription accuracy, speaker labeling accuracy, and end-to-end response latency.

**Architecture:** Add pipeline-stage latency instrumentation, build a manifest-driven sweep runner on top of existing `BenchmarkTestBase` / `ChunkedTranscriptionBenchmarkRunner` / `DiarizationBenchmarkTests`, run OAT + targeted 2-way sweeps against HF datasets, analyze results with a Python script that produces sensitivity curves, Pareto frontier, and a current-vs-optimal diff table.

**Tech Stack:** Swift (QuickTranscriberLib + test targets), WhisperKit, FluidAudio, Python 3 + matplotlib/pandas for analysis.

---

## File Structure

**New files:**
- `Sources/QuickTranscriberLib/Benchmarking/LatencyInstrumentation.swift` — singleton collector for pipeline stage timestamps (ring buffer, ordered records).
- `Tests/QuickTranscriberTests/LatencyInstrumentationTests.swift` — unit tests for the collector.
- `Tests/QuickTranscriberBenchmarks/ParameterSweepRunner.swift` — orchestrator: reads manifest, runs each config via existing runners, appends to output JSON, supports resume.
- `Tests/QuickTranscriberBenchmarks/ParameterSweepRunnerTests.swift` — unit tests for manifest parsing, resume logic, JSON writer.
- `Tests/QuickTranscriberBenchmarks/StreamingLatencyHarness.swift` — concatenates utterances with synthetic silence gaps and feeds the chunked engine at 1× playback speed while LatencyInstrumentation records per-stage timestamps.
- `Tests/QuickTranscriberBenchmarks/Manifests/stage1.json` — 34 Stage 1 configurations.
- `Tests/QuickTranscriberBenchmarks/Manifests/stage2.json` — 24 Stage 2 configurations (authored after Stage 1 analysis).
- `Scripts/analyze_sweep.py` — reads result JSON, emits sensitivity curves (PNG), Pareto scatter (PNG), diff tables (Markdown), and three-axis leaderboard.
- `docs/benchmarks/2026-04-24/stage1_results.json` — Stage 1 raw output.
- `docs/benchmarks/2026-04-24/stage2_results.json` — Stage 2 raw output.
- `docs/benchmarks/2026-04-24/stage1_report.md` — Stage 1 analysis write-up.
- `docs/benchmarks/2026-04-24/stage2_report.md` — Stage 2 analysis write-up.
- `docs/benchmarks/2026-04-24/final_recommendation.md` — Consolidated parameter recommendation (the primary artifact).

**Modified files:**
- `Sources/QuickTranscriberLib/ChunkedWhisperEngine.swift` — add `LatencyInstrumentation.mark(...)` calls at stage transitions.
- `Sources/QuickTranscriberLib/AudioCaptureService.swift` — mark VAD onset / silence-confirm.
- `Sources/QuickTranscriberLib/ChunkTranscriber.swift` — mark inference start / end.
- `Sources/QuickTranscriberLib/FluidAudioSpeakerDiarizer.swift` — mark diarize start / end.

---

## Task 1: LatencyInstrumentation core module

**Files:**
- Create: `Sources/QuickTranscriberLib/Benchmarking/LatencyInstrumentation.swift`
- Test: `Tests/QuickTranscriberTests/LatencyInstrumentationTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/QuickTranscriberTests/LatencyInstrumentationTests.swift`:

```swift
import XCTest
@testable import QuickTranscriberLib

final class LatencyInstrumentationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LatencyInstrumentation.reset()
        LatencyInstrumentation.isEnabled = true
    }

    override func tearDown() {
        LatencyInstrumentation.isEnabled = false
        LatencyInstrumentation.reset()
        super.tearDown()
    }

    func test_mark_whenDisabled_recordsNothing() {
        LatencyInstrumentation.isEnabled = false
        LatencyInstrumentation.mark(.vadOnset, utteranceId: "u1")
        XCTAssertTrue(LatencyInstrumentation.drain().isEmpty)
    }

    func test_mark_whenEnabled_recordsTimestampInOrder() async throws {
        LatencyInstrumentation.mark(.vadOnset, utteranceId: "u1")
        try await Task.sleep(nanoseconds: 1_000_000)
        LatencyInstrumentation.mark(.inferenceStart, utteranceId: "u1")
        try await Task.sleep(nanoseconds: 1_000_000)
        LatencyInstrumentation.mark(.inferenceEnd, utteranceId: "u1")

        let records = LatencyInstrumentation.drain()
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].stage, .vadOnset)
        XCTAssertEqual(records[1].stage, .inferenceStart)
        XCTAssertEqual(records[2].stage, .inferenceEnd)
        XCTAssertLessThan(records[0].timestampNanos, records[1].timestampNanos)
        XCTAssertLessThan(records[1].timestampNanos, records[2].timestampNanos)
    }

    func test_drain_clearsBuffer() {
        LatencyInstrumentation.mark(.vadOnset, utteranceId: "u1")
        _ = LatencyInstrumentation.drain()
        XCTAssertTrue(LatencyInstrumentation.drain().isEmpty)
    }

    func test_ringBuffer_dropsOldestWhenFull() {
        for i in 0..<(LatencyInstrumentation.bufferCapacity + 10) {
            LatencyInstrumentation.mark(.vadOnset, utteranceId: "u\(i)")
        }
        let records = LatencyInstrumentation.drain()
        XCTAssertEqual(records.count, LatencyInstrumentation.bufferCapacity)
        XCTAssertEqual(records.first?.utteranceId, "u10")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LatencyInstrumentationTests`
Expected: FAIL with "cannot find 'LatencyInstrumentation' in scope" (module not yet defined).

- [ ] **Step 3: Implement LatencyInstrumentation**

Create `Sources/QuickTranscriberLib/Benchmarking/LatencyInstrumentation.swift`:

```swift
import Foundation

public enum LatencyStage: String, Codable, Sendable {
    case vadOnset
    case vadConfirmSilence
    case chunkDispatched
    case inferenceStart
    case inferenceEnd
    case diarizeStart
    case diarizeEnd
    case emitToUI
}

public struct LatencyRecord: Codable, Sendable {
    public let utteranceId: String
    public let stage: LatencyStage
    public let timestampNanos: UInt64
}

public enum LatencyInstrumentation {
    public static let bufferCapacity = 4096
    public static var isEnabled: Bool = false

    private static let lock = NSLock()
    private static var buffer: [LatencyRecord] = []
    private static var head: Int = 0

    public static func mark(_ stage: LatencyStage, utteranceId: String) {
        guard isEnabled else { return }
        let ts = DispatchTime.now().uptimeNanoseconds
        let record = LatencyRecord(utteranceId: utteranceId, stage: stage, timestampNanos: ts)
        lock.lock()
        defer { lock.unlock() }
        if buffer.count < bufferCapacity {
            buffer.append(record)
        } else {
            buffer[head] = record
            head = (head + 1) % bufferCapacity
        }
    }

    public static func drain() -> [LatencyRecord] {
        lock.lock()
        defer { lock.unlock() }
        let out: [LatencyRecord]
        if buffer.count < bufferCapacity {
            out = buffer
        } else {
            out = Array(buffer[head..<bufferCapacity]) + Array(buffer[0..<head])
        }
        buffer.removeAll(keepingCapacity: true)
        head = 0
        return out
    }

    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: true)
        head = 0
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LatencyInstrumentationTests`
Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickTranscriberLib/Benchmarking/LatencyInstrumentation.swift Tests/QuickTranscriberTests/LatencyInstrumentationTests.swift
git commit -m "feat: add LatencyInstrumentation for pipeline stage timing"
```

---

## Task 2: Instrument ChunkedWhisperEngine pipeline

**Files:**
- Modify: `Sources/QuickTranscriberLib/ChunkedWhisperEngine.swift`
- Modify: `Sources/QuickTranscriberLib/AudioCaptureService.swift`
- Modify: `Sources/QuickTranscriberLib/ChunkTranscriber.swift`
- Modify: `Sources/QuickTranscriberLib/FluidAudioSpeakerDiarizer.swift`
- Test: `Tests/QuickTranscriberTests/LatencyInstrumentationIntegrationTests.swift`

- [ ] **Step 1: Write the failing integration test**

Create `Tests/QuickTranscriberTests/LatencyInstrumentationIntegrationTests.swift`:

```swift
import XCTest
@testable import QuickTranscriberLib

final class LatencyInstrumentationIntegrationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LatencyInstrumentation.reset()
        LatencyInstrumentation.isEnabled = true
    }

    override func tearDown() {
        LatencyInstrumentation.isEnabled = false
        LatencyInstrumentation.reset()
        super.tearDown()
    }

    func test_processChunk_emitsInferenceStageMarks() async throws {
        let samples = [Float](repeating: 0.0, count: 16_000 * 3)
        let transcriber = try await ChunkTranscriber(model: .stub, language: "en")
        _ = try await transcriber.transcribe(samples: samples, utteranceId: "u1")

        let records = LatencyInstrumentation.drain()
        let stages = records.filter { $0.utteranceId == "u1" }.map { $0.stage }
        XCTAssertTrue(stages.contains(.inferenceStart))
        XCTAssertTrue(stages.contains(.inferenceEnd))
    }
}
```

Note: `ChunkTranscriber` API and `ChunkTranscriber.Model.stub` may not exist yet. If `ChunkTranscriber` cannot be stubbed without loading a model, simplify by asserting on a lower-level function that can be called with a mocked WhisperKit — or mark the test with `try XCTSkipUnless(...)` if the model isn't loadable in CI.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LatencyInstrumentationIntegrationTests`
Expected: FAIL (no marks recorded — instrumentation call sites not yet added).

- [ ] **Step 3: Add mark() calls at 8 call sites**

Edit `Sources/QuickTranscriberLib/AudioCaptureService.swift` — locate the VAD onset detection (where `speechOnsetThreshold` is crossed) and the silence-confirm branch (where `silenceCutoffDuration` is satisfied). Add:

```swift
LatencyInstrumentation.mark(.vadOnset, utteranceId: currentUtteranceId)
// ... at silence-confirm:
LatencyInstrumentation.mark(.vadConfirmSilence, utteranceId: currentUtteranceId)
```

Edit `Sources/QuickTranscriberLib/ChunkedWhisperEngine.swift` — at the point where a chunk is dispatched to the transcriber:

```swift
LatencyInstrumentation.mark(.chunkDispatched, utteranceId: utteranceId)
```

And at the point where the resulting text is emitted to the UI layer:

```swift
LatencyInstrumentation.mark(.emitToUI, utteranceId: utteranceId)
```

Edit `Sources/QuickTranscriberLib/ChunkTranscriber.swift` — wrap the `whisperKit.transcribe(...)` call:

```swift
LatencyInstrumentation.mark(.inferenceStart, utteranceId: utteranceId)
let result = try await whisperKit.transcribe(audioArray: samples, decodeOptions: opts)
LatencyInstrumentation.mark(.inferenceEnd, utteranceId: utteranceId)
```

Edit `Sources/QuickTranscriberLib/FluidAudioSpeakerDiarizer.swift` — wrap `identifySpeaker(audioChunk:)`:

```swift
LatencyInstrumentation.mark(.diarizeStart, utteranceId: utteranceId)
let result = await /* existing body */
LatencyInstrumentation.mark(.diarizeEnd, utteranceId: utteranceId)
return result
```

If the existing code does not thread an `utteranceId` through these call sites, plumb it through (add an `utteranceId: String` parameter to the relevant functions). Each plumbed parameter is one edit per call site.

- [ ] **Step 4: Run integration test to verify it passes**

Run: `swift test --filter LatencyInstrumentationIntegrationTests`
Expected: PASS.

- [ ] **Step 5: Run full unit test suite to ensure no regression**

Run: `swift test --filter QuickTranscriberTests`
Expected: all existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/QuickTranscriberLib/ Tests/QuickTranscriberTests/LatencyInstrumentationIntegrationTests.swift
git commit -m "feat: instrument ChunkedWhisperEngine pipeline with LatencyInstrumentation"
```

---

## Task 3: Streaming latency harness

**Files:**
- Create: `Tests/QuickTranscriberBenchmarks/StreamingLatencyHarness.swift`
- Test: add cases to existing `ParameterBenchmarkTests.swift` or inline

- [ ] **Step 1: Write the failing test**

Add to `Tests/QuickTranscriberBenchmarks/StreamingLatencyHarnessTests.swift`:

```swift
import XCTest
@testable import QuickTranscriberLib

final class StreamingLatencyHarnessTests: XCTestCase {
    func test_concatWithSilenceGaps_producesExpectedDuration() {
        let u1 = [Float](repeating: 0.1, count: 16_000 * 2)  // 2 s
        let u2 = [Float](repeating: 0.1, count: 16_000 * 3)  // 3 s
        let harness = StreamingLatencyHarness(silenceGapSeconds: 1.2, sampleRate: 16_000)
        let stream = harness.concatenate(utterances: [u1, u2])
        let expected = (2 + 1.2 + 3) * 16_000
        XCTAssertEqual(Double(stream.samples.count), expected, accuracy: 1)
        XCTAssertEqual(stream.utteranceBoundaries.count, 2)
        XCTAssertEqual(stream.utteranceBoundaries[0].endSample, 16_000 * 2)
        XCTAssertEqual(stream.utteranceBoundaries[1].startSample, 16_000 * 2 + Int(1.2 * 16_000))
    }

    func test_computeLatencyPerUtterance_fromInstrumentationRecords() {
        let records: [LatencyRecord] = [
            .init(utteranceId: "u1", stage: .vadConfirmSilence, timestampNanos: 1_000_000_000),
            .init(utteranceId: "u1", stage: .inferenceStart,     timestampNanos: 1_050_000_000),
            .init(utteranceId: "u1", stage: .inferenceEnd,       timestampNanos: 1_450_000_000),
            .init(utteranceId: "u1", stage: .emitToUI,           timestampNanos: 1_480_000_000),
        ]
        let breakdown = StreamingLatencyHarness.perUtteranceLatency(from: records, utteranceId: "u1")
        XCTAssertEqual(breakdown.tInferenceSeconds, 0.4, accuracy: 0.001)
        XCTAssertEqual(breakdown.tEmitSeconds, 0.03, accuracy: 0.001)
        XCTAssertEqual(breakdown.tTotalSeconds, 0.48, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StreamingLatencyHarnessTests`
Expected: FAIL (`StreamingLatencyHarness` not defined).

- [ ] **Step 3: Implement the harness**

Create `Tests/QuickTranscriberBenchmarks/StreamingLatencyHarness.swift`:

```swift
import Foundation
@testable import QuickTranscriberLib

struct StreamingAudioStream {
    let samples: [Float]
    let sampleRate: Int
    let utteranceBoundaries: [UtteranceBoundary]
}

struct UtteranceBoundary {
    let utteranceId: String
    let startSample: Int
    let endSample: Int
}

struct LatencyBreakdown {
    let tVadWaitSeconds: Double
    let tInferenceSeconds: Double
    let tEmitSeconds: Double
    let tTotalSeconds: Double
}

struct StreamingLatencyHarness {
    let silenceGapSeconds: Double
    let sampleRate: Int

    func concatenate(utterances: [[Float]]) -> StreamingAudioStream {
        let gapSamples = Int(silenceGapSeconds * Double(sampleRate))
        var samples: [Float] = []
        var boundaries: [UtteranceBoundary] = []
        for (idx, u) in utterances.enumerated() {
            let start = samples.count
            samples.append(contentsOf: u)
            boundaries.append(UtteranceBoundary(
                utteranceId: "u\(idx)",
                startSample: start,
                endSample: samples.count
            ))
            if idx != utterances.count - 1 {
                samples.append(contentsOf: [Float](repeating: 0.0, count: gapSamples))
            }
        }
        return StreamingAudioStream(samples: samples, sampleRate: sampleRate, utteranceBoundaries: boundaries)
    }

    static func perUtteranceLatency(from records: [LatencyRecord], utteranceId: String) -> LatencyBreakdown {
        let own = records.filter { $0.utteranceId == utteranceId }
        func ns(_ stage: LatencyStage) -> UInt64? { own.first(where: { $0.stage == stage })?.timestampNanos }

        let vadConfirm = ns(.vadConfirmSilence) ?? 0
        let infStart = ns(.inferenceStart) ?? vadConfirm
        let infEnd = ns(.inferenceEnd) ?? infStart
        let emit = ns(.emitToUI) ?? infEnd

        let referenceEnd = ns(.vadOnset) ?? vadConfirm
        let tVadWait = Double(vadConfirm &- referenceEnd) / 1e9
        let tInference = Double(infEnd &- infStart) / 1e9
        let tEmit = Double(emit &- infEnd) / 1e9
        let tTotal = Double(emit &- vadConfirm) / 1e9
        return LatencyBreakdown(
            tVadWaitSeconds: tVadWait,
            tInferenceSeconds: tInference,
            tEmitSeconds: tEmit,
            tTotalSeconds: tTotal
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter StreamingLatencyHarnessTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Tests/QuickTranscriberBenchmarks/StreamingLatencyHarness.swift Tests/QuickTranscriberBenchmarks/StreamingLatencyHarnessTests.swift
git commit -m "feat: add StreamingLatencyHarness for utterance concat and latency breakdown"
```

---

## Task 4: ParameterSweepRunner — manifest parsing

**Files:**
- Create: `Tests/QuickTranscriberBenchmarks/ParameterSweepRunner.swift`
- Test: `Tests/QuickTranscriberBenchmarks/ParameterSweepRunnerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/QuickTranscriberBenchmarks/ParameterSweepRunnerTests.swift`:

```swift
import XCTest
@testable import QuickTranscriberLib

final class ParameterSweepRunnerManifestTests: XCTestCase {
    func test_parseManifest_readsConfigsWithOverrides() throws {
        let json = """
        {
          "stage": 1,
          "outputPath": "/tmp/out.json",
          "configs": [
            {
              "id": "baseline",
              "dataset": "fleurs_en",
              "subsetSeed": 20260424,
              "subsetSize": 100,
              "overrides": {
                "chunkDuration": 8.0,
                "silenceCutoffDuration": 0.6,
                "sampleLength": 224
              }
            },
            {
              "id": "chunkDuration_6",
              "dataset": "fleurs_en",
              "subsetSeed": 20260424,
              "subsetSize": 100,
              "overrides": { "chunkDuration": 6.0 }
            }
          ]
        }
        """
        let manifest = try ParameterSweepRunner.parseManifest(json.data(using: .utf8)!)
        XCTAssertEqual(manifest.stage, 1)
        XCTAssertEqual(manifest.configs.count, 2)
        XCTAssertEqual(manifest.configs[0].id, "baseline")
        XCTAssertEqual(manifest.configs[0].overrides["chunkDuration"]?.doubleValue, 8.0)
        XCTAssertEqual(manifest.configs[1].overrides.count, 1)
    }

    func test_applyOverrides_mutatesTranscriptionParameters() {
        var params = TranscriptionParameters.default
        let overrides: [String: ParameterSweepRunner.Value] = [
            "chunkDuration": .double(10.0),
            "sampleLength": .int(128),
            "concurrentWorkerCount": .int(8)
        ]
        ParameterSweepRunner.apply(overrides: overrides, to: &params)
        XCTAssertEqual(params.chunkDuration, 10.0)
        XCTAssertEqual(params.sampleLength, 128)
        XCTAssertEqual(params.concurrentWorkerCount, 8)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ParameterSweepRunnerManifestTests`
Expected: FAIL (`ParameterSweepRunner` not defined).

- [ ] **Step 3: Implement manifest + apply logic**

Create `Tests/QuickTranscriberBenchmarks/ParameterSweepRunner.swift`:

```swift
import Foundation
@testable import QuickTranscriberLib

struct ParameterSweepRunner {
    struct Manifest: Codable {
        let stage: Int
        let outputPath: String
        let configs: [Config]
    }

    struct Config: Codable {
        let id: String
        let dataset: String
        let subsetSeed: Int
        let subsetSize: Int
        let overrides: [String: Value]
    }

    enum Value: Codable {
        case int(Int)
        case double(Double)
        case string(String)
        case bool(Bool)

        var doubleValue: Double? {
            switch self {
            case .double(let v): return v
            case .int(let v): return Double(v)
            default: return nil
            }
        }
        var intValue: Int? {
            switch self {
            case .int(let v): return v
            case .double(let v): return Int(v)
            default: return nil
            }
        }
        var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
        var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(Bool.self)   { self = .bool(v);   return }
            if let v = try? c.decode(Int.self)    { self = .int(v);    return }
            if let v = try? c.decode(Double.self) { self = .double(v); return }
            if let v = try? c.decode(String.self) { self = .string(v); return }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported value")
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .bool(let v): try c.encode(v)
            case .int(let v): try c.encode(v)
            case .double(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            }
        }
    }

    static func parseManifest(_ data: Data) throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: data)
    }

    static func apply(overrides: [String: Value], to params: inout TranscriptionParameters) {
        for (key, value) in overrides {
            switch key {
            case "chunkDuration":             if let v = value.doubleValue { params.chunkDuration = v }
            case "silenceCutoffDuration":     if let v = value.doubleValue { params.silenceCutoffDuration = v }
            case "silenceEnergyThreshold":    if let v = value.doubleValue { params.silenceEnergyThreshold = Float(v) }
            case "speechOnsetThreshold":      if let v = value.doubleValue { params.speechOnsetThreshold = Float(v) }
            case "preRollDuration":           if let v = value.doubleValue { params.preRollDuration = v }
            case "sampleLength":              if let v = value.intValue    { params.sampleLength = v }
            case "concurrentWorkerCount":     if let v = value.intValue    { params.concurrentWorkerCount = v }
            case "temperatureFallbackCount":  if let v = value.intValue    { params.temperatureFallbackCount = v }
            case "similarityThreshold":       if let v = value.doubleValue { params.similarityThreshold = Float(v) }
            case "speakerTransitionPenalty":  if let v = value.doubleValue { params.speakerTransitionPenalty = v }
            case "diarizationChunkDuration":  if let v = value.doubleValue { params.diarizationChunkDuration = v }
            case "windowDuration":            if let v = value.doubleValue { params.windowDuration = v }
            default:
                fatalError("unknown override key: \(key)")
            }
        }
    }
}
```

Note: the property names above (`similarityThreshold`, `diarizationChunkDuration`, `windowDuration`) may not exist on `TranscriptionParameters` as of today. If compile fails, add them as pass-through properties on `TranscriptionParameters` with appropriate defaults matching the current hard-coded values, and wire them through to `FluidAudioSpeakerDiarizer` / `EmbeddingBasedSpeakerTracker` init. Commit the `TranscriptionParameters` extension as part of this task.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ParameterSweepRunnerManifestTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Tests/QuickTranscriberBenchmarks/ParameterSweepRunner.swift Tests/QuickTranscriberBenchmarks/ParameterSweepRunnerTests.swift Sources/QuickTranscriberLib/
git commit -m "feat: ParameterSweepRunner manifest parser and override applier"
```

---

## Task 5: ParameterSweepRunner — single-run execution and resume

**Files:**
- Modify: `Tests/QuickTranscriberBenchmarks/ParameterSweepRunner.swift`
- Modify: `Tests/QuickTranscriberBenchmarks/ParameterSweepRunnerTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `ParameterSweepRunnerTests.swift`:

```swift
final class ParameterSweepRunnerRunTests: XCTestCase {
    func test_run_writesResultJsonWithOneEntryPerConfig() async throws {
        let tmpPath = "/tmp/test_sweep_\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let manifest = ParameterSweepRunner.Manifest(
            stage: 1,
            outputPath: tmpPath,
            configs: [
                .init(id: "c1", dataset: "fixture_en", subsetSeed: 1, subsetSize: 1, overrides: [:]),
                .init(id: "c2", dataset: "fixture_en", subsetSeed: 1, subsetSize: 1, overrides: ["sampleLength": .int(128)])
            ]
        )

        try await ParameterSweepRunner.run(manifest: manifest, dryRun: true)

        let data = try Data(contentsOf: URL(fileURLWithPath: tmpPath))
        let results = try JSONDecoder().decode([ParameterSweepRunner.RunResult].self, from: data)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(Set(results.map { $0.configId }), ["c1", "c2"])
    }

    func test_run_resumesAndSkipsCompletedConfigs() async throws {
        let tmpPath = "/tmp/test_sweep_resume_\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let existing = [
            ParameterSweepRunner.RunResult(configId: "c1", stage: 1, dataset: "fixture_en",
                                           metrics: ["wer": 0.1], latencyBreakdown: nil, completed: true)
        ]
        try JSONEncoder().encode(existing).write(to: URL(fileURLWithPath: tmpPath))

        let manifest = ParameterSweepRunner.Manifest(
            stage: 1,
            outputPath: tmpPath,
            configs: [
                .init(id: "c1", dataset: "fixture_en", subsetSeed: 1, subsetSize: 1, overrides: [:]),
                .init(id: "c2", dataset: "fixture_en", subsetSeed: 1, subsetSize: 1, overrides: [:])
            ]
        )

        try await ParameterSweepRunner.run(manifest: manifest, dryRun: true)

        let data = try Data(contentsOf: URL(fileURLWithPath: tmpPath))
        let results = try JSONDecoder().decode([ParameterSweepRunner.RunResult].self, from: data)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].metrics["wer"], 0.1)  // c1 result preserved
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ParameterSweepRunnerRunTests`
Expected: FAIL (`run(manifest:dryRun:)` and `RunResult` not defined).

- [ ] **Step 3: Implement run() and RunResult**

Append to `ParameterSweepRunner.swift`:

```swift
extension ParameterSweepRunner {
    struct RunResult: Codable {
        let configId: String
        let stage: Int
        let dataset: String
        let metrics: [String: Double]
        let latencyBreakdown: LatencyAggregate?
        let completed: Bool
    }

    struct LatencyAggregate: Codable {
        let medianTotalSeconds: Double
        let medianInferenceSeconds: Double
        let medianVadWaitSeconds: Double
        let p95TotalSeconds: Double
        let sampleCount: Int
    }

    static func run(manifest: Manifest, dryRun: Bool = false) async throws {
        var existing: [RunResult] = []
        let url = URL(fileURLWithPath: manifest.outputPath)
        if FileManager.default.fileExists(atPath: manifest.outputPath) {
            let data = try Data(contentsOf: url)
            existing = (try? JSONDecoder().decode([RunResult].self, from: data)) ?? []
        }
        let completedIds = Set(existing.filter { $0.completed }.map { $0.configId })

        var results = existing
        for config in manifest.configs {
            if completedIds.contains(config.id) { continue }

            let result: RunResult
            if dryRun {
                result = RunResult(
                    configId: config.id, stage: manifest.stage, dataset: config.dataset,
                    metrics: ["wer": 0.0], latencyBreakdown: nil, completed: true
                )
            } else {
                result = try await executeSingle(config: config, stage: manifest.stage)
            }
            results.append(result)

            // Persist after every config so crashes don't lose progress
            let data = try JSONEncoder().encode(results)
            try data.write(to: url, options: .atomic)
        }
    }

    static func executeSingle(config: Config, stage: Int) async throws -> RunResult {
        // Stage 1 path: transcription-only via BenchmarkTestBase / ChunkedTranscriptionBenchmarkRunner.
        // Stage 2 path: + diarization via DiarizationBenchmarkTests pattern.
        // See Task 6 for the Stage 1 body; Task 11 for the Stage 2 body.
        fatalError("executeSingle: stage body not yet implemented — see Task 6/11")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ParameterSweepRunnerRunTests`
Expected: PASS (dry-run path is sufficient for these tests).

- [ ] **Step 5: Commit**

```bash
git add Tests/QuickTranscriberBenchmarks/ParameterSweepRunner.swift Tests/QuickTranscriberBenchmarks/ParameterSweepRunnerTests.swift
git commit -m "feat: ParameterSweepRunner run loop with resume-on-restart"
```

---

## Task 6: Stage 1 executeSingle — transcription-only runner

**Files:**
- Modify: `Tests/QuickTranscriberBenchmarks/ParameterSweepRunner.swift`
- Test: `Tests/QuickTranscriberBenchmarks/ParameterSweepRunnerStage1Tests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/QuickTranscriberBenchmarks/ParameterSweepRunnerStage1Tests.swift`:

```swift
import XCTest
@testable import QuickTranscriberLib

final class ParameterSweepRunnerStage1Tests: BenchmarkTestBase {
    func test_executeSingle_fleursEn_producesWerAndLatencyMetrics() async throws {
        let datasetRoot = NSString(string: "~/Documents/QuickTranscriber/test-audio/fleurs_en").expandingTildeInPath
        try XCTSkipUnless(FileManager.default.fileExists(atPath: datasetRoot), "fleurs_en dataset not downloaded")

        let config = ParameterSweepRunner.Config(
            id: "stage1_baseline_test",
            dataset: "fleurs_en",
            subsetSeed: 20260424,
            subsetSize: 3,
            overrides: [:]
        )
        let result = try await ParameterSweepRunner.executeSingle(config: config, stage: 1)
        XCTAssertEqual(result.configId, "stage1_baseline_test")
        XCTAssertNotNil(result.metrics["wer"])
        XCTAssertNotNil(result.metrics["rtf"])
        XCTAssertNotNil(result.latencyBreakdown)
        XCTAssertGreaterThan(result.latencyBreakdown!.sampleCount, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ParameterSweepRunnerStage1Tests`
Expected: FAIL with the `fatalError` from the stub in Task 5 (or XCTSkip if dataset absent — in which case skip is acceptable until dataset is present).

- [ ] **Step 3: Implement Stage 1 body**

Replace the `fatalError` in `executeSingle`:

```swift
static func executeSingle(config: Config, stage: Int) async throws -> RunResult {
    var params = TranscriptionParameters.default
    apply(overrides: config.overrides, to: &params)

    LatencyInstrumentation.reset()
    LatencyInstrumentation.isEnabled = true
    defer {
        LatencyInstrumentation.isEnabled = false
        LatencyInstrumentation.reset()
    }

    let loader = DatasetLoader(datasetName: config.dataset)
    let utterances = try loader.loadSubset(seed: config.subsetSeed, size: config.subsetSize)

    let harness = StreamingLatencyHarness(silenceGapSeconds: 1.2, sampleRate: 16_000)
    let audioSamples = utterances.map { $0.audio }
    let stream = harness.concatenate(utterances: audioSamples)

    let runner = try await ChunkedTranscriptionBenchmarkRunner(
        parameters: params,
        language: loader.language
    )
    let transcript = try await runner.run(samples: stream.samples, sampleRate: stream.sampleRate)

    let wer = WERCalculator.compute(
        predicted: transcript.perUtteranceTexts,
        reference: utterances.map { $0.referenceText },
        language: loader.language
    )
    let records = LatencyInstrumentation.drain()

    let breakdowns = stream.utteranceBoundaries.map {
        StreamingLatencyHarness.perUtteranceLatency(from: records, utteranceId: $0.utteranceId)
    }
    let sortedTotal = breakdowns.map { $0.tTotalSeconds }.sorted()
    let sortedInf = breakdowns.map { $0.tInferenceSeconds }.sorted()
    let sortedVad = breakdowns.map { $0.tVadWaitSeconds }.sorted()
    func median(_ s: [Double]) -> Double { s.isEmpty ? 0 : s[s.count / 2] }
    func p95(_ s: [Double]) -> Double { s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * 0.95))] }

    let aggregate = LatencyAggregate(
        medianTotalSeconds: median(sortedTotal),
        medianInferenceSeconds: median(sortedInf),
        medianVadWaitSeconds: median(sortedVad),
        p95TotalSeconds: p95(sortedTotal),
        sampleCount: breakdowns.count
    )

    return RunResult(
        configId: config.id, stage: stage, dataset: config.dataset,
        metrics: [
            "wer": wer,
            "rtf": transcript.realtimeFactor,
            "audioDurationSeconds": transcript.audioDurationSeconds,
            "totalInferenceSeconds": transcript.totalInferenceSeconds
        ],
        latencyBreakdown: aggregate,
        completed: true
    )
}
```

**Reusing existing code.** The following symbols are likely missing from today's codebase with these exact signatures; each is a thin wrapper over already-existing logic, not new work:

- `DatasetLoader` — wraps whatever HF-dataset loader `DatasetBenchmarkTests.swift` currently uses. The only new method is `loadSubset(seed:size:) -> [UtteranceFixture]`, which deterministically samples `size` items with `var rng = SystemRandomNumberGenerator()` seeded from `seed`. Inspect `Tests/QuickTranscriberBenchmarks/DatasetBenchmarkTests.swift` and factor out its reading code.
- `ChunkedTranscriptionBenchmarkRunner.init(parameters:language:)` and `.run(samples:sampleRate:)` — the existing runner already accepts parameters; if its public surface is narrower, add a second init/run overload in the same file that calls through.
- `WERCalculator.compute(predicted:reference:language:)` — the existing code computes WER per fixture inside `BenchmarkResult`. Factor the Levenshtein calculation into a standalone static function; keep the existing callsite delegating to it.

If any single wrapper exceeds ~40 lines, split it out as a dedicated commit within this task before continuing.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ParameterSweepRunnerStage1Tests`
Expected: PASS (or XCTSkip if dataset missing).

- [ ] **Step 5: Commit**

```bash
git add Tests/QuickTranscriberBenchmarks/
git commit -m "feat: Stage 1 executeSingle runs transcription sweep with latency breakdown"
```

---

## Task 7: Resolve historical-baseline commit SHA

**Files:**
- Modify: `docs/superpowers/specs/2026-04-24-parameter-re-evaluation-design.md` (pin the SHA)

- [ ] **Step 1: Identify the churn boundary**

Run:

```bash
git log --oneline --before=2026-04-08 -5 -- \
  Sources/QuickTranscriberLib/Constants.swift \
  Sources/QuickTranscriberLib/EmbeddingBasedSpeakerTracker.swift \
  Sources/QuickTranscriberLib/SpeakerLabelTracker.swift \
  'Sources/QuickTranscriber/Models/TranscriptionParameters.swift'
```

Pick the most-recent commit **before** Apr 8, 2026 on any of those files.

- [ ] **Step 2: Extract parameter values at that commit**

For each of these parameters, run `git show <SHA>:path/to/file | grep -n <param>` and record the value at that commit:

- `speakerTransitionPenalty` default (TranscriptionParameters.swift)
- `similarityThreshold` (EmbeddingBasedSpeakerTracker.swift)
- `stayProbability` default (SpeakerLabelTracker.swift)
- `windowDuration`, `diarizationChunkDuration` (FluidAudioSpeakerDiarizer.swift)

Record any that differ from today's values.

- [ ] **Step 3: Pin the SHA and values in the spec**

Edit `docs/superpowers/specs/2026-04-24-parameter-re-evaluation-design.md` — replace the "(commit SHA to be resolved during Stage 1 setup; candidate: …)" line with the resolved SHA and the parameter-value deltas in a small table.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-04-24-parameter-re-evaluation-design.md
git commit -m "docs: pin historical baseline commit SHA in param-re-eval spec"
```

---

## Task 8: Author Stage 1 manifest

**Files:**
- Create: `Tests/QuickTranscriberBenchmarks/Manifests/stage1.json`

- [ ] **Step 1: Enumerate all 34 configurations**

The manifest must contain exactly these configurations (replicated across all 4 datasets = 136 total runs). Each config has `id`, `dataset`, `subsetSeed: 20260424`, `subsetSize: 100`, and an `overrides` dict.

Baseline (identical to current `TranscriptionParameters.default`):
```
baseline: {chunkDuration: 8.0, silenceCutoffDuration: 0.6, silenceEnergyThreshold: 0.01,
           speechOnsetThreshold: 0.02, preRollDuration: 0.3, sampleLength: 224,
           concurrentWorkerCount: 4, temperatureFallbackCount: 0}
```

OAT variants (each overrides **one** parameter, leaving others at baseline):
- `silenceEnergyThreshold_0.005`, `_0.02`, `_0.05` (3 configs)
- `speechOnsetThreshold_0.05`, `_0.1` (2 configs)
- `preRollDuration_0.2`, `_0.5` (2 configs)
- `temperatureFallbackCount_2` (1 config)

2-way grid `chunkDuration × silenceCutoffDuration` (4×4 = 16 configs, baseline `8.0×0.6` shared with top-level baseline):
- `cd_6.0_sc_0.4`, `cd_6.0_sc_0.6`, `cd_6.0_sc_0.8`, `cd_6.0_sc_1.0`
- `cd_8.0_sc_0.4`, `cd_8.0_sc_0.8`, `cd_8.0_sc_1.0` (cd_8.0_sc_0.6 == baseline)
- `cd_10.0_sc_0.4` … etc.

2-way grid `sampleLength × concurrentWorkerCount` (3×3 = 9 configs, baseline `224 × 4` shared):
- `sl_128_cw_2`, `sl_128_cw_4`, `sl_128_cw_8`
- `sl_192_cw_2`, `sl_192_cw_4`, `sl_192_cw_8`
- `sl_224_cw_2`, `sl_224_cw_8` (sl_224_cw_4 == baseline)

Total: 1 + 8 + 15 + 8 = 32 unique. To reach 34 include the two **historical-baseline** configs if any diverge (from Task 7). If Stage 1 history == Stage 1 current, the count is 32; update the spec's Step 3 count accordingly in a follow-up commit.

- [ ] **Step 2: Write the JSON**

Create `Tests/QuickTranscriberBenchmarks/Manifests/stage1.json`. Produce 4 sub-arrays, one per dataset (`fleurs_en`, `fleurs_ja`, `librispeech_test_other`, `reazonspeech_test`), concatenated into one `configs` array. Each config repeats its id with a `__<dataset>` suffix to remain unique.

Example snippet:
```json
{
  "stage": 1,
  "outputPath": "docs/benchmarks/2026-04-24/stage1_results.json",
  "configs": [
    {
      "id": "baseline__fleurs_en",
      "dataset": "fleurs_en",
      "subsetSeed": 20260424,
      "subsetSize": 100,
      "overrides": {
        "chunkDuration": 8.0,
        "silenceCutoffDuration": 0.6,
        "silenceEnergyThreshold": 0.01,
        "speechOnsetThreshold": 0.02,
        "preRollDuration": 0.3,
        "sampleLength": 224,
        "concurrentWorkerCount": 4,
        "temperatureFallbackCount": 0
      }
    }
    // … remaining 127 entries
  ]
}
```

- [ ] **Step 2b: Register Manifests/ as test-bundle resources**

Edit `Package.swift` — locate the `QuickTranscriberBenchmarks` target definition and add a `resources:` argument (merging with any existing resources):

```swift
.testTarget(
    name: "QuickTranscriberBenchmarks",
    dependencies: [...],
    resources: [.copy("Manifests")]
),
```

Re-run `swift build` to verify the target still compiles.

- [ ] **Step 2c: Generate stage1.json programmatically (optional helper)**

Enumerating 128 entries by hand is error-prone. Write a 50-line helper `Scripts/generate_manifest.py` that emits the JSON from a compact config table. Commit the script along with the manifest so re-generation is reproducible. If the helper takes more than 50 lines, stop and generate the JSON by hand — the goal is correctness, not tooling.

- [ ] **Step 3: Validate manifest with a unit test**

Add to `ParameterSweepRunnerTests.swift`:

```swift
func test_stage1Manifest_isValid() throws {
    let path = Bundle.module.path(forResource: "Manifests/stage1", ofType: "json")!
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let manifest = try ParameterSweepRunner.parseManifest(data)
    XCTAssertEqual(manifest.stage, 1)
    XCTAssertEqual(manifest.configs.count, 128)  // or 136 if historical baselines diverge
    let ids = Set(manifest.configs.map { $0.id })
    XCTAssertEqual(ids.count, manifest.configs.count, "duplicate config ids")
    XCTAssertEqual(Set(manifest.configs.map { $0.dataset }),
                   ["fleurs_en", "fleurs_ja", "librispeech_test_other", "reazonspeech_test"])
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ParameterSweepRunnerTests/test_stage1Manifest_isValid`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Tests/QuickTranscriberBenchmarks/Manifests/stage1.json Tests/QuickTranscriberBenchmarks/ParameterSweepRunnerTests.swift
git commit -m "feat: Stage 1 parameter sweep manifest"
```

---

## Task 9: Execute Stage 1 sweep

**Files:**
- Create: `docs/benchmarks/2026-04-24/stage1_results.json` (output, committed after completion)

- [ ] **Step 1: Precheck datasets are downloaded**

Run:

```bash
ls ~/Documents/QuickTranscriber/test-audio/
```

Confirm presence of `fleurs_en`, `fleurs_ja`, `librispeech_test_other`, `reazonspeech_test`. If missing, run:

```bash
pip3 install 'datasets>=3.0,<4.0' soundfile librosa
python3 Scripts/download_datasets.py
```

- [ ] **Step 2: Precheck Mac is on AC power and background apps quit**

macOS thermal throttling introduces ±20 % noise. On battery this will dominate the signal. Plug in, quit Chrome / Slack / Docker / Xcode Indexing, and run `pmset -g | grep charging` to confirm AC.

- [ ] **Step 3: Kick off Stage 1**

Add a test entry point that runs the manifest:

```swift
// Tests/QuickTranscriberBenchmarks/ParameterSweepRunnerStage1Tests.swift
func test_executeStage1_fullManifest() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_SWEEP"] == "stage1",
                      "Set RUN_SWEEP=stage1 to execute")
    let path = Bundle.module.path(forResource: "Manifests/stage1", ofType: "json")!
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let manifest = try ParameterSweepRunner.parseManifest(data)
    try await ParameterSweepRunner.run(manifest: manifest)
}
```

Run it:

```bash
RUN_SWEEP=stage1 swift test --filter test_executeStage1_fullManifest 2>&1 | tee /tmp/stage1_sweep.log
```

Projected runtime: 6–10 h on Apple Silicon M-series. If interrupted, re-run the same command — the runner resumes.

- [ ] **Step 4: Verify completeness**

After the run, confirm all 128 (or 136) configs completed:

```bash
jq 'length' docs/benchmarks/2026-04-24/stage1_results.json
jq '[.[] | select(.completed == false)] | length' docs/benchmarks/2026-04-24/stage1_results.json
```

Expected: matches manifest count; 0 incomplete.

- [ ] **Step 5: Commit raw results**

```bash
git add docs/benchmarks/2026-04-24/stage1_results.json
git commit -m "chore: Stage 1 parameter sweep raw results"
```

---

## Task 10: Stage 1 analysis script

**Files:**
- Create: `Scripts/analyze_sweep.py`
- Create: `docs/benchmarks/2026-04-24/stage1_report.md`
- Create: `docs/benchmarks/2026-04-24/plots/` (PNG outputs)

- [ ] **Step 1: Write the failing test**

Create `Scripts/tests/test_analyze_sweep.py`:

```python
import json
import tempfile
from pathlib import Path

import pytest
from analyze_sweep import (
    load_results, oat_sensitivity, pareto_frontier,
    weighted_score_stage1, diff_table
)

FIXTURE = [
    {"configId": "baseline", "stage": 1, "dataset": "fleurs_en",
     "metrics": {"wer": 0.10, "rtf": 0.5}, "latencyBreakdown": {"medianTotalSeconds": 1.0}},
    {"configId": "chunkDuration_6.0", "stage": 1, "dataset": "fleurs_en",
     "metrics": {"wer": 0.09, "rtf": 0.5}, "latencyBreakdown": {"medianTotalSeconds": 0.8}},
    {"configId": "chunkDuration_12.0", "stage": 1, "dataset": "fleurs_en",
     "metrics": {"wer": 0.08, "rtf": 0.5}, "latencyBreakdown": {"medianTotalSeconds": 1.4}},
]

def test_load_results_returns_dataframe():
    with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as f:
        json.dump(FIXTURE, f)
        path = f.name
    df = load_results(path)
    assert len(df) == 3
    assert set(df.columns) >= {"configId", "wer", "medianTotalSeconds"}

def test_oat_sensitivity_groups_by_axis():
    df = load_results_from_fixture(FIXTURE)
    curves = oat_sensitivity(df, axis="chunkDuration", baseline_id="baseline")
    assert len(curves) == 3  # baseline + 2 variants
    assert curves[0]["chunkDuration"] == 8.0  # baseline value

def test_pareto_frontier_identifies_dominated_points():
    df = load_results_from_fixture(FIXTURE)
    frontier = pareto_frontier(df, x_col="medianTotalSeconds", y_col="wer")
    assert "chunkDuration_6.0" in frontier["configId"].values
    assert "chunkDuration_12.0" in frontier["configId"].values

def test_weighted_score_stage1():
    df = load_results_from_fixture(FIXTURE)
    scored = weighted_score_stage1(df)
    # 6.0 has best WER and best latency → lowest score
    assert scored.iloc[0]["configId"] == "chunkDuration_6.0"

def test_diff_table_flags_dominated_current():
    df = load_results_from_fixture(FIXTURE)
    table = diff_table(df, current_id="baseline")
    row = table[table["axis"] == "chunkDuration"].iloc[0]
    assert row["recommendation"] in {"adjust", "revert", "keep"}
```

Add this helper at the top of the test file:

```python
def load_results_from_fixture(fixture):
    import tempfile, json
    with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as f:
        json.dump(fixture, f)
        return load_results(f.name)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Scripts && pytest tests/test_analyze_sweep.py -v`
Expected: FAIL (module not yet defined).

- [ ] **Step 3: Implement analyze_sweep.py**

Create `Scripts/analyze_sweep.py`:

```python
#!/usr/bin/env python3
"""Analyze parameter sweep results and generate reports."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import pandas as pd
import matplotlib.pyplot as plt

AXIS_PATTERN = re.compile(r"^(?P<axis>[a-zA-Z]+)_(?P<value>[0-9.]+)(?:__(?P<dataset>.+))?$")

def load_results(path: str | Path) -> pd.DataFrame:
    data = json.loads(Path(path).read_text())
    rows = []
    for r in data:
        row = {
            "configId": r["configId"],
            "stage": r["stage"],
            "dataset": r["dataset"],
            **r.get("metrics", {}),
        }
        lb = r.get("latencyBreakdown") or {}
        row.update({
            "medianTotalSeconds": lb.get("medianTotalSeconds", float("nan")),
            "medianInferenceSeconds": lb.get("medianInferenceSeconds", float("nan")),
            "medianVadWaitSeconds": lb.get("medianVadWaitSeconds", float("nan")),
            "p95TotalSeconds": lb.get("p95TotalSeconds", float("nan")),
        })
        rows.append(row)
    return pd.DataFrame(rows)

def oat_sensitivity(df: pd.DataFrame, axis: str, baseline_id: str) -> pd.DataFrame:
    """Return subset of df where configId is baseline or matches /^{axis}_[0-9.]+/."""
    mask = (df["configId"].str.split("__").str[0] == baseline_id) | \
           (df["configId"].str.split("__").str[0].str.startswith(axis + "_"))
    return df[mask].copy()

def pareto_frontier(df: pd.DataFrame, x_col: str, y_col: str) -> pd.DataFrame:
    """Lower is better on both axes. Return frontier rows only."""
    d = df.sort_values(x_col).reset_index(drop=True)
    best = float("inf")
    keep = []
    for _, row in d.iterrows():
        if row[y_col] < best:
            keep.append(row)
            best = row[y_col]
    return pd.DataFrame(keep)

def weighted_score_stage1(df: pd.DataFrame) -> pd.DataFrame:
    d = df.copy()
    d["wer_norm"] = d["wer"] / d["wer"].max()
    d["latency_norm"] = d["medianTotalSeconds"] / d["medianTotalSeconds"].max()
    d["score"] = 0.5 * d["wer_norm"] + 0.5 * d["latency_norm"]
    return d.sort_values("score").reset_index(drop=True)

def diff_table(df: pd.DataFrame, current_id: str) -> pd.DataFrame:
    scored = weighted_score_stage1(df)
    baseline_score = scored[scored["configId"].str.startswith(current_id)]["score"].iloc[0]
    rows = []
    for axis in ["chunkDuration", "silenceCutoffDuration", "silenceEnergyThreshold",
                 "speechOnsetThreshold", "preRollDuration", "sampleLength",
                 "concurrentWorkerCount", "temperatureFallbackCount"]:
        axis_rows = scored[scored["configId"].str.split("__").str[0].str.startswith(axis + "_")]
        if axis_rows.empty:
            continue
        best_axis = axis_rows.iloc[0]
        delta = baseline_score - best_axis["score"]
        rec = "keep" if delta < 0.01 else ("adjust" if delta < 0.05 else "revert")
        rows.append({
            "axis": axis,
            "current_value": "baseline",
            "best_value": best_axis["configId"].split("__")[0],
            "delta_score": round(delta, 4),
            "recommendation": rec,
        })
    return pd.DataFrame(rows)

def main():
    p = argparse.ArgumentParser()
    p.add_argument("results", help="Path to stageN_results.json")
    p.add_argument("--stage", type=int, required=True)
    p.add_argument("--out-dir", required=True)
    args = p.parse_args()

    df = load_results(args.results)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    plots_dir = out_dir / "plots"
    plots_dir.mkdir(exist_ok=True)

    # Sensitivity curves (one PNG per axis)
    for axis in ["chunkDuration", "silenceCutoffDuration", "sampleLength"]:
        sub = oat_sensitivity(df, axis=axis, baseline_id="baseline")
        if sub.empty:
            continue
        fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(10, 4))
        ax1.plot(sub.index, sub["wer"], marker="o"); ax1.set_title(f"{axis} → WER")
        ax2.plot(sub.index, sub["medianTotalSeconds"], marker="o"); ax2.set_title(f"{axis} → median total latency")
        fig.tight_layout(); fig.savefig(plots_dir / f"sensitivity_{axis}.png"); plt.close(fig)

    # Pareto
    frontier = pareto_frontier(df, "medianTotalSeconds", "wer")
    fig, ax = plt.subplots(figsize=(8, 6))
    ax.scatter(df["medianTotalSeconds"], df["wer"], alpha=0.4, label="all configs")
    ax.plot(frontier["medianTotalSeconds"], frontier["wer"], "r-o", label="Pareto frontier")
    ax.set_xlabel("median total latency (s)"); ax.set_ylabel("WER"); ax.legend()
    fig.tight_layout(); fig.savefig(plots_dir / "pareto.png"); plt.close(fig)

    # Diff table
    table = diff_table(df, current_id="baseline")
    (out_dir / f"stage{args.stage}_diff_table.md").write_text(table.to_markdown(index=False))

    # Three-axis leaderboard
    leaderboard = weighted_score_stage1(df).head(10)
    (out_dir / f"stage{args.stage}_leaderboard.md").write_text(
        leaderboard[["configId", "wer", "medianTotalSeconds", "score"]].to_markdown(index=False)
    )

    print(f"Wrote plots and tables to {out_dir}")

if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Scripts && pytest tests/test_analyze_sweep.py -v`
Expected: all 5 tests PASS.

- [ ] **Step 5: Produce Stage 1 artifacts**

```bash
python3 Scripts/analyze_sweep.py docs/benchmarks/2026-04-24/stage1_results.json \
  --stage 1 --out-dir docs/benchmarks/2026-04-24/
```

- [ ] **Step 6: Write Stage 1 narrative report**

Create `docs/benchmarks/2026-04-24/stage1_report.md` with these sections:

1. **Summary** — one paragraph: which axes turned out non-monotonic, which matched the current baseline, which dominated the baseline.
2. **Per-axis findings** — embed each sensitivity plot and interpret it in 2–4 sentences.
3. **Pareto frontier** — embed the plot, list the frontier configurations, mark current baseline and historical baseline.
4. **Diff table** — embedded markdown table from `stage1_diff_table.md`.
5. **Top-10 leaderboard** — embedded from `stage1_leaderboard.md`.
6. **Stage 1 winner selection** — explicit statement of the configuration chosen for Stage 2, with justification.
7. **Anomalies / concerns** — e.g. noisy runs, thermal-throttling-suspect measurements.

- [ ] **Step 7: Commit**

```bash
git add Scripts/analyze_sweep.py Scripts/tests/test_analyze_sweep.py \
        docs/benchmarks/2026-04-24/stage1_report.md \
        docs/benchmarks/2026-04-24/stage1_diff_table.md \
        docs/benchmarks/2026-04-24/stage1_leaderboard.md \
        docs/benchmarks/2026-04-24/plots/
git commit -m "analysis: Stage 1 sensitivity, Pareto, and diff table"
```

---

## Task 11: Stage 2 executeSingle — + diarization runner

**Files:**
- Modify: `Tests/QuickTranscriberBenchmarks/ParameterSweepRunner.swift`
- Test: `Tests/QuickTranscriberBenchmarks/ParameterSweepRunnerStage2Tests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/QuickTranscriberBenchmarks/ParameterSweepRunnerStage2Tests.swift`:

```swift
import XCTest
@testable import QuickTranscriberLib

final class ParameterSweepRunnerStage2Tests: BenchmarkTestBase {
    func test_executeSingle_callhomeEn_producesDerAndLatencyMetrics() async throws {
        let datasetRoot = NSString(string: "~/Documents/QuickTranscriber/test-audio/callhome_en").expandingTildeInPath
        try XCTSkipUnless(FileManager.default.fileExists(atPath: datasetRoot), "callhome_en dataset not downloaded")

        let config = ParameterSweepRunner.Config(
            id: "stage2_baseline_test",
            dataset: "callhome_en",
            subsetSeed: 20260424,
            subsetSize: 2,
            overrides: [:]
        )
        let result = try await ParameterSweepRunner.executeSingle(config: config, stage: 2)
        XCTAssertEqual(result.configId, "stage2_baseline_test")
        XCTAssertNotNil(result.metrics["der"])
        XCTAssertNotNil(result.metrics["chunkAccuracy"])
        XCTAssertNotNil(result.metrics["labelFlips"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ParameterSweepRunnerStage2Tests`
Expected: FAIL (stage 2 not routed in `executeSingle`, or current impl returns no `der`).

- [ ] **Step 3: Add Stage 2 branch in executeSingle**

Wrap the existing Stage 1 body in `if stage == 1 { … } else if stage == 2 { … }`. Implement Stage 2:

```swift
if stage == 2 {
    var params = TranscriptionParameters.default
    apply(overrides: config.overrides, to: &params)
    params.enableSpeakerDiarization = true
    params.diarizationMode = .auto

    LatencyInstrumentation.reset()
    LatencyInstrumentation.isEnabled = true
    defer {
        LatencyInstrumentation.isEnabled = false
        LatencyInstrumentation.reset()
    }

    let loader = DiarizationDatasetLoader(datasetName: config.dataset)
    let conversations = try loader.loadSubset(seed: config.subsetSeed, size: config.subsetSize)

    var allDerValues: [Double] = []
    var allChunkAccuracy: [Double] = []
    var allLabelFlips: [Int] = []
    var allSpeakerCountAbsErr: [Int] = []
    var allDiarizeLatencies: [Double] = []

    for convo in conversations {
        let diarizer = FluidAudioSpeakerDiarizer(
            similarityThreshold: params.similarityThreshold,
            windowDuration: params.windowDuration,
            chunkDuration: params.diarizationChunkDuration
        )
        let transcribeRunner = try await ChunkedTranscriptionBenchmarkRunner(
            parameters: params, language: loader.language
        )
        let result = try await transcribeRunner.runWithDiarization(
            samples: convo.audio, sampleRate: 16_000, diarizer: diarizer,
            groundTruth: convo.groundTruthLabels
        )
        let metrics = DiarizationMetrics.compute(
            groundTruth: result.groundTruthLabels,
            predicted: result.predictedLabels
        )
        allDerValues.append(metrics.der)
        allChunkAccuracy.append(metrics.chunkAccuracy)
        allLabelFlips.append(metrics.labelFlips)
        allSpeakerCountAbsErr.append(abs(result.predictedSpeakerCount - convo.groundTruthSpeakerCount))
        allDiarizeLatencies.append(contentsOf: result.perChunkDiarizeSeconds)
    }

    func mean(_ a: [Double]) -> Double { a.reduce(0, +) / Double(max(a.count, 1)) }
    func mean_i(_ a: [Int]) -> Double { Double(a.reduce(0, +)) / Double(max(a.count, 1)) }
    let sortedLat = allDiarizeLatencies.sorted()

    return RunResult(
        configId: config.id, stage: 2, dataset: config.dataset,
        metrics: [
            "der": mean(allDerValues),
            "chunkAccuracy": mean(allChunkAccuracy),
            "labelFlips": mean_i(allLabelFlips),
            "speakerCountMAE": mean_i(allSpeakerCountAbsErr)
        ],
        latencyBreakdown: LatencyAggregate(
            medianTotalSeconds: 0,
            medianInferenceSeconds: 0,
            medianVadWaitSeconds: 0,
            p95TotalSeconds: sortedLat.isEmpty ? 0 : sortedLat[min(sortedLat.count - 1, Int(Double(sortedLat.count) * 0.95))],
            sampleCount: allDiarizeLatencies.count
        ),
        completed: true
    )
}
```

If `ChunkedTranscriptionBenchmarkRunner.runWithDiarization(...)`, `DiarizationDatasetLoader`, or `DiarizationMetrics.compute(...)` do not exist with these signatures, add thin wrappers — do not duplicate the existing diarization benchmark loop. See `Tests/QuickTranscriberBenchmarks/DiarizationBenchmarkTests.swift` lines 125–220 for the reference loop to wrap.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ParameterSweepRunnerStage2Tests`
Expected: PASS (or XCTSkip if dataset missing).

- [ ] **Step 5: Commit**

```bash
git add Tests/QuickTranscriberBenchmarks/
git commit -m "feat: Stage 2 executeSingle runs diarization sweep"
```

---

## Task 12: Author Stage 2 manifest (uses Stage 1 winner)

**Files:**
- Create: `Tests/QuickTranscriberBenchmarks/Manifests/stage2.json`

- [ ] **Step 1: Extract Stage 1 winner overrides**

From `docs/benchmarks/2026-04-24/stage1_report.md` (written in Task 10), read the "Stage 1 winner selection" section. Record the winning parameter values; these become the **fixed prefix** applied to every Stage 2 config.

If Stage 1 identified a top-1 and top-2 within 2 % of each other, both prefixes go into Stage 2 (Stage 2 manifest doubles to 48 configs × 3 datasets = 144 runs). Otherwise one prefix → 24 × 3 = 72 runs.

- [ ] **Step 2: Enumerate Stage 2 configurations**

Baseline (Stage 1 winner overrides + diarization defaults):
```
similarityThreshold: 0.5, speakerTransitionPenalty: 0.8,
diarizationChunkDuration: 7.0, windowDuration: 15.0,
profileStrategy: "none"
```

OAT variants:
- `diarizationChunkDuration_3.0`, `_5.0`, `_10.0` (3 configs)
- `windowDuration_10.0`, `_20.0` (2 configs)
- `profileStrategy_culling`, `_merging` (2 configs)

2-way grid `similarityThreshold × speakerTransitionPenalty` (4 × 4 = 16 configs, baseline `0.5 × 0.8` shared):
- All 16 pairs of {0.4, 0.5, 0.6, 0.7} × {0.7, 0.8, 0.9, 0.95}

Total: 1 + 7 + 15 = 23. Include historical baseline for `speakerTransitionPenalty = 0.9` as an explicit named config if not already in the 2-way grid → it already is. Total = **23 configs × 3 datasets = 69 runs** (not 72 — update spec accordingly in a follow-up docs commit).

- [ ] **Step 3: Write stage2.json and validate**

Mirror the structure of stage1.json. Add a unit-test assertion:

```swift
func test_stage2Manifest_isValid() throws {
    let path = Bundle.module.path(forResource: "Manifests/stage2", ofType: "json")!
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let manifest = try ParameterSweepRunner.parseManifest(data)
    XCTAssertEqual(manifest.stage, 2)
    XCTAssertEqual(manifest.configs.count, 69)  // or 138 if dual prefix
    XCTAssertEqual(Set(manifest.configs.map { $0.dataset }), ["callhome_en", "callhome_ja", "ami"])
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ParameterSweepRunnerTests/test_stage2Manifest_isValid`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Tests/QuickTranscriberBenchmarks/Manifests/stage2.json \
        Tests/QuickTranscriberBenchmarks/ParameterSweepRunnerTests.swift
git commit -m "feat: Stage 2 parameter sweep manifest"
```

---

## Task 13: Execute Stage 2 sweep and analyze

**Files:**
- Create: `docs/benchmarks/2026-04-24/stage2_results.json`
- Create: `docs/benchmarks/2026-04-24/stage2_report.md`

- [ ] **Step 1: Precheck diarization datasets are downloaded**

```bash
ls ~/Documents/QuickTranscriber/test-audio/{callhome_en,callhome_ja,ami}
```

If missing, re-run `python3 Scripts/download_datasets.py` (it downloads all 7 datasets).

- [ ] **Step 2: AC power + quit background apps** (same precheck as Task 9 Step 2).

- [ ] **Step 3: Kick off Stage 2**

Add a test entry point analogous to Task 9:

```swift
func test_executeStage2_fullManifest() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_SWEEP"] == "stage2",
                      "Set RUN_SWEEP=stage2 to execute")
    let path = Bundle.module.path(forResource: "Manifests/stage2", ofType: "json")!
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let manifest = try ParameterSweepRunner.parseManifest(data)
    try await ParameterSweepRunner.run(manifest: manifest)
}
```

Run:

```bash
RUN_SWEEP=stage2 swift test --filter test_executeStage2_fullManifest 2>&1 | tee /tmp/stage2_sweep.log
```

Projected runtime: 4–6 h.

- [ ] **Step 4: Verify completeness**

```bash
jq 'length' docs/benchmarks/2026-04-24/stage2_results.json
jq '[.[] | select(.completed == false)] | length' docs/benchmarks/2026-04-24/stage2_results.json
```

- [ ] **Step 5: Extend analyze_sweep.py for Stage 2**

Add a `weighted_score_stage2` function (0.4·WER + 0.3·DER + 0.3·latency). For Stage 2, WER comes from concatenating Stage 1 winner results with Stage 2 DER measurement — use the Stage 1 winner's WER as a **constant** added to every Stage 2 row (since WER does not vary in Stage 2). TDD with a fixture of 3 Stage 2 rows; add to `Scripts/tests/test_analyze_sweep.py`.

Then run:

```bash
python3 Scripts/analyze_sweep.py docs/benchmarks/2026-04-24/stage2_results.json \
  --stage 2 --out-dir docs/benchmarks/2026-04-24/
```

- [ ] **Step 6: Write Stage 2 narrative report**

Create `docs/benchmarks/2026-04-24/stage2_report.md` with the same seven sections as Stage 1, adapted to DER / chunk-accuracy / label-flips axes.

Pay special attention to: did the historical `speakerTransitionPenalty = 0.9` Pareto-dominate the current `0.8`? If yes, that is the headline finding.

- [ ] **Step 7: Commit**

```bash
git add docs/benchmarks/2026-04-24/stage2_results.json \
        docs/benchmarks/2026-04-24/stage2_report.md \
        docs/benchmarks/2026-04-24/stage2_diff_table.md \
        docs/benchmarks/2026-04-24/stage2_leaderboard.md \
        docs/benchmarks/2026-04-24/plots/
git commit -m "analysis: Stage 2 DER sensitivity and diff table"
```

---

## Task 14: Full-dataset validation of top-5 recommendations

**Files:**
- Create: `Tests/QuickTranscriberBenchmarks/Manifests/validation.json`
- Create: `docs/benchmarks/2026-04-24/validation_results.json`

- [ ] **Step 1: Identify top-5 end-to-end configurations**

Cross-reference Stage 1 leaderboard and Stage 2 leaderboard. The end-to-end configuration is `(Stage 1 winner overrides) + (Stage 2 winner overrides per row)`. Take the top 5 Stage 2 rows by weighted_score_stage2; each combined with the Stage 1 winner gives one candidate config.

- [ ] **Step 2: Write validation manifest**

Create `validation.json` with these 5 configs, each run against **all** utterances / conversations (no subset) in the relevant datasets. Use `subsetSize: -1` (interpret `-1` as "full dataset" in `DatasetLoader.loadSubset`).

- [ ] **Step 3: Add the full-dataset branch**

Modify `DatasetLoader.loadSubset` and `DiarizationDatasetLoader.loadSubset`: if `size < 0`, return everything. Add a unit test confirming the full corpus is returned.

- [ ] **Step 4: Run validation**

```bash
RUN_SWEEP=validation swift test --filter test_executeValidation_fullDatasets 2>&1 | tee /tmp/validation.log
```

Projected runtime: 2–4 h (5 configs, ~700 utterances + ~116 conversations).

- [ ] **Step 5: Confirm ranking stability**

Run:

```bash
python3 Scripts/analyze_sweep.py docs/benchmarks/2026-04-24/validation_results.json \
  --stage validation --out-dir docs/benchmarks/2026-04-24/
```

The leaderboard ordering on the full datasets should be consistent with the subset ordering (top-1 should remain top-1). If it is not, report which configs swapped and by how much.

- [ ] **Step 6: Commit**

```bash
git add Tests/QuickTranscriberBenchmarks/Manifests/validation.json \
        docs/benchmarks/2026-04-24/validation_results.json \
        docs/benchmarks/2026-04-24/validation_leaderboard.md
git commit -m "analysis: full-dataset validation of top-5 configurations"
```

---

## Task 15: Final recommendation synthesis

**Files:**
- Create: `docs/benchmarks/2026-04-24/final_recommendation.md`

- [ ] **Step 1: Draft the recommendation**

Create `docs/benchmarks/2026-04-24/final_recommendation.md` with these sections:

1. **Bottom line** — a single table: parameter / current value / recommended value / direction (keep / adjust / revert) / quantified effect (ΔWER / ΔDER / Δlatency in %).
2. **Evidence** — links to Stage 1 and Stage 2 reports and plots. For each recommended change, one sentence citing which figure supports it.
3. **Sensitivity & robustness** — which recommended values survived the full-dataset validation; which did not, and what was the swap.
4. **Open items** — parameters that the sweep could not conclude on (noisy, non-monotonic, dataset-specific). List them explicitly so they are not silently ignored.
5. **Out-of-scope reminder** — Manual-mode real-session validation is deferred per spec; recommendations for `userCorrectionConfidence`, `sessionLearningAlphaMax`, `tieBreakerEpsilon` are NOT made here.

- [ ] **Step 2: Cross-check against the spec's Success Criteria**

Open `docs/superpowers/specs/2026-04-24-parameter-re-evaluation-design.md` → `## Success Criteria`. For each bullet, verify the report satisfies it. If any bullet is not satisfied, either fix the report or add an "unmet criterion" entry to the "Open items" section with justification.

- [ ] **Step 3: Commit and notify user**

```bash
git add docs/benchmarks/2026-04-24/final_recommendation.md
git commit -m "docs: final parameter-re-evaluation recommendation"
```

Then summarize the outcome to the user in-chat: bottom-line table + link to the full report. Do NOT apply recommended parameter changes to the codebase in this plan — applying them is a separate decision the user will make after reading the recommendation.
