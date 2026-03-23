# ファイル文字起こしパイプライン精度最適化

## Context

現在のファイル文字起こしはリアルタイム録音と完全に同じパイプライン・パラメータを使用している。
リアルタイムでは低レイテンシが必要なため短チャンク(3-8s) + 品質フィルタ無効(nil)という制約があるが、
ファイル処理はバッチなのでこれらの制約を緩和でき、精度向上が可能。

**前回の失敗**: WhisperKitの一括API(`transcribe(audioArray:)` に79s全体を渡す)が16kHz Int16 WAVで空結果を返すバグ。
**教訓**: WhisperKitの一括処理は使わない。ストリーミングアーキテクチャ(VAD→小チャンク→逐次処理)を維持する。

**今回のアプローチ**: ストリーミングアーキテクチャを維持しつつ、パラメータだけをバッチ向けに最適化する。

## 設計方針

### 核心的な改善ポイント

1. **チャンクサイズ拡大**: maxChunkDuration 8s → 25s（30sメルスペクトログラムへのパディングが17%に。品質フィルタが有効に機能する）
2. **WhisperKit品質フィルタ有効化**: compressionRatio/logProb/noSpeechの各閾値を設定（リアルタイムではnilだが、長チャンクでは有効）
3. **Temperature fallback**: 失敗時に温度を上げてリトライ（0.0→0.2→0.4）
4. **suppressBlank**: 空白トークンの抑制でハルシネーション低減

### 安全策: チャンク長に基づく閾値の動的切替

VADは自然な発話境界で切るため、25sのmaxChunkDurationでも短い発話(3-5s)チャンクが発生し得る。
短チャンクに品質フィルタを適用すると有効なセグメントが破棄されるため、**チャンク長15s以上でのみ品質フィルタを有効化**する。

```
チャンク長 ≥ 15s → 品質フィルタON + temperature fallback
チャンク長 < 15s  → 品質フィルタnil（現行と同じ安全動作）
```

## 変更ファイル一覧

### 1. `Sources/QuickTranscriber/Models/TranscriptionParameters.swift`
品質フィルタ関連フィールドを追加:

```swift
// WhisperKit quality thresholds (nil = disabled, used for file mode)
public var compressionRatioThreshold: Float?
public var logProbThreshold: Float?
public var firstTokenLogProbThreshold: Float?
public var noSpeechThreshold: Float?
public var suppressBlank: Bool

/// Minimum chunk duration (seconds) to apply quality thresholds.
/// Chunks shorter than this use nil thresholds (safe for padded mel spectrograms).
public var qualityThresholdMinChunkDuration: TimeInterval
```

デフォルト値: 全てnil / false / 15.0（リアルタイム動作に影響なし）

### 2. `Sources/QuickTranscriber/Engines/ChunkTranscriber.swift`
`WhisperKitChunkTranscriber.transcribe()` でパラメータの品質フィルタを使用:

```swift
let chunkDuration = Double(audioArray.count) / Constants.Audio.sampleRate
let useQualityThresholds = chunkDuration >= parameters.qualityThresholdMinChunkDuration

let options = DecodingOptions(
    task: .transcribe,
    language: language,
    temperature: parameters.temperature,
    temperatureIncrementOnFallback: 0.2,
    temperatureFallbackCount: parameters.temperatureFallbackCount,
    sampleLength: parameters.sampleLength,
    skipSpecialTokens: true,
    withoutTimestamps: true,
    suppressBlank: useQualityThresholds ? parameters.suppressBlank : false,
    compressionRatioThreshold: useQualityThresholds ? parameters.compressionRatioThreshold : nil,
    logProbThreshold: useQualityThresholds ? parameters.logProbThreshold : nil,
    firstTokenLogProbThreshold: useQualityThresholds ? parameters.firstTokenLogProbThreshold : nil,
    noSpeechThreshold: useQualityThresholds ? parameters.noSpeechThreshold : nil,
    concurrentWorkerCount: parameters.concurrentWorkerCount
)
```

### 3. `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift`
`beginFileTranscription()` でファイル用パラメータを構築:

```swift
var params = parametersStore.parameters
// File-optimized overrides: larger chunks for more decoder context + temperature fallback
params.chunkDuration = Constants.FileTranscription.chunkDuration           // 25.0
params.silenceCutoffDuration = Constants.FileTranscription.endOfUtteranceSilence  // 1.0
params.temperatureFallbackCount = Constants.FileTranscription.temperatureFallbackCount // 2
params.concurrentWorkerCount = 1
// NOTE: 品質フィルタ(compressionRatioThreshold等)は使用しない。
// ベンチマーク結果: チャンク長が15s未満のためフィルタが発動せず効果ゼロ、
// 実際の会議音声ではセグメント脱落を引き起こした。
```

### 4. `Sources/QuickTranscriber/Constants.swift`
FileTranscription定数を更新:

```swift
public enum FileTranscription {
    public static let chunkDuration: TimeInterval = 25.0        // was 15.0
    public static let endOfUtteranceSilence: TimeInterval = 1.0  // unchanged
    public static let temperatureFallbackCount: Int = 2          // unchanged
    public static let qualityThresholdMinChunkDuration: TimeInterval = 15.0
}
```

### 5. `Sources/QuickTranscriber/Engines/ChunkTranscriber.swift` (クリーンアップ)
- 未使用の `transcribeFile()` メソッドを削除（WhisperKitChunkTranscriber + protocol）
- 未使用の `FileTranscriptionSegment` 構造体を削除
- これらは前回の失敗した専用パイプラインの残骸（gitに履歴あり）

## 変更しないもの

- **ChunkedWhisperEngine**: 変更不要。`currentParameters`経由で自動的にファイル用パラメータが流れる
- **VADChunkAccumulator**: 変更不要。`maxChunkDuration`と`endOfUtteranceSilence`のパラメータ経由で動作が変わる
- **FileAudioSource**: 変更不要。100msバッファ配信はそのまま
- **ChunkTranscriber protocol**: 変更不要。既存のシグネチャで対応可能
- **AudioLevelNormalizer**: 変更不要

## なぜこれで精度が上がるか

| 要因 | リアルタイム (現行) | ファイルモード (改善後) | 効果 |
|------|-----|-----|------|
| チャンクサイズ | 3-8s | 5-25s | デコーダに十分なコンテキスト提供 |
| 30sパディング比率 | 73-90% silence | 17-67% | 品質メトリクスが実際の音声を反映 |
| 品質フィルタ | 全てnil | 15s以上で有効 | ハルシネーション・ノイズ除去 |
| Temperature fallback | なし(count=0) | 2回リトライ | 低品質出力の再試行 |
| suppressBlank | false | true | 空白トークン抑制 |
| 並行ワーカー | 4 | 1 | 処理順序の一貫性 |

## 検証方法

1. **ユニットテスト**: ChunkTranscriberの品質フィルタ条件分岐テスト
   - 短チャンク(5s) + 品質パラメータ設定 → nil thresholdsで呼ばれることを確認
   - 長チャンク(20s) + 品質パラメータ設定 → 設定値で呼ばれることを確認
   - 品質パラメータ未設定(nil) → 常にnilで呼ばれることを確認

2. **ビルド確認**: `swift build` が通ること

3. **手動テスト**: 既存のWAVファイルをドロップして文字起こし結果を比較
   - 文字起こしが完了すること(空結果にならない)
   - ログで品質フィルタの適用状況を確認
   - 話者ダイアライゼーションが正常動作すること
