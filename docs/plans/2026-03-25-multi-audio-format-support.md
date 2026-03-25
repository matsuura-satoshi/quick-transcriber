# 音声ファイル形式の複数対応

## Context

現在ファイル文字起こし機能はWAVのみテスト済みだが、コード上は`AVAudioFile`と`UTType.audio`を使用しており、Apple Audio Toolboxがサポートする形式は**既に技術的に対応可能**。ユーザーがMP3等の主要形式をドロップしても動作するはずだが、未検証・未テストであり、エラーハンドリングも不十分。

## AVAudioFileがmacOSでネイティブサポートする形式

| 形式 | 拡張子 | 対応状況 |
|------|--------|----------|
| WAV | .wav | 対応済み（テスト済み） |
| MP3 | .mp3 | 対応（Audio Toolbox） |
| AAC/M4A | .m4a, .aac | 対応（Audio Toolbox） |
| ALAC | .m4a | 対応（Audio Toolbox） |
| AIFF | .aiff, .aif | 対応（Audio Toolbox） |
| FLAC | .flac | 対応（macOS 11+） |
| CAF | .caf | 対応（Core Audio Format） |

**AVAudioFileが非対応の形式:** OGG Vorbis, Opus, WMA, WebM/WebA
→ これらは現行フレームワークでは対応不可。対応するには外部ライブラリ（FFmpeg等）が必要になり、スコープ外。

## 結論

**コード変更は最小限で済む。** `AVAudioFile`と`AVAudioConverter`が既にフォーマット変換を処理しているため、新たなデコーダやライブラリは不要。必要なのはエラーハンドリングの改善とテスト追加。

## 変更内容

### 1. エラーハンドリング改善（FileAudioSource / ViewModel）

**ファイル:** `Sources/QuickTranscriber/Audio/FileAudioSource.swift`

- `AVAudioFile(forReading:)` が失敗した場合、現在は生の`NSError`がそのまま表示される
- ファイル形式に起因するエラーを検出し、ユーザーフレンドリーなメッセージを返す
- `AudioCaptureError` に新ケース `unsupportedFileFormat(String)` を追加

```swift
// AVAudioCaptureService.swift - AudioCaptureError に追加
case unsupportedFileFormat(String)

// errorDescription
case .unsupportedFileFormat(let ext):
    return "Unsupported audio format: .\(ext). Supported formats: WAV, MP3, M4A, AAC, FLAC, AIFF, CAF."
```

**ファイル:** `Sources/QuickTranscriber/Audio/FileAudioSource.swift`

- `startCapture` 冒頭で `AVAudioFile(forReading:)` の失敗を捕捉し、拡張子情報を含むエラーに変換

```swift
let audioFile: AVAudioFile
do {
    audioFile = try AVAudioFile(forReading: fileURL)
} catch {
    let ext = fileURL.pathExtension.lowercased()
    throw AudioCaptureError.unsupportedFileFormat(ext)
}
```

### 2. テスト追加（複数形式の読み込み検証）

**ファイル:** `Tests/QuickTranscriberTests/FileAudioSourceTests.swift`

AVFoundationを使って各形式のテストファイルをプログラム生成し、FileAudioSourceで読み込めることを検証:

- `testMP3FileCanBeRead` — MP3形式
- `testM4AFileCanBeRead` — M4A/AAC形式
- `testAIFFFileCanBeRead` — AIFF形式
- `testFLACFileCanBeRead` — FLAC形式
- `testCAFFileCanBeRead` — CAF形式
- `testUnsupportedFormatShowsDescriptiveError` — 非対応拡張子(.ogg等)

テストファイル生成: `AVAudioFile(forWriting:settings:commonFormat:interleaved:)` で各形式のファイルを作成。MP3/M4A等の圧縮形式は`AVAudioFile`の書き込みでは直接生成できないため、`AVAssetWriter`または`AudioFileCreateWithURL`を使用。

### 修正対象ファイル一覧

1. `Sources/QuickTranscriber/Audio/AVAudioCaptureService.swift` — `AudioCaptureError` に `unsupportedFileFormat` 追加
2. `Sources/QuickTranscriber/Audio/FileAudioSource.swift` — エラーハンドリング改善
3. `Tests/QuickTranscriberTests/FileAudioSourceTests.swift` — 複数形式テスト追加

## 検証方法

1. `swift test --filter FileAudioSourceTests` — 新規テスト全パス
2. `swift test --filter QuickTranscriberTests` — 既存テスト回帰なし
3. 手動: 実際のMP3/M4Aファイルをドロップして文字起こし動作確認
