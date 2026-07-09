# Resume Point — 2026-06-10 (post stickiness-diagnostic)

> **SUPERSEDED (2026-07-09)** by `2026-07-09-calibration-dead-end.md`:
> Priority 1 (per-profile calibration) and Priority 2's accuracy rationale
> were both measured dead. See
> `docs/benchmarks/2026-07-09-calibration-ceiling/report.md`.

> Self-contained restart prompt for a fresh session. Supersedes
> `2026-06-10-resume.md`. Full evidence:
> `docs/benchmarks/2026-06-10-stickiness-diagnostic/report.md`.

## One-line current state

Priority-1 diagnostic is DONE (see report) and the **correction-poisoning fix SHIPPED
as v2.4.86 (PR #86, 2026-06-12)**: `profileSeedWeight = 10` weighted seeding +
similarityThreshold gating in Manual-mode `correctAssignment`. Post-fix benchmark
(persistence-2 oracle): **reverts 0/0** (was 1/10 — the lived "直してもまた戻る" is
addressed), centroid collapse eliminated (上東↔松浦 0.880 bounded / 松浦↔森谷
0.490 unchanged, vs 0.958/0.859 pre-fix), 04-21 errors 26→20 (+6 user-fixed chunks),
04-23 lived-neutral. Residuals documented in the report §Fix results: boundary-shadow
(confirmSpeaker hard reset) and the fundamental live-voice↔profile overlap. All
roster profiles remain `isLocked`, so nothing persists across sessions.

## Next session priorities

### Priority 1 — Per-profile score calibration (attractor demotion)

松浦's 171-session centroid matched OTHERS' voices at median 0.806 while their own
profiles matched at 0.560 (04-21). Cheap AS-norm variant: at `loadProfiles`, compute
each profile's mean cos to the other registered centroids and subtract (or divide) at
`identify` time. Benchmark: 04-21 上東→松浦 13 chunks should drop; 04-23 must not
regress (no attractor there — calibration must not overcorrect symmetric pairs).

### Priority 2 — Profile health surfacing / re-enrollment path

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
- F6 (new, 2026-06-12): boundary-shadow — a correction at a speaker boundary moves
  the error onto the next chunk (`confirmSpeaker` sets others to −100 and
  `pendingCount ≥ 2` hard-labels the next speaker's first chunk with the corrected
  speaker). Candidate: pending-on-contradiction for the first post-confirmSpeaker
  observation. Low lived impact (users correct sustained errors, not boundary lag).
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

> 「コンテキストを引き継いで再開してください。状況は `docs/superpowers/handoffs/2026-06-10-post-diagnostic.md` に書いてあります。correction-poisoning 修正は v2.4.86 で出荷済み。次は優先度1の per-profile score calibration（attractor demotion）から進めてください。実セッションでの v2.4.86 体感フィードバックがあればそれを先に確認。」
