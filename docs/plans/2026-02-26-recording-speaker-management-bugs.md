# 録音中のSpeaker管理バグ修正プラン

## User Prompt
録音中のactive speaker / registered speaker管理に複数の不整合が発生している。主な症状：
1. Active speakerを削除した後、そのUUIDを持つセグメントが"Unknown:"と表示される
2. Lockされた話者が消失し、自動命名の別話者が出現（重複プロファイル）
3. manual/auto切替やパラメータ変更時のrestartRecordingでセッションデータが失われる
4. 録音中のプロファイル削除がengineと不整合を起こし、停止時にプロファイルが再作成される

## 修正対象 (実装順)

### Fix 1: 削除した話者の"Unknown:"表示防止
- `historicalSpeakerNames: [String: String]` を追加
- 削除時にスナップショットを保存し、`updateSpeakerDisplayNames()`でfallbackとして参照

### Fix 2: restartRecording()のセッションデータ損失修正
- `self.speakerDisplayNames`をstopTranscriptionに渡す

### Fix 3: 録音中のプロファイル削除を遅延実行
- `pendingProfileDeletions: Set<UUID>` を追加
- 録音中は削除をキューに入れ、stopRecording後にflush

### Fix 4: Lockされた話者プロファイルの重複防止
- lockedプロファイル限定でembedding類似度チェック（閾値0.7）
- `findLockedProfileBySimilarity(embedding:)` 追加

## 変更ファイル
- `Sources/.../ViewModels/TranscriptionViewModel.swift`
- `Sources/.../Models/SpeakerProfileStore.swift`
