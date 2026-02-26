# Speaker Name Uniqueness + Merge

## Context

現在、表示名の重複チェックが一切ない。Active Speaker / Registered Speaker のどちらをリネームしても同名が許容され、UIの話者割当メニューやトランスクリプトで区別不能になる。また「New Speaker...」でも同名の話者を作成できる。

**目的**: 表示名をシステム全体でユニーク制約とし、重複入力時にはマージ確認ダイアログで話者統合を可能にする。キーボードのみで操作完結（名前入力→Enter→ダイアログ→Enterでマージ）。

## 設計方針

### 1. 名前ユニーク制約
- Active Speakers + Registered Speakers の全表示名でグローバルユニーク
- 大文字小文字を区別しない（case-insensitive）
- 空文字列はユニーク制約の対象外（表示名クリアは許可）

### 2. リネーム時: マージ確認ダイアログ
- 重複名を入力してEnter → `.alert` でマージ確認
- **Mergeボタンが`.keyboardShortcut(.defaultAction)`** → Enterでマージ実行
- Cancelで入力テキストはそのまま残る（ユーザーが別名に修正可能）
- 全6ケース対応: Active↔Active, Active↔Registered, Registered↔Registered

### 3. 新規追加時: 重複拒否 + 既存アクティブ化
- 「New Speaker...」で既存名を入力 → 新規作成せず、既存話者をActiveに追加するか確認

### 4. マージロジック
- **生存者**: `sessionCount`が多い方（タイの場合はターゲット=既存名保持者）
- **Embedding統合**: EMA blending（`alpha = 0.3`）、生存者が基盤（0.7）、吸収側が0.3
- **セグメント再割当**: `confirmedSegments`の`speaker`フィールドを吸収側→生存側に一括更新
- **プロファイル統合**: `sessionCount`加算、`lastUsed`はmax、`tags`はunion、`isLocked`は論理OR
- **吸収側の削除**: プロファイル・Active Speaker・EmbeddingHistory全削除（ロック状態でも強制削除）

## 実装計画

### Step 1: データ型追加
**File**: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift`

```swift
public enum SpeakerEntity: Equatable {
    case active(id: UUID)
    case registered(id: UUID)
}

public struct SpeakerMergeRequest: Equatable {
    public let sourceEntity: SpeakerEntity   // リネームされた話者
    public let targetEntity: SpeakerEntity   // 既存の同名話者
    public let duplicateName: String
    public let sourceDisplayName: String     // ダイアログ表示用
    public let targetDisplayName: String
}
```

`@Published public var pendingMergeRequest: SpeakerMergeRequest? = nil` を追加。

### Step 2: ユニーク制約チェック
**File**: `TranscriptionViewModel.swift`

```swift
public func checkNameUniqueness(newName: String, forEntity: SpeakerEntity) -> SpeakerMergeRequest?
```

- トリム後、空ならnil返却
- `activeSpeakers`の全displayName + `speakerProfileStore.profiles`の全displayNameと比較（case-insensitive）
- 自分自身とリンク済みプロファイルは除外
- 衝突あり → `SpeakerMergeRequest`構築。Active Speakerを優先ターゲットとする

### Step 3: tryRenameメソッド
**File**: `TranscriptionViewModel.swift`

```swift
public func tryRenameActiveSpeaker(id: UUID, displayName: String)
public func tryRenameSpeaker(id: UUID, to name: String)
```

- `checkNameUniqueness`を呼び、衝突なしなら既存`rename*`を呼ぶ
- 衝突あり→`pendingMergeRequest`をセットしてダイアログ表示

### Step 4: マージ実行
**File**: `TranscriptionViewModel.swift`

`public func executeMerge(_ request: SpeakerMergeRequest)`:

1. **生存者決定**: sessionCount比較（高い方が生存）
2. **セグメント再割当**: `confirmedSegments[i].speaker`を吸収側→生存側に置換 + `trackerAliases`もリマップ
3. **Embedding統合**: `SpeakerProfileStore`のプロファイルでEMA blending
4. **メタデータ統合**: sessionCount加算、lastUsed max、tags union、isLocked OR
5. **Tracker統合**: 録音中なら`service.mergeSpeakerProfiles(from:into:)`
6. **Active Speaker更新**: 生存側にdisplayName設定、吸収側を削除
7. **吸収側削除**: `speakerProfileStore.forceDelete(id:)` + `embeddingHistoryStore.removeEntries(for:)`
8. **反映**: `updateSpeakerDisplayNames()` → `regenerateText()` → 翻訳sync

`public func cancelMerge()`: `pendingMergeRequest = nil`

### Step 5: 新規追加の重複チェック
**File**: `TranscriptionViewModel.swift`

`addManualSpeaker(displayName:)` を修正:
- 入力名が既存話者と一致する場合、新規作成せず `pendingActivationRequest` をセット
- Registered Speakerならアクティブ化、Active Speakerなら何もしない（既にActive）

**File**: `SettingsView.swift`
- New Speakerダイアログの結果をtry系メソッド経由で処理

### Step 6: Tracker層のマージ機能
**File**: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift`

```swift
public func mergeProfile(from sourceId: UUID, into targetId: UUID)
```
- source側の`embeddingHistory`をtargetに全追加→centroid再計算→source削除

**File**: `Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift` (protocol)
- `func mergeSpeakerProfiles(from sourceId: UUID, into targetId: UUID)` 追加（デフォルト空実装）

**File**: `FluidAudioSpeakerDiarizer.swift`, `ChunkedWhisperEngine.swift`, `TranscriptionService.swift`
- プロトコルチェーン伝播

### Step 7: SpeakerProfileStore拡張
**File**: `Sources/QuickTranscriber/Models/SpeakerProfileStore.swift`

```swift
public func forceDelete(id: UUID) throws  // isLockedを無視して削除
```

### Step 8: UI統合
**File**: `Sources/QuickTranscriber/Views/SettingsView.swift`

- `ActiveSpeakerRow`の`onRename` → `viewModel.tryRenameActiveSpeaker`に変更
- `SpeakerProfileDetailView`の`onRename` → `viewModel.tryRenameSpeaker`に変更
- `SpeakersSettingsTab`に`.alert("Merge Speakers?")`追加:
  - Mergeボタン: `.keyboardShortcut(.defaultAction)` ← **Enter**でマージ
  - Cancelボタン: `role: .cancel`
  - メッセージ: `「"<source>" を "<target>" にマージしますか？すべてのセグメントが統合されます。」`
- New Speaker...のalert: 重複時はアクティブ化確認に分岐

### Step 9: テスト
**File**: `Tests/QuickTranscriberTests/SpeakerMergeTests.swift` (新規)

| テスト | 内容 |
|---|---|
| ユニーク名→nilを返す | `checkNameUniqueness` |
| Active重複→MergeRequest返却 | Active↔Active |
| Registered重複→MergeRequest返却 | Active↔Registered |
| Case-insensitive | 「Bob」と「bob」は衝突 |
| 空文字→nil | ユニーク制約対象外 |
| 自身→nil | 同じ名前へのリネーム |
| 高sessionCount側が生存 | 生存者決定 |
| タイ→ターゲット生存 | 生存者決定 |
| セグメント再割当 | 吸収側→生存側 |
| Embedding EMA統合 | 0.7/0.3ブレンド |
| sessionCount加算 | メタデータ統合 |
| isLocked伝播 | 吸収側lockが生存側に移る |
| 吸収側プロファイル削除 | 完全クリーンアップ |
| Active↔Active (プロファイルなし) | エッジケース |
| Registered↔Registered | 非Active同士 |
| tryRename→ユニーク→直接リネーム | 統合フロー |
| tryRename→重複→pendingMergeRequestセット | 統合フロー |
| cancelMerge | pendingMergeRequest=nil |
| executeMerge→regenerateText呼出 | 後処理 |

**既存テストファイルへの追加**:
- `SpeakerProfileStoreTests.swift`: `testForceDeleteIgnoresLocked`
- `EmbeddingBasedSpeakerTrackerTests.swift`: `testMergeProfile`

## 変更対象ファイル

| File | 変更内容 |
|---|---|
| `ViewModels/TranscriptionViewModel.swift` | SpeakerEntity, SpeakerMergeRequest, checkNameUniqueness, tryRename*, executeMerge, cancelMerge, addManualSpeaker修正 |
| `Views/SettingsView.swift` | tryRename呼出、.alert追加、New Speaker重複チェック |
| `Engines/EmbeddingBasedSpeakerTracker.swift` | mergeProfile(from:into:) |
| `Engines/SpeakerDiarizer.swift` | protocol: mergeSpeakerProfiles |
| `Engines/FluidAudioSpeakerDiarizer.swift` | mergeSpeakerProfiles実装 |
| `Engines/ChunkedWhisperEngine.swift` | mergeSpeakerProfiles伝播 |
| `Services/TranscriptionService.swift` | mergeSpeakerProfiles伝播 |
| `Models/SpeakerProfileStore.swift` | forceDelete(id:) |
| `Tests/.../SpeakerMergeTests.swift` | 新規テストファイル |
| `Tests/.../SpeakerProfileStoreTests.swift` | forceDeleteテスト追加 |
| `Tests/.../EmbeddingBasedSpeakerTrackerTests.swift` | mergeProfileテスト追加 |

## 検証方法

1. **ユニットテスト**: `swift test --filter QuickTranscriberTests`
2. **手動テスト**:
   - Active Speakerをリネーム→既存Registered名と衝突→Mergeダイアログ→Enter→マージ完了確認
   - Registered Speakerをリネーム→既存Active名と衝突→同上
   - New Speaker...で既存名入力→アクティブ化確認ダイアログ
   - マージ後のトランスクリプト表示で話者名が統一されていること
   - マージ後のspeakers.jsonで吸収側プロファイルが削除されていること
   - 録音中にマージ→セグメント・tracker両方更新されること
