# Confusion Pair Analysis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Quantify which registered speaker profiles are too close in embedding space (static) and confirm, by replaying the two real CERT sessions through the v2.4.81 Manual-mode diarization pipeline, that the user's "always-flipping" speaker (false-神野 assignments) matches a high-similarity pair.

**Architecture:** Two read-only analyses over the user's production `~/QuickTranscriber/speakers.json` and the two real-session WAVs in `~/Documents/QuickTranscriber/real-sessions/`. Part A is a pure static pairwise-cosine computation (no model). Part B is a diarization-only replay: feed each WAV through `VADChunkAccumulator` → `FluidAudioSpeakerDiarizer` (Manual-mode: participant profiles loaded, `suppressLearning=true`) → `ViterbiSpeakerSmoother(0.9)`, recording `(startTime, endTime, predictedSpeakerUUID)` per chunk; cross-reference predicted-vs-Zoom-ground-truth into a confusion matrix. **No WhisperKit / no transcription** — the confusion matrix needs only speaker labels over time, so we skip the slow LLM stage. Production state is never mutated (strict read-only).

**Tech Stack:** Swift 6 (XCTest benchmark target), existing `SpeakerProfileLoader` / `ZoomTranscriptParser` / `EmbeddingBasedSpeakerTracker.cosineSimilarity` / `FluidAudioSpeakerDiarizer` / `ViterbiSpeakerSmoother`; Python 3 for rendering the JSON artifacts into a markdown report.

---

## Background findings (already computed, Part A reconnaissance 2026-06-04)

These numbers motivate the plan and are the targets the report must reproduce. Computed directly from `~/QuickTranscriber/speakers.json` with the canonical cosine formula:

Registered-roster (6 regulars present in store) pairwise cosine similarity:

```
        松浦    今村    上東     森    森谷    神野
  松浦  1.000  0.669  0.769  0.653  0.490  0.551
  今村  0.669  1.000  0.782  0.712  0.624  0.664
  上東  0.769  0.782  1.000  0.789  0.569  0.764
   森  0.653  0.712  0.789  1.000  0.585  0.768
  森谷  0.490  0.624  0.569  0.585  1.000  0.678
  神野  0.551  0.664  0.764  0.768  0.678  1.000
```

- **神野 sits at the centroid of the active-speaker cluster**: 神野↔上東 = 0.764, 神野↔森 = 0.768. The user reports 神野 is wrongly assigned; these two are the active speakers in 2026-04-23.
- **上東↔森 = 0.789** is the tightest in-roster pair.
- **佐々木** (sessions=1, an under-enrolled outlier, norm 0.723 vs ~0.55 for others) is **nearest to 神野 at 0.785** and has **no usable profile to register** → in 2026-04-21, when 佐々木 spoke, the audio has no 佐々木 home and is expected to land on 神野.
- 神野 is **not** globally promiscuous: mean similarity to all 90 profiles = 0.555. The problem is local centrality within the registered roster, not a generically central embedding.

Part A formalizes this as a reproducible, committed artifact. Part B confirms the *behavioural* consequence on real audio.

## Roster assumption (documented, see AskUserQuestion 2026-06-04)

The user does not recall the exact Manual-mode participant list but confirmed **神野 was registered yet silent, and 神野's label is frequently mis-assigned**. We therefore reconstruct the most likely standing roster:

- **Registered participants (both sessions):** 松浦, 今村, 上東, 森, 森谷, 神野 — the six regulars that exist in the store. 神野 (and, in 2026-04-21, 森/森谷) are registered-but-silent → false-assignment magnets.
- **佐々木** spoke in 2026-04-21 but has no usable profile → an unregistered "impostor" with no home label. This is a feature of the test, not a bug.

Zoom handle → short-name mapping (from the ablation spec, fixed):

| Short | Zoom handle |
|---|---|
| 松浦 | `松浦 知史 / Science Tokyo CERT / MATSUURA Satoshi` |
| 今村 | `今村＠情報セキュリティ室` |
| 上東 | `Y.Uehigashi` |
| 森 | `Kento Mori` |
| 森谷 | `moriya` |
| 佐々木 | `佐々木@情報セキュリティ室` |
| 神野 | (never appears in Zoom — silent) |

## Session time alignment (verified 2026-06-04)

Audio `t=0` is the QT recording start (qt_transcript.md frontmatter `date:`). Zoom timestamps are absolute time-of-day; audio-relative = `zoomSecondsOfDay − qtStartSecondsOfDay`.

| Session | qt start | zoom first → rel | zoom last → rel | audio dur |
|---|---|---|---|---|
| 2026-04-21 | 09:44:23 | 09:45:05 → 42s | 09:56:50 → 747s | 695s |
| 2026-04-23 | 09:44:48 | 09:44:52 → 4s | 10:00:16 → 928s | 904s |

Both align cleanly (Zoom extends a few tens of seconds past audio end; those tail turns simply have no chunks). Alignment uncertainty is acknowledged in the report — per-speaker confusion aggregates are robust to a few seconds of offset.

---

## File Structure

| File | Responsibility |
|---|---|
| `Tests/QuickTranscriberBenchmarks/SessionTimeAligner.swift` (create) | Pure: parse qt frontmatter ISO-8601 `date:` → seconds-of-day; convert Zoom absolute → audio-relative `ZoomSegment`s. |
| `Tests/QuickTranscriberBenchmarks/SessionTimeAlignerTests.swift` (create) | Unit tests for the aligner. |
| `Tests/QuickTranscriberBenchmarks/ConfusionMatrixBuilder.swift` (create) | Pure: given `[(predicted: String, groundTruth: String)]` rows → counts matrix + false-神野 attribution + per-row totals. JSON-codable result. |
| `Tests/QuickTranscriberBenchmarks/ConfusionMatrixBuilderTests.swift` (create) | Unit tests for the builder. |
| `Tests/QuickTranscriberBenchmarks/ConfusionPairAnalysisTests.swift` (create) | Orchestrators: `testStaticRosterSimilarity` (Part A) + `testRealSessionConfusion` (Part B). Both guarded with `XCTSkip` when production data is absent. Write JSON artifacts to `/tmp`. |
| `Scripts/analyze_confusion_pairs.py` (create) | Render the JSON artifacts → markdown report + plain-text heatmaps. |
| `docs/benchmarks/2026-06-04-confusion-pair/` (create at report time) | Committed JSON artifacts + final `report.md`. |

No production `Sources/` files are modified. This is a read-only analysis.

---

## Task 1: SessionTimeAligner — frontmatter date parsing

**Files:**
- Create: `Tests/QuickTranscriberBenchmarks/SessionTimeAligner.swift`
- Test: `Tests/QuickTranscriberBenchmarks/SessionTimeAlignerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import QuickTranscriberLib

final class SessionTimeAlignerTests: XCTestCase {
    func test_secondsOfDay_parsesISO8601Frontmatter() throws {
        let md = """
        ---
        date: 2026-04-21T09:44:23+09:00
        language: Japanese
        ---

        神野: はい
        """
        let sod = try SessionTimeAligner.qtStartSecondsOfDay(fromFrontmatter: md)
        XCTAssertEqual(sod, 9 * 3600 + 44 * 60 + 23, accuracy: 0.001)
    }

    func test_secondsOfDay_throwsWhenDateMissing() {
        XCTAssertThrowsError(
            try SessionTimeAligner.qtStartSecondsOfDay(fromFrontmatter: "---\nlanguage: Japanese\n---\n")
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionTimeAlignerTests/test_secondsOfDay_parsesISO8601Frontmatter`
Expected: FAIL — `SessionTimeAligner` not defined / does not compile.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Aligns Zoom absolute timestamps to audio-relative time for a real session.
/// Audio t=0 is the QT recording start, taken from qt_transcript.md frontmatter `date:`.
public enum SessionTimeAligner {
    public enum AlignError: Error, Equatable {
        case dateNotFound
        case dateUnparseable(String)
    }

    /// Extract the `date:` frontmatter value and return its seconds-of-day
    /// (hour*3600 + minute*60 + second) in the timestamp's own zone offset.
    public static func qtStartSecondsOfDay(fromFrontmatter markdown: String) throws -> Double {
        // Find `date: <ISO8601>` on its own line.
        guard let range = markdown.range(of: #/(?m)^date:\s*(?<iso>\S+)\s*$/#) else {
            throw AlignError.dateNotFound
        }
        let match = markdown[range]
        guard let m = try? #/date:\s*(?<iso>\S+)/#.firstMatch(in: String(match)) else {
            throw AlignError.dateNotFound
        }
        let iso = String(m.output.iso)
        // Parse HH:MM:SS out of the ISO string (e.g. 2026-04-21T09:44:23+09:00).
        guard let t = try? #/T(?<h>\d{2}):(?<m>\d{2}):(?<s>\d{2})/#.firstMatch(in: iso),
              let h = Int(t.output.h), let mm = Int(t.output.m), let s = Int(t.output.s) else {
            throw AlignError.dateUnparseable(iso)
        }
        return Double(h * 3600 + mm * 60 + s)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SessionTimeAlignerTests`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Tests/QuickTranscriberBenchmarks/SessionTimeAligner.swift Tests/QuickTranscriberBenchmarks/SessionTimeAlignerTests.swift
git commit -m "test: SessionTimeAligner frontmatter date parsing"
```

---

## Task 2: SessionTimeAligner — Zoom → audio-relative conversion

**Files:**
- Modify: `Tests/QuickTranscriberBenchmarks/SessionTimeAligner.swift`
- Test: `Tests/QuickTranscriberBenchmarks/SessionTimeAlignerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func test_zoomToAudioRelative_subtractsQtStart() throws {
    let zoom = """
    [松浦 知史 / Science Tokyo CERT / MATSUURA Satoshi] 09:45:05
    おはようございます。

    [Y.Uehigashi] 09:45:14
    始めます。
    """
    // qt start 09:44:23 -> 09:45:05 is +42s, 09:45:14 is +51s
    let segs = try SessionTimeAligner.zoomSegmentsAudioRelative(
        zoomRaw: zoom,
        qtStartSecondsOfDay: 9 * 3600 + 44 * 60 + 23,
        audioDurationSeconds: 695
    )
    XCTAssertEqual(segs.count, 2)
    XCTAssertEqual(segs[0].startSeconds, 42, accuracy: 0.001)
    XCTAssertEqual(segs[0].endSeconds, 51, accuracy: 0.001)   // next seg start
    XCTAssertEqual(segs[1].startSeconds, 51, accuracy: 0.001)
    XCTAssertEqual(segs[1].endSeconds, 695, accuracy: 0.001)  // audio duration
    XCTAssertEqual(segs[0].speaker, "松浦 知史 / Science Tokyo CERT / MATSUURA Satoshi")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionTimeAlignerTests/test_zoomToAudioRelative_subtractsQtStart`
Expected: FAIL — `zoomSegmentsAudioRelative` not defined.

- [ ] **Step 3: Write minimal implementation**

Add to `SessionTimeAligner`:

```swift
    /// Parse a Zoom transcript and return its segments in audio-relative time.
    /// `ZoomTranscriptParser` already converts time-of-day to session-relative
    /// given a `sessionStart` (seconds-of-day) and a session duration.
    public static func zoomSegmentsAudioRelative(
        zoomRaw: String,
        qtStartSecondsOfDay: Double,
        audioDurationSeconds: Double
    ) throws -> [ZoomSegment] {
        try ZoomTranscriptParser.parse(
            zoomRaw,
            sessionStart: qtStartSecondsOfDay,
            sessionDurationSeconds: audioDurationSeconds
        )
    }
```

(Note: `ZoomTranscriptParser.parse` already exists with this exact signature and clamps `startRel = max(0, absStart - sessionStart)`, assigns each segment's end to the next segment's start, and the last segment's end to `sessionDurationSeconds` — see `ZoomTranscriptParser.swift:33-95`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SessionTimeAlignerTests`
Expected: PASS (all three tests).

- [ ] **Step 5: Commit**

```bash
git add Tests/QuickTranscriberBenchmarks/SessionTimeAligner.swift Tests/QuickTranscriberBenchmarks/SessionTimeAlignerTests.swift
git commit -m "test: SessionTimeAligner Zoom→audio-relative conversion"
```

---

## Task 3: ConfusionMatrixBuilder — counts + false-神野 attribution

**Files:**
- Create: `Tests/QuickTranscriberBenchmarks/ConfusionMatrixBuilder.swift`
- Test: `Tests/QuickTranscriberBenchmarks/ConfusionMatrixBuilderTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import QuickTranscriberLib

final class ConfusionMatrixBuilderTests: XCTestCase {
    func test_build_countsAndFalseTarget() {
        // rows: (groundTruth, predicted)
        let rows: [(gt: String, pred: String)] = [
            ("上東", "上東"),
            ("上東", "神野"),   // false-神野 from 上東
            ("上東", "神野"),   // false-神野 from 上東
            ("森",   "神野"),   // false-神野 from 森
            ("森",   "森"),
            ("松浦", "松浦"),
        ]
        let result = ConfusionMatrixBuilder.build(
            rows: rows,
            speakers: ["松浦", "上東", "森", "神野"],
            falseTarget: "神野",
            silentSpeakers: ["神野"]
        )

        XCTAssertEqual(result.count(gt: "上東", pred: "神野"), 2)
        XCTAssertEqual(result.count(gt: "上東", pred: "上東"), 1)
        XCTAssertEqual(result.count(gt: "森", pred: "神野"), 1)
        // Total false-神野 = predicted 神野 while 神野 is silent (never a true GT)
        XCTAssertEqual(result.totalFalseTarget, 3)
        // Attribution: which GT speakers were mislabeled as 神野
        XCTAssertEqual(result.falseTargetByGroundTruth["上東"], 2)
        XCTAssertEqual(result.falseTargetByGroundTruth["森"], 1)
        // Per-GT accuracy (diagonal / row total)
        XCTAssertEqual(result.rowTotal(gt: "上東"), 3)
        XCTAssertEqual(result.accuracy(gt: "松浦"), 1.0, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConfusionMatrixBuilderTests`
Expected: FAIL — `ConfusionMatrixBuilder` not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Confusion matrix over speaker labels: rows = ground-truth speaker,
/// columns = predicted speaker. Plus false-target attribution for the
/// silent-but-registered "magnet" speaker (e.g. 神野).
public struct ConfusionMatrixResult: Codable, Sendable {
    public let speakers: [String]
    /// counts[gt][pred]
    public let counts: [String: [String: Int]]
    public let falseTarget: String
    public let totalFalseTarget: Int
    public let falseTargetByGroundTruth: [String: Int]

    public func count(gt: String, pred: String) -> Int {
        counts[gt]?[pred] ?? 0
    }
    public func rowTotal(gt: String) -> Int {
        (counts[gt] ?? [:]).values.reduce(0, +)
    }
    public func accuracy(gt: String) -> Double {
        let total = rowTotal(gt: gt)
        guard total > 0 else { return 0 }
        return Double(count(gt: gt, pred: gt)) / Double(total)
    }
}

public enum ConfusionMatrixBuilder {
    /// - Parameters:
    ///   - rows: (groundTruth, predicted) label pairs, one per attributed chunk.
    ///   - speakers: full ordered label set for matrix dimensions.
    ///   - falseTarget: the silent magnet label to attribute (e.g. "神野").
    ///   - silentSpeakers: labels that never legitimately speak; any prediction
    ///     of `falseTarget` is a false assignment by construction.
    public static func build(
        rows: [(gt: String, pred: String)],
        speakers: [String],
        falseTarget: String,
        silentSpeakers: [String]
    ) -> ConfusionMatrixResult {
        var counts: [String: [String: Int]] = [:]
        for s in speakers { counts[s] = Dictionary(uniqueKeysWithValues: speakers.map { ($0, 0) }) }

        var falseByGt: [String: Int] = [:]
        var totalFalse = 0
        for row in rows {
            // Ensure both labels exist as keys even if outside `speakers`.
            counts[row.gt, default: [:]][row.pred, default: 0] += 1
            if row.pred == falseTarget && silentSpeakers.contains(falseTarget) {
                falseByGt[row.gt, default: 0] += 1
                totalFalse += 1
            }
        }
        return ConfusionMatrixResult(
            speakers: speakers,
            counts: counts,
            falseTarget: falseTarget,
            totalFalseTarget: totalFalse,
            falseTargetByGroundTruth: falseByGt
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ConfusionMatrixBuilderTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Tests/QuickTranscriberBenchmarks/ConfusionMatrixBuilder.swift Tests/QuickTranscriberBenchmarks/ConfusionMatrixBuilderTests.swift
git commit -m "test: ConfusionMatrixBuilder with false-target attribution"
```

---

## Task 4: Part A — static roster similarity artifact

**Files:**
- Create: `Tests/QuickTranscriberBenchmarks/ConfusionPairAnalysisTests.swift`

This test needs no model. It loads the registered roster via the existing read-only `SpeakerProfileLoader`, computes the pairwise matrix with the canonical `EmbeddingBasedSpeakerTracker.cosineSimilarity`, and writes a JSON artifact. Guarded with `XCTSkip` when the production file is absent so CI stays green.

- [ ] **Step 1: Write the test (this is the analysis driver, not a unit test — it asserts the known finding and emits an artifact)**

```swift
import XCTest
@testable import QuickTranscriberLib

final class ConfusionPairAnalysisTests: XCTestCase {
    /// Standing roster of regulars present in the production store (see plan roster assumption).
    static let roster = ["松浦", "今村", "上東", "森", "森谷", "神野"]
    static let productionProfilePath = NSString(string: "~/QuickTranscriber/speakers.json").expandingTildeInPath

    struct RosterSimilarityArtifact: Codable {
        let speakers: [String]
        let matrix: [[Float]]          // matrix[i][j] = cos(speakers[i], speakers[j])
        let topPairs: [Pair]           // sorted descending, i<j
        struct Pair: Codable { let a: String; let b: String; let similarity: Float }
    }

    func testStaticRosterSimilarity() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.productionProfilePath),
            "production speakers.json not present"
        )
        let profiles = try SpeakerProfileLoader.load(
            path: Self.productionProfilePath,
            displayNames: Self.roster
        )
        // Preserve roster order for a stable matrix.
        let ordered = Self.roster.compactMap { name in profiles.first { $0.displayName == name } }
        XCTAssertEqual(ordered.count, Self.roster.count)

        var matrix = [[Float]](repeating: [Float](repeating: 0, count: ordered.count), count: ordered.count)
        var pairs: [RosterSimilarityArtifact.Pair] = []
        for i in 0..<ordered.count {
            for j in 0..<ordered.count {
                let sim = EmbeddingBasedSpeakerTracker.cosineSimilarity(ordered[i].embedding, ordered[j].embedding)
                matrix[i][j] = sim
                if i < j {
                    pairs.append(.init(a: ordered[i].displayName, b: ordered[j].displayName, similarity: sim))
                }
            }
        }
        pairs.sort { $0.similarity > $1.similarity }

        // Invariants
        for i in 0..<ordered.count {
            XCTAssertEqual(matrix[i][i], 1.0, accuracy: 0.01, "diagonal must be 1")
            for j in 0..<ordered.count {
                XCTAssertEqual(matrix[i][j], matrix[j][i], accuracy: 1e-5, "matrix must be symmetric")
            }
        }
        // Pre-registered finding: 神野 is within the top similarity neighbourhood of an active speaker.
        let kaminoToUehigashi = simBetween(matrix, ordered, "神野", "上東")
        let kaminoToMori = simBetween(matrix, ordered, "神野", "森")
        XCTAssertGreaterThan(kaminoToUehigashi, 0.70, "神野 should be close to 上東 (observed ~0.764)")
        XCTAssertGreaterThan(kaminoToMori, 0.70, "神野 should be close to 森 (observed ~0.768)")

        let artifact = RosterSimilarityArtifact(
            speakers: ordered.map(\.displayName), matrix: matrix, topPairs: pairs
        )
        let outURL = URL(fileURLWithPath: "/tmp/confusion_roster_similarity.json")
        try JSONEncoder().encode(artifact).write(to: outURL, options: .atomic)
        NSLog("[ConfusionPair] roster similarity written: \(outURL.path)")
        for p in pairs.prefix(6) {
            NSLog("[ConfusionPair] pair \(p.a)<->\(p.b): \(String(format: "%.3f", p.similarity))")
        }
    }

    private func simBetween(_ m: [[Float]], _ ordered: [LoadedSpeakerProfile], _ a: String, _ b: String) -> Float {
        guard let i = ordered.firstIndex(where: { $0.displayName == a }),
              let j = ordered.firstIndex(where: { $0.displayName == b }) else { return 0 }
        return m[i][j]
    }
}
```

- [ ] **Step 2: Run it**

Run: `swift test --filter ConfusionPairAnalysisTests/testStaticRosterSimilarity`
Expected: PASS, and `/tmp/confusion_roster_similarity.json` exists. (If the production file is absent on this machine, it SKIPs — but the user's machine has it, confirmed.)

- [ ] **Step 3: Sanity-check the artifact**

Run: `python3 -c "import json; d=json.load(open('/tmp/confusion_roster_similarity.json')); print(d['speakers']); print(d['topPairs'][:3])"`
Expected: speakers == roster order; top pair is 上東<->森 ≈ 0.789.

- [ ] **Step 4: Commit**

```bash
git add Tests/QuickTranscriberBenchmarks/ConfusionPairAnalysisTests.swift
git commit -m "feat: Part A static roster similarity analysis"
```

---

## Task 5: Part B — real-session diarization replay (one helper, fail-fast on missing data)

**Files:**
- Modify: `Tests/QuickTranscriberBenchmarks/ConfusionPairAnalysisTests.swift`

This adds the replay harness as a private method on the same test class. It mirrors production Manual-mode wiring in `ChunkedWhisperEngine.startStreaming` (lines 83-97): load participant profiles, `setSuppressLearning(true)`, `updateExpectedSpeakerCount(participants.count)`, `ViterbiSpeakerSmoother(stayProbability: 0.9)`, and `resetForSpeakerChange()` on significant preceding silence. VAD chunking is reproduced with `VADChunkAccumulator` fed in 100 ms increments (same pattern as `ChunkedDiarizationTests.generateVADChunks`).

- [ ] **Step 1: Add the session descriptor + replay helper**

```swift
    struct RealSession {
        let dirName: String
        let registered: [String]   // Manual-mode participant roster (must exist in store)
        let qtStartSecondsOfDay: Double
        let audioDurationSeconds: Double
    }

    static let sessions: [RealSession] = [
        RealSession(dirName: "2026-04-21_CERTインシデント情報共有",
                    registered: ["松浦", "今村", "上東", "森", "森谷", "神野"],
                    qtStartSecondsOfDay: 9*3600 + 44*60 + 23,
                    audioDurationSeconds: 695),
        RealSession(dirName: "2026-04-23_CERTインシデント情報共有",
                    registered: ["松浦", "今村", "上東", "森", "森谷", "神野"],
                    qtStartSecondsOfDay: 9*3600 + 44*60 + 48,
                    audioDurationSeconds: 904),
    ]

    /// Zoom handle → short name. Reverse of the plan's mapping table.
    static let zoomToShort: [String: String] = [
        "松浦 知史 / Science Tokyo CERT / MATSUURA Satoshi": "松浦",
        "今村＠情報セキュリティ室": "今村",
        "Y.Uehigashi": "上東",
        "佐々木@情報セキュリティ室": "佐々木",
        "Kento Mori": "森",
        "moriya": "森谷",
    ]

    static let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/QuickTranscriber/real-sessions")

    /// Replay one WAV through the Manual-mode diarizer; return per-chunk
    /// (startSeconds, endSeconds, predictedUUID) for confirmed (non-pending) chunks.
    private func replay(
        session: RealSession,
        idToName: inout [String: String]
    ) async throws -> [(start: Double, end: Double, predicted: String)] {
        let dir = Self.sessionsRoot.appendingPathComponent(session.dirName)
        let wavURL = dir.appendingPathComponent("audio.wav")

        let loaded = try SpeakerProfileLoader.load(
            path: Self.productionProfilePath,
            displayNames: session.registered
        )
        let participants = loaded.map { (speakerId: $0.id, embedding: $0.embedding) }
        for p in loaded { idToName[p.id.uuidString] = p.displayName }

        let diarizer = FluidAudioSpeakerDiarizer(
            similarityThreshold: Constants.Embedding.similarityThreshold,
            windowDuration: 15.0,
            diarizationChunkDuration: 7.0,
            expectedSpeakerCount: participants.count
        )
        try await diarizer.setup()
        diarizer.loadSpeakerProfiles(participants)
        diarizer.setSuppressLearning(true)

        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)

        // VAD-chunk the audio (100ms increments), tracking absolute audio time.
        let samples = try loadAudioSamples(from: wavURL.path)
        var acc = VADChunkAccumulator(
            maxChunkDuration: Constants.VAD.defaultMaxChunkDuration,
            endOfUtteranceSilence: Constants.VAD.defaultEndOfUtteranceSilence,
            silenceEnergyThreshold: Constants.VAD.defaultSilenceEnergyThreshold,
            speechOnsetThreshold: Constants.VAD.defaultSpeechOnsetThreshold,
            preRollDuration: Constants.VAD.defaultPreRollDuration,
            hangoverDuration: Constants.VAD.defaultHangoverDuration
        )
        let sr = Constants.Audio.sampleRateInt
        let inc = Int(0.1 * Double(sr))

        struct PendingChunk { let start: Double; let end: Double }
        var out: [(start: Double, end: Double, predicted: String)] = []
        var pendingChunks: [PendingChunk] = []   // chunks awaiting Viterbi confirmation

        var lastConfirmed: String? = nil
        var offset = 0
        var emittedEnd = 0

        func handle(chunk: ChunkResult, endSample: Int) async {
            let endT = Double(endSample) / Double(sr)
            let startT = endT - Double(chunk.samples.count) / Double(sr)
            let significantSilence = chunk.precedingSilenceDuration >= Constants.VAD.defaultEndOfUtteranceSilence
            if significantSilence { smoother.resetForSpeakerChange() }
            let raw = await diarizer.identifySpeaker(
                audioChunk: chunk.samples, forceRun: significantSilence, utteranceId: chunk.utteranceId
            )
            let smoothed = smoother.process(raw)
            if let s = smoothed {
                let id = s.speakerId.uuidString
                lastConfirmed = id
                // Retroactively flush any pending chunks to this confirmed id.
                for pc in pendingChunks { out.append((pc.start, pc.end, id)) }
                pendingChunks.removeAll()
                out.append((startT, endT, id))
            } else {
                pendingChunks.append(PendingChunk(start: startT, end: endT))
            }
        }

        while offset < samples.count {
            let end = min(offset + inc, samples.count)
            emittedEnd = end
            if let chunk = acc.appendBuffer(Array(samples[offset..<end])) {
                await handle(chunk: chunk, endSample: emittedEnd)
            }
            offset = end
        }
        if let chunk = acc.flush() {
            await handle(chunk: chunk, endSample: emittedEnd)
        }
        // Any still-pending chunks inherit the last confirmed speaker.
        if let last = lastConfirmed {
            for pc in pendingChunks { out.append((pc.start, pc.end, last)) }
        }
        out.sort { $0.start < $1.start }
        return out
    }
```

- [ ] **Step 2: Verify it compiles (no test runs the helper yet, but the target must build)**

Run: `swift build`
Expected: build succeeds. (`loadAudioSamples` is inherited if the class subclasses `DiarizationBenchmarkTestBase`. **Important:** change the class declaration to `final class ConfusionPairAnalysisTests: DiarizationBenchmarkTestBase` so `loadAudioSamples(from:)` is available — it lives there at `DiarizationBenchmarkTests.swift:53`.)

- [ ] **Step 3: Apply the superclass change**

Edit the class declaration from Task 4:

```swift
final class ConfusionPairAnalysisTests: DiarizationBenchmarkTestBase {
```

- [ ] **Step 4: Build again**

Run: `swift build`
Expected: success.

- [ ] **Step 5: Commit**

```bash
git add Tests/QuickTranscriberBenchmarks/ConfusionPairAnalysisTests.swift
git commit -m "feat: Part B Manual-mode diarization replay harness"
```

---

## Task 6: Part B — confusion matrix driver test

**Files:**
- Modify: `Tests/QuickTranscriberBenchmarks/ConfusionPairAnalysisTests.swift`

- [ ] **Step 1: Add the driver test**

```swift
    struct SessionConfusionArtifact: Codable {
        let session: String
        let registered: [String]
        let matrix: ConfusionMatrixResult
        let chunkCount: Int
        let attributedCount: Int   // chunks with a Zoom GT speaker
    }

    func testRealSessionConfusion() async throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.productionProfilePath),
            "production speakers.json not present"
        )
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.sessionsRoot.path),
            "real-sessions directory not present"
        )

        var artifacts: [SessionConfusionArtifact] = []
        for session in Self.sessions {
            let dir = Self.sessionsRoot.appendingPathComponent(session.dirName)
            let zoomURL = dir.appendingPathComponent("zoom_transcript.txt")
            guard FileManager.default.fileExists(atPath: zoomURL.path) else {
                NSLog("[ConfusionPair] SKIP \(session.dirName): no zoom_transcript.txt"); continue
            }
            let zoomRaw = try String(contentsOf: zoomURL, encoding: .utf8)
            let gtSegments = try SessionTimeAligner.zoomSegmentsAudioRelative(
                zoomRaw: zoomRaw,
                qtStartSecondsOfDay: session.qtStartSecondsOfDay,
                audioDurationSeconds: session.audioDurationSeconds
            )

            var idToName: [String: String] = [:]
            let predicted = try await replay(session: session, idToName: &idToName)

            // Attribute each predicted chunk to a Zoom GT speaker by max overlap.
            var rows: [(gt: String, pred: String)] = []
            for chunk in predicted {
                guard let predName = idToName[chunk.predicted] else { continue }
                guard let gtShort = groundTruthShortName(
                    chunkStart: chunk.start, chunkEnd: chunk.end, segments: gtSegments
                ) else { continue }
                rows.append((gt: gtShort, pred: predName))
            }

            // Speaker axis: registered roster ∪ any GT speaker seen (e.g. 佐々木).
            let gtSpeakers = Set(rows.map(\.gt))
            let speakers = (session.registered + gtSpeakers.sorted()).reduced()
            let matrix = ConfusionMatrixBuilder.build(
                rows: rows, speakers: speakers, falseTarget: "神野", silentSpeakers: ["神野"]
            )

            artifacts.append(SessionConfusionArtifact(
                session: session.dirName, registered: session.registered,
                matrix: matrix, chunkCount: predicted.count, attributedCount: rows.count
            ))

            NSLog("[ConfusionPair] \(session.dirName): chunks=\(predicted.count) attributed=\(rows.count) false神野=\(matrix.totalFalseTarget)")
            for (gt, n) in matrix.falseTargetByGroundTruth.sorted(by: { $0.value > $1.value }) {
                NSLog("[ConfusionPair]   神野⟵\(gt): \(n)")
            }
        }

        XCTAssertFalse(artifacts.isEmpty, "no sessions processed")
        let outURL = URL(fileURLWithPath: "/tmp/confusion_sessions.json")
        try JSONEncoder().encode(artifacts).write(to: outURL, options: .atomic)
        NSLog("[ConfusionPair] session confusion written: \(outURL.path)")
    }

    /// Max-overlap Zoom GT speaker (short name) for a chunk time-range, nil if no overlap.
    private func groundTruthShortName(
        chunkStart: Double, chunkEnd: Double, segments: [ZoomSegment]
    ) -> String? {
        var overlapByShort: [String: Double] = [:]
        for seg in segments {
            let o = max(0, min(seg.endSeconds, chunkEnd) - max(seg.startSeconds, chunkStart))
            guard o > 0 else { continue }
            let short = Self.zoomToShort[seg.speaker] ?? seg.speaker
            overlapByShort[short, default: 0] += o
        }
        return overlapByShort.max(by: { $0.value < $1.value })?.key
    }
```

Add a tiny array helper (dedupe preserving order) at file scope:

```swift
private extension Array where Element == String {
    func reduced() -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for e in self where !seen.contains(e) { seen.insert(e); out.append(e) }
        return out
    }
}
```

- [ ] **Step 2: Run the driver (this is the ~compute step — diarization only, no WhisperKit)**

Run: `swift test --filter ConfusionPairAnalysisTests/testRealSessionConfusion 2>&1 | tee /tmp/confusion_run.log`
Expected: completes (loads FluidAudio models once, then replays both WAVs). Watch the `[ConfusionPair]` lines for `false神野=N` and the `神野⟵<speaker>` breakdown. `/tmp/confusion_sessions.json` is written.

> If diarization is too slow at full length, there is no internal cap to remove — the replay is already diarization-only. Expect on the order of a few minutes per session on Apple Silicon. Do not silently truncate; if you must shorten for a smoke test, log the truncation and re-run full before writing the report.

- [ ] **Step 3: Commit**

```bash
git add Tests/QuickTranscriberBenchmarks/ConfusionPairAnalysisTests.swift
git commit -m "feat: Part B real-session confusion matrix driver"
```

---

## Task 7: Python renderer for both artifacts

**Files:**
- Create: `Scripts/analyze_confusion_pairs.py`

- [ ] **Step 1: Write the renderer**

```python
#!/usr/bin/env python3
"""Render confusion-pair JSON artifacts into a markdown report.

Inputs (written by ConfusionPairAnalysisTests):
  /tmp/confusion_roster_similarity.json   (Part A)
  /tmp/confusion_sessions.json            (Part B)

Usage:
  python3 Scripts/analyze_confusion_pairs.py [roster.json] [sessions.json] > report.md
"""
import json, sys

roster_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/confusion_roster_similarity.json"
sessions_path = sys.argv[2] if len(sys.argv) > 2 else "/tmp/confusion_sessions.json"

def render_roster(path):
    d = json.load(open(path))
    sp = d["speakers"]; m = d["matrix"]
    print("## Part A — Registered-roster pairwise cosine similarity\n")
    print("| | " + " | ".join(sp) + " |")
    print("|" + "---|" * (len(sp) + 1))
    for i, name in enumerate(sp):
        cells = " | ".join(f"{m[i][j]:.3f}" for j in range(len(sp)))
        print(f"| **{name}** | {cells} |")
    print("\n**Top pairs:**\n")
    for p in d["topPairs"][:8]:
        print(f"- {p['a']} ↔ {p['b']}: {p['similarity']:.3f}")
    print()

def render_sessions(path):
    arts = json.load(open(path))
    print("## Part B — Real-session confusion matrices\n")
    for a in arts:
        mx = a["matrix"]; sp = mx["speakers"]
        print(f"### {a['session']}")
        print(f"Registered: {', '.join(a['registered'])} · "
              f"chunks={a['chunkCount']} · attributed={a['attributedCount']} · "
              f"**false-神野={mx['totalFalseTarget']}**\n")
        print("GT＼Pred | " + " | ".join(sp) + " |")
        print("|" + "---|" * (len(sp) + 1))
        counts = mx["counts"]
        for gt in sp:
            row = counts.get(gt, {})
            cells = " | ".join(str(row.get(pred, 0)) for pred in sp)
            print(f"| **{gt}** | {cells} |")
        if mx["falseTargetByGroundTruth"]:
            print("\n**神野 ⟵ (which GT speaker got mislabeled as 神野):**\n")
            for gt, n in sorted(mx["falseTargetByGroundTruth"].items(), key=lambda x: -x[1]):
                print(f"- {gt}: {n}")
        print()

print("# Confusion Pair Analysis Report\n")
render_roster(roster_path)
render_sessions(sessions_path)
```

- [ ] **Step 2: Run it**

Run: `python3 Scripts/analyze_confusion_pairs.py > /tmp/confusion_report.md && cat /tmp/confusion_report.md`
Expected: a readable markdown report with the Part A matrix and per-session Part B confusion matrices + 神野-attribution lists.

- [ ] **Step 3: Commit**

```bash
git add Scripts/analyze_confusion_pairs.py
git commit -m "feat: confusion-pair JSON → markdown renderer"
```

---

## Task 8: Final report + committed artifacts

**Files:**
- Create: `docs/benchmarks/2026-06-04-confusion-pair/roster_similarity.json` (copy from /tmp)
- Create: `docs/benchmarks/2026-06-04-confusion-pair/sessions.json` (copy from /tmp)
- Create: `docs/benchmarks/2026-06-04-confusion-pair/report.md`

- [ ] **Step 1: Copy artifacts into the repo**

```bash
mkdir -p docs/benchmarks/2026-06-04-confusion-pair
cp /tmp/confusion_roster_similarity.json docs/benchmarks/2026-06-04-confusion-pair/roster_similarity.json
cp /tmp/confusion_sessions.json docs/benchmarks/2026-06-04-confusion-pair/sessions.json
```

> The committed JSON contains only short display names + similarity floats + integer counts — no embeddings, no raw audio, no Zoom text. Safe for the public repo. **Do not** copy `speakers.json` or any embedding vectors.

- [ ] **Step 2: Write `report.md`** combining the rendered tables with an interpretation section that answers the handoff's decision question. Required sections:
  1. **Method** — roster assumption, time alignment, diarization-only replay (no WhisperKit), read-only contract.
  2. **Part A findings** — the rendered roster matrix; call out 神野↔上東 (0.764), 神野↔森 (0.768), 上東↔森 (0.789), and 佐々木↔神野 (0.785, 佐々木 unregistered/under-enrolled).
  3. **Part B findings** — per-session confusion matrices; the headline false-神野 count and which GT speaker(s) it came from. State explicitly whether the user's "always-flipping pair" intuition is confirmed (does 神野 capture 上東/森, and does 佐々木 collapse to 神野 in 2026-04-21).
  4. **Decision** — pick among the handoff's three remediation directions with evidence:
     - registration-time overlap warning (warn when a new enrollment's max cosine to an existing profile exceeds a threshold, e.g. > 0.75),
     - runtime margin penalty (require the winning profile to beat the runner-up by a margin before switching, especially toward silent/low-activity profiles),
     - targeted re-enrollment (re-record 神野 / under-enrolled profiles).
  5. **Limitations** — two sessions only; Zoom GT noise; time-alignment ±seconds; roster reconstructed not recorded.

- [ ] **Step 3: Verify the report reproduces the reconnaissance numbers** (Part A matrix in the report must match the "Background findings" block in this plan within rounding).

- [ ] **Step 4: Commit**

```bash
git add docs/benchmarks/2026-06-04-confusion-pair/
git commit -m "docs: confusion-pair analysis report + artifacts"
```

---

## Self-Review notes

- **Spec coverage:** Plan covers handoff Priority 1 steps 1-3 (load roster, pairwise similarity, cross-reference real sessions for flip attribution). The downstream decision question (registration warning / runtime margin / re-enrollment) is answered in Task 8 step 2.4.
- **Read-only contract:** every production-data touch goes through `SpeakerProfileLoader` (load-only) or `String(contentsOf:)`; no task writes to `~/QuickTranscriber/` or `~/Documents/QuickTranscriber/real-sessions/`. Committed artifacts contain no embeddings or raw transcripts.
- **No new production code:** `Sources/` is untouched; this is pure analysis in the benchmark test target + a Script.
- **Why no WhisperKit (justification for skipping the full pipeline):** the confusion matrix needs only speaker-label-over-time vs Zoom-speaker-over-time. Transcription text is irrelevant to it, and VAD chunk boundaries (which *do* matter) come from `VADChunkAccumulator` without the LLM. This keeps Part B to minutes, not real-time-bound.
- **Type consistency:** `ConfusionMatrixResult` defined in Task 3 is reused verbatim in Task 6's artifact. `SessionTimeAligner.zoomSegmentsAudioRelative` (Task 2) is the only Zoom-parse entry point used in Task 6. `replay(session:idToName:)` signature in Task 5 matches the call in Task 6.
- **Known fidelity gaps (documented, not silently ignored):** (1) roster is reconstructed, not recorded — stated as an assumption; (2) production also runs post-hoc learning at stop, which we skip (read-only) — but post-hoc learning does not affect *within-session* labels, so the confusion matrix is unaffected; (3) we omit transcription-driven quality filtering of chunks, which can change which chunks exist — acceptable since we attribute by time-overlap regardless.
