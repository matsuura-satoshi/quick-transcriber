# Calibration ceiling diagnostic — score/profile engineering cannot fix the confusion (2026-07-09)

**Question (2026-06-10 handoff Priority 1):** can per-profile score calibration
(AS-norm variants) demote the 松浦 attractor — 04-21 上東→松浦 13 chunks should
drop, 04-23 must not regress?

**Answer: no — and the negative result generalizes.** Offline what-if
simulation over recorded per-chunk embeddings shows that (1) per-profile scalar
calibration has NO workable operating point (the attack and defense score
distributions overlap), (2) session-scoped overlay matching (learning "today's
voice" from a correction) trades errors 1:1 or regresses, and (3) even oracle
day-profiles built from the session's own ground-truth voice do not reduce
total errors. The separation ceiling is the embedding space itself under these
acoustic conditions, not profile quality or score post-processing. This
invalidates the 2026-06-10 handoff's Priority 1 (calibration) **and** the
accuracy rationale of Priority 2 (re-enrollment).

## Method

`testStickinessDiagnostic` now records the raw query embedding per chunk
(`ChunkDiagnostic.embedding` → `StickinessRow.embedding`, this PR). In Manual
mode centroids are frozen (`suppressLearning = true`), so the raw layer —
argmax over cos(query, centroid) — is exactly reproducible offline from
`/tmp/stickiness_baseline.json` without replaying audio.

All numbers below are raw-level (pre-Viterbi). This proxy is justified by the
2026-06-10 finding that rawWrongFresh dominates (42/51) and smootherFlip = 0:
the smoother never rescues a consistently-wrong raw label. Correction dynamics
(v2.4.86 gated append, seed weight 10) are reproduced in the scripts where
relevant; the persistence-2 correction model matches the Swift oracle.

Scripts (in this directory, run against a regenerated baseline artifact):

```bash
swift test --filter ConfusionPairAnalysisTests/testStickinessDiagnostic  # writes /tmp/stickiness_baseline.json
python3 calibration_sim.py    # A1 static bias + A2 online bias, λ sweeps
python3 overlay_sim.py        # plain session-overlay (C0–C3)
python3 overlay_pair_sim.py   # pair-scoped overlay, τ/δ sweeps
python3 day_profile_sim.py    # oracle day-profile LOO ceiling
```

Baseline raw-wrong counts differ from the 2026-06-10 report's final-label
counts (04-21: raw 35 vs final 26) because Viterbi/pending dynamics are not
simulated; the targeted pair counts match (上東→松浦 13).

## Result 1 — the handoff's cheap AS-norm rests on a false premise

Static bias `b_i = mean cos(centroid_i, other centroids)` from the production
roster (speakers.json, 2026-07-09):

| profile | sessions | mean bias | max |
|---|---|---|---|
| 上東 | 57 | **0.735** | 0.789 |
| 森 | 90 | 0.702 | 0.789 |
| 今村 | 66 | 0.690 | 0.782 |
| 神野 | 46 | 0.685 | 0.768 |
| **松浦 (attractor)** | 171 | **0.626** | 0.769 |
| 森谷 | 61 | 0.589 | 0.678 |

松浦's 171-session broad centroid is close to *live voices in general*, not to
the other stored centroids — its static bias is the 2nd-LOWEST in the roster.
Subtracting it demotes the wrong profiles: 上東→松浦 stays 13/13 at every λ
(04-21 total 35→34 at best). The 2026-06-10 caveat "static profile↔profile
similarity could not see this" applies to the proposed fix itself.

Online per-profile bias (causal running mean of each profile's live scores,
warm-up 10 chunks) is worse: 04-21 35→38, 04-23 43→60 at λ=1.

## Result 2 — no per-profile scalar exists (distributions overlap)

Oracle sweep demoting ONLY 松浦's score by β (04-21):

| β | total wrong | 上東→松浦 | 松浦→X |
|---|---|---|---|
| 0.00 | 35 | 13 | 12 |
| 0.15 | 36 | 12 | 14 |
| 0.20 | 39 | 11 | 18 |
| 0.25 | 49 | 9 | 30 |
| 0.30 | 56 | 1 | 45 |

The attack gap (cos松浦 − cos上東 on 上東→松浦 errors) spans **0.146–0.304**;
松浦's own defense margin (cos松浦 − runner-up on his correct chunks) spans
**0.049–0.339**. The distributions interleave, so *any* per-profile scalar
(subtractive, divisive, z-norm — all are monotone per-profile transforms)
trades one error for more than one. This is a property of the data, not of a
particular formula: the method class is dead, not just the handoff's variant.

## Result 3 — session-overlay matching trades or regresses

Design tested: a Manual-mode correction stores the corrected chunk's embedding
as a session-scoped sample for the target; identify may then match
`max(cos to centroid, cos to overlay samples)`. Rationale: the misattributed
上東 chunks are coherent (all 0.81–0.89 to 松浦's centroid), so one correction
might rescue the rest of the day. Persistence-2 correction model, v2.4.86
centroid drift on in all configs.

- Plain overlay (04-21): system-wrong 36→30, 上東→松浦 13→9, but 8 chunks
  newly broken by overlay mis-matches. 04-23: **43→46/48 regression** — in the
  symmetric 松浦↔森谷 confusion the corrected embeddings sit between both
  voices and the overlays capture each other.
- Pair-scoped overlay (flip only when centroid-argmax equals the corrected
  `from`) with gate τ ∈ [0.70, 0.90] and margin δ ∈ {0, 0.05}: best 04-21
  operating point 36→31 with good/bad flips 12/8; tightening to τ=0.90 gives
  5/2 — the signal is at noise level. 04-23 regresses or is flat everywhere
  (worst: flips 6/19).

"Today's 上東-as-misheard" and "松浦's actual voice" are too close even at the
sample level for a cosine gate to separate.

## Result 4 — oracle day-profiles do not lift the ceiling

Leave-one-out day centroids built from each speaker's *own ground-truth chunks
of the same session* — the theoretical best case for any (re-)enrollment:

| session | stored profiles | oracle day-profiles (LOO) |
|---|---|---|
| 04-21 | wrong=32 (上東→松浦 13) | wrong=**37** (上東→松浦 4, but 松浦→今村 12, 上東→今村 9) |
| 04-23 | wrong=41 (松浦↔森谷 22) | wrong=**43** (松浦↔森谷 22 — unchanged) |

Own-voice cos improves dramatically (上東 0.579→0.794, 今村 0.503→0.922) —
and impostor cos rises just as much. Errors relocate; the total does not drop.
Fresh profiles cannot separate what the embedding space does not separate.

## Conclusions

1. **Priority 1 (per-profile calibration) is dead** — no operating point
   exists for the method class (Result 2).
2. **Priority 2 (re-enrollment) loses its accuracy rationale** — even perfect
   same-day profiles don't reduce total errors (Result 4). Profile *health
   surfacing* may still be worth building for trust/UX, but it should not be
   sold as an accuracy fix for sessions like these.
3. **The ceiling is upstream**: the FluidAudio embedding under these acoustic
   conditions (Zoom far-end audio recorded in a meeting room) does not
   separate this roster. Moving it means changing the embedding input (longer
   /cleaner windows, acoustic preprocessing, model choice) — a different,
   larger project that should start with a clean-audio control experiment to
   split "model limit" from "acoustic-condition limit".
4. v2.4.86's value is untouched: it fixed correction *poisoning* (reverts
   1/10→0/0). What it cannot do — and what nothing at this layer can do — is
   make the underlying identification correct.

## Limitations

- Raw-level proxy: Viterbi/pending dynamics not simulated (justified above;
  final-label deltas may differ slightly, direction cannot flip).
- Two sessions, same roster, same room/setup — the strongest statement
  supported is "for sessions like these, nothing at this layer helps". A
  clean-audio control would bound the model's intrinsic separation ability.
- Oracle day-profiles use ground truth (selection-bias-free LOO) — real
  re-enrollment would be strictly worse.
