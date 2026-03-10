# Manual モード話者ラベル揺らぎ修正プラン

## Context

Manual モード（話者が事前に特定されている状態）で1時間以上のミーティングを録音すると、主に話す話者（司会 ~70%）のラベルが頻繁に揺らぎ、ユーザーがひたすら修正し続ける本末転倒な状況が発生している。

話者が確定しているにもかかわらず最も不安定になる根本原因は、`identify()` の at-capacity パスが **similarity threshold なしで embedding をプロファイルに強制追加**すること。加えて、修正サイクル自体がプロファイルのドリフトを加速するフィードバックループが存在する。

---

## 調査結果: 6つの揺らぎ発生ポイント

### 発見1: Centroid 汚染ウィンドウ（影響度: 高）
`identify()` が呼ばれた瞬間に embedding が誤マッチしたプロファイルの履歴に追加される（`EmbeddingBasedSpeakerTracker.swift:86`）。修正までの間、汚染された centroid が後続チャンクでさらに誤マッチを誘発する連鎖反応。

### 発見2: 修正 embedding の confidence=1.0 による centroid シフト（影響度: 高）
`correctAssignment()` は移動先プロファイルに `confidence: 1.0` で追加（`EmbeddingBasedSpeakerTracker.swift:199`）。修正される embedding は「曖昧だったもの」なので、高 confidence で追加すると centroid が曖昧方向にシフトし、次の誤識別を誘発する正のフィードバックループ。

### 発見3: Manual モードでの閾値なし強制割り当て（影響度: 非常に高）
`identify()` L92-96: `expectedSpeakerCount` に達すると similarity threshold チェックなしで最もマッチするプロファイルに強制追加。Manual モードでは常に at capacity → cosine similarity 0.3 でもプロファイルに蓄積 → centroid ドリフトの最大要因。

```swift
// EmbeddingBasedSpeakerTracker.swift:92-96 — threshold チェックなし
if let limit = expectedSpeakerCount, profiles.count >= limit, bestIndex >= 0 {
    profiles[bestIndex].embeddingHistory.append(WeightedEmbedding(embedding: embedding, confidence: bestSimilarity))
    recalculateEmbedding(at: bestIndex)
    return SpeakerIdentification(speakerId: profiles[bestIndex].id, confidence: bestSimilarity, embedding: embedding)
}
```

### 発見4: スレッド安全性の欠如（影響度: 中〜高）
- `EmbeddingBasedSpeakerTracker.profiles` 配列: `identify()`（streaming タスク）と `correctAssignment()`（UI スレッド）が同時にアクセス。FluidAudioSpeakerDiarizer の `lock` は rollingBuffer/pacer のみ保護。
- `ViterbiSpeakerSmoother`: `process()`（streaming タスク）と `confirmSpeaker()`（UI スレッド）が同時にアクセス。同期機構なし。

### 発見5: 15s ローリングウィンドウでの embedding 分散（影響度: 中）
7s ごとにダイアライゼーション実行、15s ウィンドウで8s オーバーラップ。同一音声が異なるコンテキストで再処理され、同一話者の embedding 分散が増大。

### 発見6: Viterbi confirmSpeaker の条件付き実行（影響度: 低）
`ChunkedWhisperEngine.correctSpeakerAssignment()` L222: ブロック修正で最初のセグメントで Viterbi がリセットされると、残りのセグメントでは条件不成立でスキップ。最初の1回で十分リセットされるため実害は小さい。

---

## 実装計画

### Task 1: Manual モードプロファイル学習抑制（発見1,2,3を同時解消）

**根拠**: Manual モードでは話者が事前に確定しているため、`identify()` でプロファイルを更新する必要がない。学習を抑制すれば発見1（汚染ウィンドウ）、発見2（修正フィードバック）、発見3（閾値なし強制割り当て）が全て解消される。修正（`correctAssignment`）からの学習は維持し、ユーザーフィードバックでプロファイルが改善される。

**変更ファイルと内容**:

#### 1a. `EmbeddingBasedSpeakerTracker.swift` — suppressLearning フラグ追加

```swift
public var suppressLearning: Bool = false
```

`identify()` の変更:
- Path 1 (L85-88): `if !suppressLearning` で append/recalculate をガード
- Path 2 (L92-96): 同上
- 識別結果（speakerId, confidence, embedding）は常に返す（ラベル付けに必要）

```swift
// Path 1: similarity >= threshold
if bestIndex >= 0 && bestSimilarity >= similarityThreshold {
    if !suppressLearning {
        profiles[bestIndex].embeddingHistory.append(WeightedEmbedding(embedding: embedding, confidence: bestSimilarity))
        recalculateEmbedding(at: bestIndex)
    }
    return SpeakerIdentification(speakerId: profiles[bestIndex].id, confidence: bestSimilarity, embedding: embedding)
}

// Path 2: at capacity
if let limit = expectedSpeakerCount, profiles.count >= limit, bestIndex >= 0 {
    if !suppressLearning && bestSimilarity >= similarityThreshold {
        profiles[bestIndex].embeddingHistory.append(WeightedEmbedding(embedding: embedding, confidence: bestSimilarity))
        recalculateEmbedding(at: bestIndex)
    }
    return SpeakerIdentification(speakerId: profiles[bestIndex].id, confidence: bestSimilarity, embedding: embedding)
}
```

#### 1b. `SpeakerDiarizer.swift` — protocol 拡張

```swift
public protocol SpeakerDiarizer: AnyObject, Sendable {
    // ... existing ...
    func setSuppressLearning(_ suppress: Bool)
}
```

default 実装: no-op

#### 1c. `FluidAudioSpeakerDiarizer` — パススルー

```swift
public func setSuppressLearning(_ suppress: Bool) {
    speakerTracker.suppressLearning = suppress
}
```

#### 1d. `ChunkedWhisperEngine.startStreaming()` — manual モードで有効化

L74-84 の manual モード分岐内に追加:
```swift
diarizer.setSuppressLearning(true)
```

auto モード分岐内:
```swift
diarizer.setSuppressLearning(false)
```

### Task 2: At-capacity パスの閾値ゲート追加（auto モード向け）

**根拠**: Task 1 で manual モードは解決するが、auto モードでも `expectedSpeakerCount` が設定されている場合に同じ問題が起きうる。閾値ゲートを追加して auto モードの安定性も向上させる。

**変更ファイル**: `EmbeddingBasedSpeakerTracker.swift`

Task 1a の Path 2 変更に含まれている。`suppressLearning` が false でも、`bestSimilarity >= similarityThreshold` チェックが入るため、auto モードでも低品質 embedding がプロファイルに入らなくなる。

### Task 3: スレッド安全性の追加（発見4を解消）

**変更ファイルと内容**:

#### 3a. `EmbeddingBasedSpeakerTracker.swift` — NSLock 追加

```swift
private let lock = NSLock()
```

以下のメソッドを `lock.withLock` でラップ:
- `identify()` — profiles 読み書き
- `correctAssignment()` — profiles 読み書き
- `mergeProfile()` — profiles 読み書き
- `loadProfiles()` — profiles 書き込み
- `exportProfiles()` / `exportDetailedProfiles()` — profiles 読み込み
- `reset()` — profiles 書き込み

#### 3b. `ChunkedWhisperEngine.swift` — speakerSmoother の同期

`speakerSmoother` へのアクセスを NSLock で保護:
- `processChunk()` 内の `speakerSmoother.process()` (L292)
- `correctSpeakerAssignment()` 内の `speakerSmoother.confirmSpeaker()` (L222-224)
- `mergeSpeakerProfiles()` 内の `speakerSmoother.remapSpeaker()` (L229)

```swift
private let smootherLock = NSLock()
```

---

## 実装順序

```
Task 1: Manual モード学習抑制 ← 最重要、ユーザーの苦痛の直接原因
  ↓
Task 2: At-capacity 閾値ゲート ← Task 1 の Path 2 変更に含まれる（実質同時）
  ↓
Task 3: スレッド安全性 ← 独立、並列実装可能
```

Task 1+2 は密結合（同じ identify() メソッドの変更）なので一括実装。
Task 3 は独立した変更なので worktree で並列実装も可能。

---

## 変更対象ファイル一覧

| ファイル | 変更内容 |
|---|---|
| `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift` | suppressLearning フラグ、identify() ガード、NSLock |
| `Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift` | protocol に setSuppressLearning 追加 |
| `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift` | startStreaming() で setSuppressLearning 呼び出し、smootherLock |
| `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift` | suppressLearning テスト追加 |

---

## 検証方法

### ユニットテスト
1. **suppressLearning=true で identify() がプロファイルを更新しないこと**
   - 初期プロファイル A,B をロード → suppressLearning=true → identify() 10回実行 → embeddingHistory が変化しないことを確認
2. **suppressLearning=true でも correctAssignment() がプロファイルを更新すること**
   - suppressLearning=true → correctAssignment(from:A, to:B) → B のプロファイルにembedding が追加されることを確認
3. **at-capacity パスで閾値未満の embedding がプロファイルに追加されないこと**
   - expectedSpeakerCount=2、suppressLearning=false → sim<0.5 の embedding で identify() → embeddingHistory 変化なし
4. **スレッド安全性テスト**
   - 並列で identify() と correctAssignment() を同時実行 → クラッシュしないことを確認

### 結合テスト（手動）
- Manual モードで2話者のミーティングを録音し、主話者のラベルが安定すること
- 修正操作後に次のチャンクで同じ誤識別が再発しないこと
- Auto モードの既存動作が壊れないこと（既存ベンチマークで regression なし）
