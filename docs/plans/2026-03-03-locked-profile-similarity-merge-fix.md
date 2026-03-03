# Fix: Lockedプロファイル類似度マッチングによる誤マージバグ

## Context

Manual modeの会議で新規話者(Speaker-1)を作成し、セッション終了後にタグを付与したところ、会議に一切参加していない無関係の既存メンバーにタグが適用されてしまうバグが発生。

**根本原因**: `mergeSessionProfiles()`と`linkActiveSpeakersToProfiles()`にあるlockedプロファイル類似度マッチング（閾値0.7）が、セッション参加者以外のロック済みプロファイルに対しても照合を行い、embedding類似度が偶然閾値を超えた無関係メンバーのプロファイルに新規話者のデータを統合してしまう。

**再現フロー**:
1. 既存メンバー（ロック済み）＋新規Speaker-1~3でmanualモード録音開始
2. ダイアライザーには既存メンバーのプロファイルのみロード → 新規話者は未知UUID扱い
3. ユーザーが手動でセグメントをSpeaker-1に修正
4. セッション終了 → `mergeSessionProfiles`でSpeaker-1のUUIDがIDマッチせず、lockedプロファイル類似度チェックで無関係メンバーにマージ
5. `linkActiveSpeakersToProfiles`でSpeaker-1が同じロック済みプロファイルにリンク
6. PostMeetingTagSheetでタグが無関係メンバーに適用

**この機能が冗長な理由**:
- **Manual mode**: 参加者として追加していないプロファイルへの類似度マッチはユーザー意図に反する
- **Auto mode**: ダイアライザーが全プロファイルを閾値0.5でロード済み。0.5で不一致なら0.7でも不一致（冗長）

## 変更内容

### 1. `Sources/QuickTranscriber/Models/SpeakerProfileStore.swift`

**削除対象**:
- `lockedProfileSimilarityThreshold` 定数（line 12）
- `findLockedProfileBySimilarity(embedding:)` publicメソッド（lines 117-120）
- `findLockedProfileIndexBySimilarity(embedding:)` privateメソッド（lines 122-134）
- `mergeSessionProfiles()`内の`else if`ブランチ（lines 154-161）

**変更後の`mergeSessionProfiles`**:
```swift
public func mergeSessionProfiles(...) {
    for (speakerId, embedding, displayName) in sessionProfiles {
        if let idMatchIndex = profiles.firstIndex(where: { $0.id == speakerId }) {
            // ID match → 既存プロファイル更新（変更なし）
            ...
        } else {
            // Fallback → 新規プロファイル作成（変更なし）
            let newProfile = StoredSpeakerProfile(id: speakerId, ...)
            profiles.append(newProfile)
        }
        // ※ locked similarity分岐を完全削除
    }
}
```

### 2. `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift`

**`linkActiveSpeakersToProfiles()`（lines 1160-1169）**: Priority 2ブランチを削除。

変更後のフロー:
```
Priority 1: Direct ID match → link
Priority 1.5: Tracker alias match → link
（Priority 2: 削除）
Fallback: embedding取得 → 新規プロファイル作成
```

### 3. `Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift`

| テスト | アクション |
|--------|-----------|
| `testMergeNewSpeakerMatchesLockedProfileBySimilarity` (line 470) | **リライト**: 逆のアサーション（新プロファイル作成を確認） |
| `testMergeDoesNotMatchUnlockedProfileBySimilarity` (line 492) | 変更なし（アサーションが既に正しい） |
| `testMergeDissimilarEmbeddingDoesNotMatchLockedProfile` (line 508) | 変更なし |
| `testFindLockedProfileBySimilarityReturnsMatch` (line 524) | **削除**（テスト対象メソッド削除） |
| `testFindLockedProfileBySimilarityReturnsNilForUnlocked` (line 543) | **削除**（テスト対象メソッド削除） |

### 4. `Tests/QuickTranscriberTests/TranscriptionViewModelTests.swift`

| テスト | アクション |
|--------|-----------|
| `testLinkActiveSpeakersMatchesLockedProfileBySimilarity` (line 1788) | **リライト**: 逆のアサーション（新プロファイル作成を確認） |
| `testLinkActiveSpeakersDoesNotMatchUnlockedProfileBySimilarity` (line 1818) | 変更なし |
| `testLinkActiveSpeakersDissimilarEmbeddingDoesNotMatchLockedProfile` (line 1846) | 変更なし |

## 検証

1. `swift test --filter QuickTranscriberTests` — 全テスト通過
2. 手動テスト: Manual modeでロック済みプロファイルが参加者でない場合、セッション終了後にそのプロファイルが汚染されないことを確認
