# File Drop Transcription Design

## Context

Quick Transcriberはリアルタイム文字起こし専用アプリだが、録音済み音声ファイルの文字起こし機能を追加する。主な動機：

1. 会議終了後に録音データ（PR#72で追加したWAV録音）を高精度で再文字起こし
2. 外部音声ファイル（Zoom録音等）の文字起こし
3. ベンチマーク用途：録音+Zoom文字起こしでダイアライゼーション評価

## Requirements

- 音声ファイルをメインウィンドウにドラッグ&ドロップで文字起こし開始
- リアルタイム性不要のため、WhisperKitパラメータを精度優先に調整
- 既存テキストがある場合は確認ダイアログで置き換えを選択
- 話者プロファイル（speakers.json）を引き継いで再ダイアライゼーション
- 対応形式：AVAudioFileで読めるもの全て（WAV, M4A, MP3, CAF等）
- 処理中はプログレス表示＋キャンセル可能
- 設定画面に項目を増やさない（煩わしくない）
- モデル未ロード時はドロップを拒否

## Architecture

### Processing Pipeline

既存のリアルタイムパイプラインを再利用する。ファイルモード用に**別インスタンス**の `ChunkedWhisperEngine` を `FileAudioSource` 注入で生成し、既存のマイク用エンジンとは独立して動作させる。

```
File Drop → FileAudioSource (decode + resample to 16kHz mono)
  ↓ [100ms buffers via onBuffer callback]
ChunkedWhisperEngine (file mode instance)
  → AudioLevelNormalizer → VADChunkAccumulator → ChunkTranscriber → SpeakerDiarizer
  ↓
ConfirmedSegments → UI
```

**別インスタンスにする理由**：
- `ChunkedWhisperEngine.audioCaptureService` は `let`（イミュータブル）でinit時に注入
- プロトコル `TranscriptionEngine` のシグネチャ変更が不要
- 既存のマイク用エンジンに影響を与えない

### FileAudioSource

`AudioCaptureService` プロトコル準拠。`startCapture(onBuffer:)` は**即座にreturn**し、内部で `Task` を生成してバッファを非同期に供給する（既存の `AVAudioCaptureService` と同じ契約）。

```swift
public final class FileAudioSource: AudioCaptureService {
    private let fileURL: URL
    private var readingTask: Task<Void, Never>?
    var onProgress: ((Double) -> Void)?

    func startCapture(onBuffer: @escaping ([Float]) -> Void) async throws
    func stopCapture()
}
```

実装：
1. `AVAudioFile` でファイルを開く（失敗時はthrow）
2. 内部 `Task` を生成して `startCapture` から即座にreturn
3. Task内で `AVAudioFile.read(into:frameCount:)` を増分読み出し（ファイル全体をメモリに載せない）
4. `AVAudioConverter` で16kHz mono Float32に変換
5. 1600サンプル（100ms）単位で `onBuffer` コールバックに渡す
6. バッファ間で `Task.yield()` を入れつつ、処理速度を制御するため前のチャンクが消化されるのを待つ簡易バックプレッシャー機構を入れる（`AsyncStream` のバッファリングポリシー or セマフォ）
7. `onProgress` コールバックで進捗を通知（読み出し位置 / 全フレーム数）
8. ファイル終端到達で `onBuffer` の供給を停止（エンジン側のストリーム終了をトリガー）
9. `stopCapture()` で `readingTask?.cancel()` → キャンセル時はTaskのキャンセルチェックでループ終了

### 精度優先パラメータ

ファイルモード時、TranscriptionParametersを以下に変更：
- `chunkDuration`: 15s（リアルタイムの8sから延長、より長いコンテキスト）
- `endOfUtteranceSilence`: 1.0s（文途中カット防止）
- `temperatureFallbackCount`: 2（初回失敗時にリトライ）
- 音声録音: 無効（`audioRecordingDirectory: nil`）
- その他パラメータは既存値を維持

これらはコード内の固定値とし、設定UIには露出しない。

## State Management

`TranscriptionViewModel` に `isTranscribingFile: Bool` を追加。

既存の `isRecording` と排他：
- `isRecording == true` → マイク録音中（ファイルドロップ無効）
- `isTranscribingFile == true` → ファイル処理中（録音ボタン無効、スペースキー → キャンセル）
- 両方 `false` → アイドル（ドロップ受付可能）

`fileTranscriptionProgress: Double` で進捗を保持（0.0-1.0）。`FileAudioSource.onProgress` コールバック経由で `@MainActor` 上で更新。

## UI Design

### Drop Zone

**非録音時・テキスト空**: 文字起こしエリアに薄いオーバーレイでドロップヒントを表示。
**テキストあり**: ドロップヒントは非表示だが、ドロップは受付可能（確認ダイアログが出る）。

`.onDrop(of: [.audio])` で `UTType.audio` を受け付ける。`NSItemProvider.loadFileRepresentation(forTypeIdentifier:)` でURLを取得。複数ファイルドロップ時は最初の1つのみ処理。

### ドラッグ中ハイライト

`.onDrop` の `isTargeted` パラメータでハイライト制御。エリアの枠をアクセントカラーで表示。

### 既存テキストがある場合

確認ダイアログ（`.alert`）:
- タイトル: "Re-transcribe from file?"
- メッセージ: "This will replace the current transcription. Speaker profiles will be preserved."
- ボタン: "Replace" / "Cancel"

### 処理中

- StatusBar: ファイル名 + プログレス（"Transcribing meeting.wav... 45%"）
- 録音ボタン: 無効化
- キャンセル: StatusBarのStopボタンまたはスペースキーで停止

### モデル未ロード時

ファイルドロップを受け付けない（`modelState != .ready` でドロップハンドラーがfalseを返す）。

## Speaker Information Handling

ファイル文字起こし時、既存の話者プロファイルとアクティブ話者をそのまま引き継ぐ：
- `SpeakerProfileStore`（speakers.json）のプロファイルがファイルモード用エンジンにロードされる
- `SpeakerStateCoordinator` のアクティブ話者が保持される
- ダイアライゼーションモード（auto/manual）は現在の設定を使用
- `EmbeddingHistoryStore` は既存のマイクエンジンと共有

前のセッションで学習したembeddingが活きるため、話者識別精度が向上する。

## Integration Points

### TranscriptionViewModel

```swift
@Published var isTranscribingFile = false
@Published var fileTranscriptionProgress: Double = 0.0
private var fileTranscriptionEngine: ChunkedWhisperEngine?

func transcribeFile(_ url: URL)
func cancelFileTranscription()
```

`transcribeFile` フロー：
1. `modelState == .ready` チェック
2. マイク録音中なら `await service.stopTranscription()` を待機してから進む（ChunkTranscriber競合防止）
3. 既存テキストがあれば `showReplaceFileAlert = true` でreturn（UIが確認ダイアログ表示）
4. テキストクリア + `isTranscribingFile = true`
5. `FileAudioSource(fileURL: url)` を生成、`onProgress` と `onComplete` コールバック設定
6. `ChunkedWhisperEngine(audioCaptureService: fileAudioSource, transcriber: 既存と共有, diarizer: 既存と共有, speakerProfileStore: 既存と共有, embeddingHistoryStore: 既存と共有)` で新エンジン生成
7. `TranscriptionService` は使わず `fileTranscriptionEngine.startStreaming()` を直接呼ぶ（`TranscriptionService` は `isReady` ガードがあり、新インスタンスでは `prepare()` が必要になるため。エンジン直接呼び出しで回避）
8. ファイルモード用パラメータで `startStreaming()` 呼び出し
9. `fileAudioSource.onProgress` で `fileTranscriptionProgress` を `@MainActor` 上で更新
10. `fileAudioSource.onComplete` で完了検知 → `stopStreaming()` → `isTranscribingFile = false` → TranscriptFileWriter でファイル出力

`cancelFileTranscription` フロー：
1. `fileTranscriptionEngine?.stopStreaming(speakerDisplayNames: [:])` — 空のdisplayNamesを渡すことで、`compactMap` が全て nil を返し profile merge がスキップされる
2. FileAudioSourceの `stopCapture()` → readingTask キャンセル
3. テキストクリア（処理途中のテキストは破棄）
4. `isTranscribingFile = false`
5. `fileTranscriptionEngine = nil`

### FileAudioSource コールバック

```swift
var onProgress: ((Double) -> Void)?   // 0.0-1.0、読み出し位置/全フレーム数
var onComplete: (() -> Void)?          // ファイル終端到達時に呼ばれる
```

`onComplete` は `readingTask` 内でファイル末尾到達後に呼ばれる。ViewModel側でこのコールバックを受けて `stopStreaming()` を実行し、ストリーム終了をトリガーする。

### ChunkedWhisperEngine

変更なし。`audioCaptureService` は既にinit注入パターンなので、`FileAudioSource` をそのまま渡せる。

**ChunkTranscriber共有とスレッド安全性**: WhisperKitインスタンスはスレッドセーフではない。`transcribeFile()` はマイク録音停止の `await` 完了を待ってから開始する。`isTranscribingFile` フラグでファイル処理中のマイク録音開始を排他制御する。`TranscriptionState.isRecording` はファイルモードでも `true` になるが、これは「セグメント生成中」の意味として扱う。

### ContentView

- `.onDrop(of: [.audio], isTargeted: $isDropTargeted)` を文字起こしエリアに追加
- `@State var isDropTargeted: Bool` でハイライト制御
- `viewModel.isTranscribingFile` でStatusBar表示切替
- `viewModel.showReplaceFileAlert` で確認ダイアログ制御

## File Format Support

`AVAudioFile` がサポートする全形式を受け付ける：
- WAV (PCM)
- M4A / AAC
- MP3
- CAF
- AIFF

`FileAudioSource` 内で `AVAudioConverter` により16kHz mono Float32に統一変換。ストリーミング読み出し（増分的にディスクから読む）で大容量ファイルにも対応。

## Error Handling

- ファイル読み込み失敗: アラートでエラー表示、元の状態を保持
- 未対応形式: 「Unsupported audio format」アラート
- 処理中キャンセル: 処理途中のテキストは破棄（クリーンな状態に戻る）
- キャンセル時: speaker profile mergeはスキップ（部分データでの汚染を防止）
- モデル未ロード: ドロップを受け付けない

## Testing

- `FileAudioSourceTests`: WAVファイル読み込み、リサンプリング、バッファ供給、プログレス通知、キャンセル
- 統合テスト: FileAudioSource + VADChunkAccumulator の結合動作
- 手動テスト: 各形式のファイルでドロップ動作確認、キャンセル、既存テキスト置き換え

## Not In Scope

- 複数ファイルの同時処理（最初の1つのみ）
- ファイル内タイムスタンプの表示
- 処理速度の表示（x倍速）
- Settings UIへの新規項目追加
- サンドボックスのsecurity-scoped URL（現在アプリは非サンドボックス）
