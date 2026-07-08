# PR-B3: ChunkedWhisperEngine actor 化 + SessionLearningFinalizer 抽出 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ChunkedWhisperEngine` を actor に変換して全可変状態をコンパイラ保証で直列化し（`smootherLock` 削除）、stopStreaming 内の事後学習約 70 行を `SessionLearningFinalizer` として抽出、`drainOnStop` フラグを stop 引数化、ホットパスの NSLog をチャンク毎 1 行に集約する。

**Architecture:** spec（`docs/superpowers/specs/2026-07-02-simplification-refactoring-design.md` Part B3）の案 3a。プロトコルの speaker 系 3 メソッド（`correctSpeakerAssignment` / `mergeSpeakerProfiles` / `syncViterbiConfirm`）を async 化し、`TranscriptionService` に直列転送チェーンを導入する。`SpeakerStateCoordinator` と VM の呼び出しコードは無変更。

**Tech Stack:** Swift 6 toolchain / language mode v5（`Package.swift` の `.swiftLanguageMode(.v5)` は変更しない。strict concurrency 化はスコープ外）、XCTest。

## spec からの意図的な逸脱（2 点）

1. **`drainOnStop` の置き換え先は `startStreaming` パラメータではなく `stopStreaming(speakerDisplayNames:drainRemaining:)` 引数**。
   理由: `cancelFileTranscription`（`TranscriptionViewModel.swift:930`）は file モードでも**即時**停止が必要。開始時に `.drainRemaining` を固定すると、キャンセルがファイル全量の処理完了を待ってしまう。stop 時引数なら「finish=drain / cancel=即時」の両方を表現でき、spec の目的（呼び出し順序依存の除去）も達成される。
2. **Coordinator を await 化せず、`TranscriptionService` 内の直列タスクチェーンで橋渡しする**。
   理由: `SpeakerStateCoordinator.reassignSegment(at:to:segments:)` は `inout [ConfirmedSegment]` を取る同期関数で、Swift は async 関数の inout パラメータを禁止しているため await 化できない（B2 の状態所有権解消なしには変えられない）。Service 内のチェーン（`engineSyncTask`）は (a) coordinator/VM の呼び出しコードを無変更に保ち、(b) 発行順の FIFO を保証し（素の fire-and-forget Task には順序保証がない）、(c) テストが `await service.engineSyncTask?.value` で転送完了に同期できる。

## Global Constraints

- バージョン: `Constants.Version.patch` を次の PR 番号（89 想定、Task 7 で確認）に更新。**PR のコミット内でのみ**変更する
- テストゲート: `swift test --filter QuickTranscriberTests` で **`ManualModeStabilityTests.testCorrection_trustedLearningReducesFutureMisidentification` 以外の失敗ゼロ**（この 1 件は main 由来の既知の失敗。本 PR とは無関係、触らない）
- テスト実行には Xcode が必要（Command Line Tools のみでは不可）
- ファイル削除は `trash` を使う（`rm` 禁止。このマシンでは rm は trash の alias）
- macOS GUI アプリでは `print()` が出ない。デバッグは `NSLog`
- 作業ブランチ: `refactor/simplification-pr-b1` の慣例に倣い `refactor/simplification-pr-b3`（実行時に superpowers:using-git-worktrees で worktree を作成）
- コミットは各タスク末尾で 1 回。メッセージは各タスクに記載

## File Structure

| 操作 | ファイル | 責務 |
|---|---|---|
| Create | `Sources/QuickTranscriber/Engines/SessionLearningFinalizer.swift` | stop 時の事後学習（manual post-hoc / auto merge）+ embedding history 保存。音声パイプライン非依存 |
| Create | `Tests/QuickTranscriberTests/SessionLearningFinalizerTests.swift` | PostHocLearningTests の移植 6 件 + auto merge / history 直接テスト 3 件 |
| Delete | `Tests/QuickTranscriberTests/PostHocLearningTests.swift` | finalizer 直接テストに置換 |
| Modify | `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift` | class→actor、smootherLock 削除、drainOnStop 引数化、finalizer 委譲、NSLog 集約 |
| Modify | `Sources/QuickTranscriber/Engines/TranscriptionEngine.swift` | speaker 系 3 メソッド async 化、プロトコルに Sendable 追加（Task 4） |
| Modify | `Sources/QuickTranscriber/Services/TranscriptionService.swift` | 直列転送チェーン `engineSyncTask` 導入 |
| Modify | `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift` | `finishFileTranscription` の drain 呼び出し + テスト用 join seam |
| Modify | `Sources/QuickTranscriber/Constants.swift` | version patch → 89 |
| Modify | `Tests/QuickTranscriberTests/Mocks/MockTranscriptionEngine.swift` | callOrder 記録 + `@unchecked Sendable` |
| Modify | `Tests/QuickTranscriberTests/{TranscriptionServiceTests,SpeakerStateCoordinatorTests,TranscriptionViewModelTests,ChunkedWhisperEngineTests,RetroactiveUpdateGuardTests}.swift` | await 適応 + チェーン join |
| **無変更** | `Sources/QuickTranscriber/Models/SpeakerStateCoordinator.swift` | 呼び出しは同期のまま（逸脱 2 参照） |

---

### Task 1: SessionLearningFinalizer 抽出

**Files:**
- Create: `Sources/QuickTranscriber/Engines/SessionLearningFinalizer.swift`
- Create: `Tests/QuickTranscriberTests/SessionLearningFinalizerTests.swift`
- Delete: `Tests/QuickTranscriberTests/PostHocLearningTests.swift`
- Modify: `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift:189-263`（stopStreaming 後半）, `:280-330`（applyManualModePostHocLearning + DEBUG フック削除）

**Interfaces:**
- Consumes: `SpeakerProfileStore.applyPostHocLearning(speakerId:sessionCentroid:alpha:)` / `.mergeSessionProfiles(_:)` / `.save()`、`EmbeddingHistoryStore.appendSession(entries:)` / `.loadAll()`、`EmbeddingMath.weightedMean`、`Constants.Embedding.*`、`WeightedEmbedding(entryId:embedding:confidence:)`
- Produces: `struct SessionLearningFinalizer`（internal）:
  - `init(profileStore: SpeakerProfileStore?, embeddingHistoryStore: EmbeddingHistoryStore?)`（memberwise）
  - `func finalize(mode: DiarizationMode, participantIds: Set<UUID>, segments: [ConfirmedSegment], speakerDisplayNames: [String: String], sessionProfiles: [(speakerId: UUID, embedding: [Float])], detailedProfiles: [(speakerId: UUID, embedding: [Float], embeddingHistory: [WeightedEmbedding])])`
  - `func applyManualModePostHocLearning(participantIds: Set<UUID>, segments: [ConfirmedSegment])`（テストが直接呼ぶ）

**挙動保存の注記:** 現行 engine では `exportSpeakerProfiles()` は auto 分岐でのみ、`exportDetailedSpeakerProfiles()` は historyStore 存在時のみ呼ばれるが、移行後は `diarizer != nil && diarizationActive` で常に呼ぶ。両方とも tracker の純粋読み取りで副作用がないため挙動不変（`MockSpeakerDiarizer` も stored 配列を返すだけ）。NSLog プレフィックスは `[SessionLearningFinalizer]` に変わる。

- [ ] **Step 1: テストファイルを書く（red）**

`Tests/QuickTranscriberTests/SessionLearningFinalizerTests.swift` を以下の内容で作成。前半 6 件は `PostHocLearningTests.swift` の移植（engine 構築 → finalizer 構築、`engine.applyManualModePostHocLearningForTesting(store:participantIds:segments:)` → `finalizer.applyManualModePostHocLearning(participantIds:segments:)` の機械置換。期待値・コメントは原文のまま維持）。後半 3 件が新規。

```swift
import XCTest
@testable import QuickTranscriberLib

final class SessionLearningFinalizerTests: XCTestCase {

    private func makeEmbedding(dominant dim: Int, dimensions: Int = 4) -> [Float] {
        var v = [Float](repeating: 0.01, count: dimensions)
        v[dim] = 1.0
        return v
    }

    private func makeStore() -> SpeakerProfileStore {
        SpeakerProfileStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLearningFinalizerTests-\(UUID().uuidString)"))
    }

    private func makeFinalizer(store: SpeakerProfileStore?) -> SessionLearningFinalizer {
        SessionLearningFinalizer(profileStore: store, embeddingHistoryStore: nil)
    }

    // MARK: - Manual mode post-hoc learning（PostHocLearningTests から移植）

    func testPostHocLearning_updatesProfileFromAllQualifyingSegments() {
        let store = makeStore()
        let idA = UUID()
        let idB = UUID()
        let initialA = makeEmbedding(dominant: 0)
        let initialB = makeEmbedding(dominant: 1)
        store.profiles.append(StoredSpeakerProfile(id: idA, displayName: "A", embedding: initialA))
        store.profiles.append(StoredSpeakerProfile(id: idB, displayName: "B", embedding: initialB))

        let sessionEmb = makeEmbedding(dominant: 2)
        let correctedEmb = makeEmbedding(dominant: 3)
        let segments: [ConfirmedSegment] = [
            ConfirmedSegment(text: "s1", speaker: idA.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "s2", speaker: idA.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "s3", speaker: idA.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "s4", speaker: idA.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "s5", speaker: idA.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            // User-corrected segment: a trusted ground-truth sample for idA.
            // Under the new design this is INCLUDED in post-hoc learning.
            ConfirmedSegment(text: "sc", speaker: idA.uuidString, speakerConfidence: 1.0, isUserCorrected: true, originalSpeaker: idB.uuidString, speakerEmbedding: correctedEmb),
            // B has only 2 samples → below MIN_SAMPLES (3), skipped
            ConfirmedSegment(text: "b1", speaker: idB.uuidString, speakerConfidence: 0.8, speakerEmbedding: makeEmbedding(dominant: 1)),
            ConfirmedSegment(text: "b2", speaker: idB.uuidString, speakerConfidence: 0.8, speakerEmbedding: makeEmbedding(dominant: 1))
        ]

        makeFinalizer(store: store).applyManualModePostHocLearning(
            participantIds: [idA, idB],
            segments: segments
        )

        // A has 6 qualifying samples (5 non-corrected with sessionEmb + 1 corrected with correctedEmb)
        // centroid = (5 * sessionEmb + 1 * correctedEmb) / 6
        // α = min(0.2, 6/50) = 0.12
        let dims = initialA.count
        var centroid = [Float](repeating: 0, count: dims)
        for i in 0..<dims {
            centroid[i] = (5 * sessionEmb[i] + 1 * correctedEmb[i]) / 6
        }
        let updatedA = store.profiles.first(where: { $0.id == idA })!
        let alpha: Float = 0.12
        let expectedA: [Float] = zip(initialA, centroid).map { (1 - alpha) * $0 + alpha * $1 }
        for (e, u) in zip(expectedA, updatedA.embedding) {
            XCTAssertEqual(e, u, accuracy: 1e-5)
        }

        // B has only 2 samples → unchanged
        let updatedB = store.profiles.first(where: { $0.id == idB })!
        XCTAssertEqual(updatedB.embedding, initialB)
    }

    func testPostHocLearning_includesUserCorrectedSegments() {
        // Regression guard for the "manual label is trusted truth" design:
        // corrected segments alone must be enough to drive post-hoc learning,
        // even when the auto-labeled sample count is below MIN_SAMPLES.
        let store = makeStore()
        let id = UUID()
        let initial = makeEmbedding(dominant: 0)
        store.profiles.append(StoredSpeakerProfile(id: id, displayName: "A", embedding: initial))

        let sessionEmb = makeEmbedding(dominant: 1)
        // 1 non-corrected + 2 user-corrected = 3 total (meets MIN_SAMPLES only if corrected are counted).
        let segs: [ConfirmedSegment] = [
            ConfirmedSegment(text: "auto", speaker: id.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "cor1", speaker: id.uuidString, speakerConfidence: 1.0, isUserCorrected: true, originalSpeaker: UUID().uuidString, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "cor2", speaker: id.uuidString, speakerConfidence: 1.0, isUserCorrected: true, originalSpeaker: UUID().uuidString, speakerEmbedding: sessionEmb)
        ]

        makeFinalizer(store: store).applyManualModePostHocLearning(
            participantIds: [id],
            segments: segs
        )

        // 3 samples, all with sessionEmb → centroid = sessionEmb; α = min(0.2, 3/50) = 0.06
        let alpha: Float = 0.06
        let expected = zip(initial, sessionEmb).map { (1 - alpha) * $0 + alpha * $1 }
        let updated = store.profiles.first!
        XCTAssertNotEqual(updated.embedding, initial,
            "corrected segments must contribute to post-hoc learning even when non-corrected samples are below MIN_SAMPLES alone")
        for (e, u) in zip(expected, updated.embedding) {
            XCTAssertEqual(e, u, accuracy: 1e-5)
        }
    }

    func testPostHocLearning_skipsLockedProfile() {
        let store = makeStore()
        let id = UUID()
        var profile = StoredSpeakerProfile(id: id, displayName: "Locked", embedding: makeEmbedding(dominant: 0))
        profile.isLocked = true
        store.profiles.append(profile)

        var segs = [ConfirmedSegment]()
        for _ in 0..<10 {
            segs.append(ConfirmedSegment(text: "x", speaker: id.uuidString, speakerConfidence: 0.9, speakerEmbedding: makeEmbedding(dominant: 2)))
        }

        makeFinalizer(store: store).applyManualModePostHocLearning(
            participantIds: [id],
            segments: segs
        )

        let updated = store.profiles.first!
        XCTAssertEqual(updated.embedding, makeEmbedding(dominant: 0),
            "locked profile should not be updated")
    }

    func testPostHocLearning_alphaScalesWithSampleCount() {
        let store = makeStore()
        let id = UUID()
        let initial = makeEmbedding(dominant: 0)
        store.profiles.append(StoredSpeakerProfile(id: id, displayName: "A", embedding: initial))

        let sessionEmb = makeEmbedding(dominant: 1)
        // 60 サンプル → α = min(0.2, 60/50) = 0.2 (上限)
        var segs = [ConfirmedSegment]()
        for _ in 0..<60 {
            segs.append(ConfirmedSegment(text: "x", speaker: id.uuidString, speakerConfidence: 0.9, speakerEmbedding: sessionEmb))
        }

        makeFinalizer(store: store).applyManualModePostHocLearning(
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
        let store = makeStore()
        let id = UUID()
        let initial = makeEmbedding(dominant: 0)
        store.profiles.append(StoredSpeakerProfile(id: id, displayName: "A", embedding: initial))

        let sessionEmb = makeEmbedding(dominant: 1)
        // 3 サンプル、うち 2 個は confidence が閾値未満
        let segs: [ConfirmedSegment] = [
            ConfirmedSegment(text: "ok", speaker: id.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "low", speaker: id.uuidString, speakerConfidence: 0.3, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "low2", speaker: id.uuidString, speakerConfidence: 0.2, speakerEmbedding: sessionEmb)
        ]

        makeFinalizer(store: store).applyManualModePostHocLearning(
            participantIds: [id],
            segments: segs
        )

        // 有効サンプル 1 個 → MIN_SAMPLES (3) 未満なのでスキップ
        let updated = store.profiles.first!
        XCTAssertEqual(updated.embedding, initial, "should skip when too few high-confidence samples")
    }

    func testCentroid_skipsDimensionMismatchCorrectly() {
        let store = makeStore()
        let id = UUID()
        let initial: [Float] = [1.0, 0.0, 0.0, 0.0]
        store.profiles.append(StoredSpeakerProfile(id: id, displayName: "A", embedding: initial))

        // 3 normal + 1 wrong-dim → wrong-dim is skipped
        let good: [Float] = [0.0, 1.0, 0.0, 0.0]
        let wrongDim: [Float] = [0.0, 1.0]
        let segs: [ConfirmedSegment] = [
            ConfirmedSegment(text: "s1", speaker: id.uuidString, speakerConfidence: 0.8, speakerEmbedding: good),
            ConfirmedSegment(text: "s2", speaker: id.uuidString, speakerConfidence: 0.8, speakerEmbedding: good),
            ConfirmedSegment(text: "s3", speaker: id.uuidString, speakerConfidence: 0.8, speakerEmbedding: good),
            ConfirmedSegment(text: "bad", speaker: id.uuidString, speakerConfidence: 0.8, speakerEmbedding: wrongDim)
        ]

        makeFinalizer(store: store).applyManualModePostHocLearning(
            participantIds: [id],
            segments: segs
        )

        // centroid of 3 good samples = [0,1,0,0], α = min(0.2, 4/50) = 0.08
        // (note: 4 segments pass confidence/embedding filter, but only 3 have correct dimension)
        // expected = 0.92*[1,0,0,0] + 0.08*[0,1,0,0] = [0.92, 0.08, 0, 0]
        let updated = store.profiles.first!
        XCTAssertEqual(updated.embedding[0], 0.92, accuracy: 1e-5)
        XCTAssertEqual(updated.embedding[1], 0.08, accuracy: 1e-5)
    }

    // MARK: - Auto mode merge（新規: 移植ロジックの直接テスト）

    func testAutoMerge_skipsProfilesCorrectedAway() {
        // 修正で「元話者」となった session profile は store にマージしない
        // （誤認識だった声のプロファイル汚染を防ぐ既存挙動の直接テスト）
        let store = makeStore()
        let sessionSpeaker = UUID()
        let segments: [ConfirmedSegment] = [
            ConfirmedSegment(text: "x", speaker: UUID().uuidString, speakerConfidence: 1.0,
                             isUserCorrected: true, originalSpeaker: sessionSpeaker.uuidString)
        ]

        makeFinalizer(store: store).finalize(
            mode: .auto,
            participantIds: [],
            segments: segments,
            speakerDisplayNames: [sessionSpeaker.uuidString: "Alice"],
            sessionProfiles: [(speakerId: sessionSpeaker, embedding: makeEmbedding(dominant: 0))],
            detailedProfiles: []
        )

        XCTAssertTrue(store.profiles.isEmpty,
            "corrected-away session speaker must not be merged into the store")
    }

    func testAutoMerge_skipsUnmappedProfilesAndMergesMapped() {
        // displayName マッピングのない profile はスキップ、あるものだけマージ
        let store = makeStore()
        let mapped = UUID()
        let unmapped = UUID()

        makeFinalizer(store: store).finalize(
            mode: .auto,
            participantIds: [],
            segments: [],
            speakerDisplayNames: [mapped.uuidString: "Alice"],
            sessionProfiles: [
                (speakerId: mapped, embedding: makeEmbedding(dominant: 0)),
                (speakerId: unmapped, embedding: makeEmbedding(dominant: 1))
            ],
            detailedProfiles: []
        )

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].id, mapped)
        XCTAssertEqual(store.profiles[0].displayName, "Alice")
    }

    // MARK: - Embedding history（新規: 移植ロジックの直接テスト）

    func testFinalize_savesEmbeddingHistorySkippingEmptyHistories() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLearningFinalizerTests-\(UUID().uuidString)")
        let historyStore = EmbeddingHistoryStore(directory: dir)
        let finalizer = SessionLearningFinalizer(profileStore: nil, embeddingHistoryStore: historyStore)
        let withHistory = UUID()
        let withoutHistory = UUID()

        finalizer.finalize(
            mode: .auto,
            participantIds: [],
            segments: [],
            speakerDisplayNames: [:],
            sessionProfiles: [],
            detailedProfiles: [
                (speakerId: withHistory, embedding: [1, 0],
                 embeddingHistory: [WeightedEmbedding(embedding: [1, 0], confidence: 0.9)]),
                (speakerId: withoutHistory, embedding: [0, 1], embeddingHistory: [])
            ]
        )

        let entries = try historyStore.loadAll()
        XCTAssertEqual(entries.count, 1, "empty-history profiles must be skipped")
        XCTAssertEqual(entries[0].speakerProfileId, withHistory)
        XCTAssertEqual(entries[0].label, withHistory.uuidString)
        XCTAssertEqual(entries[0].embeddings.map(\.embedding), [[1, 0]])
        XCTAssertEqual(entries[0].embeddings[0].confidence, 0.9)
    }
}
```

- [ ] **Step 2: red を確認**

Run: `swift test --filter SessionLearningFinalizerTests 2>&1 | tail -5`
Expected: コンパイルエラー `cannot find 'SessionLearningFinalizer' in scope`

- [ ] **Step 3: SessionLearningFinalizer を実装（ChunkedWhisperEngine からの移設）**

`Sources/QuickTranscriber/Engines/SessionLearningFinalizer.swift` を作成:

```swift
import Foundation

/// stopStreaming 時のセッション事後学習を engine から独立して実行する。
/// manual モードの post-hoc 学習 / auto モードの session profile マージ /
/// embedding history 保存の 3 責務を持ち、音声パイプラインなしで単体テストできる。
struct SessionLearningFinalizer {
    let profileStore: SpeakerProfileStore?
    let embeddingHistoryStore: EmbeddingHistoryStore?

    /// diarizer から export 済みの値を受け取り、セッション終了時の学習一式を実行する。
    func finalize(
        mode: DiarizationMode,
        participantIds: Set<UUID>,
        segments: [ConfirmedSegment],
        speakerDisplayNames: [String: String],
        sessionProfiles: [(speakerId: UUID, embedding: [Float])],
        detailedProfiles: [(speakerId: UUID, embedding: [Float], embeddingHistory: [WeightedEmbedding])]
    ) {
        if let store = profileStore {
            if mode == .manual && !participantIds.isEmpty {
                // Manual mode: confirmedSegments の非修正サンプルから weighted merge
                applyManualModePostHocLearning(participantIds: participantIds, segments: segments)
                do {
                    try store.save()
                } catch {
                    NSLog("[SessionLearningFinalizer] Failed to save after post-hoc learning: \(error)")
                }
            } else {
                // Auto mode: 従来どおり tracker profile を merge
                mergeAutoModeSessionProfiles(
                    store: store,
                    sessionProfiles: sessionProfiles,
                    segments: segments,
                    speakerDisplayNames: speakerDisplayNames
                )
            }
        }
        saveEmbeddingHistory(detailedProfiles: detailedProfiles)
    }

    /// Manual mode の post-hoc 学習を実行する。
    /// Tracker 側は session 中、auto 判定の混入を避けるため centroid を控えめに扱い、
    /// 手動訂正は信頼サンプルとして扱う。session 終了時にはその両方を集めて
    /// store 側 profile centroid を緩やかに更新する。
    ///
    /// 前提: user がラベルを付け替えた segment は「現時点の正解」。ラベルを
    /// 付け替えていない segment は auto 推定の結果にすぎず、ground truth とは
    /// 見なさない（user が監視役ではないため）。高 confidence フィルタだけに
    /// 頼り、修正 / 非修正で区別はしない。
    func applyManualModePostHocLearning(
        participantIds: Set<UUID>,
        segments: [ConfirmedSegment]
    ) {
        guard let store = profileStore else { return }
        for participantId in participantIds {
            let samples = segments.filter { seg in
                seg.speaker == participantId.uuidString
                    && (seg.speakerConfidence ?? 0) >= Constants.Embedding.similarityThreshold
                    && seg.speakerEmbedding != nil
            }

            guard samples.count >= Constants.Embedding.sessionLearningMinSamples else { continue }
            guard let existing = store.profiles.first(where: { $0.id == participantId }),
                  !existing.isLocked else { continue }

            let embeddings = samples.compactMap { $0.speakerEmbedding }
            guard let centroid = EmbeddingMath.weightedMean(embeddings.map { (embedding: $0, weight: 1.0) }) else { continue }

            let alpha = min(
                Constants.Embedding.sessionLearningAlphaMax,
                Float(samples.count) / Float(Constants.Embedding.sessionLearningSamplesForMaxAlpha)
            )
            store.applyPostHocLearning(
                speakerId: participantId,
                sessionCentroid: centroid,
                alpha: alpha
            )
            NSLog("[SessionLearningFinalizer] Post-hoc learning for \(participantId): \(samples.count) samples, alpha=\(alpha)")
        }
    }

    private func mergeAutoModeSessionProfiles(
        store: SpeakerProfileStore,
        sessionProfiles: [(speakerId: UUID, embedding: [Float])],
        segments: [ConfirmedSegment],
        speakerDisplayNames: [String: String]
    ) {
        guard !sessionProfiles.isEmpty else { return }
        let correctedOriginalSpeakers = Set(
            segments
                .filter { $0.isUserCorrected }
                .compactMap { $0.originalSpeaker }
        )
        let filteredProfiles: [(speakerId: UUID, embedding: [Float])]
        if correctedOriginalSpeakers.isEmpty {
            filteredProfiles = sessionProfiles
        } else {
            filteredProfiles = sessionProfiles.filter { !correctedOriginalSpeakers.contains($0.speakerId.uuidString) }
            NSLog("[SessionLearningFinalizer] Skipping merge for corrected speakers: \(correctedOriginalSpeakers)")
        }
        guard !filteredProfiles.isEmpty else { return }
        let mergeProfiles = filteredProfiles.compactMap { profile
            -> (speakerId: UUID, embedding: [Float], displayName: String)? in
            guard let name = speakerDisplayNames[profile.speakerId.uuidString] else {
                NSLog("[SessionLearningFinalizer] Skipping unmapped profile \(profile.speakerId)")
                return nil
            }
            return (speakerId: profile.speakerId, embedding: profile.embedding, displayName: name)
        }
        guard !mergeProfiles.isEmpty else { return }
        store.mergeSessionProfiles(mergeProfiles)
        do {
            try store.save()
        } catch {
            NSLog("[SessionLearningFinalizer] Failed to save speaker profiles: \(error)")
        }
        NSLog("[SessionLearningFinalizer] Saved \(mergeProfiles.count) speaker profiles to store (filtered \(sessionProfiles.count - mergeProfiles.count))")
    }

    /// Save embedding history for future profile reconstruction
    private func saveEmbeddingHistory(
        detailedProfiles: [(speakerId: UUID, embedding: [Float], embeddingHistory: [WeightedEmbedding])]
    ) {
        guard let historyStore = embeddingHistoryStore else { return }
        let entries = detailedProfiles.compactMap { profile -> EmbeddingHistoryEntry? in
            guard !profile.embeddingHistory.isEmpty else { return nil }
            // Match with stored profile to get UUID
            let storedProfile = profileStore?.profiles.first { $0.id == profile.speakerId }
            let profileId = storedProfile?.id ?? profile.speakerId
            return EmbeddingHistoryEntry(
                speakerProfileId: profileId,
                label: profile.speakerId.uuidString,
                sessionDate: Date(),
                embeddings: profile.embeddingHistory.map { entry in
                    HistoricalEmbedding(embedding: entry.embedding, confirmed: true, confidence: entry.confidence)
                }
            )
        }
        if !entries.isEmpty {
            historyStore.appendSession(entries: entries)
            NSLog("[SessionLearningFinalizer] Saved \(entries.count) speaker histories")
        }
    }
}
```

- [ ] **Step 4: 新テストの green を確認**

Run: `swift test --filter SessionLearningFinalizerTests 2>&1 | tail -5`
Expected: `Executed 9 tests, with 0 failures`

- [ ] **Step 5: engine を finalizer 委譲に置換**

`ChunkedWhisperEngine.swift` の `stopStreaming` 内、`accumulator.reset()` の直後から `currentParticipantIds = []` の直前まで（現 190-262 行: `if let diarizer, diarizationActive, let store = speakerProfileStore {` で始まる事後学習ブロックと `// Save embedding history...` ブロックの全体）を以下に置換:

```swift
        if let diarizer, diarizationActive {
            let finalizer = SessionLearningFinalizer(
                profileStore: speakerProfileStore,
                embeddingHistoryStore: embeddingHistoryStore
            )
            finalizer.finalize(
                mode: currentParameters.diarizationMode,
                participantIds: currentParticipantIds,
                segments: confirmedSegments,
                speakerDisplayNames: speakerDisplayNames,
                sessionProfiles: diarizer.exportSpeakerProfiles(),
                detailedProfiles: diarizer.exportDetailedSpeakerProfiles()
            )
        }
```

さらに engine から以下を削除:
- `internal func applyManualModePostHocLearning(store:participantIds:segments:)`（doc コメントごと。finalizer に移設済み）
- `#if DEBUG ... applyManualModePostHocLearningForTesting ... #endif` ブロック全体

旧テストファイルを削除:

```bash
trash Tests/QuickTranscriberTests/PostHocLearningTests.swift
```

- [ ] **Step 6: フル unit テストで挙動不変を確認**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -10`
Expected: 既知の 1 件（`ManualModeStabilityTests.testCorrection_trustedLearningReducesFutureMisidentification`）以外の失敗ゼロ。特に `RetroactiveUpdateGuardTests`（engine 経由で auto merge の corrected フィルタを検証）が通ること

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: SessionLearningFinalizer 抽出 — stopStreaming の事後学習を独立型に"
```

---

### Task 2: drainOnStop フラグ廃止 — stopStreaming 引数化

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift`（`drainOnStop` プロパティ削除、`stopStreaming` 分割）
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift:919-921`（`finishFileTranscription`）
- Test: `Tests/QuickTranscriberTests/ChunkedWhisperEngineTests.swift`（新テスト 1 件）

**Interfaces:**
- Produces: `ChunkedWhisperEngine.stopStreaming(speakerDisplayNames: [String: String], drainRemaining: Bool) async`（concrete 型のみ。プロトコルの `stopStreaming(speakerDisplayNames:)` は `drainRemaining: false` で委譲）
- 削除: `public var drainOnStop`

- [ ] **Step 1: drain テストを書く（red）**

`ChunkedWhisperEngineTests.swift` の `testTranscriptionFailureContinues` の後に追加:

```swift
    func testStopWithDrainRemainingProcessesQueuedBuffers() async throws {
        // File モード相当: バッファを積んでから drain 付き stop → 残りが全て処理される
        let mockTranscriber = MockChunkTranscriber()
        mockTranscriber.transcribeResults = [
            TranscribedSegment(text: "queued", avgLogprob: -0.5, compressionRatio: 1.0, noSpeechProb: 0.1)
        ]
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber
        )
        try await engine.setup(model: "test-model")
        try await engine.startStreaming(language: "en") { _ in }

        simulateSpeechAndSilence(speechDuration: 2.0)
        await engine.stopStreaming(speakerDisplayNames: [:], drainRemaining: true)

        XCTAssertEqual(mockTranscriber.transcribeCallCount, 1,
            "queued buffers must be drained and transcribed on stop")
        XCTAssertEqual(engine.currentConfirmedSegments.map(\.text), ["queued"])
    }
```

- [ ] **Step 2: red を確認**

Run: `swift test --filter ChunkedWhisperEngineTests.testStopWithDrainRemainingProcessesQueuedBuffers 2>&1 | tail -5`
Expected: コンパイルエラー（`stopStreaming(speakerDisplayNames:drainRemaining:)` は存在しない）

- [ ] **Step 3: 実装**

`ChunkedWhisperEngine.swift`:

1. プロパティ削除（doc コメントごと）:

```swift
    /// When true, stopStreaming drains all buffered samples before stopping.
    /// Used for file transcription where all buffers are queued upfront.
    public var drainOnStop = false
```

2. `stopStreaming(speakerDisplayNames:)` を分割・置換:

```swift
    public func stopStreaming(speakerDisplayNames: [String: String]) async {
        await stopStreaming(speakerDisplayNames: speakerDisplayNames, drainRemaining: false)
    }

    /// - Parameter drainRemaining: true ならバッファ済み全サンプルを処理してから停止する
    ///   （file 転写の完了時）。false なら即時停止（live 録音、file 転写のキャンセル）。
    public func stopStreaming(speakerDisplayNames: [String: String], drainRemaining: Bool) async {
        audioCaptureService.stopCapture()

        if drainRemaining {
            // Finish the stream and let the loop drain all buffered samples
            streamContinuation?.finish()
            streamContinuation = nil
            await streamingTask?.value
            streamingTask = nil
            _isStreaming = false
        } else {
            // Stop immediately
            _isStreaming = false
            streamContinuation?.finish()
            streamContinuation = nil
            streamingTask?.cancel()
            await streamingTask?.value
            streamingTask = nil
        }
        // ... 以降（audioRecorder 終了 / flush / finalizer / NSLog）は既存のまま。
        // 旧コードの `drainOnStop = false` リセット行のみ削除
    }
```

3. `TranscriptionViewModel.finishFileTranscription`（:919-921）を置換:

```swift
    private func finishFileTranscription() async {
        guard let engine = fileTranscriptionEngine else { return }
        await engine.stopStreaming(speakerDisplayNames: speakerDisplayNames, drainRemaining: true)
        // ... 以降は既存のまま
```

（`cancelFileTranscription` は `stopStreaming(speakerDisplayNames: [:])` のまま = 即時停止。従来と同じ挙動）

- [ ] **Step 4: green を確認**

Run: `swift test --filter ChunkedWhisperEngineTests 2>&1 | tail -5`
Expected: 全件 PASS

- [ ] **Step 5: フル unit テスト + Commit**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -10`
Expected: 既知の 1 件以外の失敗ゼロ

```bash
git add -A
git commit -m "refactor: drainOnStop フラグ廃止 — stopStreaming(drainRemaining:) 引数に"
```

---

### Task 3: speaker 系プロトコル async 化 + Service 直列転送チェーン

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/TranscriptionEngine.swift:34-36, 52-62`
- Modify: `Sources/QuickTranscriber/Services/TranscriptionService.swift:47-63`
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift`（テスト用 join seam 1 行）
- Modify: `Tests/QuickTranscriberTests/Mocks/MockTranscriptionEngine.swift`（callOrder 記録）
- Test: `Tests/QuickTranscriberTests/TranscriptionServiceTests.swift`, `SpeakerStateCoordinatorTests.swift`, `TranscriptionViewModelTests.swift`

**Interfaces:**
- Produces:
  - protocol: `func correctSpeakerAssignment(embedding: [Float], from oldId: UUID, to newId: UUID) async` / `func mergeSpeakerProfiles(from sourceId: UUID, into targetId: UUID) async` / `func syncViterbiConfirm(to newId: UUID) async`
  - `TranscriptionService.engineSyncTask: Task<Void, Never>?`（`private(set)`、テストの join point）
  - `TranscriptionViewModel.engineSyncTask: Task<Void, Never>?`（internal computed、service へ委譲）
  - Service の `correctSpeakerAssignment` / `syncViterbiConfirm` / `mergeSpeakerProfiles` の**公開シグネチャは同期のまま**（coordinator 無変更のため）
- 注: `ChunkedWhisperEngine`（class、同期メソッド）と `MockTranscriptionEngine`（同期メソッド）はそのままで async 要件の witness になる（Swift では同期メソッドが async 要件を満たせる）。このタスクで engine 本体は無変更

- [ ] **Step 1: 順序保証テストを書く（red）**

`MockTranscriptionEngine.swift` の speaker 系 3 メソッドに統合順序の記録を追加:

```swift
    var correctedAssignments: [(embedding: [Float], oldId: UUID, newId: UUID)] = []
    var mergedProfiles: [(sourceId: UUID, targetId: UUID)] = []
    var syncViterbiConfirmCalls: [UUID] = []
    /// 3 メソッド横断の到達順（直列チェーンの FIFO 検証用）
    var speakerOpOrder: [String] = []

    func correctSpeakerAssignment(embedding: [Float], from oldId: UUID, to newId: UUID) {
        correctedAssignments.append((embedding: embedding, oldId: oldId, newId: newId))
        speakerOpOrder.append("correct")
    }

    func syncViterbiConfirm(to newId: UUID) {
        syncViterbiConfirmCalls.append(newId)
        speakerOpOrder.append("sync")
    }

    func mergeSpeakerProfiles(from sourceId: UUID, into targetId: UUID) {
        mergedProfiles.append((sourceId: sourceId, targetId: targetId))
        speakerOpOrder.append("merge")
    }
```

`TranscriptionServiceTests.swift` に追加:

```swift
    func testSpeakerOpsForwardToEngineInIssueOrder() async {
        let engine = MockTranscriptionEngine()
        let service = TranscriptionService(engine: engine)
        let a = UUID()
        let b = UUID()

        service.correctSpeakerAssignment(embedding: [1.0], from: a.uuidString, to: b.uuidString)
        service.mergeSpeakerProfiles(from: a, into: b)
        service.syncViterbiConfirm(to: b.uuidString)
        await service.engineSyncTask?.value

        XCTAssertEqual(engine.speakerOpOrder, ["correct", "merge", "sync"],
            "speaker ops must reach the engine in issue order (serialized chain)")
    }
```

- [ ] **Step 2: red を確認**

Run: `swift test --filter TranscriptionServiceTests 2>&1 | tail -5`
Expected: コンパイルエラー `value of type 'TranscriptionService' has no member 'engineSyncTask'`

- [ ] **Step 3: プロトコルと Service を実装**

`TranscriptionEngine.swift` — プロトコル要件（:34-36）を async 化:

```swift
    func correctSpeakerAssignment(embedding: [Float], from oldId: UUID, to newId: UUID) async
    func mergeSpeakerProfiles(from sourceId: UUID, into targetId: UUID) async
    func syncViterbiConfirm(to newId: UUID) async
```

extension のデフォルト実装（:52-62）も async に:

```swift
    public func correctSpeakerAssignment(embedding: [Float], from oldId: UUID, to newId: UUID) async {
        // Default no-op for engines without diarization
    }

    public func mergeSpeakerProfiles(from sourceId: UUID, into targetId: UUID) async {
        // Default no-op for engines without diarization
    }

    public func syncViterbiConfirm(to newId: UUID) async {
        // Default no-op for engines without diarization
    }
```

`TranscriptionService.swift` — `stopTranscription` 以降（:47-63）を置換:

```swift
    public func stopTranscription(speakerDisplayNames: [String: String] = [:]) async {
        // 発行済みの speaker 系操作が engine に届いてから stop する
        // （同期呼び出し時代の「補正が stop より先に届く」順序を保存）
        await engineSyncTask?.value
        await engine.stopStreaming(speakerDisplayNames: speakerDisplayNames)
    }

    /// Speaker 系操作は engine（actor）へ直列チェーンで転送する。
    /// 呼び出し側（@MainActor の coordinator）は同期のまま、発行順序（FIFO）を保証する。
    /// テストは engineSyncTask を await して転送完了に同期する。
    private(set) var engineSyncTask: Task<Void, Never>?

    private func enqueueEngineSync(_ operation: @escaping @Sendable () async -> Void) {
        let previous = engineSyncTask
        engineSyncTask = Task {
            await previous?.value
            await operation()
        }
    }

    public func correctSpeakerAssignment(embedding: [Float], from oldSpeaker: String, to newSpeaker: String) {
        guard let oldId = UUID(uuidString: oldSpeaker), let newId = UUID(uuidString: newSpeaker) else { return }
        enqueueEngineSync { [engine] in
            await engine.correctSpeakerAssignment(embedding: embedding, from: oldId, to: newId)
        }
    }

    public func syncViterbiConfirm(to newSpeaker: String) {
        guard let newId = UUID(uuidString: newSpeaker) else { return }
        enqueueEngineSync { [engine] in
            await engine.syncViterbiConfirm(to: newId)
        }
    }

    public func mergeSpeakerProfiles(from sourceId: UUID, into targetId: UUID) {
        enqueueEngineSync { [engine] in
            await engine.mergeSpeakerProfiles(from: sourceId, into: targetId)
        }
    }
```

`TranscriptionViewModel.swift` — `private var service: TranscriptionService`（:81）の直後にテスト用 seam を追加:

```swift
    /// テスト用 join point: coordinator→service の speaker 系転送チェーンの末尾
    var engineSyncTask: Task<Void, Never>? { service.engineSyncTask }
```

- [ ] **Step 4: 転送を検証していた既存テストを join 付きに適応**

fire-and-forget 化で「呼び出し直後の mock 検証」が racy になるのは以下の 6 件のみ（転送**先**の状態を見るテスト。segments の同期更新を見るテストは影響なし）。各テストを `async` にし、mock 検証の**直前**に join を挿入する:

1. `TranscriptionServiceTests.testCorrectSpeakerAssignmentForwardsToEngine` — `func ... async` 化し、`service.correctSpeakerAssignment(...)` の後に `await service.engineSyncTask?.value`
2. `TranscriptionServiceTests.testCorrectSpeakerAssignmentWithInvalidUUIDIsNoOp` — 同様に async 化 + join（invalid UUID では enqueue されないが、対称性のため join を入れる）
3. `SpeakerStateCoordinatorTests.testReassignSegment_withNilEmbedding_callsViterbiSync`（:486）— async 化し、`coord.reassignSegment(...)` の後に `await service.engineSyncTask?.value`
4. `SpeakerStateCoordinatorTests.testReassignSegment_withEmbedding_callsCorrectAssignment`（:508）— 同上
5. `TranscriptionViewModelTests.testReassignSpeakerForBlockCallsCorrectSpeakerAssignment`（:867）— async 化し、`vm.reassignSpeakerForBlock(...)` の後、`engine.correctedAssignments` 検証の前に `await vm.engineSyncTask?.value`
6. `TranscriptionViewModelTests.testReassignSpeakerForSelectionCallsCorrectSpeakerAssignment`（:902 付近）— 同様に `vm.reassignSpeakerForSelection(...)` の後に `await vm.engineSyncTask?.value`

例（3 の変更後の形）:

```swift
    func testReassignSegment_withNilEmbedding_callsViterbiSync() async {
        let (coord, _) = makeCoordinator()
        let mockEngine = MockTranscriptionEngine()
        let service = TranscriptionService(engine: mockEngine)
        coord.setService(service)

        let oldId = UUID()
        let newId = UUID()
        var segments: [ConfirmedSegment] = [
            ConfirmedSegment(text: "hello", speaker: oldId.uuidString, speakerEmbedding: nil)
        ]

        coord.reassignSegment(at: 0, to: newId.uuidString, segments: &segments)
        await service.engineSyncTask?.value

        XCTAssertTrue(mockEngine.correctedAssignments.isEmpty,
            "should not call correctSpeakerAssignment when embedding is nil")
        XCTAssertEqual(mockEngine.syncViterbiConfirmCalls.count, 1)
        XCTAssertEqual(mockEngine.syncViterbiConfirmCalls[0], newId)
        XCTAssertEqual(segments[0].speaker, newId.uuidString)
        XCTAssertTrue(segments[0].isUserCorrected)
    }
```

- [ ] **Step 5: green + フル unit テスト確認**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -10`
Expected: 既知の 1 件以外の失敗ゼロ（上記 6 件と新規 1 件を含む）

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: speaker 系プロトコルを async 化 — Service に直列転送チェーン導入"
```

---

### Task 4: ChunkedWhisperEngine を actor 化

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift`（class→actor、smootherLock 削除、ingest 分離）
- Modify: `Sources/QuickTranscriber/Engines/TranscriptionEngine.swift:29`（`Sendable` 追加）
- Modify: `Tests/QuickTranscriberTests/Mocks/MockTranscriptionEngine.swift:4`（`@unchecked Sendable`）
- Test: `Tests/QuickTranscriberTests/ChunkedWhisperEngineTests.swift`, `RetroactiveUpdateGuardTests.swift`（await 適応）

**Interfaces:**
- Consumes: Task 3 の async プロトコル要件（actor の isolated メソッドが witness になる）
- Produces: `public actor ChunkedWhisperEngine`。外部から見た API は同名だが全メンバーが actor-isolated（呼び出しに await 必須）。`smootherLock` と `private func ingest(_:onStateChange:)` 以外の内部構造は不変
- 保証: actor reentrancy により、`stopStreaming` が `await streamingTask?.value` で suspend している間も ingest は actor に hop して drain を完了できる（deadlock しない）。`await transcriber.transcribe` 中も actor は解放され correction が割り込める（現行のロック挙動と同等）

- [ ] **Step 1: actor 変換を実装**

`TranscriptionEngine.swift:29` — actor は Sendable なのでプロトコルに明示:

```swift
public protocol TranscriptionEngine: AnyObject, Sendable {
```

`MockTranscriptionEngine.swift:4` — テスト mock は従来どおり単一スレッドから使う前提で unchecked:

```swift
final class MockTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
```

`ChunkedWhisperEngine.swift` の変換（Task 1・2 適用後のコードベースに対して）:

1. `public final class ChunkedWhisperEngine: TranscriptionEngine {` → `public actor ChunkedWhisperEngine: TranscriptionEngine {`
2. `private let smootherLock = NSLock()` を削除
3. `isStreaming` を単純化（actor プロパティは外部から await アクセスになり、`get async` 要件を満たす）:

```swift
    public var isStreaming: Bool { _isStreaming }
```

4. `startStreaming` 内の streamingTask を、actor-isolated な per-buffer メソッドへの hop に置換。**旧ループ内の `bufferCount` と `[AudioLevelNormalizer] gain=...` の 100 バッファ毎ログはここで削除**（spec の周期ログ削減）:

```swift
        streamingTask = Task { [weak self] in
            for await samples in bufferStream {
                guard let self else { break }
                guard await self.ingest(samples, onStateChange: onStateChange) else { break }
            }
        }
```

5. `// MARK: - Private` セクションに ingest を追加:

```swift
    /// Streaming task から呼ばれる 1 バッファ分の取り込み。actor 隔離により
    /// normalizer / accumulator / confirmedSegments へのアクセスが直列化される。
    /// - Returns: false なら停止済みで、呼び出し側はループを抜ける。
    private func ingest(
        _ samples: [Float],
        onStateChange: @escaping @Sendable (TranscriptionState) -> Void
    ) async -> Bool {
        guard _isStreaming else { return false }
        let normalizedSamples = normalizer.normalize(samples)
        audioRecorder?.appendSamples(normalizedSamples)
        if let chunkResult = accumulator.appendBuffer(normalizedSamples) {
            await processChunk(chunkResult, onStateChange: onStateChange)
        }
        return true
    }
```

6. speaker 系 3 メソッドからロックを外す（actor 隔離が代替。async キーワードは不要 — isolated メソッドは外部から await 呼び出しになる）:

```swift
    public func correctSpeakerAssignment(embedding: [Float], from oldId: UUID, to newId: UUID) {
        diarizer?.correctSpeakerAssignment(embedding: embedding, from: oldId, to: newId)
        if speakerSmoother.confirmedSpeakerId == oldId {
            speakerSmoother.confirmSpeaker(newId)
        }
    }

    public func syncViterbiConfirm(to newId: UUID) {
        speakerSmoother.confirmSpeaker(newId)
    }

    public func mergeSpeakerProfiles(from sourceId: UUID, into targetId: UUID) {
        diarizer?.mergeSpeakerProfiles(from: sourceId, into: targetId)
        speakerSmoother.remapSpeaker(from: sourceId, to: targetId)
    }
```

7. `processChunk` 内の 2 箇所の `smootherLock.withLock { ... }` を中身の直接実行に置換:

```swift
                if significantSilence {
                    speakerSmoother.resetForSpeakerChange()
                }
```

```swift
                smoothedResult = speakerSmoother.process(rawSpeakerResult)
```

8. `stopStreaming` 内の `// Now safe to access accumulator — streaming task is fully stopped` コメントを削除（actor 隔離で常に安全）

- [ ] **Step 2: コンパイルエラーを網羅的に await 適応**

Run: `swift build 2>&1 | grep -E "error" | head -30`

コンパイラが挙げる箇所を機械的に直す。既知の対象（すべてテスト側。本体側は Task 2・3 で対応済みのため**エラーが出ないはず** — 出たら設計違反なので立ち止まる）:

- `ChunkedWhisperEngineTests.swift`: `engine.correctSpeakerAssignment(...)` 直接呼び出し（:262, :276, :575, :625）→ `await` 付与。`engine.currentConfirmedSegments`（:571, :582, :632）→ `let segments = await engine.currentConfirmedSegments` 形式に。Task 2 で追加した drain テストの `engine.currentConfirmedSegments.map(\.text)` → `await engine.currentConfirmedSegments` を変数に取ってから検証
- `RetroactiveUpdateGuardTests.swift`: `engine.markSegmentAsUserCorrected(...)`（:122, :183）→ `await` 付与。`engine.currentConfirmedSegments`（:133 ほか）→ `await` 付与
- テスト関数が同期の場合は `async throws` に変更

Expected 最終状態: `swift build` が warning のみで成功（v5 モードなので Sendable 警告が数件出る可能性はあるが、error ゼロ）

- [ ] **Step 3: フル unit テストで green を確認**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -10`
Expected: 既知の 1 件以外の失敗ゼロ。特に `ChunkedWhisperEngineTests` / `RetroactiveUpdateGuardTests` / `QualityFilterTests` / `ConfidenceColoringTests` / `FileTranscriptionParametersTests` / `LatencyInstrumentationIntegrationTests` の全通過

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: ChunkedWhisperEngine を actor 化 — smootherLock 削除、可変状態をコンパイラ保証で直列化"
```

---

### Task 5: 並行 correction/merge の直列化スモークテスト

**Files:**
- Test: `Tests/QuickTranscriberTests/ChunkedWhisperEngineTests.swift`（新テスト 1 件）

**Interfaces:**
- Consumes: Task 4 の actor API（`await engine.correctSpeakerAssignment` 等）、`MockSpeakerDiarizer.correctedAssignments`

- [ ] **Step 1: スモークテストを書く**

ファイル末尾（クラス閉じ括弧の前）に追加:

```swift
    // MARK: - Actor serialization smoke test

    func testConcurrentSpeakerOpsDuringStreamingAreSerialized() async throws {
        // streaming 中に correction / merge / sync を多重並行発行しても、
        // actor 直列化により mock diarizer への到達が欠落なく完了することを確認する。
        // （actor 化以前は smootherLock 外の状態が data race になり得た経路）
        let mockTranscriber = MockChunkTranscriber()
        mockTranscriber.transcribeResults = [
            TranscribedSegment(text: "hello", avgLogprob: -0.5, compressionRatio: 1.0, noSpeechProb: 0.1)
        ]
        let mockDiarizer = MockSpeakerDiarizer()
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber,
            diarizer: mockDiarizer
        )
        try await engine.setup(model: "test-model")
        let params = TranscriptionParameters(enableSpeakerDiarization: true)
        try await engine.startStreaming(language: "en", parameters: params) { _ in }

        let idA = UUID()
        let idB = UUID()
        let capture = mockCapture!
        let speech = [Float](repeating: 0.1, count: 16000)
        let silence = [Float](repeating: 0.0, count: 11200)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask { await engine.correctSpeakerAssignment(embedding: [Float(i)], from: idA, to: idB) }
                group.addTask { await engine.mergeSpeakerProfiles(from: idA, into: idB) }
                group.addTask { await engine.syncViterbiConfirm(to: idB) }
                if i % 10 == 0 {
                    group.addTask {
                        capture.simulateBuffer(speech)
                        capture.simulateBuffer(silence)
                    }
                }
            }
        }

        XCTAssertEqual(mockDiarizer.correctedAssignments.count, 50,
            "all concurrent corrections must reach the diarizer exactly once (serialized, no drops)")
        let streaming = await engine.isStreaming
        XCTAssertTrue(streaming, "engine must survive concurrent speaker ops")

        await engine.stopStreaming()
    }
```

- [ ] **Step 2: green を確認（反復実行で flake がないこと）**

Run: `for i in 1 2 3; do swift test --filter ChunkedWhisperEngineTests.testConcurrentSpeakerOpsDuringStreamingAreSerialized 2>&1 | tail -2; done`
Expected: 3 回とも `Executed 1 test, with 0 failures`

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "test: 並行 correction/merge の直列化スモークテスト追加"
```

---

### Task 6: NSLog をチャンク毎 1 行に集約

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift`（`processChunk` 内）

**Interfaces:** なし（ログのみ。テスト影響なし — ログを検証するテストは存在しない）

- [ ] **Step 1: processChunk のログを整理**

削除する NSLog（4 種）:
1. 冒頭の `"Processing chunk: ..."` 行
2. filter クロージャ内の `"Filtered (metadata): ..."` と `"Filtered (text): ..."`（`if` 文を `TranscriptionUtils.shouldFilterByMetadata(segment) { return false }` 形式に単純化）
3. セグメント append ループ内の `"Confirmed: ..."` 行

（`"Retroactively assigned speaker ..."` はイベント毎 1 回の診断ログなので**残す**）

`onStateChange(...)` 呼び出しの直前に、チャンク毎 1 行のサマリを追加:

```swift
            NSLog("[ChunkedWhisperEngine] Chunk %.1fs: +%d segments (%d filtered), speaker=%@, precedingSilence=%.1fs",
                  chunkDuration,
                  filtered.count,
                  segments.count - filtered.count,
                  smoothedResult?.speakerId.uuidString ?? "pending",
                  chunkResult.precedingSilenceDuration)
```

filter クロージャの変更後の形:

```swift
            let filtered = segments.filter { segment in
                if TranscriptionUtils.shouldFilterByMetadata(segment) { return false }
                if TranscriptionUtils.shouldFilterSegment(segment.text, language: currentLanguage) { return false }
                return true
            }
```

- [ ] **Step 2: ビルドとフル unit テスト**

Run: `swift build 2>&1 | tail -3 && swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: build 成功、既知の 1 件以外の失敗ゼロ

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor: チャンク処理の NSLog をチャンク毎 1 行のサマリに集約"
```

---

### Task 7: バージョン bump + 最終検証

**Files:**
- Modify: `Sources/QuickTranscriber/Constants.swift:61`

- [ ] **Step 1: 次の PR 番号を確認**

Run: `gh api 'repos/matsuura-satoshi/quick-transcriber/issues?state=all&per_page=1&sort=created&direction=desc' --jq '.[0].number'`
Expected: `88`（→ 次 PR は #89。異なる値なら patch をその値+1 に読み替える）

- [ ] **Step 2: バージョン更新**

`Constants.swift:61` — `public static let patch = 88` → `public static let patch = 89`

- [ ] **Step 3: 最終検証（superpowers:verification-before-completion）**

Run: `swift build 2>&1 | tail -3`
Expected: Build complete

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -10`
Expected: **`ManualModeStabilityTests.testCorrection_trustedLearningReducesFutureMisidentification` 以外の失敗ゼロ**（数値をコピーして記録する）

Run: `git log --oneline main..HEAD`
Expected: Task 1-7 のコミットが揃っている

- [ ] **Step 4: Commit**

```bash
git add Sources/QuickTranscriber/Constants.swift
git commit -m "chore: bump version to v2.4.89"
```

- [ ] **Step 5: 実機スモークテスト（ユーザー確認）**

`swift run QuickTranscriber` で起動し、以下をユーザーに依頼（B3 は並行系の変更なので実機必須。spec の検証要件）:

1. ライブ録音で文字起こしが流れる（チャンク毎サマリログが 1 行/チャンクであること）
2. 録音**中**にラベルクリック再割当 → 即時反映、DEBUG コンソールに InvariantChecker 違反なし
3. 録音**中**に選択範囲の再割当
4. 録音**中**にプロファイル merge（重複名の統合）
5. 録音停止 → プロファイル保存ログ（`[SessionLearningFinalizer]`）が出る
6. ファイル文字起こしが完了まで走る（drain）+ 途中キャンセルが即時に効く
7. `qt_transcript.md` の出力が画面表示と一致

- [ ] **Step 6: PR 作成**

superpowers:finishing-a-development-branch に従う。PR タイトル: `refactor: ChunkedWhisperEngine actor 化 + SessionLearningFinalizer 抽出 (v2.4.89)`。マージは main の慣例どおり **squash**。

---

## リスクと検出手段（spec より、本計画での対応）

| リスク | 対応 |
|---|---|
| async 化で correction の到達タイミングが変わる | Service 直列チェーンで発行順 FIFO を保証（現行の同期呼び出しより弱いのは「呼び出し完了 = 到達」でなくなる点のみ）。`stopTranscription` はチェーンを await してから stop するので「補正が stop より先」の順序も保存。Task 5 のスモークテスト + 実機 2-4 で検証 |
| actor 変換によるテスト churn | 対象は特定済み（Task 3 Step 4 の 6 件 + Task 4 Step 2 の await 適応）。機械的変更のみ |
| finalizer 抽出での挙動変化 | 移植は逐語コピー。既存 `RetroactiveUpdateGuardTests`（corrected フィルタ）+ 移植 6 件 + 新規 3 件でロック |
| drain 意味論の変化 | finish=drain / cancel=即時 を Task 2 のテストと実機 6 で検証 |
