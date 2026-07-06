# シンプル化リファクタリング 設計書

日付: 2026-07-02
状態: ユーザーレビュー待ち

## 背景と目的

本体約 8,300 行 / テスト約 19,000 行。機能追加と話者識別実験の積み重ねで、
同一ロジックの重複実装・実験の残骸・状態の二重所有が蓄積している。

目的（優先順）:

1. **シンプル化** — 挙動を変えずにコードを削減・統合する
2. **安定性** — データ競合をコンパイラ保証で構造的に排除する
3. **パフォーマンス** — テキスト再計算の多層重複（O(n²) 化）を解消する

スコープはユーザーと合意済み: **A（局所リファクタ全件）+ B1 + B3**。
B1/B3 の実装深度（1a: レンダラー完全統合 / 3a: actor 化）は推奨案に基づく
仮決定であり、本ドキュメントのレビューで変更可能。

## スコープ外

- **B2**: TranscriptionViewModel ↔ SpeakerStateCoordinator の状態二重所有の解消
  （30 箇所以上の手動 sync、双方向 Combine ループ）— 今回は見送り、別途議論
- **B4**: VM の God object 解体（ファイル文字起こしコントローラ抽出等）、
  メニュー→View の NotificationCenter 配線、終了ガードの semaphore、
  SettingsView のタブ分割・filteredProfiles メモ化
- セグメント join の増分化（1 チャンクあたりの join コストは Whisper 推論に対し
  無視できる。問題は多層重複実行の方 — YAGNI）
- file モードの AsyncStream unbounded バッファリング（長尺ファイルでのメモリ増。
  follow-up として記録）
- 話者識別チューニング本体（per-profile score calibration、F1 の閾値分離）—
  本リファクタ完了後に `docs/superpowers/handoffs/2026-06-10-post-diagnostic.md`
  から再開する

## Part A: 局所リファクタ（挙動不変）

### A-1 デッドコード削除

| # | 対象 | 内容 |
|---|---|---|
| 1 | `ProfileStrategy` 機構 | `EmbeddingBasedSpeakerTracker` の `maintainProfiles` / `mergeProfiles` / `registrationGate` 分岐。本番は常に `.none`（`SpeakerDiarizer` の構築箇所で固定）。依存する `ProfileStrategyBenchmarkTests` も削除する。**実験（不採用で終結）の資産削除を含むためレビュー時に要確認** |
| 2 | `updateAlpha`（tracker 側） | 「Unused, kept for backward compatibility」と明記。`FluidAudioSpeakerDiarizer.init` → tracker の 2 層を貫通するパラメータごと削除。※ `SpeakerProfileStore.updateAlpha` は別物で使用中、残す |
| 3 | `SpeakerLabelTracker` typealias | `SpeakerLabelTracker.swift:199`。参照ゼロ |
| 4 | `cleanup()` 一式 | プロトコル → `TranscriptionService.cleanup` → `ChunkedWhisperEngine.cleanup` と貫通しているが**本番からの呼び出しゼロ**（テストのみ）。エンジン実装は fire-and-forget `Task` で stop を発火する危険な形。チェーンごと削除し、関連テストを削除・修正 |

注: `currentConfirmedSegments` / `markSegmentAsUserCorrected` は本番未使用だが
テスト seam として使われているため**存続**（B3 で actor 隔離される）。

### A-2 重複統合

| # | 対象 | 内容 |
|---|---|---|
| 5 | `EmbeddingMath` 新設 | cosineSimilarity（tracker の static）+ weighted-mean ×3（tracker `recalculateEmbedding` / `EmbeddingHistoryStore.reconstructProfile` / engine `centroid`）+ lerp ブレンド ×3（`SpeakerProfileStore` ×2 / `SpeakerStateCoordinator.executeMerge`）を 1 モジュールに統合。話者識別の中核計算の単一化は今後の calibration 作業の下地にもなる |
| 6 | `SpeakerProfileStore.requireIndex(_:)` | find-index-or-throw ガード ×6（rename/setLocked/delete/forceDelete/addTag/removeTag）を private ヘルパーに |
| 7 | JSON 書き込みヘルパー | 「ディレクトリ作成 → encode → .atomic 書き込み」×3（ProfileStore ×1 / HistoryStore ×2）を共通化 |
| 8 | 日付プレフィックス共通化 | `yyyy-MM-dd_HHmm` の `DateFormatter` インライン生成 ×3（VM ×2 / TranscriptFileWriter）を静的キャッシュ済みヘルパーに |
| 9 | `resetUtteranceState()` | `VADChunkAccumulator` の同一フィールド再初期化 ×3（reset/emitChunk/transitionToIdle）を private ヘルパーに |
| 10 | `applyIncomingState(_:sessionSegments:)` | VM の live / file 用 `onStateChange` クロージャの重複本体を統合 |
| 11 | `checkNameUniqueness` 整理 | `sourceDisplayName` switch の逐語重複を事前計算に、`SpeakerMergeRequest` 構築をローカルヘルパーに |
| 12 | `SliderRow` ジェネリック化 | `SliderRow` / `DoubleSliderRow` は型のみ異なる同一構造体。`BinaryFloatingPoint` 制約のジェネリック 1 つに |
| 13 | `ControlBarButton` 部品化 | ControlBar の 4 ボタンで繰り返される HStack+padding+background+clipShape を 1 コンポーネントに |
| 14 | TextView 配管の共通化 | `TranslationTextView` の `makeNSView` / `isScrolledToBottom` / diff-append 適用ブロックは `TranscriptionTextView` と同一。共有ファクトリ+ヘルパーに（B1 のレンダラーとは独立の配管部分） |
| 15 | `profiles(matching:)` の再利用 | `SettingsView.filteredProfiles` が同一の検索フィルタをインライン再実装。ストアのメソッドを使う |
| 16 | 文末文字セットの統一 | `TranscriptionUtils` / `TranscriptionTextView` にハードコードされた `["。","！","？"]` / `[".","!","?"]` を `Constants.Translation.sentenceEndersJA/EN` 参照に |

### 検討の上で除外

- `StoredSpeakerProfile` のカスタム `CodingKeys` + `init(from:)`: `isLocked` 欠落の
  旧 `speakers.json` との互換 seam として正当。存続

## Part B1: テキストレンダリング統合（案 1a）

### 現状の問題

セグメント→テキスト変換（4 優先度の改行判定: 話者交代 → 沈黙 → 文末 → インライン）が
3 層で独立実行されている:

1. Engine が**チャンク毎**に全セグメントを `joinSegments`（`ChunkedWhisperEngine.processChunk`）
   — しかも VM はこの結果をほぼ使わない（モック用フォールバックのみ）
2. VM の `confirmedText` が computed property — **チャンク毎 + SwiftUI body 評価毎**に全再計算
3. `TranscriptionTextView.buildAttributedStringFromSegments` が同ロジックを
   **attributed 版として丸ごと再実装**（コメントに「Mirrors the logic of joinSegments」）。
   diarization の遡及ラベル書き換えで prefix-diff が壊れるたびに全文再構築

さらに plain 版と attributed 版で文字オフセットが 1 文字でもずれると
`SegmentCharacterMap` によるクリック位置→話者判定が狂う（潜在バグ源）。

### 設計

- **`SegmentTextRenderer` 新設**（`Sources/QuickTranscriber/Rendering/`）:
  1 回の走査で改行判定を行い、plain テキスト・`NSAttributedString`・
  `SegmentCharacterMap` を同時生成する。4 優先度ロジックの実装はここ 1 箇所のみ
- **`TranscriptionState.confirmedText` を削除**。Engine はセグメントのみ emit。
  VM 側のテキスト化フォールバック（モック用）は、モックをセグメント emit に
  更新して除去
- **VM の `confirmedText` を stored `@Published` に変更**。state 受信時と編集系操作
  （clear / regenerate / saveUnconfirmedText 等）で 1 回だけ再計算
- TextView は renderer の出力を消費する。prefix が保たれる場合の diff-append
  最適化は維持
- **`TranscriptionUtils.joinSegments` は公開シグネチャを維持**し、内部を renderer の
  共有コア（改行判定）への委譲に置き換える。テスト（50 件超が exact な出力を検証）
  および本番呼び出し（VM）はそのまま。attributed 版も同じコアに委譲することで
  「両者が同一ロジックを消費する」構造にする

### 正当性の担保

- **既存 `TranscriptionUtilsTests`（50 件超）がそのままゴールデンテストになる**:
  公開挙動を変えずに内部を共有コアへ委譲するため、既存テストの通過が
  移植の正しさを直接証明する
- characterMap の各レンジが plain / attributed の両方で同一テキストを指すことの
  検証テストを追加
- 既存の `ConfidenceColoringTests` / TextView 関連テストの維持

### インパクト

join 実行が「チャンク毎 ×2 層 + 描画毎」→「チャンク毎 1 回」に。
二重実装によるオフセット不整合バグの構造的排除。長時間セッションでの
劣化（O(n²) 化）解消。

## Part B3: Engine actor 化（案 3a）

### 現状の問題

`ChunkedWhisperEngine` は素の `final class`:

- `confirmedSegments` / `pendingSegmentStartIndex` / `accumulator` が
  バックグラウンドの streaming task から変更される一方、public API
  （テスト seam 含む）から保護なしで到達可能
- `smootherLock` が守るのは smoother のみ。安全性は「// Now safe to access…」
  というコメントによる手動推論
- `drainOnStop` が外部から変更される public 可変フラグで、stop の意味論が
  呼び出し順序に依存
- ホットパスにチャンク毎・セグメント毎の NSLog 多数

### 設計

- **`actor ChunkedWhisperEngine` に変換**。全可変状態がコンパイラ保証で直列化。
  `smootherLock` 削除
- **プロトコル変更**: `correctSpeakerAssignment` / `mergeSpeakerProfiles` /
  `syncViterbiConfirm` を async 化。`@MainActor` の Coordinator からは
  await で呼ぶ（現在も別スレッドからロック越しに割り込む経路なので、
  actor 直列化は厳密に安全側の変更）
- **`SessionLearningFinalizer` 抽出**: `stopStreaming` 内の事後学習
  （manual モード post-hoc 学習 / auto モード session profile マージ）+
  embedding history 保存の約 70 行を独立型に。engine 抜きで単体テスト可能になり、
  `applyManualModePostHocLearningForTesting` の DEBUG フックは
  finalizer 直接テストに置換して削除
- **`drainOnStop` フラグ廃止**: `startStreaming` のパラメータ
  （例: `stopBehavior: .drainRemaining / .immediate`）に変更し、
  呼び出し順序依存を除去
- **NSLog 削減**: チャンク処理はチャンク毎 1 行のサマリに集約。
  セグメント毎・100 バッファ毎の周期ログは削除（必要なら debug フラグでゲート）

### 正当性の担保

- 既存 `ChunkedWhisperEngineTests` / `RetroactiveUpdateGuardTests` を await 適応
- streaming 中に correction / merge を並行発行して直列化を確認するスモークテスト追加
- DEBUG の `SpeakerStateInvariantChecker` 通過確認

### インパクト

データ競合の構造的排除（手動推論 → コンパイラ保証）。今後の話者識別作業
（F1: silence 閾値の分離は smoother リセット経路を触る）の安全な下地。

## PR 分割・実施順序

| 順 | PR | 内容 | 検証 |
|---|---|---|---|
| 1 | PR-A | A-1 + A-2（規模次第で 2 分割） | 既存ユニットテスト（挙動不変）+ EmbeddingMath 数値同一性テスト |
| 2 | PR-B1 | レンダラー統合 | ゴールデンテスト先行 + 実機（ライブ録音 + ファイル文字起こし） |
| 3 | PR-B3 | actor 化 + Finalizer 抽出 | テスト適応 + 直列化スモーク + 実機 |

順序の理由: A が engine を先に軽くし（埋め込み演算・NSLog）、B1 で emit が
セグメントのみに単純化された engine を B3 で actor 化する — 各段の diff が最小になる。

各 PR で `Constants.Version.patch` を PR 番号に更新（PR のコミット内でのみ）。
実装は superpowers:test-driven-development に従いテストファースト、完了宣言前に
superpowers:verification-before-completion で検証する。

## リスクと緩和

| リスク | 緩和 |
|---|---|
| ProfileStrategy 削除がベンチマーク資産を失わせる | 不採用実験の終結済み資産。PR レビューで最終判断、git で復元可能 |
| B1 の改行ロジック移植ミス | `joinSegments` の公開挙動を維持し、既存の 50 件超のテストで検出 |
| B3 の async 化で correction の到達タイミングが変わる | 現在も非同期割り込みであり順序保証はもともと無い。actor 化で悪化しない（改善する）。スモークテストで確認 |
| 進行中の話者識別作業との衝突 | 本リファクタを calibration 再開前に完了させる順序で合意 |
| テスト seam（currentConfirmedSegments 等）の async 化でテスト churn | 対象テストは特定済み（RetroactiveUpdateGuardTests / ChunkedWhisperEngineTests）。機械的な await 追加 |

## Follow-up（今回やらない・記録のみ）

- file モードのバックプレッシャ: `AsyncStream` unbounded + inline await 消費のため、
  長尺ファイルでバッファがファイルサイズ相当まで成長し得る（既存問題）
- B2（VM↔Coordinator 単一真実源化）と B4 群
- `qt_transcript.md` へのタイムスタンプ出力(既存メモの候補)
