# Manual mode 話者揺らぎ解消 — 修正設計

## Context

Manual mode（参加者を事前登録）で話者識別が揺らぐ問題がユーザーから継続報告されている。
過去の対策（2026-03-05 Viterbi リセット、2026-03-10 `suppressLearning` 導入）で大幅に改善されたが、
**手動で A に修正しても次のチャンクで B に戻る**現象が残存。

### 残存する根本原因

`EmbeddingBasedSpeakerTracker.correctAssignment()` が `suppressLearning` フラグに関わらず常に profile
centroid を更新する（`EmbeddingBasedSpeakerTracker.swift:56` のコメントで明示）。
結果として発生する**正のフィードバックループ**:

1. Aさんの「曖昧な embedding」が B と誤認される
2. ユーザーが A に修正 → `correctAssignment(embedding, from: B, to: A)`
3. Aの profile に **Bっぽい embedding** が `confidence=1.0` で注入 → centroid が B 方向にシフト
4. 次のチャンクで本物の Aさんが話しても、汚染された A profile より B profile の方が類似度が高い
5. → 再び B と誤認 → ユーザー再修正 → さらに汚染 → **発散**

`reassignSpeakerForBlock` / `reassignSpeakerForSelection` では 1 ブロック内の複数 segment について
個別に `correctAssignment` を呼ぶため、汚染は指数的に加速する。

### 追加で発見された揺らぎ経路

- `removeAll { $0.embedding == embedding }` の exact-match 削除脆弱性
- capacity-full パスの tie-breaker が「enumerate 順の最初」で marginal similarity 差で flip する
- `SpeakerStateCoordinator.reassignSegment` で embedding が nil の場合、Viterbi の `confirmSpeaker` すら呼ばれない

---

## Goals

1. Manual mode で「手動修正→次チャンクで戻る」連鎖を根絶する
2. 登録1回だけの participant も、Manual mode 使用を重ねるごとに緩やかに学習する
3. Auto mode の「user correction 由来の centroid 汚染」も軽減する（補助的）
4. 既存 Auto mode の benchmarks に regression を出さない

## Non-Goals

- Viterbi grace period（`pendingCount` 閾値の N チャンク引き上げ等）は本 spec では導入しない。
  A' の効果計測後、必要なら別 spec で検討する。詳細はメモリ参照。
- Session 中の participant 追加/削除をサポートする拡張は範囲外
- 本レビューで指摘された以下は別 issue として切り出す:
  - `ChunkedWhisperEngine.cleanup()` の fire-and-forget
  - `VADChunkAccumulator` thread safety
  - `TranscriptionViewModel` init の同期 I/O
  - `EmbeddingHistoryStore` pruning 改善
  - `ViterbiSpeakerSmoother.remapSpeaker` の force unwrap（コスメ）

---

## 全体アーキテクチャ

3 層で修正する:

### Layer 1: Tracker (`EmbeddingBasedSpeakerTracker`)
- `suppressLearning` の意味を拡張: true の間は `identify()` に加えて `correctAssignment()` も
  centroid を動かさない
- ユーザー修正の情報は別枠 (`userCorrections` 集合) に記録し、session 終了時の
  post-hoc 学習で使用
- Tie-breaker 強化（hitCount → lastConfirmedId）
- 削除を exact-match から ID ベース (`entryId: UUID`) に置換

### Layer 2: Engine (`ChunkedWhisperEngine`)
- `stopStreaming` に**非修正 segment を使った緩やかな post-hoc 学習**を追加
- `correctSpeakerAssignment` の public signature は不変（Layer 1 の挙動変更により自動的に
  "centroid 動かず、ラベルと Viterbi のみ反映" になる）
- Viterbi の embedding-nil 経路用に `syncViterbiConfirm(to:)` API 追加

### Layer 3: Coordinator (`SpeakerStateCoordinator`)
- `reassignSegment` の Viterbi 同期経路を強化: embedding が nil でも Viterbi の
  `confirmSpeaker` だけは呼ぶ

---

## コンポーネント変更詳細

### `EmbeddingBasedSpeakerTracker.swift`

#### (a) `WeightedEmbedding` に安定IDを追加

```swift
public struct WeightedEmbedding: Sendable, Equatable, Codable {
    public let entryId: UUID
    public let embedding: [Float]
    public let confidence: Float

    public init(entryId: UUID = UUID(), embedding: [Float], confidence: Float) {
        self.entryId = entryId
        self.embedding = embedding
        self.confidence = confidence
    }
}
```

削除時は `removeAll { $0.entryId == targetId }` で一致削除する。
Equatable は全フィールド一致で判定（既存の cosine-similarity based 比較は embedding 値のみで
マッチする箇所を ID ベースに置き換える）。

#### (b) `suppressLearning` の意味拡張

```swift
public struct UserCorrection: Sendable, Equatable {
    public let entryId: UUID
    public let fromId: UUID
    public let toId: UUID
}

private var userCorrections: [UserCorrection] = []

public func correctAssignment(embedding: [Float], from oldId: UUID, to newId: UUID) {
    lock.withLock {
        if suppressLearning {
            // centroid は動かさない。修正情報だけ記録して post-hoc 学習に備える
            let entryId = UUID()  // この embedding 固有の ID
            userCorrections.append(UserCorrection(entryId: entryId, fromId: oldId, toId: newId))
            return
        }

        // 従来ロジック + confidence 値の引き下げ
        if let oldIdx = profiles.firstIndex(where: { $0.id == oldId }) {
            profiles[oldIdx].embeddingHistory.removeAll { Self.embeddingMatches($0.embedding, embedding) }
            if profiles[oldIdx].embeddingHistory.isEmpty {
                profiles.remove(at: oldIdx)
            } else {
                recalculateEmbedding(at: oldIdx)
            }
        }

        let addConfidence = Constants.Embedding.userCorrectionConfidence  // Auto mode: 0.3
        if let newIdx = profiles.firstIndex(where: { $0.id == newId }) {
            profiles[newIdx].embeddingHistory.append(
                WeightedEmbedding(embedding: embedding, confidence: addConfidence))
            recalculateEmbedding(at: newIdx)
        } else {
            profiles.append(SpeakerProfile(
                id: newId,
                embedding: embedding,
                hitCount: 1,
                embeddingHistory: [WeightedEmbedding(embedding: embedding, confidence: addConfidence)]
            ))
        }
    }
}
```

Auto mode で suppressLearning=false の場合は従来どおり centroid 更新するが、
追加する `WeightedEmbedding` の confidence を `1.0` から `Constants.Embedding.userCorrectionConfidence`
（デフォルト 0.3）に変更することで、汚染速度を 1/3 程度に緩和する。

#### (c) Tie-breaker 導入

```swift
private var lastConfirmedId: UUID?

// identify() 内の bestIndex 決定後:
let candidates = profiles.enumerated().filter { (_, p) in
    abs(Self.cosineSimilarity(embedding, p.embedding) - bestSimilarity)
        <= Constants.Embedding.tieBreakerEpsilon
}

let chosen: Int
if candidates.count > 1 {
    // 1. hitCount 最大
    let maxHit = candidates.max { $0.1.hitCount < $1.1.hitCount }!.1.hitCount
    let byHitCount = candidates.filter { $0.1.hitCount == maxHit }
    if byHitCount.count == 1 {
        chosen = byHitCount[0].0
    } else if let lastId = lastConfirmedId,
              let lastMatch = byHitCount.first(where: { $0.1.id == lastId }) {
        // 2. lastConfirmedId と一致するもの
        chosen = lastMatch.0
    } else {
        chosen = byHitCount[0].0  // 3. enumerate 順（従来と同じ）
    }
} else {
    chosen = bestIndex
}

// 決定後
lastConfirmedId = profiles[chosen].id
```

#### (d) `exportUserCorrections()` 追加

```swift
public func exportUserCorrections() -> [UserCorrection] {
    lock.withLock { userCorrections }
}

public func resetUserCorrections() {
    lock.withLock { userCorrections = [] }
}
```

### `ChunkedWhisperEngine.swift`

#### (a) `syncViterbiConfirm(to:)` API 追加

```swift
public func syncViterbiConfirm(to newId: UUID) {
    smootherLock.withLock {
        speakerSmoother.confirmSpeaker(newId)
    }
}
```

#### (b) `startStreaming` で participant UUID を保持

`ChunkedWhisperEngine` に instance state を追加:

```swift
private var currentParticipantIds: Set<UUID> = []
```

`startStreaming` 内、Manual mode 分岐で `participantProfiles` を受け取った直後に:

```swift
currentParticipantIds = Set(participantProfiles.map { $0.speakerId })
```

Auto mode および Manual mode で参加者 0 人の場合は空集合。
`stopStreaming` 完了時に `currentParticipantIds = []` でクリアする。

#### (c) `stopStreaming` の post-hoc 学習ロジック

現行の `correctedOriginalSpeakers` による profile 丸ごと除外ロジックを廃止し、
segment-level の非修正 + 高 confidence サンプルを集計する方式へ置換する:

```swift
// Session 終了時の post-hoc 学習 (Manual mode のみ)
if let diarizer, diarizationActive,
   currentParameters.diarizationMode == .manual,
   let store = speakerProfileStore {
    var learnedUpdates: [(speakerId: UUID, embedding: [Float], displayName: String)] = []

    for participantId in currentParticipantIds {
        let samples = confirmedSegments.filter { seg in
            seg.speaker == participantId.uuidString
                && !seg.isUserCorrected
                && (seg.speakerConfidence ?? 0) >= Constants.Embedding.similarityThreshold
                && seg.speakerEmbedding != nil
        }

        guard samples.count >= Constants.Embedding.sessionLearningMinSamples else { continue }

        // Locked profile はスキップ
        guard let existing = store.profiles.first(where: { $0.id == participantId }),
              !existing.isLocked else { continue }

        let sessionCentroid = centroid(of: samples.compactMap { $0.speakerEmbedding })
        let alpha = min(
            Constants.Embedding.sessionLearningAlphaMax,
            Float(samples.count) / Float(Constants.Embedding.sessionLearningSamplesForMaxAlpha)
        )
        let merged = zip(existing.embedding, sessionCentroid).map { old, new in
            (1 - alpha) * old + alpha * new
        }
        // displayName は既存 profile のものをそのまま使う (rename は別操作で行う)
        learnedUpdates.append((participantId, merged, existing.displayName))
    }

    if !learnedUpdates.isEmpty {
        store.mergeSessionProfiles(learnedUpdates)
        try? store.save()
    }
}
```

**重要**: `tracker.exportSpeakerProfiles()` は session 中 centroid 不動なので使わず、
`confirmedSegments` を直接集計する。

`embeddingHistoryStore` への書き込みは、post-hoc 学習に使った sample のみを
`HistoricalEmbedding(embedding:, confirmed: true, confidence:)` として永続化する。
参加者以外 (Auto mode 由来の profile) の書き込みは従来どおり tracker export 経由で継続する。

### `SpeakerStateCoordinator.swift`

#### `reassignSegment` の embedding-nil 経路

```swift
func reassignSegment(at index: Int, to newSpeaker: String, segments: inout [ConfirmedSegment]) {
    guard index < segments.count else { return }
    let originalSpeaker = segments[index].speaker

    if let oldSpeaker = originalSpeaker {
        if let embedding = segments[index].speakerEmbedding {
            service?.correctSpeakerAssignment(
                embedding: embedding, from: oldSpeaker, to: newSpeaker)
        } else if let newId = UUID(uuidString: newSpeaker) {
            service?.syncViterbiConfirm(to: newId)
        }
    }

    segments[index].originalSpeaker = originalSpeaker
    segments[index].speaker = newSpeaker
    segments[index].speakerConfidence = 1.0
    segments[index].isUserCorrected = true
}
```

### `TranscriptionService.swift`

`syncViterbiConfirm(to:)` を protocol 経由で engine へ委譲する薄い wrapper を追加。

### 定数追加 (`Constants.swift`)

```swift
enum Embedding {
    // 既存
    static let similarityThreshold: Float = 0.5
    // 新規
    static let userCorrectionConfidence: Float = 0.3          // Auto mode で correctAssignment が使う
    static let sessionLearningAlphaMax: Float = 0.2           // post-hoc 学習 α の上限
    static let sessionLearningSamplesForMaxAlpha: Int = 50    // α が max に達するサンプル数
    static let sessionLearningMinSamples: Int = 3             // post-hoc 学習の最小サンプル数
    static let tieBreakerEpsilon: Float = 0.005               // tie-breaker の差分閾値
}
```

---

## データフロー

### 通常の識別（Manual mode, session 中）

```
音声チャンク到着
  ↓
ChunkedWhisperEngine.processChunk
  ↓
diarizer.identifySpeaker → EmbeddingBasedSpeakerTracker.identify(embedding)
  [profile と cosine similarity 比較]
  [tie 時: hitCount → lastConfirmedId で決定]
  [suppressLearning=true のため centroid 不動]
  ↓
ViterbiSpeakerSmoother.process → 確定 / pending
  ↓
ConfirmedSegment に speaker / embedding / confidence 保存
```

### ユーザー修正（Manual mode）

```
UI クリック「A に修正」
  ↓
SpeakerStateCoordinator.reassignSegment
  for each segment in block/selection:
    ├─ embedding あり:
    │    service.correctSpeakerAssignment(embedding, from: old, to: new)
    │      ↓ Engine → diarizer.correctSpeakerAssignment
    │      ↓ Tracker.correctAssignment(suppressLearning=true):
    │        - profile centroid 不変
    │        - userCorrections に (entryId, from, to) 記録
    │    Engine → Viterbi.confirmSpeaker(newId)
    │
    └─ embedding なし:
         service.syncViterbiConfirm(to: newId)
           ↓ Engine → Viterbi.confirmSpeaker(newId) のみ

  segment.speaker を newSpeaker に更新
  segment.isUserCorrected = true
  segment.originalSpeaker = oldSpeaker
```

→ **次のチャンク到着時も profile は変わっていないので、同じ声なら同じ判定が返る**。
Viterbi の `confirmSpeaker` により stateLogProb も newId 支配。

### Session 終了時の post-hoc 学習（Manual mode）

```
stopStreaming 呼ばれる
  ↓
confirmedSegments を走査して participant ごとに集計:
  samples = segments.filter {
    speaker == participantId
    && !isUserCorrected
    && (speakerConfidence ?? 0) >= similarityThreshold
    && speakerEmbedding != nil
  }
  ↓
samples.count < MIN_SAMPLES (3) ならスキップ
profile.isLocked ならスキップ
  ↓
sessionCentroid = weighted-mean(samples.speakerEmbedding)
α = min(0.2, samples.count / 50)
newEmbedding = (1 - α) * frozenEmbedding + α * sessionCentroid
  ↓
profileStore.mergeSessionProfiles で上書き保存
embeddingHistoryStore に session 情報追記（学習に使った embedding のみ、confirmed=true）
```

### Auto mode でのフロー差分

- Session 中の `identify()` は `suppressLearning=false` で centroid 更新（従来通り）
- `correctAssignment` の追加 embedding の confidence が `1.0` → `0.3` に変わる
  （centroid シフトが 1/3 程度に緩和）
- post-hoc 学習は実行されない（Manual mode 限定）
- Tie-breaker は両モード共通で有効

---

## エラーハンドリング & エッジケース

| ケース | 挙動 |
|---|---|
| Manual mode で参加者 0 人 | 現状通り `diarizationActive = false`（変更なし） |
| Session 全体で participant X の非修正 segment が 0 | post-hoc 学習をスキップ（profile 不動で save なし） |
| Session 全体で participant X の非修正 segment が 1-2 個 | `MIN_SAMPLES=3` 未満のためスキップ（ノイズ重視を避ける） |
| Participant の profile が `isLocked=true` | post-hoc 学習をスキップ（ユーザー意図の尊重） |
| `correctAssignment(from: X, to: Y)` で X/Y が participant list 外 | Manual mode では `suppressLearning=true` のため centroid 不変（userCorrections にのみ記録）。Auto mode では従来通り |
| embedding nil で `syncViterbiConfirm` が呼ばれる | `speakerSmoother.confirmSpeaker(newId)` のみ。Tracker には触れない |
| Tie-breaker で `lastConfirmedId` が nil | hitCount 優先 → それも同値なら enumerate 順（従来と同じ）でフォールバック |
| Session 中に participant を追加/削除 | 本修正の範囲外。現行挙動を維持 |

### `WeightedEmbedding` 互換性

`entryId: UUID` 追加により `Codable` schema が変わる。対応:
- 既存の persist フィールド (`embedding`, `confidence`) に `entryId` を**オプショナルで追加**
- 既存データの読み込み時 `entryId == nil` なら `UUID()` を割り当てて migrate
- テストで `WeightedEmbedding` を直接 struct 比較している箇所は `entryId` 一致を前提としないよう修正

---

## テスト戦略

### 追加ユニットテスト

**Tracker 層:**
1. `test_correctAssignment_suppressLearning_doesNotMutateCentroid`
2. `test_correctAssignment_suppressLearning_recordsUserCorrection`
3. `test_correctAssignment_nonSuppress_usesLowerConfidence`
4. `test_identify_tieBreaker_prefersHigherHitCount`
5. `test_identify_tieBreaker_prefersLastConfirmed`
6. `test_correctAssignment_removesByEntryId_notEmbeddingValue`

**Engine 層:**
7. `test_postHocLearning_appliesWeightedMergeForNonCorrectedSegments`
8. `test_postHocLearning_skipsWhenSampleCountBelowMin`
9. `test_postHocLearning_skipsForLockedProfile`
10. `test_postHocLearning_alphaScalesWithSampleCount`

**Coordinator 層:**
11. `test_reassignSegment_nilEmbedding_callsViterbiSync`
12. `test_reassignSegment_nilEmbedding_doesNotCallCorrectAssignment`

### 結合テスト

`ManualModeStabilityTests`（新規）:
- Mock tracker + mock diarizer で「10 回連続で同じ話者の embedding を投入 → 途中 3 回誤認 →
  ユーザー修正 → 以降誤認が再発しないこと」をシミュレート
- 現状のコードでは failing、本 spec 適用後に passing になる expected-failure テスト

### ベンチマーク

`ParameterBenchmarkTests` に追加:
- **Manual mode stability benchmark**: 2 話者シミュレーション音声で
  - 話者切り替え数（真値 vs 予測値）
  - `isUserCorrected=true` を想定した修正回数
  - α 値のスイープ (`0.0, 0.1, 0.2, 0.3`) で最適値を検証
- 既存 Auto mode benchmarks の regression ないこと

### 既存テストへの影響

以下は signature 変更や挙動変更で touch が必要:

- `EmbeddingBasedSpeakerTrackerTests.swift`: `correctAssignment` 挙動変更、`WeightedEmbedding` Equatable
- `SpeakerDiarizerTests.swift`: 同上
- `EmbeddingHistoryStoreTests.swift`: Codable schema migration テスト追加
- `SpeakerReassignmentTests.swift` / `SpeakerReassignmentUIUpdateTests.swift`: nil embedding 経路
- `ChunkedWhisperEngineTests.swift`: post-hoc 学習ロジック
- `SpeakerStateCoordinatorTests.swift`: `reassignSegment` の embedding-nil 経路

### 手動検証（Speaker State Mutation Checklist）

CLAUDE.md の checklist に従う:
1. SpeakerStateCoordinator 経由で操作しているか ✓
2. 関連コンポーネント全て更新されるか: Tracker / Viterbi / Segments / ProfileStore / EmbeddingHistory
3. `InvariantChecker` が通過するか
4. クロスコンポーネントテスト: `ManualModeStabilityTests`

---

## 実装順序

1. **Tracker 層** (`EmbeddingBasedSpeakerTracker`) — `WeightedEmbedding` schema 変更、
   `suppressLearning` 拡張、`userCorrections` 記録、tie-breaker、`exportUserCorrections`
2. **Constants** 追加
3. **Engine 層** (`ChunkedWhisperEngine`) — `syncViterbiConfirm` API、`stopStreaming` の post-hoc 学習
4. **Coordinator 層** (`SpeakerStateCoordinator`) — `reassignSegment` の nil-embedding 経路
5. **TranscriptionService** — `syncViterbiConfirm` wrapper
6. **既存テスト修正** + **新規テスト追加**
7. **ベンチマーク追加** + α 値の実測

各ステップは TDD で進める（`superpowers:test-driven-development` に準拠）。

---

## リスク & 緩和策

| リスク | 緩和策 |
|---|---|
| post-hoc 学習の α=0.2 が過大で、長期使用で centroid が drift する | ベンチマークで α を実測。設定で override 可能にする余地を残す（本 spec ではハードコード） |
| `userCorrectionConfidence=0.3` が auto mode の既存動作に regression を入れる | Auto mode benchmarks で検証。悪化が大きい場合は 0.5 程度で再調整 |
| Manual mode で participant 外の UUID に修正されるケース（例: "Unknown" に戻す操作） | Manual mode では `suppressLearning=true` により centroid は動かない。`userCorrections` に記録のみ残る |
| `WeightedEmbedding` の Codable migration 失敗 | `entryId` をオプショナルで受け入れ、nil の時は UUID() で付与する lenient decoder |
| Viterbi grace period を導入しないことで揺らぎが残る | 効果計測後に別 spec で追加を検討（メモリに deferred 記録済み） |

---

## 参考: 過去の関連設計

- `docs/plans/2026-03-05-viterbi-reset-on-correction-design.md` — Viterbi state リセット導入
- `docs/plans/2026-03-10-manual-mode-speaker-label-fix.md` — `suppressLearning` フラグ導入

本 spec はこれら 2 つの延長線上で、残存するフィードバックループを断ち切ることを目的とする。
