# Phase 3b: Per-Chunk Embedding Storage and Precise Profile Reconstruction

## Problem

現在のEmbeddingBasedSpeakerTrackerは移動平均(alpha=0.3)で単一embeddingベクトルを更新している。これにより:

1. ユーザーがセグメントの話者をA→Bに修正しても、Trackerのプロファイルには誤ったembeddingが移動平均として混入済み
2. 以降のチャンクで同じ誤認識が繰り返される
3. ユーザーは同じ修正を繰り返す必要がある
4. セッション終了時の永続化プロファイルにもノイズが蓄積される

## Solution: Approach B — Tracker内全履歴保持 + 厳密再計算

### 設計方針

- Tracker内に全embeddingの履歴を保持
- 移動平均を廃止し、全履歴の算術平均に切り替え
- ユーザー修正時にembeddingを正しい話者に移動し、両プロファイルを即座に再計算
- セッション終了時に全履歴を永続化

## Data Structures

### ConfirmedSegment の拡張

```swift
public struct ConfirmedSegment: Sendable, Equatable {
    // 既存
    public var text: String
    public var precedingSilence: TimeInterval
    public var speaker: String?
    public var speakerConfidence: Float?
    public var isUserCorrected: Bool
    public var originalSpeaker: String?

    // Phase 3b
    public var speakerEmbedding: [Float]?  // 256-dim
}
```

### EmbeddingBasedSpeakerTracker の拡張

```swift
public struct SpeakerProfile {
    public let label: String
    public var embedding: [Float]          // 全履歴の平均（常に再計算）
    public var hitCount: Int               // = embeddingHistory.count
    public var embeddingHistory: [(embedding: [Float], segmentIndex: Int)]
}
```

- `embeddingHistory`: セッション中の全embeddingとセグメントインデックス
- `embedding`: 常に `embeddingHistory` の算術平均から再計算
- 移動平均(alpha=0.3)は廃止

### EmbeddingHistoryStore（新規）

保存先: `~/QuickTranscriber/embedding_history.json`

```swift
public struct EmbeddingHistoryEntry: Codable {
    public let speakerProfileId: UUID
    public let label: String
    public let sessionDate: Date
    public let embeddings: [HistoricalEmbedding]
}

public struct HistoricalEmbedding: Codable {
    public let embedding: [Float]
    public let confirmed: Bool
}

public class EmbeddingHistoryStore {
    func appendSession(entries: [EmbeddingHistoryEntry])
    func loadAll() -> [EmbeddingHistoryEntry]
    func reconstructProfile(for profileId: UUID) -> [Float]?
}
```

### speakers.json との関係

- `speakers.json`: メインのプロファイル情報（後方互換維持）
- `embedding_history.json`: 詳細な履歴データ（再構築の材料）
- 再構築時: 確認済みembeddingを集約 → `speakers.json` の embedding を更新

## Real-Time Correction Feedback

### 修正フロー

```
ユーザーがセグメントNの話者をA→Bに修正
  ↓
InteractiveTranscriptionTextView → VM.reassignSpeaker(segmentIndex, to: "B")
  ↓
VM → ChunkedWhisperEngine.correctSpeakerAssignment(segmentIndex, from: "A", to: "B")
  ↓
EmbeddingBasedSpeakerTracker.correctAssignment(segmentIndex, from: "A", to: "B")
  1. profiles["A"].embeddingHistory から segmentIndex のエントリを削除
  2. profiles["B"].embeddingHistory に追加
  3. 両プロファイルの embedding を全履歴から再計算
  ↓
以降のチャンクは更新されたプロファイルで認識 → 精度向上
```

### 新規API

```swift
// EmbeddingBasedSpeakerTracker
public func correctAssignment(segmentIndex: Int, from oldLabel: String, to newLabel: String)

// SpeakerDiarizer protocol
func correctSpeakerAssignment(segmentIndex: Int, from oldLabel: String, to newLabel: String)

// ChunkedWhisperEngine
public func correctSpeakerAssignment(segmentIndex: Int, from oldLabel: String, to newLabel: String)
```

### プロファイル再計算

```swift
func recalculateEmbedding(for profile: inout SpeakerProfile) {
    guard !profile.embeddingHistory.isEmpty else { return }
    profile.embedding = averageEmbeddings(profile.embeddingHistory.map(\.embedding))
    profile.hitCount = profile.embeddingHistory.count
}
```

## Session End Persistence

### stopStreaming() のフロー

```
stopStreaming()
  ↓
1. Tracker.exportDetailedProfiles()
   → [(label, embedding, embeddingHistory)]
  ↓
2. ユーザー修正情報の反映
   - isUserCorrected == true → confirmed = true
   - isUserCorrected == false → confirmed = true（暗黙確認）
  ↓
3. SpeakerProfileStore.mergeSessionProfiles()
   - speakers.json: 最終embeddingでマージ（後方互換）
  ↓
4. EmbeddingHistoryStore.appendSession()
   - embedding_history.json: セッションの全履歴を追記
  ↓
5. プロファイル再構築（オプション）
   - 全セッションの確認済みembeddingから再計算
   - speakers.json のembeddingを更新
```

## Test Strategy

### EmbeddingBasedSpeakerTrackerTests（拡張）

- `testIdentifyStoresEmbeddingHistory` — identify()呼出しごとにembeddingHistoryが蓄積される
- `testCorrectAssignmentMovesEmbedding` — correctAssignment()でembeddingが正しく移動される
- `testCorrectAssignmentRecalculatesProfiles` — 移動後にプロファイルのembeddingが再計算される
- `testExportDetailedProfiles` — 履歴付きでエクスポートできる

### EmbeddingHistoryStoreTests（新規）

- `testAppendAndLoad` — セッション追記・読み込み
- `testReconstructProfile` — 確認済みembeddingからのプロファイル再構築
- `testMultipleSessionsMerge` — 複数セッション分の集約

### 統合テスト

- `testCorrectionFeedbackUpdatesTracker` — 修正がTrackerに伝播する
- `testStopStreamingSavesHistory` — セッション終了時に履歴が保存される

### 後方互換性の確認

- 既存のSpeakerProfileStoreTests — speakers.json側の後方互換性
- 既存のSegmentCharacterMapTests — embedding追加がUI表示に影響しない

## Non-Goals

- 音声録音によるenrollment UI
- デバイス間プロファイル同期
- embedding_history.json のサイズ制限（年500セッション程度、数MBで問題なし）
