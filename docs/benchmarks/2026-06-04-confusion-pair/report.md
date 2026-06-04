# Confusion Pair Analysis Report

**Date:** 2026-06-05 (analysis run) · **Plan:** `docs/superpowers/plans/2026-06-04-confusion-pair-analysis.md`
**Status:** Complete. Headline result is **nuanced / partly refutes the starting hypothesis** — read §4 (Reconciliation) and §6 (Limitations) before acting on §5.

## TL;DR

- **Part A (static, profile↔profile cosine)** confirmed the geometric hypothesis: 神野 sits at the centroid of the active-speaker cluster (神野↔上東 0.764, 神野↔森 0.768), and 上東↔森 (0.789) is the tightest registered-roster pair.
- **Part B (empirical replay through the v2.4.81 Manual-mode diarizer, current profiles)** did **not** reproduce frequent false-神野: only **2 of 202 attributed chunks (1.0 %)** were wrongly labeled 神野.
- The **dominant** within-session confusion is **→ 松浦**, the most-trained / highest-norm profile, which acted as an attractor: **28 chunks were wrongly absorbed by 松浦 vs 2 by 神野** (14×). The main victim was 上東 (21 of its chunks mislabeled), heavily in the 2026-04-21 session.
- **Static pairwise similarity did not predict live behavior.** The biggest live attractor (松浦) is not 神野's nearest neighbour, and a low-similarity pair (松浦↔森谷, 0.490) produced 7 live confusions. Live assignment is driven by per-chunk audio embeddings + diarization windowing + Viterbi stay-bias + hit-count tie-breaking, not by stored-centroid proximity alone.
- **Critical caveat:** `speakers.json` is the 2026-06-04 snapshot; the sessions are from 2026-04-21/23. ~6 weeks of additional post-hoc learning have refined the profiles since. The user's *lived* 神野 problem occurred with **earlier, less-separated** profile states this replay cannot reproduce. The cleanest follow-up is to re-run against a session-time profile snapshot if one can be recovered.

---

## 1. Method

- **Part A** loads the 6-person standing roster (松浦, 今村, 上東, 森, 森谷, 神野) from the production `~/QuickTranscriber/speakers.json` (read-only, via `SpeakerProfileLoader`) and computes the pairwise cosine-similarity matrix with the canonical `EmbeddingBasedSpeakerTracker.cosineSimilarity`. No model.
- **Part B** replays each real-session `audio.wav` through the production Manual-mode pipeline: `VADChunkAccumulator` (100 ms increments, factory-default VAD params) → `FluidAudioSpeakerDiarizer` (participant profiles loaded, `suppressLearning=true`, `expectedSpeakerCount=6`, window 15 s / diar-chunk 7 s, matching production defaults) → `ViterbiSpeakerSmoother(stayProbability: 0.9)`, with `resetForSpeakerChange()` on significant preceding silence. Each confirmed chunk yields `(startTime, endTime, predictedSpeakerUUID)`. **No WhisperKit / no transcription** — the confusion matrix needs only speaker-label-over-time. Strictly read-only on production data; no embeddings, audio, or Zoom text are committed.
- **Ground truth** comes from the Zoom transcripts (`ZoomTranscriptParser` + `SessionTimeAligner`), aligned to audio time via the qt_transcript frontmatter `date:` (audio t=0). Each predicted chunk is attributed to the max-overlap Zoom speaker.
- **Roster assumption:** the exact Manual-mode participant list was not recorded; we reconstruct the standing roster of 6 regulars present in the store. The user confirmed 神野 was registered-but-silent and is *frequently* mis-assigned in lived use — the headline metric is therefore the false-神野 count.

## 2. Part A — Registered-roster pairwise cosine similarity

| | 松浦 | 今村 | 上東 | 森 | 森谷 | 神野 |
|---|---|---|---|---|---|---|
| **松浦** | 1.000 | 0.669 | 0.769 | 0.653 | 0.490 | 0.551 |
| **今村** | 0.669 | 1.000 | 0.782 | 0.712 | 0.624 | 0.664 |
| **上東** | 0.769 | 0.782 | 1.000 | 0.789 | 0.569 | 0.764 |
| **森** | 0.653 | 0.712 | 0.789 | 1.000 | 0.585 | 0.768 |
| **森谷** | 0.490 | 0.624 | 0.569 | 0.585 | 1.000 | 0.678 |
| **神野** | 0.551 | 0.664 | 0.764 | 0.768 | 0.678 | 1.000 |

Top pairs: 上東↔森 **0.789**, 今村↔上東 0.782, 松浦↔上東 0.769, 森↔神野 **0.768**, 上東↔神野 **0.764**, 今村↔森 0.712.

**Reading:** 神野 is geometrically central — within ~0.76 of both active speakers 上東 and 森 — and 上東/今村/森 form a tight cluster (all ≥ 0.71). 森谷 is the most distinct (lowest off-diagonals). Profile maturity varies widely: 松浦 171 sessions (norm 0.610, highest), 森 90, 今村 66, 森谷 61, 上東 57, 神野 46. 佐々木 has only 1 session (norm 0.723, an under-enrolled outlier) and is **not** part of the loadable roster.

This static view *supports* the "神野 overlaps the active speakers" hypothesis. Part B tests whether that translates into behavior.

## 3. Part B — Real-session confusion matrices (current profiles)

### 2026-04-21 — registered 6; active in Zoom: 松浦, 上東, 今村, (佐々木 ×1); 森/森谷/神野 silent
chunks=88 · attributed=83 · **false-神野 = 0**

| GT＼Pred | 松浦 | 今村 | 上東 | 森 | 森谷 | 神野 |
|---|---|---|---|---|---|---|
| **松浦** | 48 | 0 | 5 | 0 | 0 | 0 |
| **今村** | 4 | 0 | 0 | 0 | 0 | 0 |
| **上東** | 13 | 4 | 9 | 0 | 0 | 0 |
| **森** | 0 | 0 | 0 | 0 | 0 | 0 |
| **森谷** | 0 | 0 | 0 | 0 | 0 | 0 |
| **神野** | 0 | 0 | 0 | 0 | 0 | 0 |

- 松浦 91 % correct. **上東 only 35 %** — 13/26 of 上東's chunks labeled 松浦, 4 labeled 今村. 今村 0/4 (all → 松浦).
- The silent registered speakers 森/森谷/神野 were **never** predicted. **No false-神野.**
- 佐々木 (1 brief Zoom turn) never won an attributed chunk → the "佐々木 impostor → 神野" hypothesis is **untested** here (insufficient 佐々木 speech).

### 2026-04-23 — active: 松浦, 上東, 森, 森谷; 今村×2, 神野 silent
chunks=119 · attributed=119 · **false-神野 = 2** (森→神野 1, 松浦→神野 1)

| GT＼Pred | 松浦 | 今村 | 上東 | 森 | 森谷 | 神野 |
|---|---|---|---|---|---|---|
| **松浦** | 32 | 0 | 3 | 1 | 7 | 1 |
| **今村** | 0 | 0 | 0 | 0 | 0 | 0 |
| **上東** | 3 | 0 | 29 | 0 | 1 | 0 |
| **森** | 2 | 0 | 0 | 6 | 0 | 1 |
| **森谷** | 6 | 0 | 0 | 0 | 27 | 0 |
| **神野** | 0 | 0 | 0 | 0 | 0 | 0 |

- Much cleaner: 上東 88 %, 森谷 82 %, 松浦 73 %, 森 67 %.
- 神野 captured only 2 chunks total. 松浦→森谷 (7) is notable **despite** their low static similarity (0.490).

### Cross-session aggregates (both sessions, 202 attributed chunks)

- **Overall chunk accuracy: 151/202 = 75 %.**
- **Attractor** (label that wrongly absorbed other speakers' chunks): **→松浦 28**, →上東 8, →森谷 8, →今村 4, **→神野 2**, →森 1.
- **Victim** (GT speaker whose chunks were mislabeled): **上東 21**, 松浦 17, 森谷 6, 今村 4, 森 3.

## 4. Reconciliation — why static similarity ≠ live behavior

The starting hypothesis (神野's high centroid-similarity to active speakers makes it a frequent attractor) is **not** what the replay shows. Instead:

1. **The attractor is the high-hit-count / high-norm profile (松浦), not the nearest-neighbour silent profile (神野).** 松浦 has 171 sessions and the highest embedding norm; the tracker's tie-breaker explicitly prefers the highest `hitCount` profile (`EmbeddingBasedSpeakerTracker.identify`), and a larger-norm centroid wins more cosine comparisons against noisy live embeddings. 松浦 absorbed 28 chunks; 神野 absorbed 2.
2. **Diarization windowing matters.** A 15 s rolling window with 7 s accumulation means a short turn by speaker B inside speaker A's monologue is embedded in an A-dominated window and inherits A's label (`findRelevantSegment` picks the max-overlap segment). 上東's short agenda interjections inside 松浦's long 04-21 monologue are the clearest case (13 → 松浦).
3. **Viterbi stay-bias (0.9)** further locks onto the currently-confirmed speaker, so once 松浦 is confirmed, brief other-speaker chunks tend not to flip.
4. **Low-similarity confusions occur** (松浦→森谷 at 0.490), and **high-similarity pairs stay separated** (上東 88 % in 04-23 despite 上東↔森 0.789, 上東↔松浦 0.769). Pairwise centroid cosine is therefore a weak predictor of live confusion.
5. **Session dependence:** 上東 was 35 % correct in 04-21 but 88 % in 04-23. Confusion is a property of session dynamics (overlap, turn length, who dominates each window), not a fixed property of a profile pair.

**Bottom line:** confusion is dominated by an attractor effect (well-trained 松浦) compounded by windowing, not by 神野's embedding overlap — at least with the current profile snapshot.

## 5. Decision — recommendations against the handoff's three directions

| Direction | Verdict on this evidence |
|---|---|
| **Targeted 神野 re-enrollment** | **De-prioritize.** With current profiles, 神野 misfires on only 2/202 chunks. Re-enrolling 神野 would address a problem the current data barely shows. (May still matter for older profile states — see §6.) |
| **Registration-time overlap warning** | **Keep as cheap prevention, not a proven fix.** The high static overlaps are real (神野↔上東 0.764, 神野↔森 0.768, 上東↔森 0.789); a warning when a new enrollment's max cosine to an existing profile exceeds ~0.75 would flag them. But Part B shows high static overlap does not reliably cause runtime confusion, so the warning is informational/preventive, not a behavioral remedy. |
| **Runtime margin penalty** | **Most promising, but re-targeted.** The lever is the **high-hit-count attractor (松浦)**, not the silent profile. Two concrete experiments worth a dedicated study: (a) require the winning profile to beat the runner-up by a similarity margin before (re)assigning, especially toward a much-higher-hit-count profile; (b) reduce or remove the `hitCount`-based tie-breaker (or normalize centroids) so a heavily-trained profile stops winning marginal comparisons. Target metric: 上東/今村 → 松浦 rate. |

**Single highest-value follow-up:** **re-run Part B against a session-time `speakers.json` snapshot** (Time Machine / any backup from late April 2026). That is the only way to test whether the lived frequent-神野 problem was a property of *earlier* profile states that current learning has already partly fixed. If no snapshot exists, treat the lived problem as "likely self-corrected by subsequent learning" and watch for recurrence.

## 6. Limitations

1. **Profile-snapshot mismatch (most important).** `speakers.json` is 2026-06-04; sessions are 2026-04-21/23. The replay uses profiles that have had ~6 weeks more post-hoc learning than the live sessions did. This very plausibly explains why false-神野 is rarer in replay than in lived experience — the current 神野/active-speaker centroids are better separated than they were in April.
2. **Two sessions only**, both from the same recurring meeting and speaker set — limited statistical power.
3. **Roster reconstructed, not recorded** (6 regulars assumed). A different live roster would change the dynamics.
4. **佐々木 impostor test inconclusive** — only 1 brief Zoom turn, no attributed chunk.
5. **Zoom GT noise + alignment.** Zoom's own ASR/diarization is imperfect; audio↔Zoom alignment carries a ±sub-second offset (chunk timestamps also include ~0.3 s pre-roll + ~0.15 s hangover). Robust for per-speaker aggregates, not for individual-chunk verdicts.
6. **WhisperKit-free replay.** Production filters some chunks by transcription quality before they become segments; the replay attributes every VAD chunk by time-overlap regardless. This can shift which chunks exist at the margins.
7. **VAD parameters assumed factory-default** (`Constants.VAD.default*`); a session run with customized VAD settings would segment differently. The recorded WAV is already normalized (QT writes normalized samples), so it is replayed raw; the Int16 round-trip adds negligible quantization.

## 7. Reproduce

```bash
# Part A (static, seconds): writes /tmp/confusion_roster_similarity.json
swift test --filter ConfusionPairAnalysisTests/testStaticRosterSimilarity
# Part B (diarization replay, ~40 s): writes /tmp/confusion_sessions.json
swift test --filter ConfusionPairAnalysisTests/testRealSessionConfusion
# Render:
python3 Scripts/analyze_confusion_pairs.py > /tmp/confusion_report.md
```

Committed artifacts (names/floats/counts only — no embeddings): `roster_similarity.json`, `sessions.json`.
