# Speaker Diarization Benchmark Design

## Overview

話者特定（speaker diarization）の自動テストとパラメータチューニングの設計。
CALLHOMEデータセットを使い、ストリーミング方式のシミュレーションテストで評価する。

## Phase 1: データセット取得

### 対象
- **CALLHOME English**: 英語電話会話、2話者、~120会話
- **CALLHOME Japanese**: 日本語電話会話、2話者、~120会話
- ソース: HuggingFace `talkbank/callhome` (CC BY-NC-SA)

### ダウンロード
- `Scripts/download_datasets.py` を拡張
- 各言語50会話をランダムサンプリング（seed=42）

### 保存フォーマット
```
~/Documents/QuickTranscriber/test-audio/
  callhome_en/
    en_0000.wav    # 16kHz PCM mono
    en_0001.wav
    ...
    references.json
  callhome_ja/
    ja_0000.wav
    ...
    references.json
```

#### references.json 形式
```json
{
  "en_0000": {
    "language": "en",
    "duration_seconds": 312.5,
    "speakers": 2,
    "segments": [
      {"start": 0.0, "end": 2.3, "speaker": "A"},
      {"start": 1.8, "end": 5.1, "speaker": "B"}
    ]
  }
}
```

## Phase 2: シミュレーションテスト

### テストフロー
1. CALLHOMEの1会話分の音声をロード
2. 固定長チャンクに分割（デフォルト3秒）
3. 各チャンクを `FluidAudioSpeakerDiarizer.identifySpeaker()` に逐次投入
4. 出力ラベルをハンガリアンアルゴリズムで正解にマッピングし比較

### 評価指標
| 指標 | 説明 |
|---|---|
| **チャンクレベル正答率** | 各チャンクの多数派話者 vs 予測ラベルの一致率 |
| **話者数正答率** | 検出話者数 vs 実際話者数 |
| **ラベル安定性** | 同一話者の連続発言でラベルが変わった回数 |
| **初期収束時間** | 話者ラベルが安定するまでのチャンク数 |

### ラベルマッチング
- 予測ラベル(A, B, ...)と正解ラベル(spk_0, spk_1)の対応をハンガリアンアルゴリズムで最適化
- 会話ごとにマッピングを計算

### テストファイル配置
`Tests/QuickTranscriberBenchmarks/DiarizationBenchmarkTests.swift`

## Phase 3: パラメータチューニング

### 調整対象パラメータ

| パラメータ | 現在値 | テスト範囲 | 仮説 |
|---|---|---|---|
| similarityThreshold | 0.5 | 0.3, 0.4, 0.5, 0.6, 0.7 | 低→同一視、高→分裂 |
| updateAlpha | 0.3 | 0.1, 0.2, 0.3, 0.5 | 高→追従しすぎ、低→適応遅い |
| chunkDuration | 3.0s | 3.0, 5.0, 7.0 | 長→embedding品質↑、レイテンシ↑ |
| windowDuration | 30.0s | 15, 30, 45, 60 | 短→コンテキスト不足、長→計算コスト↑ |
| confirmationThreshold | 2 | 1, 2, 3 | 高→確定遅延、低→誤確定 |

### テスト方針
- 1パラメータずつ変更（他は固定）
- 優先順: similarityThreshold → chunkDuration → windowDuration → updateAlpha → confirmationThreshold
- chunkDuration変更時はWERも同時測定（文字起こし品質の副作用チェック）
- 各設定でCALLHOME EN 50会話 + JA 50会話を実行

### コサイン類似度閾値の根拠
- 現在の0.5は経験的初期値（厳密な根拠なし）
- 話者検証文献の一般的な範囲: 同一話者 0.6-0.9、異なる話者 0.1-0.5
- 0.5は境界値のため、データ駆動で最適化する価値がある

### チャンク長変更の副作用リスク
- 文字起こしレイテンシ増加
- 長チャンクに複数話者が混在するリスク
- WhisperKit 30秒パディングとの相互作用は変わらない（品質フィルタnil必須は維持）
- 改善が大きい場合のみ採用、副作用を慎重に測定
