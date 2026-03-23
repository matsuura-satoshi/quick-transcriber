# 音声録音機能の追加

## Context

Quick Transcriberに音声録音機能を追加する。主な目的は：
1. 録音データ + Zoom文字起こし（完璧な話者ラベル付き）でダイアライゼーションのベンチマーク・パラメータチューニングを可能にする
2. 会議の音声アーカイブとして活用

設計決定：
- **サンプルレート**: 16kHz（WhisperKitパイプラインと同一、ベンチマーク直接投入可能）
- **タップポイント**: 正規化後（AudioLevelNormalizer適用済み = WhisperKitが処理する信号と同一）
- **フォーマット**: WAVのみ（初回リリース。M4Aは将来追加可能）
- **ファイル名**: 文字起こしと同一プレフィックス `YYYY-MM-DD_HHmm_qt_recording.wav`

## Step 1: AudioRecordingService の作成

**新規ファイル**: `Sources/QuickTranscriberLib/Services/AudioRecordingService.swift`

WAVファイルへのストリーミング書き込みサービス。TranscriptFileWriterと同様のセッションライフサイクル。

```swift
public final class AudioRecordingService {
    private let writeQueue = DispatchQueue(label: "audio-recording-write", qos: .utility)
    private var fileHandle: FileHandle?
    private var currentFileURL: URL?
    private var sampleCount: Int = 0

    func startSession(directory: URL, datePrefix: String)
    func appendSamples(_ samples: [Float])  // writeQueue.asyncで非ブロッキング書き込み
    func endSession()                        // WAVヘッダーを正しいサイズで書き直し
}
```

WAV書き込み戦略：
- セッション開始時に44バイトのプレースホルダーヘッダーを書く
- `appendSamples`でFloat32→Int16変換してPCMデータを追記（writeQueue.async）
- `endSession`でファイル先頭のRIFFチャンクサイズ（byte 4）とdataチャンクサイズ（byte 40）を書き戻す
- WAVスペック: 16kHz, 16-bit, mono PCM → 約115MB/時

## Step 2: Constants に録音関連定数を追加

**変更ファイル**: `Sources/QuickTranscriberLib/Constants.swift`

```swift
public enum AudioRecording {
    public static let fileSuffix = "_qt_recording"
    public static let sampleRate: Double = 16000.0
    public static let channels: UInt16 = 1
    public static let bitsPerSample: UInt16 = 16
}
```

## Step 3: ChunkedWhisperEngine に録音サービスを統合

**変更ファイル**: `Sources/QuickTranscriberLib/Engines/ChunkedWhisperEngine.swift`

- `audioRecorder: AudioRecordingService?` プロパティ追加
- `startStreaming()`: 録音設定が有効なら `AudioRecordingService` を生成・開始
  - datePrefix と directory は新しいパラメータで受け取る
- ストリーミングループ（line 123付近）: `normalizedSamples` を `audioRecorder?.appendSamples()` に渡す
- `stopStreaming()`: `audioRecorder?.endSession()` を呼んでnil化

録音設定の伝達方法：`startStreaming()` に録音用パラメータを追加（TranscriptionParametersは変更しない — 録音はトランスクリプションのパラメータではないため）

```swift
public func startStreaming(
    language: String,
    parameters: TranscriptionParameters = .default,
    participantProfiles: [(speakerId: UUID, embedding: [Float])]? = nil,
    audioRecordingDirectory: URL? = nil,   // 追加
    audioRecordingDatePrefix: String? = nil, // 追加
    onStateChange: @escaping @Sendable (TranscriptionState) -> Void
) async throws
```

## Step 4: TranscriptionEngine プロトコル・TranscriptionService 更新

**変更ファイル**:
- `Sources/QuickTranscriberLib/Engines/TranscriptionEngine.swift` — `startStreaming` シグネチャ更新
- `Sources/QuickTranscriberLib/Services/TranscriptionService.swift` — パラメータ透過

## Step 5: TranscriptionViewModel で録音設定を読み取り・伝達

**変更ファイル**: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift`

`startRecording()`内で：
1. `UserDefaults.standard.bool(forKey: "audioRecordingEnabled")` を読む
2. 有効なら `datePrefix`（TranscriptFileWriterと同じ形式）を生成
3. `service.startTranscription()` に `audioRecordingDirectory` と `datePrefix` を渡す

datePrefixの共有：TranscriptFileWriterとAudioRecordingServiceが同じ分内に開始するため、それぞれが `Date()` で生成すれば自然に一致する。ただし確実性のため、ViewModel側で一度生成して両方に渡す設計にする。

→ TranscriptFileWriter.startSession() にも `datePrefix` パラメータを追加し、両者で同一のプレフィックスを使用する。

## Step 6: Output設定画面にUIを追加

**変更ファイル**: `Sources/QuickTranscriber/Views/SettingsView.swift` (OutputSettingsTab)

既存の "Transcript Output" セクションの下に追加：

```swift
Section("Audio Recording") {
    Toggle("Record audio during transcription", isOn: $audioRecordingEnabled)
    if audioRecordingEnabled {
        Text("Audio is saved as WAV (16kHz mono) alongside the transcript file.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}
```

`@AppStorage` キー:
- `"audioRecordingEnabled"` (Bool, デフォルト `false`)

録音中はトグル変更を無効化する（既存の `isRecording` フラグを使用）。

## Step 7: テスト

**新規ファイル**: `Tests/QuickTranscriberTests/AudioRecordingServiceTests.swift`

テストケース：
1. `testStartSessionCreatesWavFile` — ファイル生成確認
2. `testAppendSamplesWritesCorrectData` — Float32→Int16変換とPCMデータの検証
3. `testEndSessionFinalizesWavHeader` — ヘッダーのサイズフィールドが正しいか
4. `testFilenameFormat` — `YYYY-MM-DD_HHmm_qt_recording.wav` 形式の検証
5. `testRoundTrip` — 書いたサンプルを読み戻して一致確認
6. `testEndSessionWithoutStartIsNoOp` — 安全性
7. `testMultipleSessions` — 複数セッションで複数ファイル生成

## 変更対象ファイル一覧

| ファイル | 変更内容 |
|---------|---------|
| `Services/AudioRecordingService.swift` | **新規** — WAVストリーミング書き込み |
| `Constants.swift` | `AudioRecording` enum追加 |
| `Engines/ChunkedWhisperEngine.swift` | recorder統合（startStreaming/loop/stop） |
| `Engines/TranscriptionEngine.swift` | startStreamingシグネチャ更新 |
| `Services/TranscriptionService.swift` | 録音パラメータ透過 |
| `Services/TranscriptFileWriter.swift` | startSession()にdatePrefixパラメータ追加 |
| `ViewModels/TranscriptionViewModel.swift` | 設定読み取り・datePrefix生成・伝達 |
| `Views/SettingsView.swift` | OutputSettingsTabに録音トグル追加 |
| `Tests/.../AudioRecordingServiceTests.swift` | **新規** — ユニットテスト |

## 検証方法

1. `swift test --filter QuickTranscriberTests` — 全テスト通過
2. `swift build` — ビルド成功
3. 手動テスト:
   - Settings > Output で録音を有効化
   - 録音開始 → 数秒話す → 停止
   - `~/QuickTranscriber/` に `.wav` ファイルと `.md` ファイルが同じプレフィックスで生成されていることを確認
   - WAVファイルをQuickTime等で再生して音声が正常か確認
   - 録音無効時はWAVファイルが生成されないことを確認
