# Quick Transcriber

macOS向けリアルタイム文字起こしアプリ。WhisperKit (large-v3-turbo) による高精度な音声認識、話者識別、リアルタイム翻訳を完全ローカルで実行します。

## Highlights

- **WhisperKit (large-v3-turbo)** — Apple Silicon最適化の高精度文字起こし
- **話者ダイアライゼーション** — FluidAudioベースの話者識別 + 永続プロファイル管理
- **リアルタイム翻訳** — Apple Translation frameworkによるEN↔JA翻訳
- **Markdown自動保存** — YAMLフロントマター付きで自動保存、シンボリックリンクで常に最新ファイルにアクセス
- **完全ローカル処理** — 全ての処理がデバイス上で完結、ネットワーク不要

## Requirements

- macOS 15.0 (Sequoia) 以降
- Apple Silicon (M1 以降)
- マイクアクセス許可

## Getting Started

### Download

[GitHub Releases](https://github.com/matsuura-satoshi/quick-transcriber/releases) からzipをダウンロードし、展開して `Applications` フォルダに移動してください。

アプリは署名・公証されていないため、初回起動前にGatekeeperの隔離属性を解除する必要があります:

```bash
xattr -d com.apple.quarantine /Applications/QuickTranscriber.app
```

初回起動時にWhisperKitモデルが自動ダウンロードされます（約1.5GB、一度のみ）。

### Build from Source

Xcode + macOS 15 SDK が必要です。

```bash
# ビルド＆実行
swift build && swift run QuickTranscriber

# .appバンドル生成（配布用）
./Scripts/build_app.sh
```

## Features

### Transcription

WhisperKit large-v3-turboモデルによるリアルタイム文字起こし。English / Japanese に対応し、VAD (Voice Activity Detection) による自然な発話区切りを行います。

**使い方:** `Space` または `Cmd+R` で録音開始/停止。ツールバーの言語ピッカーで言語を切り替え。

### Speaker Diarization

FluidAudioによる音声埋め込み抽出、コサイン類似度マッチング、Viterbiスムージングを組み合わせた話者識別。

- **Auto mode** — 話者を自動検出・追跡
- **Manual mode** — 事前に参加者を定義して識別
- **プロファイル永続化** — セッションをまたいで話者を記憶
- **プロファイル管理** — リネーム、タグ付け、ロック、マージに対応

**使い方:** Settings > Speakers で話者識別を有効化。トランスクリプト上の話者ラベルをクリックして再割当て、右クリックメニューから話者を変更。録音終了後のタグシートで話者にタグを付与。

### Translation

Apple Translation frameworkによる完全ローカルの EN↔JA リアルタイム翻訳。Two-pass方式で、発話直後に即時翻訳し、グループ確定時に連結テキストで再翻訳して精度を向上します。

**使い方:** `Cmd+T` で翻訳パネルを表示/非表示（HSplitView）。初回使用時に翻訳モデルが自動ダウンロードされます。

### Transcript Output

トランスクリプトを `~/QuickTranscriber/` にMarkdown形式で自動保存します。YAMLフロントマター（日時、言語、話者情報）付き。`~/QuickTranscriber/qt_transcript.md` シンボリックリンクが常に最新のファイルを指します。

**使い方:** 録音中に自動保存。Settings > Output で保存先ディレクトリを変更可能。`Cmd+Shift+C` で全テキストをコピー。

## Keyboard Shortcuts

| ショートカット | 操作 |
|---|---|
| `Space` | 録音 開始/停止 |
| `Cmd+R` | 録音 開始/停止 |
| `Cmd+T` | 翻訳パネル 表示/非表示 |
| `Cmd+Shift+C` | 全テキストをコピー |
| `Cmd+E` | エクスポート |
| `Cmd+Delete` | トランスクリプトをクリア |
| `Cmd++` / `Cmd+-` | フォントサイズ 拡大/縮小 |
| `Cmd+0` | フォントサイズ リセット |
| `Cmd+,` | 設定 |

## Data Storage

デフォルトの保存先は `~/QuickTranscriber/` で、Settings > Output で変更できます。トランスクリプト・シンボリックリンク・話者プロファイルは全て同じディレクトリに保存されます。

| データ | ファイル |
|---|---|
| トランスクリプト | `<出力先>/YYYY-MM-DD_HHmmss.md` |
| 最新トランスクリプトへのリンク | `<出力先>/qt_transcript.md` (シンボリックリンク) |
| 話者プロファイル | `<出力先>/speakers.json` |

## Building & Development

```bash
# ユニットテスト
swift test --filter QuickTranscriberTests

# ベンチマーク（WhisperKitモデル + テストデータセット必要）
swift test --filter QuickTranscriberBenchmarks
```

アーキテクチャ: MVVM (Views → TranscriptionViewModel → TranscriptionService → ChunkedWhisperEngine)。詳細は [CLAUDE.md](CLAUDE.md) を参照。

## Technologies

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — Apple Silicon向け音声認識
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — 話者埋め込み抽出
- [Apple Translation](https://developer.apple.com/documentation/translation) — オンデバイス翻訳