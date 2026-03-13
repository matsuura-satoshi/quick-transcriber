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

正規化後の音声は話者ダイアライゼーション（FluidAudio）にも渡るが、
話者埋め込みは振幅に対して不変であるため影響しない。

### AudioLevelNormalizer

新規ファイル: `Sources/QuickTranscriber/Audio/AudioLevelNormalizer.swift`

Sendable struct。`mutating func normalize(_ samples: [Float]) -> [Float]` を提供。
ChunkedWhisperEngineでは既存の `accumulator`（VADChunkAccumulator）と同じパターンで
プロパティとして保持し、streamingTaskループ内で `self.normalizer.normalize(samples)` として呼び出す。

#### 正規化方式

ピークベース正規化。ベンチマーク実証済みの `normalizeAudio(targetPeak: 0.5)` と同じ考え方。
**gain-upのみ**の設計: 小さい入力はブーストするが、大きい入力は減衰させない。
targetPeakは「目標最低ピークレベル」として機能する。

#### ピーク追跡: 減衰ピークトラッカー

リングバッファによるスライディングウィンドウではなく、減衰ピークトラッカーを使用（メモリ効率）。

```
バッファごとに:
  bufferPeak = max(abs(sample)) for sample in buffer
  if bufferPeak > runningPeak:
    runningPeak = bufferPeak               // 即座に追従
  else:
    runningPeak = runningPeak * decayFactor // 時間とともに減衰
```

decayFactor: `pow(0.01, bufferDuration / windowDuration)` — windowDuration秒後にピークが1%に減衰。

ゼロ除算保護: `runningPeak < 1e-6` の場合は gain = 1.0（正規化しない）。

#### ゲインスムージング（EMA）

ゲインの急激な変化を防止するため、指数移動平均でスムージング:

```
rawGain = clamp(targetPeak / runningPeak, minGain, maxGain)
if rawGain < smoothedGain:
  smoothedGain += (rawGain - smoothedGain) * attackCoefficient   // ゲイン下降（入力が大きくなった）
else:
  smoothedGain += (rawGain - smoothedGain) * releaseCoefficient  // ゲイン上昇（入力が小さくなった）
```

- **attack**（ゲイン下降）: 大きい音への追従。速め(0.1)で歪みを防止
- **release**（ゲイン上昇）: 静かになった時のブースト。遅め(0.01)で急激なノイズ増幅を防止
- **初期値**: smoothedGain = 1.0（起動時は正規化なし、徐々に適応）

#### パラメータ（Constants.AudioNormalization）

| パラメータ | 初期値 | 根拠 |
|-----------|--------|------|
| targetPeak | 0.5 | ベンチマーク実証値 |
| minGain | 1.0 | gain-upのみ（減衰しない） |
| maxGain | 10.0 | 初期値、実機テストで調整 |
| windowDuration | 1.0s | 初期値、実機テストで調整 |
| attackCoefficient | 0.1 | 初期値、実機テストで調整 |
| releaseCoefficient | 0.01 | 初期値、実機テストで調整 |

attack/release/maxGain/windowDurationは理論的根拠が弱い初期推定値。
実機テストで調整する前提。

### パイプライン統合

`ChunkedWhisperEngine` に `AudioLevelNormalizer` をプロパティとして保持。
`for await samples in bufferStream` ループ内で、`accumulator.appendBuffer` の前に正規化を適用。

#### 状態リセット

`startStreaming()` で `normalizer` を再初期化する（accumulatorと同じパターン）。
前回録音セッションのゲイン状態が次のセッションに影響しないようにする。

#### ロギング

チューニングのため、録音開始時と定期的（10秒ごと）にゲイン状態をNSLogで出力:
- `[AudioLevelNormalizer] gain=X.XX runningPeak=X.XXXX`

変更ファイル:
- `ChunkedWhisperEngine.swift`: normalizerプロパティ追加、ループ内で適用、startStreamingでリセット
- `Constants.swift`: `AudioNormalization` enum追加

### チャンク単位正規化

不要。AGCでバッファ単位に正規化済みのため、チャンクも正規化されている。

## Edge Cases

- **マイク切替**: 入力デバイスが変わるとレベルが急変する可能性がある。
  減衰ピークトラッカーはwindowDuration内で自然に適応する。
- **完全無音**: runningPeak < 1e-6 の場合はgain=1.0で正規化をスキップ。
- **セッション間**: startStreamingでリセットされるため、前セッションの影響なし。

## Testing

### AudioLevelNormalizerTests（単体テスト）

- 小さい入力がブーストされること
- 十分大きい入力は変更されないこと（gain=1.0、減衰しない）
- 最大ゲイン制限が機能すること
- クリッピング保護（±1.0クランプ）
- 減衰ピークトラッカーの動作
- ゼロ除算保護（無音入力）
- 初期ゲインが1.0であること

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
