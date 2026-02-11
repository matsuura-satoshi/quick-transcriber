# MyTranscriber

macOSリアルタイム文字起こしアプリ。WhisperKit (large-v3-turbo) + SwiftUI。

## Build & Run
```
swift build && swift run MyTranscriber
```

## Test
```bash
# ユニットテスト（モデル不要、~2秒）
swift test --filter MyTranscriberTests

# ベンチマーク全体（モデル必要、5-10分）
swift test --filter MyTranscriberBenchmarks

# 特定ベンチマーク
swift test --filter ParameterBenchmarkTests
swift test --filter LibriSpeechBenchmarkTests
swift test --filter ReazonSpeechBenchmarkTests
```

## Architecture
- **ターゲット構成**: `MyTranscriberLib`(library) + `MyTranscriber`(executable)
- MVVM: Views -> TranscriptionViewModel -> TranscriptionService -> TranscriptionEngine(protocol) -> WhisperKitEngine
- AudioStreamTranscriber がマイクキャプチャ+VAD+推論を一体で処理（AudioCaptureService不要）

## Pitfalls
- WhisperKit init には `load: true` 必須（省略するとtokenizerがロードされない）
- モデル名は `large-v3-v20240930_turbo`（WhisperKit命名規則）
- `cpuAndGPU` compute でANEコンパイルをスキップ（起動~1秒。ANEだと~70秒）
- DecodingOptions に `skipSpecialTokens: true, withoutTimestamps: true` 必須
- macOS GUIアプリでは `print()` が出ない。デバッグは `NSLog` を使う
- テスト実行にはXcodeが必要（Command Line Toolsのみでは不可）
- `sampleLength` は最大224（WhisperKit内部バッファ制限。448でfatalError）

## Benchmark Datasets
`Scripts/download_datasets.py` でダウンロード:
```bash
pip3 install "datasets>=3.0,<4.0" soundfile librosa
python3 Scripts/download_datasets.py
```
出力先: `~/Documents/MyTranscriber/test-audio/`（fleurs_en, fleurs_ja, librispeech_test_other, reazonspeech_test）
