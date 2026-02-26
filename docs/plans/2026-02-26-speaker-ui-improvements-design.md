# Speaker UI Improvements Design

## 概要

Manualモードの話者管理UIに3つの改善を行う。

## 1. デフォルト名付き話者追加

- アラートのTextFieldにplaceholder「Speaker-N」（次の自動生成名）を表示
- 空のままAdd → `addManualSpeaker(displayName: "")` → `generateSpeakerName()` でデフォルト名割当
- SettingsView側の `!name.isEmpty` ガードを削除

## 2. 空名拒否（リネーム時）

- `tryRenameActiveSpeaker`: trimmed後が空なら即return（リネーム無視）
- `ActiveSpeakerRow`: `onSubmit` で空の場合、元のdisplayNameに戻す
- `renameActiveSpeaker` 内の `displayName.isEmpty ? nil` 変換をガードに変更

## 3. Manualモード参加者数表示

- 「Number of Speakers」行: `activeSpeakers.count` に変更（全active speaker）
- セクションヘッダ: 現状維持（既に `activeSpeakers.count`）

## 4. Manualモードエンジン制約

- `expectedSpeakerCount` に `activeSpeakers.count` を渡す
- `participantProfiles` は引き続きリンク済みのみを渡す（embeddingが必要なため）
- 0人 → `diarizationActive = false`（現状維持）

## 5. Autoモード（変更なし）

- Pickerのまま（ダイアライザーへのヒント、active speaker数とは独立した概念）

## 影響範囲

- `SettingsView.swift`: alert UI、参加者数表示
- `TranscriptionViewModel.swift`: `tryRenameActiveSpeaker`, `renameActiveSpeaker`, `startRecording`
- `ActiveSpeakerRow`: onSubmit空名ハンドリング
