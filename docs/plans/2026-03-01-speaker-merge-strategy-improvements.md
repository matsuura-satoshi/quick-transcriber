# Speaker Merge Strategy Improvements

## Context

話者マージ機能は名前衝突トリガーとして実装済み（PR ~2026-02-26）。バックエンドのマージインフラ（`executeMerge`, protocol chain, テスト45+件）は完成しているが、マージ戦略自体に2つの改善点がある：

1. **Embedding EMAブレンドが固定 0.7/0.3** — sessionCountに関係なく同じ比率。20セッション分のプロファイルと2セッション分のプロファイルを対等にブレンドしてしまう
2. **Viterbi状態空間が更新されない** — マージ後に吸収UUIDのstateが残り、遷移ノイズが発生する可能性

品質フィルタリング（低confidence embedding除外）は将来的な改善として保留。

---

## 実装計画

### Task 1: sessionCount比例ブレンド — テスト

**Files:**
- Modify: `Tests/QuickTranscriberTests/SpeakerMergeTests.swift`

**Step 1: 既存テストの確認・修正**

現在の `testExecuteMergeEmbeddingBlending` テストは固定0.7/0.3を前提としている。sessionCount比例に変更後の期待値に修正する。

```swift
// 既存テスト: survivor sessionCount=5, absorbed sessionCount=3
// 現在の期待: 0.7 * survivor + 0.3 * absorbed
// 変更後の期待: alpha = 3/(5+3) = 0.375
//   survivor * 0.625 + absorbed * 0.375

// 新規テスト追加:
func testExecuteMergeEmbeddingBlending_proportionalToSessionCount() {
    // survivor: sessionCount=10, absorbed: sessionCount=2
    // alpha = 2/12 ≈ 0.167 → absorbed influence is small
    // expected: 0.833 * survivor + 0.167 * absorbed
}

func testExecuteMergeEmbeddingBlending_equalSessionCount() {
    // sessionCount=3 vs sessionCount=3
    // alpha = 3/6 = 0.5 → 50/50 blend
}

func testExecuteMergeEmbeddingBlending_zeroSessionCounts() {
    // 両方sessionCount=0（新規作成直後）
    // fallback: alpha = 0.5 (50/50)
}
```

**Step 2: テストが失敗することを確認**

Run: `swift test --filter QuickTranscriberTests/SpeakerMergeTests`

### Task 2: sessionCount比例ブレンド — 実装

**File:** `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift` (L453-454)

**変更箇所:** `executeMerge()` メソッドのembeddingブレンド部分

```swift
// 変更前:
let alpha: Float = 0.3

// 変更後:
let totalSessions = speakerProfileStore.profiles[survIdx].sessionCount
    + absProfile.sessionCount
let alpha: Float = totalSessions > 0
    ? Float(absProfile.sessionCount) / Float(totalSessions)
    : 0.5  // 両方0の場合は対等ブレンド
```

残りのブレンド計算コード（L455-460）は変更不要。`alpha` の意味が「吸収側の寄与率」なのは同じ。

**注意:** `absProfile.sessionCount` は `executeMerge()` のL451で取得済み。ただし `speakerProfileStore.profiles[survIdx].sessionCount` はStep3のメタデータ統合（L463）で加算**される前**に参照する必要がある。現在のコード順序で問題なし（blendがL453-460、metadata統合がL462-472）。

**Step 3: テストが通ることを確認**

Run: `swift test --filter QuickTranscriberTests/SpeakerMergeTests`

---

### Task 3: ViterbiSpeakerSmoother remapSpeaker — テスト

**File:** `Tests/QuickTranscriberTests/ViterbiSpeakerSmootherTests.swift`（既存ファイルに追加）

```swift
func testRemapSpeaker_mergesLogProbabilities() {
    let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
    let speakerA = UUID()
    let speakerB = UUID()

    // speakerA を2回確認してstate構築
    let id1 = SpeakerIdentification(speakerId: speakerA, confidence: 0.8, embedding: [])
    let id2 = SpeakerIdentification(speakerId: speakerB, confidence: 0.9, embedding: [])
    _ = smoother.process(id1)
    _ = smoother.process(id2)
    _ = smoother.process(id2)  // speakerB確認

    // remapでspeakerBをspeakerAに統合
    smoother.remapSpeaker(from: speakerB, to: speakerA)

    // speakerBのstateが消えていること
    // 次の処理でspeakerAが正常に動作すること
    let result = smoother.process(id1)
    XCTAssertEqual(result?.speakerId, speakerA)
}

func testRemapSpeaker_unknownSourceIsNoOp() {
    let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
    let speakerA = UUID()
    let unknownId = UUID()

    let id1 = SpeakerIdentification(speakerId: speakerA, confidence: 0.8, embedding: [])
    _ = smoother.process(id1)

    // 存在しないUUIDのremapは何も起きない
    smoother.remapSpeaker(from: unknownId, to: speakerA)

    let result = smoother.process(id1)
    XCTAssertEqual(result?.speakerId, speakerA)
}

func testRemapSpeaker_updatesConfirmedSpeaker() {
    let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)
    let speakerA = UUID()
    let speakerB = UUID()

    // speakerBを確認状態にする
    let id1 = SpeakerIdentification(speakerId: speakerB, confidence: 0.9, embedding: [1.0])
    _ = smoother.process(id1)

    // speakerBをspeakerAにremap → confirmed も更新されるべき
    smoother.remapSpeaker(from: speakerB, to: speakerA)

    // nilを渡すとconfirmedが返る → speakerAになっているはず
    let result = smoother.process(nil)
    XCTAssertEqual(result?.speakerId, speakerA)
}
```

**Step: テストが失敗することを確認**

Run: `swift test --filter QuickTranscriberTests/ViterbiSpeakerSmootherTests`

---

### Task 4: ViterbiSpeakerSmoother remapSpeaker — 実装

**File:** `Sources/QuickTranscriber/Engines/SpeakerLabelTracker.swift`

`resetForSpeakerChange()` の直前（L141付近）に追加:

```swift
/// Merge speaker state: redirect absorbed speaker's Viterbi state to survivor.
/// After merge, the absorbed UUID is removed from the state space, reducing
/// transition noise and preventing stale states.
public func remapSpeaker(from oldId: UUID, to newId: UUID) {
    // Merge log-probabilities
    if let oldProb = stateLogProb.removeValue(forKey: oldId) {
        if let existingProb = stateLogProb[newId] {
            // Log-sum-exp for combining probabilities
            let maxProb = max(existingProb, oldProb)
            stateLogProb[newId] = maxProb + log(exp(existingProb - maxProb) + exp(oldProb - maxProb))
        } else {
            stateLogProb[newId] = oldProb
        }
    }

    // Update confirmed speaker if it was the absorbed one
    if confirmed?.speakerId == oldId {
        confirmed = SpeakerIdentification(
            speakerId: newId,
            confidence: confirmed!.confidence,
            embedding: confirmed!.embedding
        )
    }

    // Update pending speaker if it was the absorbed one
    if pendingSpeakerId == oldId {
        pendingSpeakerId = newId
    }
}
```

**注意点:**
- `confirmed` が吸収UUIDの場合は生存者UUIDに更新（そうしないとnilInput時に古いUUIDが返る）
- `pendingSpeakerId` も同様に更新
- log-sum-expで数値安定性を確保

---

### Task 5: マージチェーンにViterbi更新を統合

**File:** `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift` (L224-226)

```swift
// 変更前:
public func mergeSpeakerProfiles(from sourceId: UUID, into targetId: UUID) {
    diarizer?.mergeSpeakerProfiles(from: sourceId, into: targetId)
}

// 変更後:
public func mergeSpeakerProfiles(from sourceId: UUID, into targetId: UUID) {
    diarizer?.mergeSpeakerProfiles(from: sourceId, into: targetId)
    speakerSmoother.remapSpeaker(from: sourceId, to: targetId)
}
```

1行追加のみ。

---

### Task 6: 全テスト実行 + 最終検証

**Step 1:** `swift test --filter QuickTranscriberTests`（全テスト）
**Step 2:** `swift build`（ビルド確認）

---

## 変更対象ファイル

| File | 変更内容 |
|---|---|
| `ViewModels/TranscriptionViewModel.swift` | `executeMerge()` L453-454: 固定alpha→sessionCount比例alpha |
| `Engines/SpeakerLabelTracker.swift` | `remapSpeaker(from:to:)` メソッド追加 |
| `Engines/ChunkedWhisperEngine.swift` | `mergeSpeakerProfiles()` L225: smoother.remapSpeaker追加 |
| `Tests/.../SpeakerMergeTests.swift` | embedding blendテスト修正・追加 |
| `Tests/.../ViterbiSpeakerSmootherTests.swift` | remapSpeakerテスト追加 |

## 検証方法

1. `swift test --filter QuickTranscriberTests` — 全テストパス
2. 手動テスト: 名前衝突でマージ → sessionCountが異なる場合にembeddingの寄与率が変わること
3. 手動テスト: 録音中にマージ → マージ後の話者切り替えが安定すること（Viterbi状態更新の効果）
