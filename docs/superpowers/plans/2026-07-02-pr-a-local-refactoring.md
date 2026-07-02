# PR-A: 局所リファクタリング（デッドコード削除 + 重複統合）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 挙動を変えずにデッドコード4件を削除し重複ロジック12件を統合する（スペック: `docs/superpowers/specs/2026-07-02-simplification-refactoring-design.md` Part A）。

**Architecture:** 各タスクは独立した挙動不変リファクタ。既存の QuickTranscriberTests（~2秒）が安全網。新規 API（EmbeddingMath）のみテストファースト。

**Tech Stack:** Swift 5 mode / SwiftPM / XCTest / SwiftUI + AppKit

## Global Constraints

- ブランチ: `refactor/simplification-design` を `refactor/simplification-pr-a` にリネームして作業（Task 1 冒頭）
- テスト実行: `swift test --filter QuickTranscriberTests`（モデル不要、~2秒。Xcode 必須）
- ベンチマークターゲットもコンパイル対象: 各タスク完了時 `swift build --build-tests` が通ること
- ファイル削除は `git rm`（トラッキング済み）を使う。**`rm` コマンドは使用禁止**（このマシンでは trash にエイリアスされており `-f` 等で失敗する）
- `Constants.Version.patch` は Task 13 の PR 作成後コミットでのみ変更する
- macOS GUI アプリのデバッグ出力は `NSLog`（`print()` は出ない）
- コミットメッセージは既存リポジトリ慣行に従い `refactor:` / `test:` プレフィックス + 日本語サマリ

---

### Task 1: ProfileStrategy 機構の削除

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift`
- Modify: `Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift:76-95`
- Modify: `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift`
- Delete: `Tests/QuickTranscriberBenchmarks/ProfileStrategyBenchmarkTests.swift`
- Modify: `Tests/QuickTranscriberBenchmarks/DiarizationBenchmarkTests.swift:105-145`
- Modify: `Tests/QuickTranscriberBenchmarks/ParameterSweepRunner.swift:233-238`
- Modify: `Tests/QuickTranscriberBenchmarks/ParameterSweepRunnerTests.swift:97-115`

**Interfaces:**
- Produces: `EmbeddingBasedSpeakerTracker.init(similarityThreshold:updateAlpha:expectedSpeakerCount:)`（`strategy` パラメータ消滅）。Task 2 がさらに `updateAlpha` を消す。

**背景:** 本番コードは常に `.none`（`SpeakerDiarizer.swift:82` のデフォルト値経由）。culling/merging/registrationGate は不採用に終わった実験（ユーザー削除承認済み 2026-07-02）。

- [ ] **Step 1: ブランチをリネーム**

```bash
git branch -m refactor/simplification-design refactor/simplification-pr-a
```

- [ ] **Step 2: ベースライン確認（全テスト green を確認してから開始）**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -3`
Expected: `Test Suite 'All tests' passed`

- [ ] **Step 3: Tracker から strategy 機構を削除**

`EmbeddingBasedSpeakerTracker.swift` で以下を削除:

1. `public enum ProfileStrategy` 宣言全体（L3-9）
2. プロパティ `private let strategy: ProfileStrategy`（L76）と `private var identifyCount: Int = 0`（L77）
3. init の `strategy` パラメータとその代入、doc コメントの `- strategy:` 行。init は次の形になる:

```swift
    /// - Parameters:
    ///   - similarityThreshold: Minimum cosine similarity to match a known speaker (default: 0.5)
    ///   - updateAlpha: Unused, kept for backward compatibility (default: 0.3)
    ///   - expectedSpeakerCount: Maximum number of speakers to track (nil = unlimited)
    public init(similarityThreshold: Float = Constants.Embedding.similarityThreshold, updateAlpha: Float = 0.3,
                expectedSpeakerCount: Int? = nil) {
        self.similarityThreshold = similarityThreshold
        self.updateAlpha = updateAlpha
        self.expectedSpeakerCount = expectedSpeakerCount
    }
```

4. `identify()` 冒頭の 2 行（L104-105）:

```swift
            identifyCount += 1
            maintainProfiles()
```

5. `identify()` 内の registration gate ブロック全体（L163-173、`// Registration gate:` コメントから閉じ括弧まで）
6. `private func maintainProfiles()` 全体（L201-216）
7. `private func mergeProfiles(threshold: Float)` 全体（L218-237）

- [ ] **Step 4: SpeakerDiarizer から profileStrategy パラメータを削除**

`SpeakerDiarizer.swift:76-95` の init から `profileStrategy: ProfileStrategy = .none` パラメータ（L82）と `strategy: profileStrategy` 引数（L89）を削除。

- [ ] **Step 5: ユニットテストから strategy 系テストを削除**

`Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift` で:

1. 次の 5 テスト関数と直前の `// MARK:` コメントを削除:
   `testCullingRemovesLowHitProfiles` / `testMergingCombinesSimilarProfiles` / `testRegistrationGateBlocksSimilarNewSpeaker` / `testRegistrationGateAllowsTrulyDifferentSpeaker` / `testCombinedStrategyCullsThenMerges`
2. `testProfileStrategyNoneIsDefault`（L225）は挙動テストとして有効なので**残し**、`testDistinctEmbeddingsRegisterDistinctSpeakers` にリネーム。直前の `// MARK: - Profile Strategy` は `// MARK: - Registration` に変更。`testHitCountIncrementsOnMatch` はそのまま残す。

- [ ] **Step 6: ベンチマークターゲットの参照を削除**

```bash
git rm Tests/QuickTranscriberBenchmarks/ProfileStrategyBenchmarkTests.swift
```

`DiarizationBenchmarkTests.swift`: ヘルパーのパラメータ `profileStrategy: ProfileStrategy = .none,`（L109）と、`FluidAudioSpeakerDiarizer` 構築時の `profileStrategy: profileStrategy`（L145）を削除。

`ParameterSweepRunner.swift:233-238`: residual キーリストから `"profileStrategy"` を削除:

```swift
            // Stage-2 diarization component parameters — pass through to caller.
            case "similarityThreshold",
                 "diarizationChunkDuration",
                 "windowDuration":
                residual[key] = value
```

`ParameterSweepRunnerTests.swift`: `test_apply_leavesStage2OnlyKeysInResidualBucket` から L104 `"profileStrategy": .string("culling"),` と L113 `XCTAssertEqual(residual["profileStrategy"]?.stringValue, "culling")` の 2 行を削除。

- [ ] **Step 7: ビルド + テスト**

Run: `swift build --build-tests 2>&1 | tail -3 && swift test --filter QuickTranscriberTests 2>&1 | tail -3`
Expected: ビルド成功、`Test Suite 'All tests' passed`

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor: ProfileStrategy 機構を削除（本番で常に .none の実験残骸）"
```

---

### Task 2: 未使用 updateAlpha パラメータの削除

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift:74,88,91-94`
- Modify: `Sources/QuickTranscriber/Engines/SpeakerDiarizer.swift:78,87`
- Modify: `Tests/QuickTranscriberBenchmarks/DiarizationBenchmarkTests.swift:105,141`

**Interfaces:**
- Produces: `EmbeddingBasedSpeakerTracker.init(similarityThreshold:expectedSpeakerCount:)` / `FluidAudioSpeakerDiarizer.init(similarityThreshold:windowDuration:diarizationChunkDuration:expectedSpeakerCount:)`

**注意:** `SpeakerProfileStore.swift:11` の `updateAlpha` は**別物で使用中**。触らない。

- [ ] **Step 1: Tracker から削除**

`EmbeddingBasedSpeakerTracker.swift`: プロパティ `private let updateAlpha: Float`（L74）、doc コメント `///   - updateAlpha: ...`（L88）、init パラメータ `updateAlpha: Float = 0.3,` と代入 `self.updateAlpha = updateAlpha` を削除。init は最終的に:

```swift
    public init(similarityThreshold: Float = Constants.Embedding.similarityThreshold,
                expectedSpeakerCount: Int? = nil) {
        self.similarityThreshold = similarityThreshold
        self.expectedSpeakerCount = expectedSpeakerCount
    }
```

- [ ] **Step 2: SpeakerDiarizer から削除**

`SpeakerDiarizer.swift`: init パラメータ `updateAlpha: Float = 0.3,`（L78）と `updateAlpha: updateAlpha,`（L87）を削除。

- [ ] **Step 3: ベンチマークヘルパーから削除**

`DiarizationBenchmarkTests.swift`: ヘルパーのパラメータ `updateAlpha: Float = 0.3,`（L105）と `updateAlpha: updateAlpha,`（L141）を削除。

- [ ] **Step 4: 他に呼び出し残がないか確認**

Run: `grep -rn "updateAlpha" Sources/ Tests/ | grep -v SpeakerProfileStore`
Expected: 出力なし

- [ ] **Step 5: ビルド + テスト + Commit**

Run: `swift build --build-tests 2>&1 | tail -3 && swift test --filter QuickTranscriberTests 2>&1 | tail -3`
Expected: pass

```bash
git add -A
git commit -m "refactor: 未使用の updateAlpha パラメータを Diarizer/Tracker から削除"
```

---

### Task 3: 小型デッドコード削除（typealias / cleanup チェーン）

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/SpeakerLabelTracker.swift:198-199`
- Modify: `Sources/QuickTranscriber/Engines/TranscriptionEngine.swift:35`
- Modify: `Sources/QuickTranscriber/Services/TranscriptionService.swift:65-67`
- Modify: `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift:370-374`
- Modify: `Tests/QuickTranscriberTests/Mocks/MockTranscriptionEngine.swift:20,63-67`
- Modify: `Tests/QuickTranscriberTests/TranscriptionServiceTests.swift:65-74,104-117`
- Modify: `Tests/QuickTranscriberTests/ChunkedWhisperEngineTests.swift:46-51`

**背景:** `SpeakerLabelTracker` typealias は参照ゼロ。`cleanup()` はプロトコル→Service→Engine と貫通するが**本番呼び出しゼロ**（テストのみ）。Engine 実装は fire-and-forget `Task { await stopStreaming() }` で、後続の startStreaming と競合しうる危険な形のため、修正でなく削除する（スペック A-1 #4）。

- [ ] **Step 1: typealias 削除**

`SpeakerLabelTracker.swift` 末尾の 2 行を削除:

```swift
// Backward compatibility alias
public typealias SpeakerLabelTracker = ViterbiSpeakerSmoother
```

（ファイル名は Viterbi 実装の置き場として据え置き。リネームは B3 で検討）

- [ ] **Step 2: cleanup チェーン削除**

1. `TranscriptionEngine.swift`: プロトコルから `func cleanup()` 行を削除
2. `TranscriptionService.swift`: `public func cleanup() { ... }` メソッド全体を削除（L65-67 付近、`engine.cleanup()` と `isReady = false` を含むボディごと）
3. `ChunkedWhisperEngine.swift`: `public func cleanup() { Task { [weak self] in await self?.stopStreaming() } }` 全体を削除
4. `MockTranscriptionEngine.swift`: `var cleanupCalled = false`（L20）と `func cleanup() { ... }`（L63-67）を削除

- [ ] **Step 3: cleanup 系テストを削除**

1. `TranscriptionServiceTests.swift`: `testCleanup()`（L65-74）と `testCleanupThenStartThrows()`（L104-117）を削除
2. `ChunkedWhisperEngineTests.swift`: `testCleanupResetsState()`（L46-51）を削除

- [ ] **Step 4: 参照残がないか確認**

Run: `grep -rn "cleanup\b" Sources/ | grep -iv "session boundary"; grep -rn "SpeakerLabelTracker\b" Sources/ Tests/ | grep -v "SpeakerLabelTracker.swift\|SpeakerLabelTrackerTests"`
Expected: `cleanup` の Sources ヒットなし。typealias 参照なし（ファイル名・テストファイル名のみ）

- [ ] **Step 5: ビルド + テスト + Commit**

Run: `swift build --build-tests 2>&1 | tail -3 && swift test --filter QuickTranscriberTests 2>&1 | tail -3`
Expected: pass

```bash
git add -A
git commit -m "refactor: 本番未使用の cleanup() チェーンと SpeakerLabelTracker typealias を削除"
```

---

### Task 4: EmbeddingMath 新設と埋め込み演算の統合

**Files:**
- Create: `Sources/QuickTranscriber/Engines/EmbeddingMath.swift`
- Create: `Tests/QuickTranscriberTests/EmbeddingMathTests.swift`
- Modify: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift`（cosineSimilarity 移設、recalculateEmbedding 委譲）
- Modify: `Sources/QuickTranscriber/Models/EmbeddingHistoryStore.swift:124-144`
- Modify: `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift:306,332-346`
- Modify: `Sources/QuickTranscriber/Models/SpeakerProfileStore.swift:127-131,149-157`
- Modify: `Sources/QuickTranscriber/Models/SpeakerStateCoordinator.swift:424-429`
- Modify: `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift`（cosineSimilarity 呼び出し 6 箇所）
- Modify: `Tests/QuickTranscriberBenchmarks/ConfusionPairAnalysisTests.swift`（同 4 箇所）

**Interfaces:**
- Produces:
  - `EmbeddingMath.cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float`
  - `EmbeddingMath.weightedMean(_ items: [(embedding: [Float], weight: Float)]) -> [Float]?`
  - `EmbeddingMath.blend(_ a: [Float], _ b: [Float], alpha: Float) -> [Float]`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/QuickTranscriberTests/EmbeddingMathTests.swift` を新規作成:

```swift
import XCTest
@testable import QuickTranscriberLib

final class EmbeddingMathTests: XCTestCase {

    // MARK: - cosineSimilarity

    func testCosineIdenticalVectorsIsOne() {
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([1, 2, 3], [1, 2, 3]), 1.0, accuracy: 1e-6)
    }

    func testCosineOrthogonalVectorsIsZero() {
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([1, 0], [0, 1]), 0.0, accuracy: 1e-6)
    }

    func testCosineMismatchedDimensionsReturnsZero() {
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([1, 2], [1, 2, 3]), 0)
    }

    func testCosineEmptyVectorsReturnsZero() {
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([], []), 0)
    }

    func testCosineZeroVectorReturnsZero() {
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([0, 0], [1, 1]), 0)
    }

    // MARK: - weightedMean

    func testWeightedMeanSingleItemReturnsItself() {
        let result = EmbeddingMath.weightedMean([(embedding: [1, 2, 3], weight: 0.7)])
        XCTAssertEqual(result!, [1, 2, 3])
    }

    func testWeightedMeanTwoItemsExactValues() {
        // (3*[1,0] + 1*[0,1]) / 4 = [0.75, 0.25]
        let result = EmbeddingMath.weightedMean([
            (embedding: [1, 0], weight: 3),
            (embedding: [0, 1], weight: 1),
        ])!
        XCTAssertEqual(result[0], 0.75, accuracy: 1e-6)
        XCTAssertEqual(result[1], 0.25, accuracy: 1e-6)
    }

    func testWeightedMeanSkipsMismatchedDimensions() {
        // 次元不一致エントリはスキップ（engine の旧 centroid と同じ防御挙動）
        let result = EmbeddingMath.weightedMean([
            (embedding: [1, 0], weight: 1),
            (embedding: [9, 9, 9], weight: 100),
        ])!
        XCTAssertEqual(result, [1, 0])
    }

    func testWeightedMeanEmptyReturnsNil() {
        XCTAssertNil(EmbeddingMath.weightedMean([]))
    }

    func testWeightedMeanZeroTotalWeightReturnsNil() {
        XCTAssertNil(EmbeddingMath.weightedMean([(embedding: [1, 2], weight: 0)]))
    }

    // MARK: - blend

    func testBlendAlphaZeroReturnsFirst() {
        XCTAssertEqual(EmbeddingMath.blend([1, 2], [5, 6], alpha: 0), [1, 2])
    }

    func testBlendAlphaOneReturnsSecond() {
        XCTAssertEqual(EmbeddingMath.blend([1, 2], [5, 6], alpha: 1), [5, 6])
    }

    func testBlendExactValues() {
        // (1-0.25)*[4,0] + 0.25*[0,4] = [3, 1]
        let result = EmbeddingMath.blend([4, 0], [0, 4], alpha: 0.25)
        XCTAssertEqual(result[0], 3, accuracy: 1e-6)
        XCTAssertEqual(result[1], 1, accuracy: 1e-6)
    }
}
```

- [ ] **Step 2: テストが失敗（コンパイルエラー）することを確認**

Run: `swift test --filter EmbeddingMathTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'EmbeddingMath' in scope`

- [ ] **Step 3: EmbeddingMath を実装**

`Sources/QuickTranscriber/Engines/EmbeddingMath.swift` を新規作成:

```swift
import Foundation

/// 話者 embedding ベクトルの共有演算。
/// tracker / EmbeddingHistoryStore / engine / store に分散していた
/// 中核計算を 1 箇所に集約する。
public enum EmbeddingMath {
    /// Cosine similarity between two vectors.
    /// Returns 0 for mismatched dimensions, empty vectors, or zero norm.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    /// Weight 付き平均。次元が先頭エントリと異なるものはスキップする。
    /// - Returns: items が空、または有効な総 weight が 0 のとき nil。
    public static func weightedMean(_ items: [(embedding: [Float], weight: Float)]) -> [Float]? {
        guard let first = items.first, !first.embedding.isEmpty else { return nil }
        let dims = first.embedding.count
        var weightedSum = [Float](repeating: 0, count: dims)
        var totalWeight: Float = 0
        for item in items {
            guard item.embedding.count == dims else { continue }
            totalWeight += item.weight
            for i in 0..<dims {
                weightedSum[i] += item.weight * item.embedding[i]
            }
        }
        guard totalWeight > 0 else { return nil }
        return weightedSum.map { $0 / totalWeight }
    }

    /// 線形ブレンド: (1-alpha)*a + alpha*b（zip 準拠: 長さが違う場合は短い方に切り詰め）。
    public static func blend(_ a: [Float], _ b: [Float], alpha: Float) -> [Float] {
        zip(a, b).map { (1 - alpha) * $0 + alpha * $1 }
    }
}
```

- [ ] **Step 4: 新テストが通ることを確認**

Run: `swift test --filter EmbeddingMathTests 2>&1 | tail -3`
Expected: PASS

- [ ] **Step 5: Tracker を委譲に置き換え**

`EmbeddingBasedSpeakerTracker.swift`:

1. `public static func cosineSimilarity` の実装全体（L368-381）を削除し、ファイル内の `Self.cosineSimilarity(` 5 箇所を `EmbeddingMath.cosineSimilarity(` に置換（`removeClosestMatch` 内の `cosineSimilarity(` も含む）
2. `recalculateEmbedding` を委譲に置き換え:

```swift
    /// Recalculate the centroid embedding as confidence-weighted mean of all history entries.
    private func recalculateEmbedding(at index: Int) {
        let history = profiles[index].embeddingHistory
        guard let mean = EmbeddingMath.weightedMean(history.map { (embedding: $0.embedding, weight: $0.confidence) }) else { return }
        profiles[index].embedding = mean
        profiles[index].hitCount = history.count
    }
```

- [ ] **Step 6: EmbeddingHistoryStore を委譲に置き換え**

`EmbeddingHistoryStore.swift` の `reconstructProfile`（L124-144）を:

```swift
    public func reconstructProfile(for profileId: UUID) throws -> [Float]? {
        let entries = try loadAll()
        let confirmedEntries = entries
            .filter { $0.speakerProfileId == profileId }
            .flatMap { $0.embeddings }
            .filter { $0.confirmed }
        return EmbeddingMath.weightedMean(confirmedEntries.map { (embedding: $0.embedding, weight: $0.confidence ?? 1.0) })
    }
```

- [ ] **Step 7: Engine の centroid を削除して委譲**

`ChunkedWhisperEngine.swift`:

1. `private static func centroid(of embeddings: [[Float]]) -> [Float]?` 全体（L332-346）を削除
2. `applyManualModePostHocLearning` 内（L306）の
   `guard let centroid = Self.centroid(of: embeddings) else { continue }` を
   `guard let centroid = EmbeddingMath.weightedMean(embeddings.map { (embedding: $0, weight: 1.0) }) else { continue }` に置換

- [ ] **Step 8: Store と Coordinator の blend を委譲**

`SpeakerProfileStore.swift` `mergeSessionProfiles`（L127-131）:

```swift
            if let idMatchIndex = profiles.firstIndex(where: { $0.id == speakerId }) {
                profiles[idMatchIndex].embedding = EmbeddingMath.blend(
                    profiles[idMatchIndex].embedding, embedding, alpha: updateAlpha)
                profiles[idMatchIndex].lastUsed = Date()
                profiles[idMatchIndex].sessionCount += 1
            } else {
```

`applyPostHocLearning`（L149-157）— **既存の次元ガードは維持する**（不一致時に lastUsed/sessionCount を触らない挙動を保つ）:

```swift
    public func applyPostHocLearning(speakerId: UUID, sessionCentroid: [Float], alpha: Float) {
        guard let idx = profiles.firstIndex(where: { $0.id == speakerId }) else { return }
        guard profiles[idx].embedding.count == sessionCentroid.count else { return }
        profiles[idx].embedding = EmbeddingMath.blend(profiles[idx].embedding, sessionCentroid, alpha: alpha)
        profiles[idx].lastUsed = Date()
        profiles[idx].sessionCount += 1
    }
```

`SpeakerStateCoordinator.swift` `executeMerge` 内（L424-429）:

```swift
            profileStore.profiles[survIdx].embedding = EmbeddingMath.blend(
                profileStore.profiles[survIdx].embedding,
                absProfile.embedding,
                alpha: alpha
            )
```

- [ ] **Step 9: テストの cosineSimilarity 呼び出しを更新**

Run: `grep -rln "EmbeddingBasedSpeakerTracker.cosineSimilarity" Tests/`
対象 2 ファイル（`EmbeddingBasedSpeakerTrackerTests.swift` 6 箇所 / `ConfusionPairAnalysisTests.swift` 4 箇所）で `EmbeddingBasedSpeakerTracker.cosineSimilarity(` → `EmbeddingMath.cosineSimilarity(` に一括置換。

- [ ] **Step 10: ビルド + 全テスト + Commit**

Run: `swift build --build-tests 2>&1 | tail -3 && swift test --filter QuickTranscriberTests 2>&1 | tail -3`
Expected: pass（tracker/store/engine の既存テストが数値同一性を担保）

```bash
git add -A
git commit -m "refactor: 埋め込み演算(cosine/weightedMean/blend)を EmbeddingMath に統合"
```

---

### Task 5: SpeakerProfileStore の整理（requireIndex / JSON 書き込み / 検索フィルタ再利用）

**Files:**
- Create: `Sources/QuickTranscriber/Models/JSONFileStorage.swift`
- Modify: `Sources/QuickTranscriber/Models/SpeakerProfileStore.swift`
- Modify: `Sources/QuickTranscriber/Models/EmbeddingHistoryStore.swift:44-53,108-114`
- Modify: `Sources/QuickTranscriber/Models/StoredSpeakerProfile.swift`（末尾に extension 追加）
- Modify: `Sources/QuickTranscriber/Views/SettingsView.swift:288-300`

**Interfaces:**
- Produces:
  - `JSONFileStorage.write<T: Encodable>(_ value: T, to fileURL: URL) throws`
  - `Array<StoredSpeakerProfile>.matching(_ search: String) -> [StoredSpeakerProfile]`

- [ ] **Step 1: JSONFileStorage を作成**

`Sources/QuickTranscriber/Models/JSONFileStorage.swift`:

```swift
import Foundation

/// JSON ストアの共通書き込み処理（ディレクトリ作成 → encode → atomic write）。
enum JSONFileStorage {
    static func write<T: Encodable>(_ value: T, to fileURL: URL) throws {
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder().encode(value)
        try data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 2: 3 箇所の書き込みを委譲**

`SpeakerProfileStore.save()`（L28-35）:

```swift
    public func save() throws {
        try JSONFileStorage.write(profiles, to: fileURL)
    }
```

`EmbeddingHistoryStore.appendSession`（L44-50 の do ブロック内）:

```swift
        do {
            try JSONFileStorage.write(existing, to: fileURL)
        } catch {
            NSLog("[EmbeddingHistoryStore] Failed to save: \(error)")
        }
```

`EmbeddingHistoryStore.removeEntries`（L108-114 の do ブロック内、空でないとき）:

```swift
        do {
            if existing.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
            } else {
                try JSONFileStorage.write(existing, to: fileURL)
            }
        } catch {
            NSLog("[EmbeddingHistoryStore] Failed to remove entries: \(error)")
        }
```

- [ ] **Step 3: requireIndex ヘルパーを導入**

`SpeakerProfileStore.swift` に private ヘルパーを追加し、`rename` / `setLocked` / `delete` / `forceDelete` / `addTag` / `removeTag` の 6 メソッドの `guard let index = profiles.firstIndex(where: { $0.id == ... }) else { throw ... }` を置き換える:

```swift
    private func requireIndex(_ id: UUID) throws -> Int {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw SpeakerProfileStoreError.profileNotFound
        }
        return index
    }
```

置換例（`rename`。他 5 件も同型）:

```swift
    public func rename(id: UUID, to name: String) throws {
        let index = try requireIndex(id)
        if !name.isEmpty {
            profiles[index].displayName = name
        }
        try save()
    }
```

- [ ] **Step 4: 検索フィルタを extension 化して再利用**

`StoredSpeakerProfile.swift` 末尾に追加:

```swift
public extension Array where Element == StoredSpeakerProfile {
    /// displayName / タグの部分一致検索。空文字はそのまま返す。
    func matching(_ search: String) -> [StoredSpeakerProfile] {
        guard !search.isEmpty else { return self }
        return filter {
            $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }
}
```

`SpeakerProfileStore.profiles(matching:)`（L116-122）を委譲に:

```swift
    public func profiles(matching search: String) -> [StoredSpeakerProfile] {
        profiles.matching(search)
    }
```

`SettingsView.filteredProfiles`（L288-300）のインライン検索を置換:

```swift
    private var filteredProfiles: [StoredSpeakerProfile] {
        var result = viewModel.speakerProfiles
        if !selectedTags.isEmpty {
            result = result.filter { selectedTags.isSubset(of: $0.tags) }
        }
        return result.matching(searchText).sorted { $0.lastUsed > $1.lastUsed }
    }
```

- [ ] **Step 5: ビルド + テスト + Commit**

Run: `swift build --build-tests 2>&1 | tail -3 && swift test --filter QuickTranscriberTests 2>&1 | tail -3`
Expected: pass（SpeakerProfileStoreTests / TagTests が挙動を担保）

```bash
git add -A
git commit -m "refactor: ProfileStore の find-or-throw/JSON書き込み/検索フィルタを共通化"
```

---

### Task 6: 日付プレフィックス生成の共通化

**Files:**
- Modify: `Sources/QuickTranscriber/Services/TranscriptFileWriter.swift:48-55`
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift:663-665,884-886`

**Interfaces:**
- Produces: `TranscriptFileWriter.makeDatePrefix(for: Date = Date()) -> String`（形式 `yyyy-MM-dd_HHmm`）

- [ ] **Step 1: TranscriptFileWriter に static ヘルパーを追加**

```swift
    /// 文字起こし/録音ファイル名の共通プレフィックス（yyyy-MM-dd_HHmm）。
    private static let datePrefixFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return formatter
    }()

    public static func makeDatePrefix(for date: Date = Date()) -> String {
        datePrefixFormatter.string(from: date)
    }
```

`startSession` 内（L48-55）の else ブロックを置換:

```swift
        let prefix = datePrefix ?? Self.makeDatePrefix()
```

- [ ] **Step 2: VM の 2 箇所を置換**

`TranscriptionViewModel.swift` L663-665（`startRecording` 内）と L884-886（`beginFileTranscription` 内）の

```swift
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let datePrefix = formatter.string(from: Date())
```

をどちらも次に置換:

```swift
        let datePrefix = TranscriptFileWriter.makeDatePrefix()
```

- [ ] **Step 3: ビルド + テスト + Commit**

Run: `swift build --build-tests 2>&1 | tail -3 && swift test --filter QuickTranscriberTests 2>&1 | tail -3`
Expected: pass

```bash
git add -A
git commit -m "refactor: yyyy-MM-dd_HHmm フォーマッタを TranscriptFileWriter.makeDatePrefix に集約"
```

---

### Task 7: VADChunkAccumulator のリセット処理統合

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/ChunkAccumulator.swift:137-147,250-287`

- [ ] **Step 1: 共通ヘルパーを追加し 3 箇所を委譲**

private ヘルパーを追加:

```swift
    /// 発話単位の蓄積状態を初期化する（pendingPrecedingSilence は呼び出し側が管理）。
    private mutating func resetUtteranceState() {
        state = .idle
        speechBuffer.removeAll(keepingCapacity: true)
        preRollRing = RingBuffer(capacity: Int(preRollDuration * sampleRate))
        silenceDurationInIdle = 0
        trailingSilenceInSpeech = 0
        hangoverElapsed = 0
        netSpeechDuration = 0
        currentUtteranceId = ""
    }
```

`reset()`（L137-147）:

```swift
    /// Reset the accumulator, discarding all buffered audio.
    public mutating func reset() {
        resetUtteranceState()
        pendingPrecedingSilence = 0
    }
```

`emitChunk()`（L250-276）— 値のキャプチャ後にヘルパーを呼ぶ:

```swift
    private mutating func emitChunk() -> ChunkResult {
        let chunk = speechBuffer
        let trailing = trailingSilenceInSpeech
        let preceding = pendingPrecedingSilence
        // Use the id generated at VAD onset. If this is called from flush() without
        // a preceding onset (defensive), fall back to a fresh UUID.
        let utteranceId = currentUtteranceId.isEmpty ? UUID().uuidString : currentUtteranceId

        resetUtteranceState()
        // Carry over trailing silence as pending preceding for next chunk
        pendingPrecedingSilence = trailing

        return ChunkResult(
            samples: chunk,
            trailingSilenceDuration: trailing,
            precedingSilenceDuration: preceding,
            utteranceId: utteranceId
        )
    }
```

`transitionToIdle()`（L278-287）:

```swift
    private mutating func transitionToIdle() {
        resetUtteranceState()
    }
```

（`transitionToIdle` の呼び出し元は 3 箇所のみで全て private。委譲後は `transitionToIdle()` を削除して呼び出し元を `resetUtteranceState()` に直接置換してもよい — 実装者の判断でどちらでも可、ただし片方に統一すること）

- [ ] **Step 2: ビルド + テスト + Commit**

Run: `swift test --filter ChunkAccumulatorTests 2>&1 | tail -3 && swift test --filter QuickTranscriberTests 2>&1 | tail -3`
Expected: pass

```bash
git add -A
git commit -m "refactor: VAD accumulator のリセット処理を resetUtteranceState に統合"
```

---

### Task 8: VM の onStateChange クロージャ統合（applyIncomingState）

**Files:**
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift:704-753,901-923`

**Interfaces:**
- Produces: `TranscriptionViewModel.applyIncomingState(_ state: TranscriptionState, sessionSegments: [ConfirmedSegment])`（`@MainActor` private）

**挙動注記（PR 説明にも記載すること）:** 統合により file 転写経路にも「遡及話者変更→translationService.syncSpeakerMetadata」同期が入る。live 経路と同一の扱いへの統一で、従来 file 経路にだけ欠けていた同期の補完（翻訳無効時は no-op）。

- [ ] **Step 1: 共通メソッドを追加**

```swift
    /// エンジンからの状態更新を confirmedSegments / 話者 / 翻訳 / ファイルに反映する。
    /// live 録音と file 転写の両経路で共用。
    private func applyIncomingState(_ state: TranscriptionState, sessionSegments: [ConfirmedSegment]) {
        NSLog("[QuickTranscriber] State update - confirmed: \(state.confirmedText.count) chars, unconfirmed: \(state.unconfirmedText.count) chars")
        unconfirmedText = state.unconfirmedText
        // Derive segments from text if engine didn't provide them
        var stateSegments = state.confirmedSegments
        if stateSegments.isEmpty && !state.confirmedText.isEmpty {
            stateSegments = [ConfirmedSegment(text: state.confirmedText)]
        }
        let newSegments: [ConfirmedSegment]
        if sessionSegments.isEmpty {
            newSegments = stateSegments
        } else if stateSegments.isEmpty {
            newSegments = sessionSegments
        } else {
            newSegments = sessionSegments + stateSegments
        }
        // Snapshot speakers before merge for change detection
        let oldSpeakers = confirmedSegments.map { $0.speaker }

        confirmedSegments = Self.mergePreservingUserCorrections(
            existing: confirmedSegments,
            incoming: newSegments
        )

        // Detect retroactive speaker changes and propagate to translation
        let existingCount = min(oldSpeakers.count, confirmedSegments.count)
        var speakerChanged = false
        for i in 0..<existingCount where oldSpeakers[i] != confirmedSegments[i].speaker {
            speakerChanged = true
            break
        }
        if speakerChanged {
            translationService.syncSpeakerMetadata(from: confirmedSegments)
        }

        // Auto-detect new speakers from segments
        for segment in stateSegments {
            if let speakerId = segment.speaker {
                coordinator.addAutoDetectedSpeaker(speakerId: speakerId, embedding: segment.speakerEmbedding)
            }
        }

        syncSpeakerState()
        fileWriter.updateText(confirmedText)
    }
```

- [ ] **Step 2: live 経路（startRecording 内 L704-753）を置換**

`service.startTranscription(...)` の末尾クロージャを:

```swift
                ) { [weak self] state in
                    Task { @MainActor [weak self] in
                        self?.applyIncomingState(state, sessionSegments: sessionSegments)
                    }
                }
```

- [ ] **Step 3: file 経路（beginFileTranscription 内 L901-923）を置換**

`fileEngine.startStreaming(...)` の末尾クロージャを:

```swift
            ) { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.isTranscribingFile else { return }
                    self.applyIncomingState(state, sessionSegments: [])
                }
            }
```

- [ ] **Step 4: ビルド + テスト + Commit**

Run: `swift test --filter TranscriptionViewModelTests 2>&1 | tail -3 && swift test --filter QuickTranscriberTests 2>&1 | tail -3`
Expected: pass

```bash
git add -A
git commit -m "refactor: live/file の onStateChange 処理を applyIncomingState に統合"
```

---

### Task 9: checkNameUniqueness の内部重複解消

**Files:**
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift:368-432`

- [ ] **Step 1: sourceDisplayName を事前計算しヘルパーで置換**

`checkNameUniqueness` 全体を次に置き換え（ロジックは同一、`sourceDisplayName` の switch 重複 2 箇所を hoist、`SpeakerMergeRequest` 構築をローカル関数化）:

```swift
    public func checkNameUniqueness(newName: String, forEntity: SpeakerEntity) -> SpeakerMergeRequest? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let selfId: UUID
        let selfLinkedProfileId: UUID?
        let sourceDisplayName: String
        switch forEntity {
        case .active(let id):
            selfId = id
            let speaker = coordinator.activeSpeakers.first(where: { $0.id == id })
            selfLinkedProfileId = speaker?.speakerProfileId
            sourceDisplayName = speaker?.displayName ?? ""
        case .registered(let id):
            selfId = id
            selfLinkedProfileId = nil
            sourceDisplayName = speakerProfileStore.profiles.first(where: { $0.id == id })?.displayName ?? ""
        }

        func makeRequest(target: SpeakerEntity, targetDisplayName: String) -> SpeakerMergeRequest {
            SpeakerMergeRequest(
                sourceEntity: forEntity,
                targetEntity: target,
                duplicateName: trimmed,
                sourceDisplayName: sourceDisplayName,
                targetDisplayName: targetDisplayName
            )
        }

        // Check active speakers
        for speaker in coordinator.activeSpeakers {
            guard speaker.id != selfId else { continue }
            // Skip if this active speaker is the linked profile of self
            if let linkedId = selfLinkedProfileId, speaker.id == linkedId { continue }
            if let name = speaker.displayName, name.caseInsensitiveCompare(trimmed) == .orderedSame {
                return makeRequest(target: .active(id: speaker.id), targetDisplayName: speaker.displayName ?? "")
            }
        }

        // Check registered profiles
        for profile in speakerProfileStore.profiles {
            guard profile.id != selfId else { continue }
            // Skip if self is active and linked to this profile
            if let linkedId = selfLinkedProfileId, profile.id == linkedId { continue }
            // Skip if this profile is already represented by an active speaker we checked above
            if coordinator.activeSpeakers.contains(where: { $0.speakerProfileId == profile.id || $0.id == profile.id }) { continue }
            if profile.displayName.caseInsensitiveCompare(trimmed) == .orderedSame {
                return makeRequest(target: .registered(id: profile.id), targetDisplayName: profile.displayName)
            }
        }

        return nil
    }
```

- [ ] **Step 2: ビルド + テスト + Commit**

Run: `swift test --filter SpeakerMergeTests 2>&1 | tail -3 && swift test --filter QuickTranscriberTests 2>&1 | tail -3`
Expected: pass

```bash
git add -A
git commit -m "refactor: checkNameUniqueness の sourceDisplayName 重複と request 構築を整理"
```

---

### Task 10: ControlBarButton 部品化と SliderRow ジェネリック化

**Files:**
- Modify: `Sources/QuickTranscriber/Views/ControlBar.swift`
- Modify: `Sources/QuickTranscriber/Views/SettingsView.swift:828-875` + `DoubleSliderRow` 呼び出し箇所

- [ ] **Step 1: ControlBarButton を導入**

`ControlBar.swift` に private コンポーネントを追加し、4 ボタンを置換:

```swift
private struct ControlBarButton: View {
    let systemImage: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
            .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
```

`translateButton` / `copyAllButton` / `exportButton` / `clearButton` の 4 computed property を置換:

```swift
    private var translateButton: some View {
        ControlBarButton(systemImage: "translate", title: translationEnabled ? "Hide" : "Translate") {
            translationEnabled.toggle()
        }
        .keyboardShortcut("t", modifiers: .command)
    }

    private var copyAllButton: some View {
        ControlBarButton(systemImage: "doc.on.doc", title: "Copy", action: onCopyAll)
    }

    private var exportButton: some View {
        ControlBarButton(systemImage: "square.and.arrow.down", title: "Save", action: onExport)
    }

    private var clearButton: some View {
        ControlBarButton(systemImage: "trash", title: "Clear", action: onClear)
    }
```

**注意:** `.keyboardShortcut` をラッパー View に適用した場合の Cmd+T 動作は Task 13 の実機確認で検証する。効かない場合は `ControlBarButton` に `var shortcut: KeyboardShortcut? = nil` を追加して内部の `Button` に適用する形にフォールバック。

- [ ] **Step 2: SliderRow をジェネリック化し DoubleSliderRow を削除**

`SettingsView.swift` の `SliderRow`（L828-854）と `DoubleSliderRow`（L856-875）を単一のジェネリック実装に置換:

```swift
private struct SliderRow<V: BinaryFloatingPoint>: View {
    let label: String
    @Binding var value: V
    let range: ClosedRange<V>
    let step: V
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, Double(value)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = V($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
        }
    }
}
```

呼び出し箇所を更新:

```bash
grep -n "DoubleSliderRow(" Sources/QuickTranscriber/Views/SettingsView.swift
```

ヒットした各行の `DoubleSliderRow(` を `SliderRow(` に置換（引数はそのまま。型推論で `V = TimeInterval` / `V = Float` が決まる）。

- [ ] **Step 3: ビルド + テスト + Commit**

Run: `swift build --build-tests 2>&1 | tail -3 && swift test --filter QuickTranscriberTests 2>&1 | tail -3`
Expected: pass

```bash
git add -A
git commit -m "refactor: ControlBar ボタンを部品化し SliderRow をジェネリック統合"
```

---

### Task 11: テキストビュー配管の共通化（TranscriptTextViewSupport）

**Files:**
- Create: `Sources/QuickTranscriber/Views/TranscriptTextViewSupport.swift`
- Modify: `Sources/QuickTranscriber/Views/TranscriptionTextView.swift:183-210,509-575`
- Modify: `Sources/QuickTranscriber/Views/TranslationTextView.swift`

**Interfaces:**
- Produces:
  - `TranscriptTextViewSupport.makeScrollView(wrapping textView: NSTextView) -> NSScrollView`
  - `TranscriptTextViewSupport.applyDiffAppendOrReplace(_ attributed: NSAttributedString, to textView: NSTextView, canDiffAppend: Bool)`
  - `TranscriptTextViewSupport.isScrolledToBottom(_ scrollView: NSScrollView?) -> Bool`

**背景:** `TranslationTextView.makeNSView` は `TranscriptionTextView.makeNSView` と逐語一致。diff-append/選択復元/最下部判定も同一実装が 2 セット存在する。canDiffAppend の判定条件は 2 ビューで異なるため**判定は各呼び出し側に残し**、適用処理のみ共通化する。

- [ ] **Step 1: 共通ヘルパーを作成**

`Sources/QuickTranscriber/Views/TranscriptTextViewSupport.swift`:

```swift
import AppKit

/// TranscriptionTextView / TranslationTextView が共用する NSTextView 配管。
enum TranscriptTextViewSupport {
    /// 標準のトランスクリプト表示用 scroll view + text view を構成する。
    static func makeScrollView(wrapping textView: NSTextView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        return scrollView
    }

    /// canDiffAppend のとき末尾差分のみ append、それ以外は選択範囲を保って全置換する。
    static func applyDiffAppendOrReplace(
        _ attributed: NSAttributedString,
        to textView: NSTextView,
        canDiffAppend: Bool
    ) {
        guard let textStorage = textView.textStorage else { return }
        if canDiffAppend {
            let deltaStart = (textStorage.string as NSString).length
            let deltaRange = NSRange(location: deltaStart, length: attributed.length - deltaStart)
            textStorage.append(attributed.attributedSubstring(from: deltaRange))
        } else {
            let savedRange = textView.selectedRange()
            let hadSelection = savedRange.length > 0
            textStorage.setAttributedString(attributed)
            if hadSelection && NSMaxRange(savedRange) <= textStorage.length {
                textView.setSelectedRange(savedRange)
            }
        }
    }

    static func isScrolledToBottom(_ scrollView: NSScrollView?) -> Bool {
        guard let scrollView, let documentView = scrollView.documentView else { return true }
        let threshold: CGFloat = 50
        return scrollView.contentView.bounds.maxY >= documentView.frame.height - threshold
    }
}
```

- [ ] **Step 2: TranscriptionTextView を委譲**

1. `makeNSView`（L183-210）を置換:

```swift
    func makeNSView(context: Context) -> NSScrollView {
        let textView = InteractiveTranscriptionTextView()
        let scrollView = TranscriptTextViewSupport.makeScrollView(wrapping: textView)
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        return scrollView
    }
```

2. `Coordinator.applySegmentUpdate` 内の diff-append/全置換ブロック（L540-561、`let newText = attributed.string` から末尾まで）を置換:

```swift
            let newText = attributed.string
            let currentText = textView.textStorage?.string ?? ""

            let canDiffAppend = fontSize == oldFontSize
                && unconfirmed.isEmpty
                && oldUnconfirmed.isEmpty
                && !currentText.isEmpty
                && newText.hasPrefix(currentText)
                && newText.count > currentText.count

            TranscriptTextViewSupport.applyDiffAppendOrReplace(attributed, to: textView, canDiffAppend: canDiffAppend)
```

3. `Coordinator.isScrolledToBottom`（L564-573）を委譲:

```swift
        func isScrolledToBottom() -> Bool {
            TranscriptTextViewSupport.isScrolledToBottom(scrollView)
        }
```

（`updateNSView` L257-282 の「segments が空」の分岐は plain-string diff のため対象外。そのまま残す）

- [ ] **Step 3: TranslationTextView を委譲**

1. `makeNSView`（L15-42）を置換:

```swift
    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        let scrollView = TranscriptTextViewSupport.makeScrollView(wrapping: textView)
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        return scrollView
    }
```

2. `updateNSView` 内の適用ブロック（L61-80）を置換:

```swift
        let newText = attributed.string
        let currentText = textStorage.string

        let canDiffAppend = fontSize == coordinator.lastFontSize
            && !currentText.isEmpty
            && newText.hasPrefix(currentText)
            && newText.count > currentText.count

        TranscriptTextViewSupport.applyDiffAppendOrReplace(attributed, to: textView, canDiffAppend: canDiffAppend)
```

3. `Coordinator.isScrolledToBottom`（L96-105）を委譲:

```swift
        func isScrolledToBottom() -> Bool {
            TranscriptTextViewSupport.isScrolledToBottom(scrollView)
        }
```

- [ ] **Step 4: ビルド + テスト + Commit**

Run: `swift build --build-tests 2>&1 | tail -3 && swift test --filter QuickTranscriberTests 2>&1 | tail -3`
Expected: pass

```bash
git add -A
git commit -m "refactor: TextView の NSViewRepresentable 配管を TranscriptTextViewSupport に共通化"
```

---

### Task 12: 文末文字セットを Constants 参照に統一

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/TranscriptionUtils.swift:156-157`
- Modify: `Sources/QuickTranscriber/Views/TranscriptionTextView.swift:368-369`

- [ ] **Step 1: 2 箇所のハードコードを置換**

両ファイルの

```swift
        let sentenceEnders: Set<Character> = (language == "ja")
            ? ["。", "！", "？"] : [".", "!", "?"]
```

を次に置換:

```swift
        let sentenceEnders: Set<Character> = (language == "ja")
            ? Constants.Translation.sentenceEndersJA : Constants.Translation.sentenceEndersEN
```

- [ ] **Step 2: ビルド + テスト + Commit**

Run: `swift test --filter TranscriptionUtilsTests 2>&1 | tail -3 && swift test --filter QuickTranscriberTests 2>&1 | tail -3`
Expected: pass

```bash
git add -A
git commit -m "refactor: 文末文字セットを Constants.Translation 参照に統一"
```

---

### Task 13: 最終検証と PR 作成

**Files:**
- Modify: `Sources/QuickTranscriber/Constants.swift:61`（PR 番号確定後）

- [ ] **Step 1: 全テストスイート実行**

Run: `swift build --build-tests 2>&1 | tail -3 && swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: `Test Suite 'All tests' passed`、failure 0

- [ ] **Step 2: 実機スモーク確認（verification-before-completion）**

```bash
swift run QuickTranscriber
```

確認項目:
1. ライブ録音を開始→数発話→停止（文字起こし表示・話者ラベル・ファイル出力が従来どおり）
2. ControlBar: Copy / Save / Clear / Translate の各ボタン動作、**Cmd+T** で翻訳トグル（Task 10 の注意点）
3. Settings → Speakers タブ: 検索フィールドとタグフィルタ（Task 5）、スライダー操作（Task 10）
4. 翻訳ペイン表示時のスクロール追従（Task 11）
5. ファイル転写: 音声ファイルをドロップ → 転写完了まで正常動作。翻訳 ON の場合、遡及的な話者変更が翻訳ペインにも同期される（本 PR 唯一の意図的挙動変更の確認）

- [ ] **Step 3: push と PR 作成**

```bash
git push -u origin refactor/simplification-pr-a
gh pr create --title "refactor: 局所リファクタリング — デッドコード削除 + 重複統合" --body "$(cat <<'EOF'
## Summary
- スペック: docs/superpowers/specs/2026-07-02-simplification-refactoring-design.md (Part A)
- デッドコード削除: ProfileStrategy 機構（本番常に .none）/ updateAlpha / SpeakerLabelTracker typealias / cleanup() チェーン（本番呼び出しゼロ + fire-and-forget Task の危険源）
- 重複統合: EmbeddingMath（cosine/weightedMean/blend ×8箇所）/ ProfileStore requireIndex ×6 / JSON 書き込み ×3 / 日付プレフィックス ×3 / VAD リセット ×3 / VM onStateChange live+file / checkNameUniqueness / ControlBarButton ×4 / SliderRow 統合 / TextView 配管 ×2ビュー / 文末文字セット

## 挙動注記
- file 転写経路に live と同じ「遡及話者変更→翻訳メタデータ同期」が入る（従来は live のみ。翻訳無効時は no-op）
- 上記以外は挙動不変（既存 ~19k 行のテストスイートで検証）

## Test plan
- [x] swift test --filter QuickTranscriberTests 全パス
- [x] swift build --build-tests（ベンチマークターゲット含めコンパイル確認）
- [x] 実機スモーク: ライブ録音 / ControlBar / Settings 検索・スライダー / Cmd+T

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: PR 番号でバージョン更新**

PR 番号（`gh pr view --json number` で確認）を `Constants.swift:61` の `patch` に設定:

```swift
        public static let patch = <PR番号>
```

```bash
git add Sources/QuickTranscriber/Constants.swift
git commit -m "chore: bump version to v2.4.<PR番号>"
git push
```

---

## Self-Review 記録

- **Spec coverage:** スペック Part A の A-1 #1-4 → Task 1/2/3、A-2 #5-16 → Task 4-12。`currentConfirmedSegments`/`markSegmentAsUserCorrected` の存続、`StoredSpeakerProfile` デコーダの除外もスペックどおり。
- **Placeholder scan:** 全ステップに実コード/実コマンドあり。Task 13 の `<PR番号>` のみ実行時確定値。
- **Type consistency:** `EmbeddingMath.weightedMean` のタプルラベル `(embedding:weight:)` を全呼び出しで統一。`TranscriptTextViewSupport` の 3 メソッドシグネチャは Task 11 内で一貫。
