# VAD駆動動的チャンキング vs 固定チャンキング 評価計画

## Context

PR #60でChunkAccumulatorをVADChunkAccumulatorに置換した。固定5秒チャンクから、音声活動検出（VAD）による動的チャンキングへの移行は、アプリの文字起こしパイプラインの根幹に関わる変更である。

**目的**: VAD実装が固定チャンキングと比較して実際にメリットをもたらしているか、定量的に評価し、keep/discard判断の根拠を得る。

**重要な発見**: 既存のBenchmarkRunnerは`whisperKit.transcribe(audioPath:)`を直接呼び出しており、カスタムチャンキングパイプラインを完全にバイパスしている。つまり、既存ベンチマーク結果はVADの効果を一切反映していない。**新規ベンチマークコードが必要**。

## 評価の3軸

| 軸 | 指標 | 意義 |
|---|---|---|
| **WER** | Word Error Rate (EN) / Character Error Rate (JA) | チャンキング方式が文字起こし精度に与える影響 |
| **レイテンシ** | チャンク生成までの時間分布 | ユーザ体感の応答速度 |
| **ダイアライゼーション** | チャンク精度・ラベルフリップ | 自然な発話境界が話者検出を改善するか |

## Step 1: FixedChunkSimulator作成

旧ChunkAccumulatorの動作を再現するシンプルなシミュレータを作成し、同一バイナリ内でVADと比較可能にする。

**ファイル**: `Tests/QuickTranscriberBenchmarks/FixedChunkSimulator.swift`

```swift
/// 旧ChunkAccumulatorの動作を再現するシミュレータ
struct FixedChunkSimulator {
    let chunkDuration: TimeInterval      // 5.0s (旧デフォルト)
    let silenceCutoff: TimeInterval       // 0.8s
    let silenceThreshold: Float           // 0.01
    let minimumChunkDuration: TimeInterval // 1.0s
    let silenceSkipThreshold: Float       // 0.005 (エンジン側スキップ)

    mutating func appendBuffer(_ samples: [Float]) -> ChunkResult?
    mutating func flush() -> ChunkResult?
}
```

旧コードの動作:
- バッファに全サンプル蓄積
- `totalDuration >= chunkDuration(5s)` → 強制カット
- `trailingSilence >= silenceCutoff(0.8s) && totalDuration >= minimumChunkDuration(1.0s)` → 早期カット
- エンジン側: `energy < 0.005` のチャンクはスキップ（silenceSinceLastSegmentに加算）

## Step 2: ChunkedTranscriptionBenchmark作成

ストリーミングパイプラインをシミュレートする新ベンチマークランナー。

**ファイル**: `Tests/QuickTranscriberBenchmarks/ChunkedTranscriptionBenchmarkRunner.swift`

### 動作フロー
1. 音声ファイルを16kHz monoでロード
2. 100ms（1600サンプル）ずつアキュムレータに投入（ストリーミング模擬）
3. ChunkResult発生時にChunkTranscriber（WhisperKit）で文字起こし
4. 品質フィルタ（shouldFilterByMetadata, shouldFilterSegment）適用
5. 全セグメントを連結してリファレンスとWER比較

### 測定メトリクス

```swift
struct ChunkedBenchmarkResult: Codable {
    let fixture: String
    let label: String                    // "vad" or "fixed"
    let language: String
    let wer: Double
    let audioDurationSeconds: Double
    let totalInferenceSeconds: Double    // WhisperKit推論合計時間
    let realtimeFactor: Double
    let chunkCount: Int                  // 生成チャンク数
    let skippedChunkCount: Int           // スキップされた無音チャンク数
    let avgChunkDurationSeconds: Double  // 平均チャンク長
    let p50ChunkDurationSeconds: Double  // 中央値チャンク長
    let p95ChunkDurationSeconds: Double  // 95パーセンタイルチャンク長
    let minChunkDurationSeconds: Double  // 最短チャンク長
    let maxChunkDurationSeconds: Double  // 最長チャンク長
    let firstChunkLatencySeconds: Double // 最初のチャンク出力までの時間
    let transcribedText: String
    let referenceText: String
    let peakMemoryMB: Double
}
```

### 再利用する既存コード
- `BenchmarkTestBase.swift`: WhisperKit初期化
- `BenchmarkRunner.calculateWER()`: WER計算（Levenshtein距離ベース）
- `BenchmarkRunner.currentMemoryMB()`: メモリ測定
- `DatasetBenchmarkTestBase.loadDatasetReferences()`: データセットロード
- `DiarizationBenchmarkTestBase.loadAudioSamples()`: WAVファイル読み込み
- `TranscriptionUtils.shouldFilterByMetadata()`, `shouldFilterSegment()`: 品質フィルタ
- `TranscriptionUtils.cleanSegmentText()`: テキスト正規化

## Step 3: WER比較テスト

**ファイル**: `Tests/QuickTranscriberBenchmarks/ChunkedTranscriptionTests.swift`

### テストケース

| テスト | データセット | サンプル数 | 言語 | 目的 |
|--------|-------------|-----------|------|------|
| FLEURS EN VAD vs Fixed | fleurs_en | 50 | en | 短い発話での比較 |
| FLEURS JA VAD vs Fixed | fleurs_ja | 50 | ja | 日本語短い発話 |
| LibriSpeech VAD vs Fixed | librispeech_test_other | 50 | en | ノイジー英語 |
| ReazonSpeech VAD vs Fixed | reazonspeech_test | 50 | ja | ノイジー日本語TV |

各テストは同一音声に対してVADとFixed両方を実行し、結果をペアで出力。

### 出力先
- `/tmp/quicktranscriber_chunked_comparison.json`

## Step 4: レイテンシ比較テスト

Step 3のChunkedBenchmarkResultに含まれるチャンク長統計で評価。追加テストは不要。

## Step 5: ダイアライゼーション比較テスト

既存のDiarizationBenchmarkTestBaseを拡張し、VAD方式のチャンク分割をサポートする。

**ファイル**: `Tests/QuickTranscriberBenchmarks/ChunkedDiarizationTests.swift`

### テストケース

| テスト | データセット | 会話数 | 設定 |
|--------|-------------|--------|------|
| CALLHOME EN Fixed | callhome_en | 5 | 5sチャンク, Viterbi stayProb=0.80, speakers=2 |
| CALLHOME EN VAD | callhome_en | 5 | VAD, Viterbi stayProb=0.80, speakers=2 |
| CALLHOME JA Fixed | callhome_ja | 5 | 同上 |
| CALLHOME JA VAD | callhome_ja | 5 | 同上 |
| AMI Fixed | ami | 5 | 5sチャンク, Viterbi stayProb=0.80, speakers=GT |
| AMI VAD | ami | 5 | VAD, Viterbi stayProb=0.80, speakers=GT |

## Step 6: 世界ポジショニング分析

ベンチマーク結果を以下の学術データと比較する。

### 学術ベンチマーク参照値

| モデル | パラメータ | LibriSpeech test-clean | LibriSpeech test-other |
|--------|-----------|----------------------|----------------------|
| **Whisper large-v3-turbo** | 809M | ~2.27% | ~4.24% |
| Whisper large-v3 | 1.55B | ~2.7% | ~5.2% |
| WhisperKit (on-device FP16) | 1.55B | 1.93% | — |

## Step 7: 判断フレームワーク

### Keep判定基準
以下の**いずれか**が満たされればVAD実装をkeep:

| 条件 | 閾値 |
|------|------|
| WER改善 | VAD WER < Fixed WER (全データセット平均) |
| レイテンシ改善 | p50チャンク長がFixed以下 |
| ダイアライゼーション改善 | accuracy差 > -2pp かつ flips減少 |

### Discard判定基準
以下の**いずれか**が満たされればdiscard:

| 条件 | 閾値 |
|------|------|
| WER悪化 | VAD WER > Fixed WER + 2% (abs) |
| レイテンシ悪化 | p95チャンク長 > 10s |
| ダイアライゼーション悪化 | accuracy低下 > 5pp |
