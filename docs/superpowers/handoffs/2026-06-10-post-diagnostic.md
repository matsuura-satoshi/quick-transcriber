# Resume Point — 2026-06-10 (post stickiness-diagnostic)

> Self-contained restart prompt for a fresh session. Supersedes
> `2026-06-10-resume.md`. Full evidence:
> `docs/benchmarks/2026-06-10-stickiness-diagnostic/report.md`.

## One-line current state

Priority-1 diagnostic is DONE and redirected the plan: the flip problem is **raw
embedding/profile confusion** (smootherFlip = 0/51, window-swallow refuted), and the
**manual-correction path actively poisons the target profile** (confidence-1.0 append
of the confusable embedding at ~50 % weight → centroid collapse 上東↔松浦
0.769→0.958; oracle-correction replay made 04-23 WORSE, 25→41 wrong, 10/33
corrections reverted — reproducing the user's "直してもまた戻る"). All roster
profiles are `isLocked`, so no learning/correction persists across sessions.

## Next session priorities

### Priority 1 — Fix the correction-poisoning path (TDD, `Sources/` change, version bump + PR)

Two complementary levers, benchmark both with the now-existing oracle replay:

1. **Weighted seeding**: `EmbeddingBasedSpeakerTracker.loadProfiles` seeds each
   profile's history with ONE entry at confidence 1.0, so the first
   `correctAssignment` append (confidence 1.0) moves the centroid ~50 %. Seed with an
   effective weight ≫ 1 (e.g., confidence ~10, or k duplicate entries) so corrections
   nudge gently.
2. **Sample gating**: in Manual-mode `correctAssignment`, only append the corrected
   embedding when `cos(embedding, target centroid) >= similarityThreshold`; always
   record the `UserCorrection`. Rationale: the corrected segment's embedding is by
   construction the vector that matched the WRONG profile; blind 1.0-confidence
   append drags centroids together.

Success criteria (run `testCorrectionStickiness`): corrections strictly reduce errors
in BOTH sessions; centroid pairs stay apart (no before→after collapse); reverts drop.
Follow the Speaker State Mutation Checklist (CLAUDE.md). Mind the
feedback_user_not_watchdog principle: corrected = trusted *label*, but the attached
*embedding* may be blended/cached audio — trusting the label does not require
poisoning the centroid.

### Priority 2 — Per-profile score calibration (attractor demotion)

松浦's 171-session centroid matched OTHERS' voices at median 0.806 while their own
profiles matched at 0.560 (04-21). Cheap AS-norm variant: at `loadProfiles`, compute
each profile's mean cos to the other registered centroids and subtract (or divide) at
`identify` time. Benchmark: 04-21 上東→松浦 13 chunks should drop; 04-23 must not
regress (no attractor there — calibration must not overcorrect symmetric pairs).

### Priority 3 — Profile health surfacing / re-enrollment path

上東's own-voice↔own-profile cos is 0.55–0.72 depending on session. Options: warn
when a participant's best own-match median stays < 0.6 during a session; UI for
re-enrollment. Profiles are locked — any improvement must be explicit, not silent.

### Backlog (unchanged unless noted)

- F1: `silenceCutoffDuration` (0.6 s) doubles as VAD end-of-utterance AND Viterbi
  reset trigger → smoother bypassed at every pause, `confirmSpeaker` protection
  erased. Decouple thresholds (separate, larger silence for Viterbi reset).
- F2: pacer-cached results re-fed to Viterbi + stored on segments (3 staleCache
  errors, stale correction embeddings).
- F5 (new): `~/QuickTranscriber/embedding_history.json` has NEVER been written
  despite wiring in `stopStreaming` — root-cause the wiring (engine instance? error
  swallowed?).
- QT output timestamps; deferred_viterbi_grace_period (now low value — smoother is
  not the bottleneck); deferred_post_stability_fix item 1 (Viterbi guard — partially
  obsoleted by F1 finding).

## What NOT to do (updated)

- **Don't implement the old Priority-2 candidates**: smoother similarity-margin gate
  (smootherFlip = 0) or finer `findRelevantSegment` windowing (wrong-runs persist
  through 60 s+ of clean single-speaker audio; nothing is being "swallowed").
- Don't tune `speakerTransitionPenalty` further; don't ship A++ (0.95).
- Don't chase 神野 re-enrollment (false-神野 1 %); no April speakers.json exists.
- Don't enable Manual-mode within-session learning (config C) — diagnostic confirmed
  in-session appends are exactly how centroids collapse.

## Key files

| Concern | File |
|---|---|
| Diagnostic report (read first) | `docs/benchmarks/2026-06-10-stickiness-diagnostic/report.md` |
| Replay + oracle corrections + diagnostics | `Tests/QuickTranscriberBenchmarks/ConfusionPairAnalysisTests.swift` |
| Cause taxonomy + classifier (+ unit tests) | `Tests/QuickTranscriberBenchmarks/StickinessDiagnostic.swift`, `StickinessClassifierTests.swift` |
| Correction path (poisoning fix target) | `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift` (`correctAssignment`, `loadProfiles`) |
| Viterbi bypass (F1) | `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift` (`processChunk` significantSilence), `SpeakerLabelTracker.swift` (`resetForSpeakerChange`) |
| Artifacts | `/tmp/stickiness_baseline.json`, `/tmp/stickiness_corrections.json` |

## Repro

```bash
swift test --filter ConfusionPairAnalysisTests/testStickinessDiagnostic   # ~40 s
swift test --filter ConfusionPairAnalysisTests/testCorrectionStickiness   # ~75 s
swift test --filter StickinessClassifierTests                             # instant
```

## Suggested first prompt for the next session

> 「コンテキストを引き継いで再開してください。状況は `docs/superpowers/handoffs/2026-06-10-post-diagnostic.md` に書いてあります。優先度1の correction-poisoning 修正（weighted seeding + sample gating、TDD）から進めてください。」
