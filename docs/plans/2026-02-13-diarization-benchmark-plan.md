# Speaker Diarization Benchmark Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** CALLHOME EN/JAデータセットを使ったストリーミング話者特定の自動テストとパラメータチューニング基盤を構築する

**Architecture:** Pythonスクリプトでデータセット取得 → Swiftベンチマークテストで3秒チャンクシミュレーション → ハンガリアンアルゴリズムでラベルマッチング → パラメータバリエーションテスト

**Tech Stack:** Python (datasets, soundfile) / Swift (XCTest, FluidAudio, QuickTranscriberLib)

---

### Task 1: CALLHOME データセットダウンロードスクリプト

**Files:**
- Modify: `Scripts/download_datasets.py`

**Step 1: download_datasets.py にCALLHOME EN/JAダウンロード関数を追加**

CALLHOMEデータセットの構造:
- HuggingFace: `talkbank/callhome` の `eng` / `jpn` config、split名は `"data"`
- 1行 = 1会話全体（音声配列 + timestamps_start/timestamps_end/speakers の並列配列）
- 話者ラベルは `A`, `B` 等
- 16kHz音声
- gatedデータセット（HuggingFace認証が必要、`huggingface-cli login` で事前ログイン）

`Scripts/download_datasets.py` の末尾（`if __name__` の前）に以下の2関数を追加:

```python
def download_callhome_en(out_dir):
    """CALLHOME English diarization dataset (50 conversations)."""
    from datasets import load_dataset
    print("  Loading CALLHOME English (talkbank/callhome eng)...")
    ds = load_dataset("talkbank/callhome", "eng", split="data", trust_remote_code=True)
    print(f"  Loaded {len(ds)} conversations")

    random.seed(42)
    indices = random.sample(range(len(ds)), min(50, len(ds)))

    save_diarization_data(ds, sorted(indices), out_dir, "en")


def download_callhome_ja(out_dir):
    """CALLHOME Japanese diarization dataset (50 conversations)."""
    from datasets import load_dataset
    print("  Loading CALLHOME Japanese (talkbank/callhome jpn)...")
    ds = load_dataset("talkbank/callhome", "jpn", split="data", trust_remote_code=True)
    print(f"  Loaded {len(ds)} conversations")

    random.seed(42)
    indices = random.sample(range(len(ds)), min(50, len(ds)))

    save_diarization_data(ds, sorted(indices), out_dir, "ja")
```

`save_audio_and_refs` 関数の後に、ダイアライゼーション用の保存関数を追加:

```python
def save_diarization_data(ds, indices, out_dir, lang):
    """Save diarization audio and speaker-annotated references."""
    import soundfile as sf
    os.makedirs(out_dir, exist_ok=True)
    references = {}
    prefix = f"{lang}_"

    for i, idx in enumerate(indices):
        item = ds[idx]
        audio = item["audio"]
        fname = f"{prefix}{i:04d}"
        wav_path = os.path.join(out_dir, f"{fname}.wav")

        sf.write(wav_path, audio["array"], audio["sampling_rate"])

        duration = len(audio["array"]) / audio["sampling_rate"]
        segments = []
        for start, end, speaker in zip(
            item["timestamps_start"],
            item["timestamps_end"],
            item["speakers"],
        ):
            segments.append({
                "start": round(start, 3),
                "end": round(end, 3),
                "speaker": speaker,
            })

        speakers = list(set(item["speakers"]))
        references[fname] = {
            "language": lang,
            "duration_seconds": round(duration, 2),
            "speakers": len(speakers),
            "segments": segments,
        }

    refs_path = os.path.join(out_dir, "references.json")
    with open(refs_path, "w", encoding="utf-8") as f:
        json.dump(references, f, ensure_ascii=False, indent=2)

    total_dur = sum(r["duration_seconds"] for r in references.values())
    print(f"  Saved {len(references)} conversations, total {total_dur:.1f}s ({total_dur/60:.1f}min)")
    print(f"  Output: {out_dir}")
```

`main()` の `tasks` リストに追加:

```python
    tasks = [
        ("fleurs_en", download_fleurs_en),
        ("fleurs_ja", download_fleurs_ja),
        ("librispeech_test_other", download_librispeech_test_other),
        ("reazonspeech_test", download_reazonspeech_test),
        ("callhome_en", download_callhome_en),
        ("callhome_ja", download_callhome_ja),
    ]
```

docstringも更新（先頭のコメント）:

```python
"""Download and prepare speech recognition evaluation datasets.

Datasets:
  - FLEURS en_us + ja_jp (minimal, ~350 utterances each)
  - LibriSpeech test-other (standard, ~200 utterances subset)
  - ReazonSpeech test (standard, ~200 utterances subset)
  - CALLHOME en + ja (diarization, ~50 conversations each)

Output: ~/Documents/QuickTranscriber/test-audio/<dataset_name>/
  Each directory contains WAV files + references.json
"""
```

**Step 2: スクリプト実行してデータセットダウンロード**

```bash
# HuggingFace認証（gatedデータセットのため必要）
huggingface-cli login

# ダウンロード実行
python3 Scripts/download_datasets.py callhome_en callhome_ja
```

Expected: `~/Documents/QuickTranscriber/test-audio/callhome_en/` と `callhome_ja/` に各50会話のWAVファイルとreferences.jsonが生成される。

**Step 3: ダウンロード結果を確認**

```bash
ls ~/Documents/QuickTranscriber/test-audio/callhome_en/ | head -5
python3 -c "import json; d=json.load(open('$HOME/Documents/QuickTranscriber/test-audio/callhome_en/references.json')); k=list(d.keys())[0]; print(k, d[k]['speakers'], len(d[k]['segments']), 'segments')"
```

Expected: WAVファイルが50個、references.jsonに話者セグメント情報が含まれる。

**Step 4: コミット**

```bash
git add Scripts/download_datasets.py
git commit -m "feat: add CALLHOME EN/JA diarization dataset download"
```

---

### Task 2: ハンガリアンアルゴリズムとDiarizationMetrics

**Files:**
- Create: `Sources/QuickTranscriberLib/Benchmark/HungarianAlgorithm.swift`
- Create: `Sources/QuickTranscriberLib/Benchmark/DiarizationMetrics.swift`
- Test: `Tests/QuickTranscriberTests/HungarianAlgorithmTests.swift`
- Test: `Tests/QuickTranscriberTests/DiarizationMetricsTests.swift`

**注意:** これらはベンチマーク専用のユーティリティだが、`QuickTranscriberLib` に配置する（ベンチマークテストターゲットから参照するため `@testable import` 不要にする）。

**Step 1: ハンガリアンアルゴリズムのテストを書く**

`Tests/QuickTranscriberTests/HungarianAlgorithmTests.swift`:

```swift
import XCTest
@testable import QuickTranscriberLib

final class HungarianAlgorithmTests: XCTestCase {

    func testTwoByTwoPerfectMatch() {
        // Cost matrix: assigning 0→0 and 1→1 costs 0+0=0
        let cost: [[Int]] = [
            [0, 10],
            [10, 0],
        ]
        let assignment = HungarianAlgorithm.solve(cost)
        XCTAssertEqual(assignment, [0, 1])
    }

    func testTwoByTwoSwapped() {
        // Assigning 0→1 and 1→0 is cheaper (1+1=2 vs 10+10=20)
        let cost: [[Int]] = [
            [10, 1],
            [1, 10],
        ]
        let assignment = HungarianAlgorithm.solve(cost)
        XCTAssertEqual(assignment, [1, 0])
    }

    func testThreeByThree() {
        let cost: [[Int]] = [
            [1, 2, 3],
            [2, 4, 6],
            [3, 6, 9],
        ]
        let assignment = HungarianAlgorithm.solve(cost)
        // Total cost should be minimized
        let totalCost = assignment.enumerated().map { cost[$0.offset][$0.element] }.reduce(0, +)
        // Optimal: 0→0(1) + 1→1(4) + 2→2(9) = 14 or other combos
        // Actually: 0→2(3) + 1→1(4) + 2→0(3) = 10
        XCTAssertEqual(totalCost, 10)
    }

    func testSingleElement() {
        let cost: [[Int]] = [[5]]
        let assignment = HungarianAlgorithm.solve(cost)
        XCTAssertEqual(assignment, [0])
    }

    func testEmpty() {
        let cost: [[Int]] = []
        let assignment = HungarianAlgorithm.solve(cost)
        XCTAssertEqual(assignment, [])
    }
}
```

**Step 2: テスト実行してFAILを確認**

```bash
swift test --filter HungarianAlgorithmTests 2>&1 | tail -5
```

Expected: コンパイルエラー（`HungarianAlgorithm` が存在しない）

**Step 3: ハンガリアンアルゴリズム実装**

`Sources/QuickTranscriberLib/Benchmark/HungarianAlgorithm.swift`:

```swift
import Foundation

/// Solves the assignment problem using the Hungarian algorithm.
/// Given an NxN cost matrix, returns an array where result[i] = column assigned to row i.
public enum HungarianAlgorithm {

    /// Solve the assignment problem. Returns assignment[row] = col for each row.
    /// Cost matrix must be square. Returns empty array for empty input.
    public static func solve(_ costMatrix: [[Int]]) -> [Int] {
        let n = costMatrix.count
        guard n > 0 else { return [] }
        guard costMatrix.allSatisfy({ $0.count == n }) else { return [] }

        // Kuhn-Munkres (Hungarian) algorithm - O(n^3)
        let INF = Int.max / 2
        // We use 1-indexed arrays for convenience
        var u = Array(repeating: 0, count: n + 1)
        var v = Array(repeating: 0, count: n + 1)
        var p = Array(repeating: 0, count: n + 1)  // p[j] = row assigned to col j
        var way = Array(repeating: 0, count: n + 1)

        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = Array(repeating: INF, count: n + 1)
            var used = Array(repeating: false, count: n + 1)

            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = INF
                var j1 = 0

                for j in 1...n {
                    if !used[j] {
                        let cur = costMatrix[i0 - 1][j - 1] - u[i0] - v[j]
                        if cur < minv[j] {
                            minv[j] = cur
                            way[j] = j0
                        }
                        if minv[j] < delta {
                            delta = minv[j]
                            j1 = j
                        }
                    }
                }

                for j in 0...n {
                    if used[j] {
                        u[p[j]] += delta
                        v[j] -= delta
                    } else {
                        minv[j] -= delta
                    }
                }

                j0 = j1
            } while p[j0] != 0

            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }

        // Convert to result: assignment[row] = col (0-indexed)
        var result = Array(repeating: 0, count: n)
        for j in 1...n {
            result[p[j] - 1] = j - 1
        }
        return result
    }
}
```

**Step 4: テスト実行してPASSを確認**

```bash
swift test --filter HungarianAlgorithmTests 2>&1 | tail -10
```

Expected: All tests pass.

**Step 5: DiarizationMetricsのテストを書く**

`Tests/QuickTranscriberTests/DiarizationMetricsTests.swift`:

```swift
import XCTest
@testable import QuickTranscriberLib

final class DiarizationMetricsTests: XCTestCase {

    func testPerfectPrediction() {
        // Ground truth: 5 chunks of A, 5 chunks of B
        let groundTruth = Array(repeating: "A", count: 5) + Array(repeating: "B", count: 5)
        // Prediction matches perfectly (may use different labels)
        let predicted = Array(repeating: "X", count: 5) + Array(repeating: "Y", count: 5)

        let metrics = DiarizationMetrics.compute(
            groundTruth: groundTruth,
            predicted: predicted
        )

        XCTAssertEqual(metrics.chunkAccuracy, 1.0)
        XCTAssertEqual(metrics.speakerCountCorrect, true)
    }

    func testSwappedLabels() {
        // Hungarian should handle label swapping
        let groundTruth = ["A", "A", "B", "B"]
        let predicted = ["B", "B", "A", "A"]  // Labels swapped but pattern correct

        let metrics = DiarizationMetrics.compute(
            groundTruth: groundTruth,
            predicted: predicted
        )

        XCTAssertEqual(metrics.chunkAccuracy, 1.0)
    }

    func testHalfWrong() {
        let groundTruth = ["A", "A", "B", "B"]
        let predicted = ["X", "X", "X", "Y"]  // First two correct, third wrong

        let metrics = DiarizationMetrics.compute(
            groundTruth: groundTruth,
            predicted: predicted
        )

        XCTAssertEqual(metrics.chunkAccuracy, 0.75)
    }

    func testLabelStability() {
        // Same speaker talks 5 times, but label flips: A, B, A, B, A
        let groundTruth = Array(repeating: "SPK1", count: 5)
        let predicted = ["A", "B", "A", "B", "A"]

        let metrics = DiarizationMetrics.compute(
            groundTruth: groundTruth,
            predicted: predicted
        )

        // Best mapping: SPK1→A (3 correct out of 5)
        XCTAssertEqual(metrics.chunkAccuracy, 0.6)
        XCTAssertEqual(metrics.labelFlips, 4)  // 4 transitions in predicted
    }

    func testNilPredictions() {
        // nil predictions (pending speaker) treated as incorrect
        let groundTruth = ["A", "A", "B"]
        let predicted: [String?] = [nil, "X", "Y"]

        let metrics = DiarizationMetrics.compute(
            groundTruth: groundTruth,
            predicted: predicted.map { $0 ?? "__nil__" }
        )

        // nil→mapped to __nil__ which won't match anything well
        XCTAssertLessThan(metrics.chunkAccuracy, 1.0)
    }

    func testSpeakerCountDetection() {
        let groundTruth = ["A", "B", "C"]
        let predicted = ["X", "Y", "X"]  // Detected 2 speakers, actual 3

        let metrics = DiarizationMetrics.compute(
            groundTruth: groundTruth,
            predicted: predicted
        )

        XCTAssertEqual(metrics.speakerCountCorrect, false)
        XCTAssertEqual(metrics.detectedSpeakerCount, 2)
        XCTAssertEqual(metrics.actualSpeakerCount, 3)
    }
}
```

**Step 6: テスト実行してFAILを確認**

```bash
swift test --filter DiarizationMetricsTests 2>&1 | tail -5
```

**Step 7: DiarizationMetrics実装**

`Sources/QuickTranscriberLib/Benchmark/DiarizationMetrics.swift`:

```swift
import Foundation

/// Results of diarization evaluation for a single conversation.
public struct DiarizationMetrics: Codable, Sendable {
    /// Fraction of chunks where predicted speaker matches ground truth (after optimal label mapping)
    public let chunkAccuracy: Double
    /// Whether the detected number of speakers matches the actual number
    public let speakerCountCorrect: Bool
    /// Number of detected speakers
    public let detectedSpeakerCount: Int
    /// Number of actual speakers
    public let actualSpeakerCount: Int
    /// Number of label changes in the predicted sequence
    public let labelFlips: Int

    /// Compute diarization metrics using Hungarian algorithm for optimal label mapping.
    ///
    /// - Parameters:
    ///   - groundTruth: Array of ground-truth speaker labels, one per chunk
    ///   - predicted: Array of predicted speaker labels, one per chunk (same length)
    /// - Returns: Computed metrics
    public static func compute(
        groundTruth: [String],
        predicted: [String]
    ) -> DiarizationMetrics {
        precondition(groundTruth.count == predicted.count)
        let n = groundTruth.count
        guard n > 0 else {
            return DiarizationMetrics(
                chunkAccuracy: 1.0, speakerCountCorrect: true,
                detectedSpeakerCount: 0, actualSpeakerCount: 0, labelFlips: 0
            )
        }

        let gtLabels = Array(Set(groundTruth)).sorted()
        let predLabels = Array(Set(predicted)).sorted()

        // Build confusion matrix: cost[gtIdx][predIdx] = -count of co-occurrences
        // (negative because Hungarian minimizes, we want to maximize matches)
        let size = max(gtLabels.count, predLabels.count)
        var cost = Array(repeating: Array(repeating: 0, count: size), count: size)

        for i in 0..<n {
            if let gtIdx = gtLabels.firstIndex(of: groundTruth[i]),
               let predIdx = predLabels.firstIndex(of: predicted[i]) {
                cost[gtIdx][predIdx] -= 1  // Negative = more matches = lower cost
            }
        }

        let assignment = HungarianAlgorithm.solve(cost)

        // Build mapping: predicted label → ground truth label
        var predToGt: [String: String] = [:]
        for (gtIdx, predIdx) in assignment.enumerated() {
            if gtIdx < gtLabels.count && predIdx < predLabels.count {
                predToGt[predLabels[predIdx]] = gtLabels[gtIdx]
            }
        }

        // Compute chunk accuracy using optimal mapping
        var correct = 0
        for i in 0..<n {
            if predToGt[predicted[i]] == groundTruth[i] {
                correct += 1
            }
        }

        // Compute label flips
        var flips = 0
        for i in 1..<n {
            if predicted[i] != predicted[i - 1] {
                flips += 1
            }
        }

        return DiarizationMetrics(
            chunkAccuracy: Double(correct) / Double(n),
            speakerCountCorrect: gtLabels.count == predLabels.count,
            detectedSpeakerCount: predLabels.count,
            actualSpeakerCount: gtLabels.count,
            labelFlips: flips
        )
    }
}
```

**Step 8: テスト実行してPASSを確認**

```bash
swift test --filter "HungarianAlgorithmTests|DiarizationMetricsTests" 2>&1 | tail -10
```

Expected: All tests pass.

**Step 9: コミット**

```bash
git add Sources/QuickTranscriberLib/Benchmark/ Tests/QuickTranscriberTests/HungarianAlgorithmTests.swift Tests/QuickTranscriberTests/DiarizationMetricsTests.swift
git commit -m "feat: add HungarianAlgorithm and DiarizationMetrics for speaker eval"
```

---

### Task 3: DiarizationBenchmarkTests（シミュレーションテスト）

**Files:**
- Create: `Tests/QuickTranscriberBenchmarks/DiarizationBenchmarkTests.swift`

**前提:** Task 1でデータセットがダウンロード済み、Task 2でメトリクスが実装済み。

**Step 1: テストファイルを作成**

`Tests/QuickTranscriberBenchmarks/DiarizationBenchmarkTests.swift`:

```swift
import XCTest
import FluidAudio
@testable import QuickTranscriberLib

/// Reference format for CALLHOME diarization datasets.
struct DiarizationReference: Codable {
    let language: String
    let duration_seconds: Double
    let speakers: Int
    let segments: [SegmentRef]

    struct SegmentRef: Codable {
        let start: Double
        let end: Double
        let speaker: String
    }
}

/// Aggregated results across multiple conversations.
struct DiarizationBenchmarkResult: Codable {
    let dataset: String
    let label: String
    let conversationCount: Int
    let averageChunkAccuracy: Double
    let averageLabelFlips: Double
    let speakerCountAccuracy: Double  // Fraction of conversations with correct speaker count
}

/// Base class for diarization benchmark tests.
/// Simulates streaming: splits audio into fixed-length chunks,
/// feeds them to FluidAudioSpeakerDiarizer, and compares output
/// labels against ground truth using Hungarian algorithm.
class DiarizationBenchmarkTestBase: XCTestCase {

    var outputPath: String { "/tmp/quicktranscriber_diarization_results.json" }

    func datasetDir(name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/QuickTranscriber/test-audio/\(name)")
    }

    func loadDiarizationReferences(name: String) throws -> [String: DiarizationReference] {
        let dir = datasetDir(name: name)
        let refsURL = dir.appendingPathComponent("references.json")
        guard FileManager.default.fileExists(atPath: refsURL.path) else {
            throw XCTSkip("Dataset \(name) not found. Run: python3 Scripts/download_datasets.py \(name)")
        }
        let data = try Data(contentsOf: refsURL)
        return try JSONDecoder().decode([String: DiarizationReference].self, from: data)
    }

    /// Run diarization benchmark on a dataset.
    ///
    /// - Parameters:
    ///   - dataset: Dataset directory name (e.g., "callhome_en")
    ///   - maxConversations: Maximum number of conversations to evaluate
    ///   - chunkDuration: Chunk duration in seconds for simulation
    ///   - similarityThreshold: Cosine similarity threshold for speaker matching
    ///   - updateAlpha: Moving average weight for embedding updates
    ///   - windowDuration: Rolling buffer duration in seconds
    ///   - label: Label for result identification
    func runDiarizationBenchmark(
        dataset: String,
        maxConversations: Int = 50,
        chunkDuration: Double = 3.0,
        similarityThreshold: Float = 0.5,
        updateAlpha: Float = 0.3,
        windowDuration: TimeInterval = 30.0,
        label: String = "default"
    ) async throws -> DiarizationBenchmarkResult {
        let refs = try loadDiarizationReferences(name: dataset)
        let dir = datasetDir(name: dataset)
        let sampleRate = 16000

        let keys = Array(refs.keys.sorted().prefix(maxConversations))
        guard !keys.isEmpty else {
            throw XCTSkip("No conversations in dataset \(dataset)")
        }

        var allMetrics: [DiarizationMetrics] = []

        for (convIdx, key) in keys.enumerated() {
            guard let ref = refs[key] else { continue }
            let wavPath = dir.appendingPathComponent("\(key).wav").path
            guard FileManager.default.fileExists(atPath: wavPath) else { continue }

            // Load audio
            let audioURL = URL(fileURLWithPath: wavPath)
            let audioFile = try AVAudioFile(forReading: audioURL)
            let frameCount = AVAudioFrameCount(audioFile.length)
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate),
                channels: 1,
                interleaved: false
            )!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
            try audioFile.read(into: buffer)
            let samples = Array(UnsafeBufferPointer(
                start: buffer.floatChannelData![0],
                count: Int(buffer.frameLength)
            ))

            // Create fresh diarizer for each conversation
            let diarizer = FluidAudioSpeakerDiarizer()
            try await diarizer.setup()

            // Split into chunks and feed to diarizer
            let chunkSamples = Int(chunkDuration * Double(sampleRate))
            var predictedLabels: [String] = []
            var chunkMidpoints: [Double] = []

            var offset = 0
            while offset < samples.count {
                let end = min(offset + chunkSamples, samples.count)
                let chunk = Array(samples[offset..<end])
                let midpoint = (Double(offset) + Double(end)) / 2.0 / Double(sampleRate)
                chunkMidpoints.append(midpoint)

                let speakerLabel = await diarizer.identifySpeaker(audioChunk: chunk)
                predictedLabels.append(speakerLabel ?? "__nil__")

                offset = end
            }

            // Determine ground-truth label for each chunk (majority speaker)
            var groundTruthLabels: [String] = []
            for midpoint in chunkMidpoints {
                let halfChunk = chunkDuration / 2.0
                let chunkStart = midpoint - halfChunk
                let chunkEnd = midpoint + halfChunk

                // Find speaker with most overlap in this chunk's time range
                var speakerOverlap: [String: Double] = [:]
                for seg in ref.segments {
                    let overlapStart = max(seg.start, chunkStart)
                    let overlapEnd = min(seg.end, chunkEnd)
                    let overlap = max(0, overlapEnd - overlapStart)
                    if overlap > 0 {
                        speakerOverlap[seg.speaker, default: 0] += overlap
                    }
                }

                if let majority = speakerOverlap.max(by: { $0.value < $1.value }) {
                    groundTruthLabels.append(majority.key)
                } else {
                    groundTruthLabels.append("__silence__")
                    predictedLabels[groundTruthLabels.count - 1] = "__silence__"
                }
            }

            let metrics = DiarizationMetrics.compute(
                groundTruth: groundTruthLabels,
                predicted: predictedLabels
            )
            allMetrics.append(metrics)

            NSLog("[Diarization] \(key): accuracy=\(String(format: "%.2f", metrics.chunkAccuracy)) speakers=\(metrics.detectedSpeakerCount)/\(metrics.actualSpeakerCount) flips=\(metrics.labelFlips)")
        }

        // Aggregate
        let avgAccuracy = allMetrics.map(\.chunkAccuracy).reduce(0, +) / Double(allMetrics.count)
        let avgFlips = Double(allMetrics.map(\.labelFlips).reduce(0, +)) / Double(allMetrics.count)
        let speakerCountAcc = Double(allMetrics.filter(\.speakerCountCorrect).count) / Double(allMetrics.count)

        let result = DiarizationBenchmarkResult(
            dataset: dataset,
            label: label,
            conversationCount: allMetrics.count,
            averageChunkAccuracy: avgAccuracy,
            averageLabelFlips: avgFlips,
            speakerCountAccuracy: speakerCountAcc
        )

        NSLog("[Diarization] \(dataset)/\(label) | conversations=\(result.conversationCount) | avgAccuracy=\(String(format: "%.3f", avgAccuracy)) | avgFlips=\(String(format: "%.1f", avgFlips)) | speakerCountAcc=\(String(format: "%.2f", speakerCountAcc))")

        // Save result
        appendDiarizationResult(result)

        return result
    }

    private func appendDiarizationResult(_ result: DiarizationBenchmarkResult) {
        let url = URL(fileURLWithPath: outputPath)
        var existing: [DiarizationBenchmarkResult] = []
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([DiarizationBenchmarkResult].self, from: data) {
            existing = decoded
        }
        existing.append(result)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(existing) {
            try? data.write(to: url)
        }
    }
}

// MARK: - CALLHOME Diarization Benchmarks

final class CallHomeDiarizationTests: DiarizationBenchmarkTestBase {

    override var outputPath: String { "/tmp/quicktranscriber_diarization_results.json" }

    // MARK: - Default parameters

    func testCallHome_en_default() async throws {
        let result = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 50, label: "default"
        )
        XCTAssertGreaterThan(result.averageChunkAccuracy, 0.0, "Diarization should produce some correct labels")
    }

    func testCallHome_ja_default() async throws {
        let result = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 50, label: "default"
        )
        XCTAssertGreaterThan(result.averageChunkAccuracy, 0.0, "Diarization should produce some correct labels")
    }
}
```

**Step 2: ビルド確認**

```bash
swift build --build-tests 2>&1 | tail -10
```

Expected: コンパイル成功。`import AVFoundation` が必要な場合は追加。FluidAudioのインポートが正しいことを確認。

**Step 3: テスト実行（1会話だけで動作確認）**

```bash
swift test --filter "testCallHome_en_default" 2>&1 | tail -20
```

Expected: テストが実行され、結果がログに出力される。データセットが無い場合はXCTSkip。

**Step 4: コミット**

```bash
git add Tests/QuickTranscriberBenchmarks/DiarizationBenchmarkTests.swift
git commit -m "feat: add streaming diarization benchmark tests with CALLHOME"
```

---

### Task 4: パラメータバリエーションテスト

**Files:**
- Modify: `Tests/QuickTranscriberBenchmarks/DiarizationBenchmarkTests.swift`

**Step 1: similarityThreshold バリエーションテストを追加**

`DiarizationBenchmarkTests.swift` の `CallHomeDiarizationTests` クラスに追加:

```swift
    // MARK: - similarityThreshold variations

    func testCallHome_en_similarity03() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 50,
            similarityThreshold: 0.3, label: "similarity_0.3"
        )
    }

    func testCallHome_en_similarity04() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 50,
            similarityThreshold: 0.4, label: "similarity_0.4"
        )
    }

    func testCallHome_en_similarity06() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 50,
            similarityThreshold: 0.6, label: "similarity_0.6"
        )
    }

    func testCallHome_en_similarity07() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 50,
            similarityThreshold: 0.7, label: "similarity_0.7"
        )
    }

    func testCallHome_ja_similarity03() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 50,
            similarityThreshold: 0.3, label: "similarity_0.3"
        )
    }

    func testCallHome_ja_similarity04() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 50,
            similarityThreshold: 0.4, label: "similarity_0.4"
        )
    }

    func testCallHome_ja_similarity06() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 50,
            similarityThreshold: 0.6, label: "similarity_0.6"
        )
    }

    func testCallHome_ja_similarity07() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 50,
            similarityThreshold: 0.7, label: "similarity_0.7"
        )
    }
```

**注意:** `runDiarizationBenchmark` 内で `FluidAudioSpeakerDiarizer` を生成する際、`similarityThreshold` パラメータを `EmbeddingBasedSpeakerTracker` に渡す必要がある。現在の `FluidAudioSpeakerDiarizer` はハードコードされているため、テスト用にパラメータ注入できるように `FluidAudioSpeakerDiarizer.init()` を拡張するか、テスト内で直接 `EmbeddingBasedSpeakerTracker` を使うかを決める。

**実装方針:** `FluidAudioSpeakerDiarizer` の init にパラメータを追加:

```swift
// SpeakerDiarizer.swift の FluidAudioSpeakerDiarizer を修正
public final class FluidAudioSpeakerDiarizer: SpeakerDiarizer, @unchecked Sendable {
    // ... 既存フィールド
    private let speakerTracker: EmbeddingBasedSpeakerTracker  // let→var は不要、init時に設定

    public init(
        similarityThreshold: Float = 0.5,
        updateAlpha: Float = 0.3,
        windowDuration: TimeInterval = 30.0
    ) {
        self.speakerTracker = EmbeddingBasedSpeakerTracker(
            similarityThreshold: similarityThreshold,
            updateAlpha: updateAlpha
        )
        self.windowDuration = windowDuration  // windowDuration を var に変更
    }
}
```

`windowDuration` を `private var` に変更し、init で受け取る。

**Step 2: FluidAudioSpeakerDiarizer のinit拡張**

`Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift` を修正:

変更箇所:
1. `private let windowDuration` → `private let windowDuration: TimeInterval`（init引数で設定）
2. `private let speakerTracker = EmbeddingBasedSpeakerTracker()` → init引数で生成
3. `public init()` → パラメータ付きinit追加

```swift
public final class FluidAudioSpeakerDiarizer: SpeakerDiarizer, @unchecked Sendable {
    // ...
    private let sampleRate: Int = 16000
    private let windowDuration: TimeInterval
    private var rollingBuffer: [Float] = []
    private var diarizer: OfflineDiarizerManager?
    private let speakerTracker: EmbeddingBasedSpeakerTracker
    private let lock = NSLock()

    public init(
        similarityThreshold: Float = 0.5,
        updateAlpha: Float = 0.3,
        windowDuration: TimeInterval = 30.0
    ) {
        self.windowDuration = windowDuration
        self.speakerTracker = EmbeddingBasedSpeakerTracker(
            similarityThreshold: similarityThreshold,
            updateAlpha: updateAlpha
        )
    }
    // ... 残りは同じ
}
```

**Step 3: テスト実行してPASSを確認**

```bash
swift test --filter QuickTranscriberTests 2>&1 | tail -10
```

Expected: 既存ユニットテストがすべてPASS（デフォルト値を維持しているので振る舞い変更なし）

**Step 4: コミット**

```bash
git add Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift Tests/QuickTranscriberBenchmarks/DiarizationBenchmarkTests.swift
git commit -m "feat: add parameterized diarization benchmarks for similarity threshold"
```

---

### Task 5: chunkDuration バリエーションテスト

**Files:**
- Modify: `Tests/QuickTranscriberBenchmarks/DiarizationBenchmarkTests.swift`

**Step 1: chunkDuration バリエーションテストを追加**

```swift
    // MARK: - chunkDuration variations

    func testCallHome_en_chunk5s() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 50,
            chunkDuration: 5.0, label: "chunk_5s"
        )
    }

    func testCallHome_en_chunk7s() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 50,
            chunkDuration: 7.0, label: "chunk_7s"
        )
    }

    func testCallHome_ja_chunk5s() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 50,
            chunkDuration: 5.0, label: "chunk_5s"
        )
    }

    func testCallHome_ja_chunk7s() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 50,
            chunkDuration: 7.0, label: "chunk_7s"
        )
    }
```

**Step 2: windowDuration バリエーションテストを追加**

```swift
    // MARK: - windowDuration variations

    func testCallHome_en_window15s() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 50,
            windowDuration: 15.0, label: "window_15s"
        )
    }

    func testCallHome_en_window45s() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 50,
            windowDuration: 45.0, label: "window_45s"
        )
    }

    func testCallHome_en_window60s() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 50,
            windowDuration: 60.0, label: "window_60s"
        )
    }
```

**Step 3: コミット**

```bash
git add Tests/QuickTranscriberBenchmarks/DiarizationBenchmarkTests.swift
git commit -m "feat: add chunk duration and window duration benchmark variations"
```

---

### Task 6: ベンチマーク実行と結果分析

**Step 1: デフォルトパラメータでベースライン取得**

```bash
swift test --filter "testCallHome_en_default" 2>&1 | grep "\[Diarization\]"
swift test --filter "testCallHome_ja_default" 2>&1 | grep "\[Diarization\]"
```

**Step 2: similarityThreshold バリエーション実行**

```bash
swift test --filter "testCallHome_en_similarity" 2>&1 | grep "\[Diarization\].*callhome_en"
swift test --filter "testCallHome_ja_similarity" 2>&1 | grep "\[Diarization\].*callhome_ja"
```

**Step 3: 結果をJSON出力から分析**

```bash
python3 -c "
import json
with open('/tmp/quicktranscriber_diarization_results.json') as f:
    results = json.load(f)
print(f'{'Label':<25} {'Conversations':>14} {'Accuracy':>10} {'Flips':>8} {'SpkrAcc':>10}')
print('-' * 70)
for r in results:
    print(f'{r[\"dataset\"]+\"/\"+r[\"label\"]:<25} {r[\"conversationCount\"]:>14} {r[\"averageChunkAccuracy\"]:>10.3f} {r[\"averageLabelFlips\"]:>8.1f} {r[\"speakerCountAccuracy\"]:>10.2f}')
"
```

**Step 4: 最適パラメータを特定してコミット**

結果に基づいてデフォルト値の変更が必要な場合は、`EmbeddingBasedSpeakerTracker.init` と `FluidAudioSpeakerDiarizer.init` のデフォルト引数を更新。

```bash
git add -A
git commit -m "docs: add diarization benchmark results and analysis"
```

---

## 実行順序まとめ

| Task | 内容 | 依存 |
|------|------|------|
| 1 | CALLHOME ダウンロードスクリプト + 実行 | なし |
| 2 | HungarianAlgorithm + DiarizationMetrics | なし |
| 3 | DiarizationBenchmarkTests | Task 1, 2 |
| 4 | パラメータ注入 + similarityThreshold テスト | Task 3 |
| 5 | chunkDuration / windowDuration テスト | Task 4 |
| 6 | ベンチマーク実行 + 結果分析 | Task 5 |

Task 1 と Task 2 は並列実行可能。
