# Loopback capture — システムオーディオ直接キャプチャによる Zoom 遠端音声のデジタル取得 (2026-07-17)

## 背景

PR #91 の separability 診断で、話者分離不能の犯人は Zoom 遠端音声の音響経路
（コーデック → スピーカー再生 → 部屋残響 → マイク再録音）と確定した。同一モデルが
AMI で LOO 99.4% を出す一方、real-sessions は GT 純粋スパンでも 70.7%
（margin +0.100）。リモート話者の声が「部屋 + スピーカーの共有伝達関数」で
互いに似ることが原因であり、モデル変更・スコア層工学は理論上限ゼロが確定済み。

対策はリモート音声を**スピーカー再録音ではなく loopback でデジタルに取る**こと。
共有伝達関数が消え、副産物として「マイク = 現地 / loopback = リモート」という
チャネル帰属も得られる。

実会議の loopback 同時録音はまだ存在しない（real-sessions は qt_transcript /
zoom_transcript / audio.wav のみ）ため、効果の事前計測はできない。
よって**フェーズ分割**する:

- **Phase 1（本 spec の実装範囲）**: loopback キャプチャ基盤 + 同時録音。
  技術リスク（キャプチャ権限・API 選定）を先に潰し、計測資産を作る
- **Phase 1.5**: 次の実会議でデータ取得 → separability プロトコルで効果を実測
- **Phase 2（別 spec、計測後に brainstorming）**: 文字起こし・話者識別
  パイプラインへの本統合。ミキシング方式は実測データを見て選定

## 要件（確定事項）

- **タップ対象**: 全システム出力のミックスダウン（自プロセス除外）。
  会議アプリ非依存（Zoom/Teams/Webex/ブラウザ会議すべてで動く）。
  通知音等の混入は許容（会議中は少なく、Phase 2 では VAD で除外される）
- **API**: Core Audio Process Tap（`CATapDescription` +
  `AudioHardwareCreateProcessTap`、macOS 14.4+、min target 15.0 なので問題なし）。
  権限が「システムオーディオ録音」のみで、ScreenCaptureKit と違い画面収録権限
  （macOS 15+ の定期再承認ダイアログ付き）が不要
- **UX**: Settings の既存「Record audio during transcription」トグルの下に
  サブトグル「Record system audio (loopback)」を追加。デフォルト ON、
  親 OFF 時は無効。権限ダイアログが出るのは録音を意図的に有効にした人だけ
- **想定環境**: 主ケースは「自室で Mac スピーカー再生・現地話者は本人のみ」。
  副ケース（ゼミ等、現地複数名・リモートなし）では loopback は実質無音になる
  だけで、既存動作を壊さない

## アーキテクチャ

### 新規コンポーネント

1. **`SystemAudioCaptureService`**（`Sources/QuickTranscriber/Audio/`、
   既存 `AudioCaptureService` プロトコル準拠）
   - `CATapDescription`（全プロセス mixdown・自プロセス除外・private・unmuted）
     → `AudioHardwareCreateProcessTap` → private aggregate device → IOProc
   - タップフォーマット（通常 48kHz stereo）をステレオ→モノ ダウンミックス +
     16kHz リサンプルして `onBuffer([Float])`（~100ms バッファ）に流す。
     変換は `AVAudioCaptureService` と同じ `AVAudioConverter` パターン
   - Core Audio C API 部分は内部ラッパー型（`ProcessTap`）に隔離
     （参考実装: insidegui/AudioCap）
   - プロトコル準拠が Phase 2 への布石: 効果確認後、このサービスをそのまま
     エンジンの第 2 ストリームとして差し込める

2. **`LoopbackRecordingSession`**（`Sources/QuickTranscriber/Services/`）
   - `SystemAudioCaptureService` + 2 つ目の `AudioRecordingService` を束ねる
     コーディネータ。`start(directory:datePrefix:)` / `stop()` のみ
   - 出力: `{日付}_qt_loopback.wav`（既存 `{日付}_qt_recording.wav` と
     同じディレクトリ・同じ 16kHz mono Int16）

### 既存コンポーネントへの変更（最小限）

- `AudioRecordingService`: ファイル接尾辞を init パラメータ化
  （デフォルト現行値 `_qt_recording` = 後方互換）
- `TranscriptionService`: loopback 有効時に `LoopbackRecordingSession` を
  開始/停止する配線。**`ChunkedWhisperEngine` は一切変更しない**
- `SettingsView`: サブトグル追加（`@AppStorage("loopbackRecordingEnabled")`、
  デフォルト true）
- `Scripts/build_app.sh`: Info.plist に `NSAudioCaptureUsageDescription` を追加
  （Xcode ドロップダウンに出ない手動キー）
- `Constants`: `AudioRecording.loopbackFileSuffix = "_qt_loopback"` 追加、
  `Version.patch` を PR 番号に更新（慣例通り）

## データフロー

```
システム出力（全プロセス mixdown, 自プロセス除外）
  → Process Tap (48kHz stereo)
  → ダウンミックス + リサンプル (16kHz mono Float32, ~100ms)
  → AudioRecordingService
  → {日付}_qt_loopback.wav (16kHz mono Int16)
```

マイク側の既存フロー（`AVAudioCaptureService` → エンジン →
`*_qt_recording.wav`）とは完全に独立して並走する。両者は別デバイスクロックで、
開始オフセット ~100ms 以下 + ドリフト典型 <0.01%（2h で 1s 未満）だが、
separability 計測はスパン単位（数秒）なので影響なし。Phase 2 のリアルタイム統合は
録音ファイルではなくライブバッファを使うためこれも問題にならない。

## 権限・エラー処理

- 初回の `AudioHardwareCreateProcessTap` 呼び出しで TCC ダイアログが自動表示
  （文言は `NSAudioCaptureUsageDescription`）。事前リクエスト API・権限照会 API は
  存在せず、**タップ作成の成否が唯一の判定手段**
- 再許可の場所: システム設定 > プライバシーとセキュリティ >
  画面収録とシステムオーディオ録音（音声のみタップは
  「システムオーディオ録音のみ」欄）
- **開始失敗時**: マイク録音・文字起こしは通常通り続行。セッション開始時に
  一度だけ非ブロッキング NSAlert で通知（黙って失敗すると実会議 1 回分の
  計測機会を失うため）。アラートには再許可手順を含める
- 録音中の書き込みエラー: 既存 `AudioRecordingService` と同じ
  （NSLog のみ、セッション継続）

### 既知の制約（Phase 1 で許容）

- ad-hoc 署名の再ビルドで CDHash が変わり TCC が再プロンプト
  （マイク権限と同じ既知挙動）
- 開発時 `swift run` では責任プロセスがターミナルになり権限がターミナルに付く
- 会議中の出力デバイス切替をまたぐ継続キャプチャは best-effort
  （AudioCap パターンの範囲。切替で途切れたら WAV はそこまで。
  主ケース「自室 Mac スピーカー」では発生しない）

## 計測プロトコル（Phase 1.5）

1. 次の Zoom 実会議で録音 + loopback ON → `*_qt_recording.wav` /
   `*_qt_loopback.wav` / `qt_transcript.md` / `zoom_transcript.txt` を保存
2. zoom_transcript の話者ターンから loopback WAV 上のリモート話者純粋スパンを
   抽出（`PureSpanExtractor` パターン流用）→ 既存 separability プロトコル
   （span embedding → `separability_analysis.py` の LOO 分析）
3. ベースライン: 同一話者群で real-sessions 70.7% / margin +0.100

### Phase 2 GO/NO-GO 判定

- **LOO ≥ 90% または margin ≥ +0.3** → 共有伝達関数の除去が効いている。GO
- **callhome_ja 水準（~86%）** → 残る制約は Zoom コーデック。Phase 2 の期待精度を
  その水準に置いた上で投資判断
- **~70% から改善なし** → 仮説見直し。loopback 統合は中止し、代替案
  「不確実性の表面化 UX」（handoff 参照）へ

## テスト戦略（TDD）

- **ユニットテスト（モデル不要・CI 可）**:
  1. `AudioRecordingService` の接尾辞パラメータ化
  2. `LoopbackRecordingSession` の start/stop/失敗フォールバック
     （`AudioCaptureService` プロトコルのフェイク注入）
  3. ステレオ→モノ + リサンプル変換ロジック（デバイス非依存の関数に切り出し、
     `AVAudioPCMBuffer` を直接与えてテスト）
- **手動スモークテスト（TCC・実ハードは CI 不可、PR にチェックリスト添付）**:
  音楽再生中に 10 秒録音 → loopback WAV の RMS 非無音・`afinfo` で
  フォーマット確認・権限拒否時のフォールバック確認

## Phase 2 展望（本 spec では実装しない）

- `SystemAudioCaptureService` をエンジンの第 2 ストリームとして注入
- ミキシング方式候補: (a) エネルギーゲート式ミキサー、(b) マイク側 AEC
  （voice processing）、(c) 単純加算 — 実測データで選定
- チャネル帰属（マイク = 現地 / loopback = リモート）を話者識別の事前情報として
  `SpeakerStateCoordinator` 系へ配線

## 成功基準（Phase 1）

- ユニットテスト全通過（既存 803 件 + 新規、失敗ゼロ）
- 手動スモークテスト通過（実音声で loopback WAV が非無音・正フォーマット、
  権限拒否時にマイク録音のみで継続）
- 次の実会議で計測資産（4 ファイル一式）が取得できる状態でリリース
