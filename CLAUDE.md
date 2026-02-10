# MyTranscriber

macOSリアルタイム文字起こしアプリ。WhisperKit (large-v3-turbo) + SwiftUI。

## Build & Run
```
swift build && swift run MyTranscriber
```

## Architecture
MVVM: Views -> TranscriptionViewModel -> TranscriptionService -> TranscriptionEngine(protocol) -> WhisperKitEngine
AudioStreamTranscriber がマイクキャプチャ+VAD+推論を一体で処理するため、AudioCaptureServiceは不要。

## Pitfalls
- WhisperKit init には `load: true` 必須（省略するとtokenizerがロードされない）
- モデル名は `large-v3-v20240930_turbo`（WhisperKit命名規則）
- `cpuAndGPU` compute でANEコンパイルをスキップ（起動~1秒。ANEだと~70秒）
- DecodingOptions に `skipSpecialTokens: true, withoutTimestamps: true` 必須
- macOS GUIアプリでは `print()` が出ない。デバッグは `NSLog` を使う
- テスト実行にはXcodeが必要（Command Line Toolsのみでは不可）
