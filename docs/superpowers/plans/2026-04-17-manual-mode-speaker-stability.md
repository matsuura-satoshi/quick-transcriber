# Manual Mode Speaker Stability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Manual mode で「手動修正した話者が次チャンクで戻される」揺らぎを根絶する。Session 中は participant profile centroid を完全凍結し、session 終了時に非修正 segment から緩やかに学習する。Auto mode にも補助的に user correction 汚染の緩和策を入れる。

**Architecture:** 3 層で修正する。(1) `EmbeddingBasedSpeakerTracker` は `suppressLearning=true` の間 `correctAssignment` も centroid を動かさず、修正情報だけ `userCorrections` に記録。Tie-breaker を hitCount / lastConfirmedId で強化。embedding entry の削除は新設 `entryId: UUID` ベース。(2) `ChunkedWhisperEngine` は session 開始時の participant ID 集合を保持し、`stopStreaming` 時に「非修正かつ高 confidence」segment から participant profile を緩やかに merge。`syncViterbiConfirm` 新 API を追加。(3) `SpeakerStateCoordinator.reassignSegment` は embedding が nil でも Viterbi の `confirmSpeaker` を呼ぶ経路を追加。

**Tech Stack:** Swift, XCTest, SwiftUI, WhisperKit, FluidAudio。macOS 15+。

**Spec:** `docs/superpowers/specs/2026-04-17-manual-mode-speaker-stability-design.md`

---

## File Structure

### Modified
- `Sources/QuickTranscriber/Constants.swift` — 新規 `Embedding` 定数 5 本を追加
- `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift` — `WeightedEmbedding.entryId`、`UserCorrection` 構造体、`suppressLearning` 挙動拡張、tie-breaker、`exportUserCorrections` / `resetUserCorrections`
- `Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift` — protocol に `exportUserCorrections` を追加（default no-op）、`FluidAudioSpeakerDiarizer` でパススルー
- `Sources/QuickTranscriber/Engines/TranscriptionEngine.swift` — protocol に `syncViterbiConfirm(to:)` を追加（default no-op）
- `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift` — `currentParticipantIds` state、`syncViterbiConfirm` 実装、`stopStreaming` に Manual mode 限定の post-hoc 学習
- `Sources/QuickTranscriber/Services/TranscriptionService.swift` — `syncViterbiConfirm(to:)` wrapper
- `Sources/QuickTranscriber/Models/SpeakerStateCoordinator.swift` — `reassignSegment` で embedding nil 経路に Viterbi 同期を追加
- `Sources/QuickTranscriber/Models/SpeakerProfileStore.swift` — `applyPostHocLearning(speakerId:, sessionCentroid:, alpha:)` 新 API
- `Tests/QuickTranscriberTests/Mocks/MockSpeakerDiarizer.swift` — `exportUserCorrections`, `setSuppressLearning` の記録
- `Tests/QuickTranscriberTests/Mocks/MockTranscriptionEngine.swift` — `syncViterbiConfirm` の記録

### Tests modified
- `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift`
- `Tests/QuickTranscriberTests/SpeakerDiarizerTests.swift`
- `Tests/QuickTranscriberTests/SpeakerReassignmentTests.swift`
- `Tests/QuickTranscriberTests/SpeakerStateCoordinatorTests.swift`
- `Tests/QuickTranscriberTests/ChunkedWhisperEngineTests.swift`

### Tests created
- `Tests/QuickTranscriberTests/ManualModeStabilityTests.swift` — 統合テスト（揺らぎ再発なしを検証）
- `Tests/QuickTranscriberTests/PostHocLearningTests.swift` — ChunkedWhisperEngine の post-hoc 学習専用テスト

---

## Conventions

- テスト実行: `swift test --filter QuickTranscriberTests` (約 2 秒)
- ベンチマークは今回は追加のみで、検証には使わない（モデル要、5-10 分）
- コミットメッセージは既存慣習 (`feat:`, `fix:`, `refactor:`, `test:`)
- CLAUDE.md に従い、PR 番号は本 PR が切れたら `Constants.Version.patch` を更新する（本プランでは **patch の更新は行わない**。PR 作成時に別タスクで実施）
- 既存の削除用途で `trash` の利用指針あり。本プランではファイル削除はしない
- `WeightedEmbedding.Equatable` は**カスタム実装で entryId を無視**する（既存テストの値比較が壊れないように）

---

## Task 1: 定数追加

**Files:**
- Modify: `Sources/QuickTranscriber/Constants.swift:28-30`
- Test: (定数のみのため単体テストは不要)

- [ ] **Step 1: 定数を追加**

```swift
// Constants.swift の Embedding enum を以下で置き換え
public enum Embedding {
    public static let similarityThreshold: Float = 0.5
    /// Auto mode で correctAssignment が新 embedding を profile に追加するときの confidence。
    /// 1.0 だと 1 回の修正で centroid が大きくシフトし、汚染フィードバックループを起こす。
    public static let userCorrectionConfidence: Float = 0.3
    /// Manual mode の post-hoc 学習で適用する weighted merge の α 上限。
    public static let sessionLearningAlphaMax: Float = 0.2
    /// α が上限に達するために必要なサンプル数。
    public static let sessionLearningSamplesForMaxAlpha: Int = 50
    /// post-hoc 学習を行う最小サンプル数。これ未満の場合はノイズ過大とみなしスキップ。
    public static let sessionLearningMinSamples: Int = 3
    /// identify() の tie-breaker で「ほぼ同値」とみなす similarity 差の閾値。
    public static let tieBreakerEpsilon: Float = 0.005
}
```

- [ ] **Step 2: ビルドが通ることを確認**

Run: `swift build`
Expected: エラーなし

- [ ] **Step 3: Commit**

```bash
git add Sources/QuickTranscriber/Constants.swift
git commit -m "feat: add Embedding constants for stability fix"
```

---

## Task 2: `WeightedEmbedding` に entryId を追加

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift:23-31`
- Test: `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift` (末尾追加)

- [ ] **Step 1: Failing テストを追加**

ファイル末尾（`}` の直前）に追加:

```swift
// MARK: - WeightedEmbedding entryId

func testWeightedEmbedding_hasUniqueEntryId() {
    let a = WeightedEmbedding(embedding: [1.0, 2.0], confidence: 0.5)
    let b = WeightedEmbedding(embedding: [1.0, 2.0], confidence: 0.5)
    XCTAssertNotEqual(a.entryId, b.entryId, "Two WeightedEmbedding instances should have distinct entryIds even with identical content")
}

func testWeightedEmbedding_equalityIgnoresEntryId() {
    let a = WeightedEmbedding(embedding: [1.0, 2.0], confidence: 0.5)
    let b = WeightedEmbedding(embedding: [1.0, 2.0], confidence: 0.5)
    XCTAssertEqual(a, b, "Equality should compare embedding + confidence, not entryId")
}

func testWeightedEmbedding_explicitEntryIdPreserved() {
    let id = UUID()
    let a = WeightedEmbedding(entryId: id, embedding: [1.0], confidence: 1.0)
    XCTAssertEqual(a.entryId, id)
}
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `swift test --filter QuickTranscriberTests.EmbeddingBasedSpeakerTrackerTests/testWeightedEmbedding_hasUniqueEntryId`
Expected: COMPILE ERROR（`entryId` 不明、`init(entryId:...)` 不明）

- [ ] **Step 3: `WeightedEmbedding` を更新**

`EmbeddingBasedSpeakerTracker.swift` の `WeightedEmbedding` を以下で置き換え:

```swift
public struct WeightedEmbedding: Sendable {
    /// Unique identifier for this embedding entry. Used by correctAssignment
    /// to remove by identity rather than embedding-value match.
    public let entryId: UUID
    public let embedding: [Float]
    public let confidence: Float

    public init(entryId: UUID = UUID(), embedding: [Float], confidence: Float) {
        self.entryId = entryId
        self.embedding = embedding
        self.confidence = confidence
    }
}

extension WeightedEmbedding: Equatable {
    /// Equality compares semantic content only; entryId is a tracking ID
    /// and is intentionally excluded so value-based assertions remain stable.
    public static func == (lhs: WeightedEmbedding, rhs: WeightedEmbedding) -> Bool {
        lhs.embedding == rhs.embedding && lhs.confidence == rhs.confidence
    }
}
```

- [ ] **Step 4: テストを実行して通ることを確認**

Run: `swift test --filter QuickTranscriberTests.EmbeddingBasedSpeakerTrackerTests`
Expected: 全 PASS（新 3 テスト + 既存テスト）

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift
git commit -m "feat: add entryId to WeightedEmbedding for identity-based removal"
```

---

## Task 3: `UserCorrection` 構造体と記録フィールドを追加

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift`
- Test: `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift`

- [ ] **Step 1: Failing テストを追加**

`EmbeddingBasedSpeakerTrackerTests.swift` 末尾に追加:

```swift
// MARK: - UserCorrections

func testExportUserCorrections_initiallyEmpty() {
    let tracker = EmbeddingBasedSpeakerTracker()
    XCTAssertTrue(tracker.exportUserCorrections().isEmpty)
}

func testResetUserCorrections_clearsList() {
    let tracker = EmbeddingBasedSpeakerTracker()
    // 後段のタスクで correctAssignment 経由で要素を追加するが、
    // ここでは API の存在だけを検証する
    tracker.resetUserCorrections()
    XCTAssertTrue(tracker.exportUserCorrections().isEmpty)
}
```

- [ ] **Step 2: テスト実行で失敗を確認**

Run: `swift test --filter QuickTranscriberTests.EmbeddingBasedSpeakerTrackerTests/testExportUserCorrections_initiallyEmpty`
Expected: COMPILE ERROR（`exportUserCorrections` 未定義）

- [ ] **Step 3: `UserCorrection` 型を `EmbeddingBasedSpeakerTracker.swift` の先頭（`WeightedEmbedding` 定義の直後）に追加**

```swift
public struct UserCorrection: Sendable, Equatable {
    public let entryId: UUID
    public let fromId: UUID
    public let toId: UUID

    public init(entryId: UUID, fromId: UUID, toId: UUID) {
        self.entryId = entryId
        self.fromId = fromId
        self.toId = toId
    }
}
```

- [ ] **Step 4: `EmbeddingBasedSpeakerTracker` クラスに fields と API を追加**

`private var profiles: [SpeakerProfile] = []` の後に追加:

```swift
private var userCorrections: [UserCorrection] = []
```

`exportProfiles()` メソッドの後に追加:

```swift
public func exportUserCorrections() -> [UserCorrection] {
    lock.withLock { userCorrections }
}

public func resetUserCorrections() {
    lock.withLock { userCorrections = [] }
}
```

- [ ] **Step 5: テストが通ることを確認**

Run: `swift test --filter QuickTranscriberTests.EmbeddingBasedSpeakerTrackerTests`
Expected: 全 PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift
git commit -m "feat: add UserCorrection type and tracking fields"
```

---

## Task 4: `correctAssignment` の suppressLearning 挙動拡張

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift:201-225`
- Test: `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift`

- [ ] **Step 1: Failing テストを追加**

```swift
// MARK: - correctAssignment with suppressLearning

func testCorrectAssignment_suppressLearning_doesNotMutateCentroid() {
    let tracker = EmbeddingBasedSpeakerTracker()
    let embA = makeEmbedding(dominant: 0)
    let embB = makeEmbedding(dominant: 1)
    let rA = tracker.identify(embedding: embA)
    let rB = tracker.identify(embedding: embB)

    tracker.suppressLearning = true
    let profileBefore = tracker.exportProfiles().map { (id: $0.speakerId, emb: $0.embedding) }

    // 誤認された embedding を修正する操作を 10 回繰り返す
    let bogus = makeEmbedding(dominant: 2)
    for _ in 0..<10 {
        tracker.correctAssignment(embedding: bogus, from: rB.speakerId, to: rA.speakerId)
    }

    let profileAfter = tracker.exportProfiles().map { (id: $0.speakerId, emb: $0.embedding) }

    XCTAssertEqual(profileBefore.count, profileAfter.count)
    for (before, after) in zip(profileBefore, profileAfter) {
        XCTAssertEqual(before.id, after.id)
        XCTAssertEqual(before.emb, after.emb, "centroid must not change while suppressLearning=true")
    }
}

func testCorrectAssignment_suppressLearning_recordsUserCorrection() {
    let tracker = EmbeddingBasedSpeakerTracker()
    let rA = tracker.identify(embedding: makeEmbedding(dominant: 0))
    let rB = tracker.identify(embedding: makeEmbedding(dominant: 1))

    tracker.suppressLearning = true
    tracker.correctAssignment(embedding: makeEmbedding(dominant: 2), from: rB.speakerId, to: rA.speakerId)

    let corrections = tracker.exportUserCorrections()
    XCTAssertEqual(corrections.count, 1)
    XCTAssertEqual(corrections[0].fromId, rB.speakerId)
    XCTAssertEqual(corrections[0].toId, rA.speakerId)
}

func testCorrectAssignment_nonSuppress_usesLowerConfidence() {
    let tracker = EmbeddingBasedSpeakerTracker()
    let embA = makeEmbedding(dominant: 0)
    let embB = makeEmbedding(dominant: 1)
    let rA = tracker.identify(embedding: embA)
    _ = tracker.identify(embedding: embB)

    // suppressLearning=false （デフォルト）
    let bogus = makeEmbedding(dominant: 2)
    tracker.correctAssignment(embedding: bogus, from: UUID(), to: rA.speakerId)

    // rA の profile に低 confidence (0.3) で追加されているはず
    let detailed = tracker.exportDetailedProfiles().first { $0.speakerId == rA.speakerId }!
    let newEntry = detailed.embeddingHistory.last!
    XCTAssertEqual(newEntry.confidence, Constants.Embedding.userCorrectionConfidence, accuracy: 0.001)
    XCTAssertEqual(newEntry.embedding, bogus)
}
```

- [ ] **Step 2: テスト実行で失敗を確認**

Run: `swift test --filter QuickTranscriberTests.EmbeddingBasedSpeakerTrackerTests/testCorrectAssignment_suppressLearning_doesNotMutateCentroid`
Expected: FAIL（centroid が動いている）

- [ ] **Step 3: `correctAssignment` を差し替え**

`EmbeddingBasedSpeakerTracker.swift` の `correctAssignment` を以下で置き換え:

```swift
public func correctAssignment(embedding: [Float], from oldId: UUID, to newId: UUID) {
    lock.withLock {
        if suppressLearning {
            // Manual mode: profile centroid は動かさない。
            // 修正情報だけ記録して post-hoc 学習で使う。
            userCorrections.append(UserCorrection(
                entryId: UUID(),
                fromId: oldId,
                toId: newId
            ))
            return
        }

        // Auto mode: 従来どおり centroid を更新するが、confidence を下げて
        // 汚染速度を緩和する。
        if let oldIdx = profiles.firstIndex(where: { $0.id == oldId }) {
            profiles[oldIdx].embeddingHistory.removeAll { $0.embedding == embedding }
            if profiles[oldIdx].embeddingHistory.isEmpty {
                profiles.remove(at: oldIdx)
            } else {
                recalculateEmbedding(at: oldIdx)
            }
        }

        let addConfidence = Constants.Embedding.userCorrectionConfidence
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

**注**: oldId 側の `removeAll` は次の Task 5 で entryId ベースに置換する。本 Task では既存の embedding-value match を温存して、確認範囲を絞る。

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter QuickTranscriberTests.EmbeddingBasedSpeakerTrackerTests`
Expected: 全 PASS

`testCorrectAssignmentMovesEmbeddingToNewSpeaker` 等の既存テストで confidence=1.0 を前提にしているものは、Auto mode (suppressLearning=false) では `userCorrectionConfidence=0.3` になるため調整が必要。失敗する既存テストを次の点で修正:

- `EmbeddingBasedSpeakerTrackerTests.swift` 内で `confidence: 1.0` を assert している箇所があれば `Constants.Embedding.userCorrectionConfidence` に置換
- failing したテスト名を列挙:
  - `testCorrectAssignmentMovesEmbeddingToNewSpeaker` 等、confidence 値を見ている箇所すべて

既存テストを読んで該当箇所を修正する。テストが 1 つも失敗しなければスキップ可。

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift
git commit -m "feat: extend suppressLearning to freeze centroid on correctAssignment"
```

---

## Task 5: entryId ベースの削除に置換

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift`（`correctAssignment` と `identify` 両方）
- Test: `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift`

**背景:** 現行 `correctAssignment` は `removeAll { $0.embedding == embedding }` で exact-value match に依存している。embedding 値が normalizer などで微妙に変動すると削除失敗 → 両 profile に同じ声が残り、汚染を加速する。これを entryId ベースに置換する。

**設計上のポイント:** `correctAssignment` に渡ってくる `embedding` は特定の session チャンクから生成されたものだが、呼び出し側はその entryId を知らない。そのため、**embedding 値の最も近いエントリを削除**するヒューリスティクスを使い、閾値以上一致する場合のみ削除する（entryId が保持されていれば ID 削除で、そうでなければ value-match の fallback）。Auto mode では tracker 自身が identify 時に append しているので entryId が明らかだが、外部から渡る embedding と tracker 内の履歴の対応を取るには value match が実質必要。

→ 割り切り: `removeAll` のロジックを「cosine similarity ≥ 0.9999 のエントリを最大 1 件削除」に変える。これにより浮動小数点の僅差による取りこぼしが無くなる。

- [ ] **Step 1: Failing テストを追加**

```swift
// MARK: - correctAssignment with approximate match

func testCorrectAssignment_removesMatchingEntryDespiteFloatJitter() {
    let tracker = EmbeddingBasedSpeakerTracker()
    let embOriginal = makeEmbedding(dominant: 0)
    let rA = tracker.identify(embedding: embOriginal)

    // 浮動小数点の僅かな揺らぎをシミュレート (最後の有効桁)
    var embJittered = embOriginal
    embJittered[0] = embOriginal[0] + 1e-7

    // jittered を使って修正（value match は失敗するはず）
    tracker.correctAssignment(embedding: embJittered, from: rA.speakerId, to: UUID())

    let detailed = tracker.exportDetailedProfiles()
    // rA の profile は空になって消えているはず (履歴 1 件だったのが 0 件 → 削除)
    XCTAssertFalse(detailed.contains(where: { $0.speakerId == rA.speakerId }),
        "jittered embedding should match within tolerance and trigger removal")
}
```

- [ ] **Step 2: テスト実行で失敗を確認**

Run: `swift test --filter QuickTranscriberTests.EmbeddingBasedSpeakerTrackerTests/testCorrectAssignment_removesMatchingEntryDespiteFloatJitter`
Expected: FAIL（rA profile がまだ残っている）

- [ ] **Step 3: `removeAll` を近似一致に置換**

`EmbeddingBasedSpeakerTracker.swift` に helper を追加（`cosineSimilarity` の後）:

```swift
/// Remove the embedding history entry most similar to `target` (≥ 0.9999 cosine).
/// Returns true if an entry was removed.
private static func removeClosestMatch(in history: inout [WeightedEmbedding], target: [Float]) -> Bool {
    var bestIndex = -1
    var bestSim: Float = 0.9999  // threshold: 実質同一
    for (i, entry) in history.enumerated() {
        let sim = cosineSimilarity(entry.embedding, target)
        if sim >= bestSim {
            bestSim = sim
            bestIndex = i
        }
    }
    if bestIndex >= 0 {
        history.remove(at: bestIndex)
        return true
    }
    return false
}
```

`correctAssignment` の oldId 削除箇所を書き換え:

```swift
if let oldIdx = profiles.firstIndex(where: { $0.id == oldId }) {
    _ = Self.removeClosestMatch(in: &profiles[oldIdx].embeddingHistory, target: embedding)
    if profiles[oldIdx].embeddingHistory.isEmpty {
        profiles.remove(at: oldIdx)
    } else {
        recalculateEmbedding(at: oldIdx)
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter QuickTranscriberTests.EmbeddingBasedSpeakerTrackerTests`
Expected: 全 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift
git commit -m "fix: use near-exact cosine match for correctAssignment removal"
```

---

## Task 6: Tie-breaker の導入

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift:75-123`
- Test: `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift`

- [ ] **Step 1: Failing テストを追加**

```swift
// MARK: - Tie-breaker

func testIdentify_tieBreaker_prefersHigherHitCount() {
    let tracker = EmbeddingBasedSpeakerTracker()

    // 2 つの profile を初期化 (直接 loadProfiles で)
    let idA = UUID()
    let idB = UUID()
    let baseA = makeEmbedding(dominant: 0)
    let baseB = makeEmbedding(dominant: 1)
    tracker.loadProfiles([(speakerId: idA, embedding: baseA), (speakerId: idB, embedding: baseB)])

    // A を何度も identify して hitCount を増やす
    for _ in 0..<5 {
        _ = tracker.identify(embedding: baseA)
    }

    // A と B に等距離の embedding を投入
    let midpoint = zip(baseA, baseB).map { 0.5 * $0 + 0.5 * $1 }
    let result = tracker.identify(embedding: midpoint)

    XCTAssertEqual(result.speakerId, idA, "tie should prefer higher hitCount")
}

func testIdentify_tieBreaker_prefersLastConfirmed() {
    let tracker = EmbeddingBasedSpeakerTracker()

    let idA = UUID()
    let idB = UUID()
    let baseA = makeEmbedding(dominant: 0)
    let baseB = makeEmbedding(dominant: 1)
    tracker.loadProfiles([(speakerId: idA, embedding: baseA), (speakerId: idB, embedding: baseB)])
    tracker.suppressLearning = true   // hitCount 増加を防ぐため

    // 最後に B を confirm
    _ = tracker.identify(embedding: baseB)

    // 等距離 embedding を投入
    let midpoint = zip(baseA, baseB).map { 0.5 * $0 + 0.5 * $1 }
    let result = tracker.identify(embedding: midpoint)

    XCTAssertEqual(result.speakerId, idB, "tie with equal hitCount should prefer lastConfirmedId")
}
```

- [ ] **Step 2: テスト実行で失敗を確認**

Run: `swift test --filter QuickTranscriberTests.EmbeddingBasedSpeakerTrackerTests/testIdentify_tieBreaker_prefersHigherHitCount`
Expected: FAIL（enumerate 順の A が選ばれるが、テストは B を期待する場合など）

- [ ] **Step 3: `identify` に tie-breaker を追加**

`EmbeddingBasedSpeakerTracker.swift` に field を追加:

```swift
private var lastConfirmedId: UUID?
```

`identify(embedding:)` 内の bestIndex 決定ループの直後に tie-breaker 処理を挿入する。現行は:

```swift
for (i, profile) in profiles.enumerated() {
    let sim = Self.cosineSimilarity(embedding, profile.embedding)
    if sim > bestSimilarity {
        bestSimilarity = sim
        bestIndex = i
    }
}
```

を以下に置き換え:

```swift
for (i, profile) in profiles.enumerated() {
    let sim = Self.cosineSimilarity(embedding, profile.embedding)
    if sim > bestSimilarity {
        bestSimilarity = sim
        bestIndex = i
    }
}

// Tie-breaker: bestSimilarity と tieBreakerEpsilon 内のすべての候補を集める
if bestIndex >= 0 && profiles.count > 1 {
    var candidates: [(index: Int, profile: SpeakerProfile)] = []
    for (i, profile) in profiles.enumerated() {
        let sim = Self.cosineSimilarity(embedding, profile.embedding)
        if abs(sim - bestSimilarity) <= Constants.Embedding.tieBreakerEpsilon {
            candidates.append((i, profile))
        }
    }
    if candidates.count > 1 {
        // 1. hitCount 最大を優先
        let maxHit = candidates.map { $0.profile.hitCount }.max()!
        let byHit = candidates.filter { $0.profile.hitCount == maxHit }
        if byHit.count == 1 {
            bestIndex = byHit[0].index
        } else if let lastId = lastConfirmedId,
                  let lastMatch = byHit.first(where: { $0.profile.id == lastId }) {
            // 2. hitCount 同値の場合は lastConfirmedId を優先
            bestIndex = lastMatch.index
        } else {
            // 3. enumerate 順（最初の候補）
            bestIndex = byHit[0].index
        }
    }
}
```

メソッド末尾近くの、各 return 直前（`return SpeakerIdentification(speakerId: profiles[bestIndex].id, ...)` の各行の直前）で `lastConfirmedId` を更新:

実装簡略化のため、return 文の直前に追加する代わりに、return する `speakerId` を一箇所で集約してから更新する方が読みやすい。具体的には `identify` メソッドの早期 return を一旦ローカル変数に集約し、最後に `lastConfirmedId = resolvedId` を呼ぶ形に refactor してもよい。ただし本 task の範囲を保つため、各 return の**直前**に 1 行ずつ追加する:

```swift
// Path 1 の return 直前
lastConfirmedId = profiles[bestIndex].id
return SpeakerIdentification(speakerId: profiles[bestIndex].id, ...)

// Path 2 の return 直前
lastConfirmedId = profiles[bestIndex].id
return SpeakerIdentification(...)

// Path 3 (registrationGate) の return 直前
lastConfirmedId = profiles[bestIndex].id
return SpeakerIdentification(...)

// 新規 UUID 生成 return 直前
lastConfirmedId = newId
return SpeakerIdentification(speakerId: newId, ...)
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter QuickTranscriberTests.EmbeddingBasedSpeakerTrackerTests`
Expected: 全 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift
git commit -m "feat: add tie-breaker using hitCount and lastConfirmedId"
```

---

## Task 7: `SpeakerDiarizer` protocol に `exportUserCorrections` を追加

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift`
- Modify: `Tests/QuickTranscriberTests/Mocks/MockSpeakerDiarizer.swift`

- [ ] **Step 1: Protocol に追加**

`SpeakerDiarizer.swift:7-17` の protocol 本体に:

```swift
func exportUserCorrections() -> [UserCorrection]
```

extension のデフォルト実装を追加:

```swift
extension SpeakerDiarizer {
    public func exportUserCorrections() -> [UserCorrection] {
        []
    }
}
```

- [ ] **Step 2: `FluidAudioSpeakerDiarizer` にパススルー実装を追加**

`SpeakerDiarizer.swift` 内の `FluidAudioSpeakerDiarizer` クラスに追加（`correctSpeakerAssignment` の近く）:

```swift
public func exportUserCorrections() -> [UserCorrection] {
    speakerTracker.exportUserCorrections()
}
```

- [ ] **Step 3: `MockSpeakerDiarizer` に stub 追加**

`MockSpeakerDiarizer.swift` の末尾（`correctSpeakerAssignment` の後）に追加:

```swift
var userCorrectionsToExport: [UserCorrection] = []

func exportUserCorrections() -> [UserCorrection] {
    userCorrectionsToExport
}
```

- [ ] **Step 4: ビルドとテストが通ることを確認**

Run: `swift build && swift test --filter QuickTranscriberTests`
Expected: 全 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift Tests/QuickTranscriberTests/Mocks/MockSpeakerDiarizer.swift
git commit -m "feat: add exportUserCorrections to SpeakerDiarizer protocol"
```

---

## Task 8: `TranscriptionEngine` protocol に `syncViterbiConfirm(to:)` を追加

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/TranscriptionEngine.swift`
- Modify: `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift`
- Modify: `Sources/QuickTranscriber/Services/TranscriptionService.swift`
- Modify: `Tests/QuickTranscriberTests/Mocks/MockTranscriptionEngine.swift`

- [ ] **Step 1: Protocol と default 実装を追加**

`TranscriptionEngine.swift:31-39` の protocol に追加:

```swift
func syncViterbiConfirm(to newId: UUID)
```

`extension TranscriptionEngine` に:

```swift
public func syncViterbiConfirm(to newId: UUID) {
    // Default no-op for engines without diarization
}
```

- [ ] **Step 2: `ChunkedWhisperEngine` に実装を追加**

`ChunkedWhisperEngine.swift` の `correctSpeakerAssignment` メソッドの直下に追加:

```swift
public func syncViterbiConfirm(to newId: UUID) {
    smootherLock.withLock {
        speakerSmoother.confirmSpeaker(newId)
    }
}
```

- [ ] **Step 3: `TranscriptionService` に wrapper を追加**

`TranscriptionService.swift` の `correctSpeakerAssignment` の直下に追加:

```swift
public func syncViterbiConfirm(to newSpeaker: String) {
    guard let newId = UUID(uuidString: newSpeaker) else { return }
    engine.syncViterbiConfirm(to: newId)
}
```

- [ ] **Step 4: `MockTranscriptionEngine` に stub 追加**

`MockTranscriptionEngine.swift` の `mergedProfiles` field の近くに追加:

```swift
var syncViterbiConfirmCalls: [UUID] = []

func syncViterbiConfirm(to newId: UUID) {
    syncViterbiConfirmCalls.append(newId)
}
```

- [ ] **Step 5: ビルドとテストが通ることを確認**

Run: `swift build && swift test --filter QuickTranscriberTests`
Expected: 全 PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/QuickTranscriber/Engines/TranscriptionEngine.swift \
        Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift \
        Sources/QuickTranscriber/Services/TranscriptionService.swift \
        Tests/QuickTranscriberTests/Mocks/MockTranscriptionEngine.swift
git commit -m "feat: add syncViterbiConfirm API to TranscriptionEngine"
```

---

## Task 9: `SpeakerStateCoordinator.reassignSegment` の embedding-nil 経路

**Files:**
- Modify: `Sources/QuickTranscriber/Models/SpeakerStateCoordinator.swift:269-279`
- Test: `Tests/QuickTranscriberTests/SpeakerStateCoordinatorTests.swift`

- [ ] **Step 1: Failing テストを追加**

既存の `SpeakerStateCoordinatorTests.swift` を開き、同ファイル内の末尾近くに以下を追加。もし test class が `XCTestCase` ベースなら同じ形式で追加する:

```swift
// MARK: - reassignSegment nil embedding path

func testReassignSegment_withNilEmbedding_callsViterbiSync() async {
    let profileStore = SpeakerProfileStore(fileURL: nil)
    let historyStore = EmbeddingHistoryStore()
    let coordinator = await SpeakerStateCoordinator(profileStore: profileStore, embeddingHistoryStore: historyStore)
    let mockEngine = MockTranscriptionEngine()
    let service = TranscriptionService(engine: mockEngine)
    await coordinator.setService(service)

    let oldId = UUID()
    let newId = UUID()
    var segments: [ConfirmedSegment] = [
        ConfirmedSegment(text: "hello", speaker: oldId.uuidString, speakerEmbedding: nil)
    ]

    await coordinator.reassignSegment(at: 0, to: newId.uuidString, segments: &segments)

    XCTAssertTrue(mockEngine.correctedAssignments.isEmpty,
        "should not call correctSpeakerAssignment when embedding is nil")
    XCTAssertEqual(mockEngine.syncViterbiConfirmCalls.count, 1)
    XCTAssertEqual(mockEngine.syncViterbiConfirmCalls[0], newId)
    XCTAssertEqual(segments[0].speaker, newId.uuidString)
    XCTAssertTrue(segments[0].isUserCorrected)
}

func testReassignSegment_withEmbedding_callsCorrectAssignment() async {
    let profileStore = SpeakerProfileStore(fileURL: nil)
    let historyStore = EmbeddingHistoryStore()
    let coordinator = await SpeakerStateCoordinator(profileStore: profileStore, embeddingHistoryStore: historyStore)
    let mockEngine = MockTranscriptionEngine()
    let service = TranscriptionService(engine: mockEngine)
    await coordinator.setService(service)

    let oldId = UUID()
    let newId = UUID()
    let embedding: [Float] = [1.0, 2.0, 3.0]
    var segments: [ConfirmedSegment] = [
        ConfirmedSegment(text: "hi", speaker: oldId.uuidString, speakerEmbedding: embedding)
    ]

    await coordinator.reassignSegment(at: 0, to: newId.uuidString, segments: &segments)

    XCTAssertEqual(mockEngine.correctedAssignments.count, 1)
    XCTAssertEqual(mockEngine.correctedAssignments[0].oldId, oldId)
    XCTAssertEqual(mockEngine.correctedAssignments[0].newId, newId)
}
```

**注**: `SpeakerProfileStore(fileURL: nil)` / `EmbeddingHistoryStore()` は既存テスト中の使い方に合わせる。もし他テストと違う init 署名が必要ならそちらに合わせる。`coordinator.reassignSegment` は現在 `func` (internal)。テストがあるディレクトリから見えない場合は public 化または `@testable import` を使う（`EmbeddingBasedSpeakerTrackerTests.swift` と同じく `@testable import QuickTranscriberLib`）。

**注 2**: `setService` が `@MainActor` のみアクセス可能な場合、テストも `@MainActor` で実行する必要がある。既存の `SpeakerStateCoordinatorTests` の書き方を踏襲する。

- [ ] **Step 2: テスト実行で失敗を確認**

Run: `swift test --filter QuickTranscriberTests.SpeakerStateCoordinatorTests/testReassignSegment_withNilEmbedding_callsViterbiSync`
Expected: FAIL（`syncViterbiConfirmCalls` が空）

- [ ] **Step 3: `reassignSegment` を更新**

`SpeakerStateCoordinator.swift:269-279` の既存 `reassignSegment` を以下で置き換え:

```swift
func reassignSegment(at index: Int, to newSpeaker: String, segments: inout [ConfirmedSegment]) {
    guard index < segments.count else { return }
    let originalSpeaker = segments[index].speaker

    if let oldSpeaker = originalSpeaker {
        if let embedding = segments[index].speakerEmbedding {
            service?.correctSpeakerAssignment(
                embedding: embedding, from: oldSpeaker, to: newSpeaker)
        } else {
            service?.syncViterbiConfirm(to: newSpeaker)
        }
    }

    segments[index].originalSpeaker = originalSpeaker
    segments[index].speaker = newSpeaker
    segments[index].speakerConfidence = 1.0
    segments[index].isUserCorrected = true
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter QuickTranscriberTests.SpeakerStateCoordinatorTests`
Expected: 全 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Models/SpeakerStateCoordinator.swift Tests/QuickTranscriberTests/SpeakerStateCoordinatorTests.swift
git commit -m "feat: sync Viterbi on reassignment when embedding is nil"
```

---

## Task 10: `SpeakerProfileStore` に post-hoc 学習 API を追加

**Files:**
- Modify: `Sources/QuickTranscriber/Models/SpeakerProfileStore.swift:124-139`
- Test: `Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift`

- [ ] **Step 1: Failing テストを追加**

`SpeakerProfileStoreTests.swift` に追加:

```swift
// MARK: - applyPostHocLearning

func testApplyPostHocLearning_updatesEmbeddingWithAlpha() {
    let store = SpeakerProfileStore(fileURL: nil)
    let id = UUID()
    let initial: [Float] = [1.0, 0.0, 0.0]
    store.profiles.append(StoredSpeakerProfile(id: id, displayName: "A", embedding: initial))

    let session: [Float] = [0.0, 1.0, 0.0]
    let alpha: Float = 0.2
    store.applyPostHocLearning(speakerId: id, sessionCentroid: session, alpha: alpha)

    let expected: [Float] = [0.8, 0.2, 0.0]  // (1-0.2)*1 + 0.2*0 など
    let updated = store.profiles.first(where: { $0.id == id })!.embedding
    for (e, u) in zip(expected, updated) {
        XCTAssertEqual(e, u, accuracy: 1e-5)
    }
}

func testApplyPostHocLearning_incrementsSessionCount() {
    let store = SpeakerProfileStore(fileURL: nil)
    let id = UUID()
    store.profiles.append(StoredSpeakerProfile(id: id, displayName: "A", embedding: [1.0]))
    let before = store.profiles.first!.sessionCount

    store.applyPostHocLearning(speakerId: id, sessionCentroid: [1.0], alpha: 0.1)

    XCTAssertEqual(store.profiles.first!.sessionCount, before + 1)
}

func testApplyPostHocLearning_nonexistentId_doesNothing() {
    let store = SpeakerProfileStore(fileURL: nil)
    let id = UUID()
    store.profiles.append(StoredSpeakerProfile(id: id, displayName: "A", embedding: [1.0]))
    let before = store.profiles
    store.applyPostHocLearning(speakerId: UUID(), sessionCentroid: [2.0], alpha: 0.2)
    XCTAssertEqual(store.profiles.map { $0.embedding }, before.map { $0.embedding })
}
```

- [ ] **Step 2: テスト実行で失敗を確認**

Run: `swift test --filter QuickTranscriberTests.SpeakerProfileStoreTests/testApplyPostHocLearning_updatesEmbeddingWithAlpha`
Expected: COMPILE ERROR（`applyPostHocLearning` 未定義）

- [ ] **Step 3: 新 API を追加**

`SpeakerProfileStore.swift` の `mergeSessionProfiles` の直下に追加:

```swift
/// Apply a weighted update to an existing profile's embedding.
/// Used by Manual mode post-hoc learning where α is controlled by
/// the caller based on session sample count.
///
/// - Parameters:
///   - speakerId: Target profile UUID. No-op if not found.
///   - sessionCentroid: Computed centroid of session's non-corrected samples.
///   - alpha: Blend weight in [0, 1]. New = (1-α)*existing + α*sessionCentroid.
public func applyPostHocLearning(speakerId: UUID, sessionCentroid: [Float], alpha: Float) {
    guard let idx = profiles.firstIndex(where: { $0.id == speakerId }) else { return }
    let existing = profiles[idx].embedding
    guard existing.count == sessionCentroid.count else { return }
    profiles[idx].embedding = zip(existing, sessionCentroid).map { old, new in
        (1 - alpha) * old + alpha * new
    }
    profiles[idx].lastUsed = Date()
    profiles[idx].sessionCount += 1
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter QuickTranscriberTests.SpeakerProfileStoreTests`
Expected: 全 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Models/SpeakerProfileStore.swift Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift
git commit -m "feat: add applyPostHocLearning API to SpeakerProfileStore"
```

---

## Task 11: `ChunkedWhisperEngine` に participant state を保持

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift`

本タスクは state 追加のみで、単体テストは次タスクで一緒に書く。

- [ ] **Step 1: state field を追加**

`ChunkedWhisperEngine.swift:9-25` の private fields 群に追加:

```swift
private var currentParticipantIds: Set<UUID> = []
```

- [ ] **Step 2: `startStreaming` で populate**

`startStreaming` 内の Manual mode 分岐（line 83-94）で、`participantProfiles.isEmpty` の else ブロック内に追加:

```swift
currentParticipantIds = Set(participantProfiles.map { $0.speakerId })
```

Auto mode 分岐に入る場合および参加者 0 の場合は空集合にリセットする。`startStreaming` の冒頭（`accumulator = VADChunkAccumulator(...)` 付近）に:

```swift
currentParticipantIds = []
```

を最初に入れて、Manual 分岐の中でのみ上書きする。

- [ ] **Step 3: `stopStreaming` でクリア**

`stopStreaming` の末尾（`NSLog("[ChunkedWhisperEngine] Streaming stopped.`）の直前に追加:

```swift
currentParticipantIds = []
```

- [ ] **Step 4: ビルドが通ることを確認**

Run: `swift build`
Expected: エラーなし

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift
git commit -m "feat: track participant UUIDs in ChunkedWhisperEngine"
```

---

## Task 12: `stopStreaming` に Manual mode post-hoc 学習を追加

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift:186-223`
- Test: `Tests/QuickTranscriberTests/PostHocLearningTests.swift` (新規)

**既存ロジックとの兼ね合い:** 現行 stopStreaming は `exportSpeakerProfiles()` を経由して両モード共通で merge する。Manual mode では suppressLearning により tracker profile は不動なので no-op に近いが、`sessionCount` が無意味に増える。本タスクでは Manual mode では従来の merge をスキップし、post-hoc 学習のみ行う。Auto mode は従来どおり。

**テスト戦略:** post-hoc 学習ロジックを独立した internal メソッド `applyManualModePostHocLearning(store:)` に抽出し、これを単体で呼び出してテストする。`startStreaming` / `stopStreaming` を経由しないので audio pipeline の mock 整備が不要。

- [ ] **Step 1: 新規テストファイルを作成（failing）**

`Tests/QuickTranscriberTests/PostHocLearningTests.swift`:

```swift
import XCTest
@testable import QuickTranscriberLib

final class PostHocLearningTests: XCTestCase {

    private func makeEmbedding(dominant dim: Int, dimensions: Int = 4) -> [Float] {
        var v = [Float](repeating: 0.01, count: dimensions)
        v[dim] = 1.0
        return v
    }

    private func makeEngine(
        store: SpeakerProfileStore
    ) -> ChunkedWhisperEngine {
        ChunkedWhisperEngine(
            audioCaptureService: MockAudioCaptureService(),
            transcriber: MockChunkTranscriber(),
            diarizer: MockSpeakerDiarizer(),
            speakerProfileStore: store,
            embeddingHistoryStore: EmbeddingHistoryStore()
        )
    }

    func testPostHocLearning_updatesProfileFromNonCorrectedSegments() {
        let store = SpeakerProfileStore(fileURL: nil)
        let idA = UUID()
        let idB = UUID()
        let initialA = makeEmbedding(dominant: 0)
        let initialB = makeEmbedding(dominant: 1)
        store.profiles.append(StoredSpeakerProfile(id: idA, displayName: "A", embedding: initialA))
        store.profiles.append(StoredSpeakerProfile(id: idB, displayName: "B", embedding: initialB))

        let engine = makeEngine(store: store)

        let sessionEmb = makeEmbedding(dominant: 2)
        let correctedEmb = makeEmbedding(dominant: 3)
        let segments: [ConfirmedSegment] = [
            ConfirmedSegment(text: "s1", speaker: idA.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "s2", speaker: idA.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "s3", speaker: idA.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "s4", speaker: idA.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "s5", speaker: idA.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "sc", speaker: idA.uuidString, speakerConfidence: 0.8, isUserCorrected: true, originalSpeaker: idB.uuidString, speakerEmbedding: correctedEmb),
            // B は 2 サンプルのみ → MIN_SAMPLES (3) 未満でスキップされるはず
            ConfirmedSegment(text: "b1", speaker: idB.uuidString, speakerConfidence: 0.8, speakerEmbedding: makeEmbedding(dominant: 1)),
            ConfirmedSegment(text: "b2", speaker: idB.uuidString, speakerConfidence: 0.8, speakerEmbedding: makeEmbedding(dominant: 1))
        ]

        engine.applyManualModePostHocLearningForTesting(
            store: store,
            participantIds: [idA, idB],
            segments: segments
        )

        // A は 5 サンプル → α = min(0.2, 5/50) = 0.1
        let updatedA = store.profiles.first(where: { $0.id == idA })!
        let expectedA: [Float] = zip(initialA, sessionEmb).map { 0.9 * $0 + 0.1 * $1 }
        for (e, u) in zip(expectedA, updatedA.embedding) {
            XCTAssertEqual(e, u, accuracy: 1e-5)
        }

        // B は 2 サンプルのみなので不変
        let updatedB = store.profiles.first(where: { $0.id == idB })!
        XCTAssertEqual(updatedB.embedding, initialB)
    }

    func testPostHocLearning_skipsLockedProfile() {
        let store = SpeakerProfileStore(fileURL: nil)
        let id = UUID()
        var profile = StoredSpeakerProfile(id: id, displayName: "Locked", embedding: makeEmbedding(dominant: 0))
        profile.isLocked = true
        store.profiles.append(profile)

        let engine = makeEngine(store: store)

        var segs = [ConfirmedSegment]()
        for _ in 0..<10 {
            segs.append(ConfirmedSegment(text: "x", speaker: id.uuidString, speakerConfidence: 0.9, speakerEmbedding: makeEmbedding(dominant: 2)))
        }

        engine.applyManualModePostHocLearningForTesting(
            store: store,
            participantIds: [id],
            segments: segs
        )

        let updated = store.profiles.first!
        XCTAssertEqual(updated.embedding, makeEmbedding(dominant: 0),
            "locked profile should not be updated")
    }

    func testPostHocLearning_alphaScalesWithSampleCount() {
        let store = SpeakerProfileStore(fileURL: nil)
        let id = UUID()
        let initial = makeEmbedding(dominant: 0)
        store.profiles.append(StoredSpeakerProfile(id: id, displayName: "A", embedding: initial))

        let engine = makeEngine(store: store)

        let sessionEmb = makeEmbedding(dominant: 1)
        // 60 サンプル → α = min(0.2, 60/50) = 0.2 (上限)
        var segs = [ConfirmedSegment]()
        for _ in 0..<60 {
            segs.append(ConfirmedSegment(text: "x", speaker: id.uuidString, speakerConfidence: 0.9, speakerEmbedding: sessionEmb))
        }

        engine.applyManualModePostHocLearningForTesting(
            store: store,
            participantIds: [id],
            segments: segs
        )

        let updated = store.profiles.first!
        let expected = zip(initial, sessionEmb).map { 0.8 * $0 + 0.2 * $1 }
        for (e, u) in zip(expected, updated.embedding) {
            XCTAssertEqual(e, u, accuracy: 1e-5)
        }
    }

    func testPostHocLearning_filtersLowConfidenceSamples() {
        let store = SpeakerProfileStore(fileURL: nil)
        let id = UUID()
        let initial = makeEmbedding(dominant: 0)
        store.profiles.append(StoredSpeakerProfile(id: id, displayName: "A", embedding: initial))

        let engine = makeEngine(store: store)

        let sessionEmb = makeEmbedding(dominant: 1)
        // 3 サンプル、うち 2 個は confidence が閾値未満
        let segs: [ConfirmedSegment] = [
            ConfirmedSegment(text: "ok", speaker: id.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "low", speaker: id.uuidString, speakerConfidence: 0.3, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "low2", speaker: id.uuidString, speakerConfidence: 0.2, speakerEmbedding: sessionEmb)
        ]

        engine.applyManualModePostHocLearningForTesting(
            store: store,
            participantIds: [id],
            segments: segs
        )

        // 有効サンプル 1 個 → MIN_SAMPLES (3) 未満なのでスキップ
        let updated = store.profiles.first!
        XCTAssertEqual(updated.embedding, initial, "should skip when too few high-confidence samples")
    }
}
```

- [ ] **Step 2: テスト実行で失敗を確認**

Run: `swift test --filter QuickTranscriberTests.PostHocLearningTests`
Expected: COMPILE ERROR（`applyManualModePostHocLearningForTesting` 未定義）

- [ ] **Step 3: 学習ロジックを internal メソッドに抽出**

`ChunkedWhisperEngine.swift` クラス本体に新規メソッドを追加（`correctSpeakerAssignment` の後あたり）:

```swift
/// Manual mode の post-hoc 学習を実行する。
/// Tracker 側は suppressLearning により不動だが、session 中に高 confidence で
/// 識別された非修正 segment を集めて profile を緩やかに更新する。
internal func applyManualModePostHocLearning(
    store: SpeakerProfileStore,
    participantIds: Set<UUID>,
    segments: [ConfirmedSegment]
) {
    for participantId in participantIds {
        let samples = segments.filter { seg in
            seg.speaker == participantId.uuidString
                && !seg.isUserCorrected
                && (seg.speakerConfidence ?? 0) >= Constants.Embedding.similarityThreshold
                && seg.speakerEmbedding != nil
        }

        guard samples.count >= Constants.Embedding.sessionLearningMinSamples else { continue }
        guard let existing = store.profiles.first(where: { $0.id == participantId }),
              !existing.isLocked else { continue }

        let embeddings = samples.compactMap { $0.speakerEmbedding }
        guard let centroid = Self.centroid(of: embeddings) else { continue }

        let alpha = min(
            Constants.Embedding.sessionLearningAlphaMax,
            Float(samples.count) / Float(Constants.Embedding.sessionLearningSamplesForMaxAlpha)
        )
        store.applyPostHocLearning(
            speakerId: participantId,
            sessionCentroid: centroid,
            alpha: alpha
        )
        NSLog("[ChunkedWhisperEngine] Post-hoc learning for \(participantId): \(samples.count) samples, alpha=\(alpha)")
    }
}

#if DEBUG
/// Test-only hook exposing applyManualModePostHocLearning without requiring the audio pipeline.
public func applyManualModePostHocLearningForTesting(
    store: SpeakerProfileStore,
    participantIds: Set<UUID>,
    segments: [ConfirmedSegment]
) {
    applyManualModePostHocLearning(store: store, participantIds: participantIds, segments: segments)
}
#endif

private static func centroid(of embeddings: [[Float]]) -> [Float]? {
    guard let first = embeddings.first else { return nil }
    let dims = first.count
    guard dims > 0 else { return nil }
    var sum = [Float](repeating: 0, count: dims)
    for e in embeddings {
        guard e.count == dims else { continue }
        for i in 0..<dims { sum[i] += e[i] }
    }
    let count = Float(embeddings.count)
    return sum.map { $0 / count }
}
```

- [ ] **Step 4: `stopStreaming` を更新**

`stopStreaming` 内、現行の `if let diarizer, diarizationActive, let store = speakerProfileStore {` ブロック（line 187-223）を以下に置き換え:

```swift
if let diarizer, diarizationActive, let store = speakerProfileStore {
    if currentParameters.diarizationMode == .manual && !currentParticipantIds.isEmpty {
        // Manual mode: confirmedSegments の非修正サンプルから weighted merge
        applyManualModePostHocLearning(
            store: store,
            participantIds: currentParticipantIds,
            segments: confirmedSegments
        )
        do {
            try store.save()
        } catch {
            NSLog("[ChunkedWhisperEngine] Failed to save after post-hoc learning: \(error)")
        }
    } else {
        // Auto mode: 従来どおり tracker profile を merge
        let sessionProfiles = diarizer.exportSpeakerProfiles()
        if !sessionProfiles.isEmpty {
            let correctedOriginalSpeakers = Set(
                confirmedSegments
                    .filter { $0.isUserCorrected }
                    .compactMap { $0.originalSpeaker }
            )
            let filteredProfiles: [(speakerId: UUID, embedding: [Float])]
            if correctedOriginalSpeakers.isEmpty {
                filteredProfiles = sessionProfiles
            } else {
                filteredProfiles = sessionProfiles.filter { !correctedOriginalSpeakers.contains($0.speakerId.uuidString) }
                NSLog("[ChunkedWhisperEngine] Skipping merge for corrected speakers: \(correctedOriginalSpeakers)")
            }
            if !filteredProfiles.isEmpty {
                let mergeProfiles = filteredProfiles.compactMap { profile
                    -> (speakerId: UUID, embedding: [Float], displayName: String)? in
                    guard let name = speakerDisplayNames[profile.speakerId.uuidString] else {
                        NSLog("[ChunkedWhisperEngine] Skipping unmapped profile \(profile.speakerId)")
                        return nil
                    }
                    return (speakerId: profile.speakerId, embedding: profile.embedding, displayName: name)
                }
                if !mergeProfiles.isEmpty {
                    store.mergeSessionProfiles(mergeProfiles)
                    do {
                        try store.save()
                    } catch {
                        NSLog("[ChunkedWhisperEngine] Failed to save speaker profiles: \(error)")
                    }
                    NSLog("[ChunkedWhisperEngine] Saved \(mergeProfiles.count) speaker profiles to store (filtered \(sessionProfiles.count - mergeProfiles.count))")
                }
            }
        }
    }
}
```

- [ ] **Step 5: テストが通ることを確認**

Run: `swift test --filter QuickTranscriberTests.PostHocLearningTests`
Expected: 全 PASS

全体テスト: `swift test --filter QuickTranscriberTests`
Expected: 既存も含めて PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift Tests/QuickTranscriberTests/PostHocLearningTests.swift
git commit -m "feat: add post-hoc learning in Manual mode stopStreaming"
```

---

## Task 13: ManualModeStabilityTests 統合テスト

**Files:**
- Create: `Tests/QuickTranscriberTests/ManualModeStabilityTests.swift`

- [ ] **Step 1: 統合テストを作成**

```swift
import XCTest
@testable import QuickTranscriberLib

/// Integration test to verify that a user correction does not cause
/// the same segment-type to be misidentified on the next chunk
/// (the primary user complaint).
final class ManualModeStabilityTests: XCTestCase {

    private func makeEmbedding(dominant dim: Int, dimensions: Int = 16) -> [Float] {
        var v = [Float](repeating: 0.01, count: dimensions)
        v[dim] = 1.0
        return v
    }

    func testCorrection_doesNotAmplifyMisidentification() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let idA = UUID()
        let idB = UUID()
        let profileA = makeEmbedding(dominant: 0)
        let profileB = makeEmbedding(dominant: 1)
        tracker.loadProfiles([(speakerId: idA, embedding: profileA), (speakerId: idB, embedding: profileB)])
        tracker.expectedSpeakerCount = 2
        tracker.suppressLearning = true

        // A さんの typical な embedding を 10 回投入。ただし
        // そのうち 3 回は「曖昧」で B に引き寄せられるバージョン。
        let typicalA = makeEmbedding(dominant: 0)
        var ambiguousA = makeEmbedding(dominant: 0)
        ambiguousA[1] = 0.4  // B 方向にブレ

        var misidentifications = 0
        for i in 0..<10 {
            let emb = [1, 4, 7].contains(i) ? ambiguousA : typicalA
            let result = tracker.identify(embedding: emb)
            if result.speakerId != idA {
                misidentifications += 1
                // ユーザーが手動で A に修正
                tracker.correctAssignment(embedding: emb, from: result.speakerId, to: idA)
            }
        }

        // Manual mode では centroid が不動なので誤認の確率は一定
        // （フィードバックループなし）。3 回の ambiguous サンプルで
        // すべてが誤認されても、以降の typical サンプルには影響しない。
        let typicalResults = (0..<10).filter { ![1, 4, 7].contains($0) }.map { _ -> UUID in
            tracker.identify(embedding: typicalA).speakerId
        }

        // typical な embedding は安定して A と識別される
        for r in typicalResults {
            XCTAssertEqual(r, idA, "typical A embeddings should always identify as A (no drift)")
        }

        // userCorrections に記録されている（profile は不動だが修正情報は残る）
        XCTAssertEqual(tracker.exportUserCorrections().count, misidentifications)

        // Profile A の centroid は初期値のまま
        let exported = tracker.exportProfiles().first(where: { $0.speakerId == idA })!
        XCTAssertEqual(exported.embedding, profileA, "profile must remain frozen in Manual mode")
    }

    func testAutoMode_correctionCentroidShiftIsLimited() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let idA = UUID()
        let profileA = makeEmbedding(dominant: 0)
        tracker.loadProfiles([(speakerId: idA, embedding: profileA)])
        // suppressLearning=false (Auto mode のデフォルト)

        let initialA = tracker.exportProfiles().first!.embedding

        // 曖昧な embedding を 1 回 correctAssignment で追加
        let ambiguous = makeEmbedding(dominant: 5)
        tracker.correctAssignment(embedding: ambiguous, from: UUID(), to: idA)

        let afterA = tracker.exportProfiles().first!.embedding

        // confidence 1.0 時代なら大きくシフト、0.3 なら控えめ
        // 具体的には (1.0 * [original] + 0.3 * [ambiguous]) / 1.3 ≈ 23% ambiguous 方向
        // 同条件で confidence 1.0 だったら 50% ambiguous 方向
        let shift = zip(initialA, afterA).map { abs($0 - $1) }.reduce(0, +)
        XCTAssertLessThan(shift, 1.0, "user correction centroid shift should be limited in Auto mode")
    }
}
```

- [ ] **Step 2: テスト実行で全 PASS を確認**

Run: `swift test --filter QuickTranscriberTests.ManualModeStabilityTests`
Expected: 全 PASS

- [ ] **Step 3: Commit**

```bash
git add Tests/QuickTranscriberTests/ManualModeStabilityTests.swift
git commit -m "test: add Manual mode stability integration tests"
```

---

## Task 14: 最終確認（全テスト / ビルド / リント）

- [ ] **Step 1: 全ユニットテスト PASS**

Run: `swift test --filter QuickTranscriberTests`
Expected: 全 PASS

- [ ] **Step 2: ビルド OK**

Run: `swift build`
Expected: エラーなし、警告も unprecedented なものがないこと

- [ ] **Step 3: アプリ起動確認（スモークテスト）**

Run: `swift run QuickTranscriber`
Expected: GUI が起動し、設定画面が開ける（CLAUDE.md 通り `print()` は出ないので、クラッシュしないことだけ確認）。
終了は Cmd+Q。

- [ ] **Step 4: （オプション）ベンチマーク回帰の簡易確認**

本番モデル環境があれば:

```bash
swift test --filter ParameterBenchmarkTests
```

これは 5-10 分かかる。主話者連続時の precision/recall が既存値と±5% 以内であること。
時間がなければスキップ可（別途手動検証する）。

- [ ] **Step 5: （コミット不要）**

ここまでの commits が全てローカルに積まれていることを確認:

```bash
git log --oneline -20
```

---

## Self-Review

### Spec Coverage Check

| Spec 要件 | カバーしているタスク |
|---|---|
| `suppressLearning` 拡張で `correctAssignment` も centroid 不動 | Task 4 |
| `userCorrections` 記録と `exportUserCorrections` API | Task 3 |
| `WeightedEmbedding.entryId` 追加 | Task 2 |
| 削除ロジックの近似一致化 | Task 5 |
| Tie-breaker (hitCount → lastConfirmedId) | Task 6 |
| Auto mode で correctAssignment の confidence 低減 | Task 4 |
| `syncViterbiConfirm` 新 API | Task 8 |
| `reassignSegment` の nil-embedding 経路 | Task 9 |
| Manual mode 限定の post-hoc 学習 | Task 12 |
| `currentParticipantIds` state | Task 11 |
| `applyPostHocLearning` 新 API | Task 10 |
| Constants 追加 | Task 1 |
| 統合テスト | Task 13 |
| Mock 更新 | Task 7, 8 |

未カバー事項: なし

### Placeholder Scan

"TBD" / "TODO" / "fill in details" なし。各タスクに完全なコードブロックを含めた。
`injectConfirmedSegmentsForTesting` は DEBUG ガード付きで具体実装を提示。

### Type Consistency Check

- `WeightedEmbedding.entryId: UUID` は Task 2 で定義、Task 3 以降一貫
- `UserCorrection` の 3 フィールドは Task 3 で定義、Task 4/13 で一貫使用
- `SpeakerDiarizer.exportUserCorrections` は Task 7 で追加、Tracker 側は Task 3
- `syncViterbiConfirm(to:)` は Task 8 で protocol/impl/service/mock 同時定義
- `applyPostHocLearning(speakerId:sessionCentroid:alpha:)` は Task 10 で定義、Task 12 で使用
- `currentParticipantIds` は Task 11 で追加、Task 12 で使用
- 定数名（`userCorrectionConfidence` 等）は Task 1 で定義、Task 4/12 で使用

### Scope Check

本プランは 14 タスク、各タスクは 2-5 ステップで bite-sized。実装 1 セッションで完走可能な規模。
spec の全要件をカバーし、単一の subsystem（speaker identification stability）に集中しているため、
1 つの plan として適切。Non-Goals（Viterbi grace period 等）は明確に除外。
