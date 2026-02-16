# Diarization Parameter Optimization

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** ベンチマーク結果に基づきダイアライゼーションパラメータを最適化し、文字起こしレイテンシを維持しつつ話者識別精度を向上させる。

**Architecture:** FluidAudioSpeakerDiarizer内部にチャンク蓄積メカニズムを追加。文字起こしは3秒チャンクを維持し、ダイアライザーは複数チャンクを蓄積して7秒分溜まってから推論を実行。

**Tech Stack:** Swift, FluidAudio, XCTest

---

## Background

### ベンチマーク結果（CALLHOME EN/JA, 各5会話）

| パラメータ | 最適値 | 改善効果 |
|-----------|--------|---------|
| chunkDuration | 7s | 正答率 +32%(EN), +14%(JA)、フリップ激減 |
| windowDuration | 15s | 正答率 +11%(EN) |
| similarityThreshold | 0.3-0.5 | 影響小（±2%程度） |

### 問題分析

chunkDurationが効果的な理由:
1. **呼び出し頻度の低下**: 3sチャンクでは30秒間に10回呼ばれ、各回でラベルフリップの機会がある。7sでは4回。
2. **findRelevantSegmentの探索範囲**: 3sでは末尾3sを見るが、7sでは末尾7sを見る。より広い範囲で話者判定するため安定する。

## Design

### FluidAudioSpeakerDiarizer変更

新パラメータ: `diarizationChunkDuration: TimeInterval = 7.0`
デフォルト変更: `windowDuration: 30.0 → 15.0`

```
identifySpeaker(audioChunk:) の新フロー:

1. audioChunkをローリングバッファに常に追加
2. samplesSinceLastDiarization += audioChunk.count
3. if 蓄積量 < diarizationChunkDuration:
   → lastLabel（前回の結果）を返す
4. if 蓄積量 >= diarizationChunkDuration:
   → FluidAudio.process() を実行
   → findRelevantSegment で蓄積分全体の範囲を検索
   → speakerTracker.identify() で安定ラベル取得
   → lastLabel を更新、samplesSinceLastDiarization リセット
   → 新ラベルを返す
```

### SpeakerLabelTrackerとの相互作用

蓄積中にlastLabel（前回の確定ラベル）を返すため、SpeakerLabelTrackerには同じラベルが連続で渡される。これはpending状態をリセットする方向に作用し、安定化に寄与する。

### 変更対象ファイル

- `Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift` - メイン変更
- `Tests/QuickTranscriberTests/SpeakerDiarizerTests.swift` - ユニットテスト追加
- `Tests/QuickTranscriberBenchmarks/DiarizationBenchmarkTests.swift` - 組み合わせベンチマーク追加

---

## Tasks

### Task 1: ユニットテスト作成

**Files:**
- Create: `Tests/QuickTranscriberTests/DiarizationChunkAccumulationTests.swift`

**Step 1: テストファイル作成**

```swift
import XCTest
@testable import QuickTranscriberLib

final class DiarizationChunkAccumulationTests: XCTestCase {

    func testReturnsNilWhenAccumulatingBelowThreshold() async {
        // diarizationChunkDuration=6s, 3sチャンクの1回目→蓄積中→nil
        let diarizer = FluidAudioSpeakerDiarizer(
            diarizationChunkDuration: 6.0,
            windowDuration: 15.0
        )
        // setup()を呼ばない(diarizerがnil)のでnilが返る
        // → このテストはモック不要で蓄積ロジックのみテスト
        let samples3s = [Float](repeating: 0.1, count: 48000) // 3s at 16kHz
        let result = await diarizer.identifySpeaker(audioChunk: samples3s)
        XCTAssertNil(result) // diarizer未セットアップなのでnil
    }

    func testFindRelevantSegmentUsesAccumulatedDuration() {
        // 蓄積分全体(7s)がchunkDurationとして使われることを確認
        let segments = [
            FluidAudioSpeakerDiarizer.TimedSegmentInfo(
                speakerId: "0", embedding: [1,0,0], startTime: 8.0, endTime: 15.0
            ),
            FluidAudioSpeakerDiarizer.TimedSegmentInfo(
                speakerId: "1", embedding: [0,1,0], startTime: 0.0, endTime: 8.0
            ),
        ]
        // bufferDuration=15s, chunkDuration=7s → 探索範囲は 8-15s
        let result = FluidAudioSpeakerDiarizer.findRelevantSegment(
            segments: segments, bufferDuration: 15.0, chunkDuration: 7.0
        )
        XCTAssertEqual(result?.speakerId, "0")
    }
}
```

**Step 2: テスト実行して失敗確認**

```bash
swift test --filter DiarizationChunkAccumulationTests
```

diarizationChunkDurationパラメータが存在しないのでコンパイルエラー。

### Task 2: FluidAudioSpeakerDiarizer実装変更

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift`

**Step 1: パラメータ追加とデフォルト変更**

init()に`diarizationChunkDuration`パラメータを追加。
`windowDuration`のデフォルトを30.0→15.0に変更。

```swift
private let diarizationChunkDuration: TimeInterval
private var samplesSinceLastDiarization: Int = 0
private var lastLabel: String?

public init(
    similarityThreshold: Float = 0.5,
    updateAlpha: Float = 0.3,
    windowDuration: TimeInterval = 15.0,
    diarizationChunkDuration: TimeInterval = 7.0
) {
    self.windowDuration = windowDuration
    self.diarizationChunkDuration = diarizationChunkDuration
    self.speakerTracker = EmbeddingBasedSpeakerTracker(
        similarityThreshold: similarityThreshold,
        updateAlpha: updateAlpha
    )
}
```

**Step 2: identifySpeaker()にチャンク蓄積ロジック追加**

```swift
public func identifySpeaker(audioChunk: [Float]) async -> String? {
    guard let diarizer else { return nil }

    let windowSamples = Int(windowDuration * Double(sampleRate))
    let diarizationSamples = Int(diarizationChunkDuration * Double(sampleRate))

    let (currentBuffer, shouldRunDiarization, accumulatedDuration) = lock.withLock {
        rollingBuffer.append(contentsOf: audioChunk)
        if rollingBuffer.count > windowSamples {
            rollingBuffer.removeFirst(rollingBuffer.count - windowSamples)
        }
        samplesSinceLastDiarization += audioChunk.count

        let shouldRun = samplesSinceLastDiarization >= diarizationSamples
        let accumulated = Float(samplesSinceLastDiarization) / Float(sampleRate)
        return (rollingBuffer, shouldRun, accumulated)
    }

    // 蓄積中は前回の結果を返す
    guard shouldRunDiarization else {
        return lastLabel
    }

    guard currentBuffer.count >= sampleRate else { return nil }

    do {
        let result = try await diarizer.process(audio: currentBuffer)
        // ... (既存のセグメント処理)
        // findRelevantSegmentにはaccumulatedDurationを渡す

        lock.withLock { samplesSinceLastDiarization = 0 }
        lastLabel = label
        return label
    } catch { ... }
}
```

**Step 3: テスト実行して成功確認**

```bash
swift test --filter DiarizationChunkAccumulationTests
swift test --filter QuickTranscriberTests
```

**Step 4: コミット**

```bash
git add Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift Tests/QuickTranscriberTests/DiarizationChunkAccumulationTests.swift
git commit -m "feat: add diarization chunk accumulation and optimize defaults"
```

### Task 3: ベンチマーク組み合わせテスト追加

**Files:**
- Modify: `Tests/QuickTranscriberBenchmarks/DiarizationBenchmarkTests.swift`

**Step 1: 組み合わせテスト追加**

```swift
// MARK: - Combined parameter tests

func testCallHome_en_chunk7_window15() async throws {
    let _ = try await runDiarizationBenchmark(
        dataset: "callhome_en", maxConversations: 5,
        chunkDuration: 7.0, windowDuration: 15.0,
        label: "chunk_7s_window_15s"
    )
}

func testCallHome_ja_chunk7_window15() async throws {
    let _ = try await runDiarizationBenchmark(
        dataset: "callhome_ja", maxConversations: 5,
        chunkDuration: 7.0, windowDuration: 15.0,
        label: "chunk_7s_window_15s"
    )
}
```

**Step 2: コミット**

```bash
git add Tests/QuickTranscriberBenchmarks/DiarizationBenchmarkTests.swift
git commit -m "test: add combined chunk+window benchmark tests"
```

### Task 4: ベンチマーク実行・検証

**Step 1: 組み合わせベンチマーク実行**

```bash
swift test --filter "testCallHome_en_chunk7_window15" 2>&1 | grep "Diarization"
swift test --filter "testCallHome_ja_chunk7_window15" 2>&1 | grep "Diarization"
```

**Step 2: 結果比較と分析**

chunk_7s_window_15s の結果を既存結果と比較。

**Step 3: MEMORY.md更新**
