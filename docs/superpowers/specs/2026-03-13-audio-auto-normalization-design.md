# Audio Auto-Normalization Design

## Problem

マイク入力レベルが低い場合、VADのonset閾値(0.02)に到達せず、チャンクが切り出されない。
結果としてWhisperKitに音声が渡らず、文字起こしが失敗する。

ベンチマークでは `normalizeAudio(targetPeak: 0.5)` で同じ問題を解決済み。
本番パイプラインにはこの正規化が存在しない。

## Solution

リアルタイムAGC（Automatic Gain Control）をオーディオパイプラインに挿入し、
VADの前段で音声レベルを自動正規化する。

## Architecture

### パイプライン

```
AudioCapture → [AudioLevelNormalizer] → VADChunkAccumulator → ChunkTranscriber
```

正規化はVADの前に適用する。これによりVAD検出とWhisperKit入力品質の両方が改善される。

### AudioLevelNormalizer

新規ファイル: `Sources/QuickTranscriber/Audio/AudioLevelNormalizer.swift`

Sendable struct。`mutating func normalize(_ samples: [Float]) -> [Float]` を提供。

#### 正規化方式

ピークベース正規化。ベンチマーク実証済みの `normalizeAudio(targetPeak: 0.5)` と同じ考え方。

- スライディングウィンドウ（直近1秒）のピーク値を追跡
- `gain = targetPeak / runningPeak`
- EMAでゲイン変化を平滑化（急激な音量変化を防止）
- 正規化後に±1.0にクランプ（クリッピング保護）

#### パラメータ（Constants.AudioNormalization）

| パラメータ | 初期値 | 根拠 |
|-----------|--------|------|
| targetPeak | 0.5 | ベンチマーク実証値 |
| minGain | 1.0 | 入力を減衰させない |
| maxGain | 10.0 | 初期値、実機テストで調整 |
| windowDuration | 1.0s | 初期値、実機テストで調整 |
| attackCoefficient | 0.1 | 初期値、実機テストで調整 |
| releaseCoefficient | 0.01 | 初期値、実機テストで調整 |

attack/release/maxGain/windowDurationは理論的根拠が弱い初期推定値。
実機テストで調整する前提。

### パイプライン統合

`ChunkedWhisperEngine` に `AudioLevelNormalizer` をプロパティとして保持。
`for await samples in bufferStream` ループ内で、`accumulator.appendBuffer` の前に正規化を適用。

変更ファイル:
- `ChunkedWhisperEngine.swift`: normalizerプロパティ追加、ループ内で適用
- `Constants.swift`: `AudioNormalization` enum追加

### チャンク単位正規化

不要。AGCでバッファ単位に正規化済みのため、チャンクも正規化されている。

## Testing

### AudioLevelNormalizerTests（単体テスト）

- 小さい入力がブーストされること
- 十分大きい入力は変更されないこと（gain >= 1.0のためそのまま）
- 最大ゲイン制限が機能すること
- クリッピング保護（±1.0クランプ）
- ウィンドウ追跡が正しく動作すること

### 既存テストへの影響

- ChunkAccumulatorTests: 変更不要（正規化はaccumulatorの外）
- ChunkedWhisperEngineの統合テスト: 小さい音声→正規化→VAD発火の確認

## Scope

### 含む
- AudioLevelNormalizer実装
- Constants.AudioNormalization定数
- ChunkedWhisperEngineへの統合
- 単体テスト

### 含まない
- UI変更（設定画面への追加なし）
- マイクデバイス選択
- 手動ゲイン調整（テスト後に検討）
