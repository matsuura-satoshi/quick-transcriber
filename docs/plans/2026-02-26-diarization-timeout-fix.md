# Diarization Timeout Fix: Manual Mode Transcription Freeze Prevention

## Context

### 問題
Manualモードで4名のregistered speakerを割り当てた状態で、テキストエリアが全く更新されなくなるバグが発生。重要な会議中に発生し、強制終了を余儀なくされ、それまでの文字起こしデータを喪失した。

### 根本原因分析

`ChunkedWhisperEngine.processChunk()` (ChunkedWhisperEngine.swift:261-276) で、文字起こしとダイアライゼーションが `async let` で並列実行される:

```swift
async let transcription = transcriber.transcribe(...)
async let speakerId = diarizer.identifySpeaker(...)
segments = try await transcription
rawSpeakerResult = await speakerId
```

**問題点**: `FluidAudio.OfflineDiarizerManager.process(audio:)` （`identifySpeaker` 内部でDiarizationPacerが発火する約7秒毎に呼ばれる）がハング/極端に遅延した場合、`await speakerId` が永久にブロックされる。Swift structured concurrencyの仕様上、`async let` の子タスクはスコープ終了前に必ず完了しなければならないため、**文字起こしが正常に完了しても結果をUIに送出できない**。処理ループ全体が停止し、以降のすべての音声チャンクが処理されなくなる。

### なぜSegmentが落ちないはずなのにフリーズするか

コード分析により以下が確認済み:
- `EmbeddingBasedSpeakerTracker.identify()` はcapacity到達時に必ず最も類似度の高い話者に強制割当（nil返却なし）
- `ViterbiSpeakerSmoother` はpending状態でnilを返すが、セグメントは `speaker: nil` で追加され、後にretroactive updateされる
- 品質フィルタを通過したセグメントは **必ず** `confirmedSegments` に追加される

つまり、セグメント処理ロジック自体にはバグはない。問題は `processChunk` 自体が `identifySpeaker` のハングにより完了しないことにある。

## 修正方針

`FluidAudioSpeakerDiarizer.identifySpeaker()` 内の `diarizer.process(audio:)` 呼び出しにタイムアウトを追加する。

### なぜこのレベルか
- 最も狭いスコープで問題箇所をラップできる
- `SpeakerDiarizer` protocolの変更不要
- `ChunkedWhisperEngine` の変更不要（既にnil diarizationを正しくハンドル済み）
- 既存のerror catchブロックと同じフォールバック動作（pacer reset → cached result返却）

## 実装ステップ

### Step 1: Constants.swift にタイムアウト定数を追加

**ファイル**: `Sources/QuickTranscriber/Constants.swift`

```swift
public enum Diarization {
    /// Maximum time to wait for a single diarization process() call.
    public static let processTimeout: TimeInterval = 10.0
}
```

通常の `process()` は0.5-2秒。10秒は十分なヘッドルームを確保しつつ、ハングを検出する。

### Step 2: SpeakerDiarizer.swift にタイムアウトロジックを追加

**ファイル**: `Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift`

#### 2a. エラー型を追加 (ファイル先頭、protocol定義前)

```swift
struct DiarizationTimeoutError: Error {}
```

#### 2b. `FluidAudioSpeakerDiarizer` にタイムアウト付きprocessメソッドを追加

`withThrowingTaskGroup` のレースパターンで、`process()` と `Task.sleep` を競わせる:

```swift
private static func processWithTimeout(
    diarizer: OfflineDiarizerManager,
    audio: [Float],
    timeout: TimeInterval
) async throws -> FluidAudio.DiarizationResult {
    try await withThrowingTaskGroup(of: FluidAudio.DiarizationResult.self) { group in
        group.addTask {
            try await diarizer.process(audio: audio)
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw DiarizationTimeoutError()
        }
        guard let result = try await group.next() else {
            throw DiarizationTimeoutError()
        }
        group.cancelAll()
        return result
    }
}
```

動作: `process()` がタイムアウト前に完了すれば結果を返す。`Task.sleep` が先に完了すれば `DiarizationTimeoutError` をthrow。グループ終了時に残りの子タスクは自動キャンセルされる。

#### 2c. `identifySpeaker` 内の `process()` 呼び出しを差し替え

**Before** (line 114):
```swift
let result = try await diarizer.process(audio: currentBuffer)
```

**After**:
```swift
let result = try await Self.processWithTimeout(
    diarizer: diarizer,
    audio: currentBuffer,
    timeout: Constants.Diarization.processTimeout
)
```

#### 2d. catchブロックにタイムアウト専用ハンドリングを追加

**Before** (lines 143-147):
```swift
} catch {
    NSLog("[SpeakerDiarizer] Diarization failed: \(error)")
    lock.withLock { pacer.reset() }
    return lock.withLock { pacer.lastResult }
}
```

**After**:
```swift
} catch is DiarizationTimeoutError {
    NSLog("[SpeakerDiarizer] Diarization timed out after \(Constants.Diarization.processTimeout)s, returning cached result")
    lock.withLock { pacer.reset() }
    return lock.withLock { pacer.lastResult }
} catch {
    NSLog("[SpeakerDiarizer] Diarization failed: \(error)")
    lock.withLock { pacer.reset() }
    return lock.withLock { pacer.lastResult }
}
```

### Step 3: テスト追加

#### 3a. MockSpeakerDiarizer にdelay機能を追加

**ファイル**: `Tests/QuickTranscriberTests/Mocks/MockSpeakerDiarizer.swift`

```swift
var identifyDelay: TimeInterval = 0
```

`identifySpeaker` 内で `identifyDelay > 0` なら `Task.sleep` してから結果を返す。将来のタイムアウト関連テストに使用可能。

#### 3b. nil diarization時にtranscriptionが継続するテスト

**ファイル**: `Tests/QuickTranscriberTests/ChunkedWhisperEngineTests.swift`

MockSpeakerDiarizerが常にnilを返す（タイムアウト後のcached resultがnilの場合をシミュレート）状態で、`confirmedSegments` にテキストが追加されることを検証するテスト。

## 変更対象ファイル

| ファイル | 変更内容 |
|---------|---------|
| `Sources/QuickTranscriber/Constants.swift` | `Diarization.processTimeout` 定数追加 |
| `Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift` | タイムアウトロジック追加 |
| `Tests/QuickTranscriberTests/Mocks/MockSpeakerDiarizer.swift` | delay機能追加 |
| `Tests/QuickTranscriberTests/ChunkedWhisperEngineTests.swift` | nil diarizationテスト追加 |

## 並行実行ガードが不要な理由

タイムアウトした `process()` がバックグラウンドで実行し続ける可能性があるが、以下の理由で並行実行ガードは不要:
- `OfflineDiarizerManager.process()` はステートレス（内部でモデル推論のみ）。並行呼び出しで状態が壊れない
- `DiarizationPacer` が約7秒間隔で呼び出しを制御。連続タイムアウトでも呼び出しが積み上がらない
- タイムアウトが持続的に発生する場合、毎回cached resultが返却され、transcriptionは話者ラベルなしで正常動作する（graceful degradation）

## 検証方法

1. `swift test --filter QuickTranscriberTests` — 既存テスト + 新規テストが全パス
2. `swift build && swift run QuickTranscriber` — manualモード + registered speakerで文字起こし動作確認
3. NSLogで `[SpeakerDiarizer]` のログを確認し、通常のdiarization処理が10秒以内に完了していることを確認
