# Quick Transcriber

macOSリアルタイム文字起こしアプリ。WhisperKit (large-v3-turbo) + SwiftUI。

## Development Rules
実装の全ての過程において、該当するsuperpowersスキルを必ず利用すること。全てのシーンに対応するスキルが存在する。スキップしてはならない。

例:
- 機能追加・設計判断の前に `superpowers:brainstorming` で要件と設計を探索する
- 実装コードを書く前に `superpowers:test-driven-development` でテストファーストを徹底する
- 完了を宣言する前に `superpowers:verification-before-completion` で検証を行う

## Build & Run
```bash
swift build && swift run QuickTranscriber

# .app バンドルをビルド（配布用）
./Scripts/build_app.sh
# → build/QuickTranscriber.app, build/QuickTranscriber-v{version}.zip
```

## Test
```bash
# ユニットテスト（モデル不要、~2秒）
swift test --filter QuickTranscriberTests

# ベンチマーク全体（モデル必要、5-10分）
swift test --filter QuickTranscriberBenchmarks

# 特定ベンチマーク
swift test --filter ParameterBenchmarkTests
swift test --filter LibriSpeechBenchmarkTests
swift test --filter ReazonSpeechBenchmarkTests
```

## Architecture
- **ターゲット構成**: `QuickTranscriberLib`(library) + `QuickTranscriber`(executable)
- MVVM: Views -> TranscriptionViewModel -> TranscriptionService -> TranscriptionEngine(protocol) -> ChunkedWhisperEngine
- ChunkedWhisperEngine: AudioCaptureService → ChunkAccumulator → ChunkTranscriber(WhisperKit) のパイプライン
- 短チャンク（3秒等）の品質フィルタは全てnil必須（30秒パディングで90%無音になるため）

## Speaker State Mutation Checklist
話者アイデンティティを変更する操作を追加・修正する際:
1. SpeakerStateCoordinator経由で操作しているか？
2. 関連コンポーネントが全て更新されるか？（Tracker, Viterbi, Segments, ActiveSpeakers, DisplayNames, ProfileStore, EmbeddingHistory）
3. InvariantCheckerが通過するか？
4. クロスコンポーネントのテストがあるか？

## Pitfalls
- WhisperKit init には `load: true` 必須（省略するとtokenizerがロードされない）
- モデル名は `large-v3-v20240930_turbo`（WhisperKit命名規則）
- `cpuAndGPU` compute でANEコンパイルをスキップ（起動~1秒。ANEだと~70秒）
- DecodingOptions に `skipSpecialTokens: true, withoutTimestamps: true` 必須
- macOS GUIアプリでは `print()` が出ない。デバッグは `NSLog` を使う
- テスト実行にはXcodeが必要（Command Line Toolsのみでは不可）
- `sampleLength` は最大224（WhisperKit内部バッファ制限。448でfatalError）

## Versioning
- 形式: `Major.Minor.PR#`（例: 1.0.57）、表示形式は `v1.0.57`
- 定義場所: `Constants.Version`（Constants.swift）
- `string`は数値のみ、`versionString`は`v`付き
- PR作成時に `Constants.Version.patch` を該当PR番号に更新すること
- **patchの更新はPRのコミット内でのみ行う**（main直pushでバージョンを変更しない）
- リリースタグ: `v{Major}.{Minor}.{PR#}`（例: `v1.0.57`）

## Benchmark Datasets
`Scripts/download_datasets.py` でダウンロード:
```bash
pip3 install "datasets>=3.0,<4.0" soundfile librosa
python3 Scripts/download_datasets.py
```
出力先: `~/Documents/QuickTranscriber/test-audio/`（fleurs_en, fleurs_ja, librispeech_test_other, reazonspeech_test）
