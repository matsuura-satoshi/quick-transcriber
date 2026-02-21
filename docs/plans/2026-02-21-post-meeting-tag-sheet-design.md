# PostMeetingTagSheet 設計

## 概要

録音停止後に表示されるシートで、セッション中の話者全員に一括タグ付与する機能。
TagFilterSheet（PR4）の逆フロー: 「タグで話者を選んで追加」→「会議後に話者にタグを付ける」。

## 要件

- 録音停止後、プロファイルマージ完了後にシートを表示
- Settings > Output でON/OFF切替（デフォルトON）
- activeSpeakers全員が対象（新規プロファイル含む、チェックボックスで個別選択可）
- タグは1つ、空欄デフォルト、既存タグのサジェストボタン付き
- Apply / Skip の2ボタン

## UI設計

```
┌─ Tag Session Speakers ───────────────┐
│                                       │
│  5 speakers in this session:          │
│  ☑ Alice (A) - registered             │
│  ☑ Bob (B) - registered               │
│  ☑ Speaker C - new                    │
│  ☑ Dave (D) - registered              │
│  ☐ Speaker E - new                    │
│                                       │
│  Tag: [                          ]    │
│  Suggestions: [engineering] [weekly]  │
│                                       │
│  [Apply]                     [Skip]   │
└───────────────────────────────────────┘
```

- 全員デフォルトチェック済み
- 新規話者には "new" バッジ、登録済みには "registered" バッジ
- サジェストは `speakerProfileStore.allTags` から取得
- タグ未入力で Apply 押下時は何もしない（Skip同等）

## データフロー

```
stopRecording()
  ↓ プロファイルマージ完了
  ↓ activeSpeakersのspeakerProfileId更新（新規も含め全員profileIdあり）
  ↓ showPostMeetingTagging = true（@AppStorage設定ON時のみ）
  ↓
PostMeetingTagSheet表示
  ↓ ユーザーがタグ入力 + 話者選択
  ↓ Apply → bulkAddTag(tag:, profileIds:)
  ↓ シート閉じる
```

## コンポーネント

### 1. PostMeetingTagSheet.swift（新規）

SwiftUIシート。

- Input: `activeSpeakers: [ActiveSpeaker]`, `allTags: [String]`
- State: `selectedSpeakerIds: Set<UUID>`, `tag: String`
- Output: `onApply(tag: String, profileIds: [UUID])`, `onSkip()`
- 話者リスト: sessionLabel + displayName + new/registered バッジ
- タグ入力: TextField + サジェストボタン（FlowLayout）

### 2. TranscriptionViewModel 変更

- `@Published var showPostMeetingTagging = false`
- `@AppStorage("showPostMeetingSheet") var showPostMeetingSheetEnabled = true`
- `stopRecording()`: マージ完了後に `showPostMeetingTagging = true`（設定ON時）
- `bulkAddTag(tag:profileIds:)`: 選択話者のプロファイルに一括タグ追加

### 3. ContentView 変更

- `.sheet(isPresented: $viewModel.showPostMeetingTagging)` でシート表示
- onApply → `viewModel.bulkAddTag(tag:profileIds:)`
- onSkip → シート閉じるのみ

### 4. SettingsView 変更

- Output セクションに「Show post-meeting tag sheet」トグル追加

## テスト計画

- bulkAddTag: 正常系（複数話者にタグ追加）、空タグ無視、重複タグスキップ
- stopRecording後のフラグ: 設定ON時にtrue、OFF時にfalse
- PostMeetingTagSheet: 選択/解除、タグ入力、Apply/Skip動作
