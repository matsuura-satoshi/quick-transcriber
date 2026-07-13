# Stickiness Diagnostic — why labels flip and why corrections don't stick (2026-06-10)

> **FIX SHIPPED (2026-06-12, v2.4.86):** the correction-poisoning path identified below
> was fixed by weighted profile seeding (`profileSeedWeight = 10`) + correction-sample
> gating (`>= similarityThreshold` vs target). See §"Fix results (2026-06-12)" at the
> end of this report for the post-fix benchmark.
>
> **FOLLOW-UP (2026-07-09):** the "per-profile score calibration" direction recommended
> below (§Recommended Priority-2 direction, item 2) was measured and is a dead end —
> as is re-enrollment for accuracy purposes. See
> `docs/benchmarks/2026-07-09-calibration-ceiling/report.md`.

**Question (handoff Priority 1):** why do 上東/今村's chunks become 松浦 — is the raw
diarizer already wrong (window-swallow), or does the smoothing layer flip a correct
raw label (smoother-flip)? The split chooses the Priority-2 fix.

**Extension (user report 2026-06-10):** "A が話し続けているのに B に振れ、手動で A に
直してもまた B に戻る" — the diagnostic also simulates manual corrections through the
production path and measures whether they *stick*.

## TL;DR — the handoff's two candidate levers are both wrong; the problem is one layer deeper

1. **smoother-flip: 0 of 51 misattributed chunks.** The Viterbi layer never flipped a
   correct raw label. Tuning `speakerTransitionPenalty` further, margin gates in the
   smoother, or grace periods cannot fix what is already wrong before smoothing.
2. **window-swallow is refuted as the mechanism.** 42/51 errors are raw-wrong on
   *fresh* diarization runs, but they persist through 60 s+ of continuous
   single-speaker audio (verified against the Zoom transcript: 上東 gives a ~75 s
   report at 04-21 t=81–156 while every chunk is labeled 松浦 at cos 0.81–0.89).
   By then the 15 s window holds only 上東's voice — there is nothing to "swallow".
   The real cause is **embedding/profile confusion**: 上東's *live* voice scores
   0.85 to 松浦's stored centroid vs only 0.55 to 上東's own.
3. **Manual corrections poison the target profile** (the new, biggest finding).
   The production correction path appends the misattributed chunk's embedding —
   the very vector that scored 0.85 against the *wrong* profile — into the *right*
   speaker's history at confidence 1.0, where it gets ~50 % weight (history is
   seeded with a single entry at load). Oracle-correction replay of 04-23:
   **25 wrong → 41 wrong** (worse), 10/33 corrections reverted (often within 16 s —
   the user's lived "直してもまた戻る"), and centroid pairs collapsed toward each
   other: 上東↔松浦 0.769→0.958 (04-21), 松浦↔森谷 0.490→0.859 (04-23).
4. **Nothing persists across sessions.** All 6 roster profiles are `isLocked=true`,
   and `applyManualModePostHocLearning` skips locked profiles — so neither
   corrections nor post-hoc learning ever improve the stored profiles. Every meeting
   restarts the same battle. (The user's intuition "学習が進めば減るはず" is
   structurally impossible in the current configuration.)

## Results

### Part 1 — misattribution cause split (baseline replay, current profiles)

| Session | attributed | wrong | rawWrongFresh | pendingInherit | staleCache | smootherFlip |
|---|---|---|---|---|---|---|
| 2026-04-21 | 83 | 26 | 22 | 2 | 2 | **0** |
| 2026-04-23 | 119 | 25 | 20 | 4 | 1 | **0** |

Key pairs (all causes = rawWrongFresh unless noted):
- 上東→松浦 13 (04-21) + 3 (04-23) — **all rawWrongFresh**
- 今村→松浦 4 (04-21) — all rawWrongFresh
- 松浦→森谷 7 / 森谷→松浦 6 (04-23) — mostly rawWrongFresh, some pendingInherit
- 松浦→上東 5 (04-21) — staleCache 2, pendingInherit 2, rawWrongFresh 1

### Part 2 — why raw is wrong: profile match quality, not windowing

Margins (cosPred − cosGT) of wrong chunks are **large**: typically +0.15…+0.6
(median ≈ +0.29). These are not borderline ties a margin gate could veto.

cos(live voice, OWN stored centroid), per speaker:

| | correct chunks (median) | wrong chunks (median) |
|---|---|---|
| 松浦 04-21 | 0.809 | 0.522 |
| 上東 04-21 | 0.675 | 0.557 |
| 上東 04-23 | 0.717 | 0.585 |
| 森谷 04-23 | 0.738 | 0.365 |

Same speaker, same session: own-profile similarity swings hugely chunk-to-chunk.
When it dips, the broadest profile wins by default.

**The attractor is session-dependent.** For GT≠松浦 chunks:
- 04-21: cos to 松浦 median **0.806** vs cos to own **0.560** → 松浦's profile
  matched other people's voices *better than their own profiles did*, all session.
- 04-23: cos to 松浦 median 0.444 vs own 0.713 → no attractor; confusion was
  symmetric pair noise (松浦↔森谷).

松浦's profile (171 sessions of accumulated learning vs 46–90 for others) behaves
like a broad "generic meeting voice" centroid in bad-condition sessions. Static
profile↔profile similarity (#83 Part A) could not see this: it is a
live-voice↔profile phenomenon.

### Part 3 — correction stickiness (oracle replay through the production path)

Every own-confirmed wrong chunk corrected instantly (upper bound of user diligence):

| Session | baseline wrong | with corrections | corrections | reverts | revert delay (s) |
|---|---|---|---|---|---|
| 2026-04-21 | 26 | 16 | 12 | 1 | 120 |
| 2026-04-23 | 25 | **41** | 33 | **10** | 16,16,16,32,40,48,71,148,240,531 |

Centroid collapse caused by corrections (cos between stored-profile pair, before → after):
- 上東↔松浦 0.769 → **0.958** (04-21), 0.769 → 0.865 (04-23)
- 松浦↔森谷 0.490 → **0.859**, 松浦↔森 0.653 → 0.835 (04-23)
- 上東↔今村 0.782 → 0.911 (04-21)

Mechanism: `EmbeddingBasedSpeakerTracker.correctAssignment` (Manual mode) appends the
segment's embedding at confidence 1.0 to the target's history. Because `loadProfiles`
seeds the history with one entry, the first correction moves the centroid ~50 %, the
k-th leaves the original at 1/(k+1) weight. The appended vector is by definition the
confusable one (it just scored higher to the wrong profile), so each correction drags
the two centroids together; in dense sessions this *increases* subsequent errors and
produces the lived A→B→(correct)→B cycle. Cached embeddings (F2 below) were a minor
contributor here (3/45 corrections).

## Code-level findings (confirmed while building the diagnostic)

### F1. The Viterbi smoother is bypassed at every natural pause ≥ 0.6 s

`silenceCutoffDuration` (default 0.6 s) is both the VAD end-of-utterance threshold
and the "significant silence" trigger in `ChunkedWhisperEngine.processChunk`.
`VADChunkAccumulator.emitChunk` carries the ≥ 0.6 s trailing silence into the next
chunk's `precedingSilenceDuration`, so **every silence-terminated utterance** triggers
`resetForSpeakerChange()` → `immediateConfirmNext` → the next raw label is confirmed
instantly, no pending evaluation, no stay-bias. Viterbi smoothing only ever applies to
8 s max-duration cuts inside continuous speech. This also erases `confirmSpeaker()`
protection after a manual correction at the speaker's first pause.
*Not the measured cause of the #83 errors (smootherFlip = 0) but explains why the
smoother provides so little protection and why corrections have no lasting Viterbi
effect.*

### F2. Pacer-cached results are re-fed to the smoother and stored on segments

Between 7 s diarization runs, `pacer.lastResult` is returned per VAD chunk, counted
again by the Viterbi update, and stored as `ConfirmedSegment.speakerEmbedding` — an
embedding computed from an earlier window's audio. Caused 3 staleCache misattributions
and means some corrections inject audio the user never heard. Minor but real.

### F3. What a manual correction actually does

`reassignSegment` → `correctSpeakerAssignment`: (1) appends the segment embedding to
the target tracker profile at confidence 1.0 (the poisoning above); (2) calls Viterbi
`confirmSpeaker(newId)` only behind `if confirmedSpeakerId == oldId` (the 2026-04-17
deferred guard); whatever it sets is discarded at the next 0.6 s pause (F1). The only
durable within-session effect is the centroid move of (1) — which is the harmful part.

### F4. Profiles are locked and post-hoc learning is skipped

All roster profiles have `isLocked=true`; `applyManualModePostHocLearning` skips
locked profiles. Cross-session adaptation is fully off. (This also currently shields
the stored profiles from F3's poisoning — the collapse resets every session.)

### F5. `embedding_history.json` has never been written

`EmbeddingHistoryStore` targets `~/QuickTranscriber/embedding_history.json`; the file
does not exist despite many diarization sessions. The profile-reconstruction data the
store was built to accumulate is silently not being captured. Wiring not yet
root-caused (backlog).

## Recommended Priority-2 direction (replaces the handoff's two candidates)

Ranked by evidence:

1. **Fix the correction-poisoning path** (small, high-confidence, directly addresses
   the user's complaint):
   - Seed `loadProfiles` history with an effective weight ≫ 1 for the stored centroid
     (e.g., one entry with confidence ~10), so a correction nudges ~9 % instead of 50 %.
   - And/or gate the appended sample: only add the corrected embedding to the target
     when cos(embedding, target centroid) ≥ similarityThreshold; always record the
     `UserCorrection` regardless.
   - Benchmark with the oracle-correction replay (now in the test suite): success =
     corrections strictly reduce errors in BOTH sessions and centroid pairs stay apart.
2. **Per-profile score calibration** (the principled fix for the broad-profile
   attractor): normalize each profile's similarity by its expected off-target score
   (e.g., subtract mean cos to the other registered centroids — cheap AS-norm
   variant computable at session start). Should specifically demote 松浦-type broad
   centroids in bad sessions like 04-21.
3. **Profile health / re-enrollment**: 上東's profile matches his own live voice at
   only 0.55–0.72. A per-session "profile match health" signal (e.g., warn when a
   registered participant's best own-match stays < 0.6) would surface re-enrollment
   needs. Locked profiles currently prevent any silent fix.
4. (Hygiene, lower priority) F1 silence-reset threshold decoupling from the VAD
   end-of-utterance threshold; F2 cache re-feeding; F5 history-store wiring.

## What this changes vs the 2026-06-10 handoff

- "window-swallow vs smoother-flip" → **neither**. The split is 42 rawWrongFresh /
  6 pendingInherit / 3 staleCache / 0 smootherFlip, and rawWrongFresh is profile
  confusion, not windowing.
- The Priority-2 candidates listed there (similarity-margin gate in the smoother /
  finer `findRelevantSegment` granularity) target mechanisms measured at zero or
  near-zero here. Do not implement them for this problem.
- New top lever: correction-path repair (above), which also has the best
  effort-to-relief ratio for the user's daily pain.

## Method

Replay harness from #83 (`ConfusionPairAnalysisTests`), extended test-only:
per chunk: raw (pre-Viterbi) label, per-profile cosines, pacer-cache flag
(repeated-embedding detection), `significantSilence`, smoothed/final label,
pending-inheritance; classification in `StickinessClassifier`
(unit-tested, `StickinessClassifierTests`); oracle corrections replay the production
`reassignSegment` path (embedding append + guarded `confirmSpeaker`).
Refactored replay reproduces #83 exactly (83/119 attributed, false-神野 2).

Repro:
```bash
swift test --filter ConfusionPairAnalysisTests/testStickinessDiagnostic   # ~40 s
swift test --filter ConfusionPairAnalysisTests/testCorrectionStickiness   # ~75 s
# artifacts: /tmp/stickiness_baseline.json, /tmp/stickiness_corrections.json
```

## Limitations

- Same fidelity caveats as #83 (normalized WAV replay, default VAD params,
  ±sub-second boundary attribution, 2026-06-04 profile snapshot vs April audio).
- Oracle corrections are zero-latency and exhaustive; real users correct later and
  less often. The 04-23 worsening (25→41) is therefore an upper bound on damage —
  but the centroid-collapse direction holds for any correction count, and the first
  correction alone moves the centroid ~50 %.
- Zoom GT is per-utterance active-speaker; overlapping speech attributes to the
  max-overlap speaker.
- The pacer-cache flag detects caching via repeated embeddings (bit-identical fresh
  embeddings are practically impossible).

## Fix results (2026-06-12, v2.4.86)

Implemented: `profileSeedWeight = 10` (loadProfiles seeds the stored centroid as
10 samples → a correction nudges ~9 % instead of 50 %) + sample gating in Manual-mode
`correctAssignment` (embedding appended only when cos ≥ `similarityThreshold` against
the target; the `UserCorrection` label is recorded regardless).

The oracle was also made realistic: corrections fire on the **2nd consecutive**
same-pair error ("persistence-2" — users correct labels that stay wrong, not
one-chunk boundary lag). The original every-error/zero-latency oracle is kept below
as a stress case.

| Metric (persistence-2 oracle) | 04-21 before fix* | 04-21 after | 04-23 before fix* | 04-23 after |
|---|---|---|---|---|
| system-wrong (baseline → with corrections) | 26 → 16 | 26 → **20** | 25 → **41** | 26 → **28** |
| reverts | 1 | **0** | 10 | **0** |
| centroid 上東↔松浦 | 0.769 → **0.958** | 0.769 → 0.880 | 0.769 → 0.865 | 0.769 → 0.817 |
| centroid 松浦↔森谷 | — | — | 0.490 → **0.859** | 0.490 → **0.490** |

\* "before fix" columns are the 2026-06-10 every-error oracle (the only pre-fix data);
after-fix columns use persistence-2. Stress case after the fix (every-error oracle):
04-21 26→18 / reverts 0, 04-23 26→32 / reverts 7 — i.e., even under unrealistically
aggressive correction the collapse is gone (0.933 / 0.766 vs 0.958 / 0.865+) and
reverts drop.

Reading:
- **The lived complaint is addressed**: zero reverts in both sessions (was the
  A→B→correct→B cycle), and the attractor session (04-21) improves 26→20 in
  system-wrong terms — plus the 6 corrected chunks themselves are user-fixed, so
  lived wrong-label exposure is roughly halved.
- **04-23 is net-neutral in lived terms** (28 system-wrong − 3 user-fixed ≈ baseline
  26): the residual +2 decomposes into (a) boundary-shadow trades — correcting at a
  speaker boundary moves the error onto the next chunk via the `confirmSpeaker`
  hard reset (state −100 floor + `pendingCount ≥ 2` means the next speaker's first
  chunk is hard-labeled with the corrected speaker), and (b) one genuine adaptation
  trade-off — teaching 上東's (that-day 松浦-like) live voice slightly increases
  reverse 松浦→上東 confusion late in the session. (a) is a smoother-dynamics
  property worth a future look (pending-on-contradiction after confirmSpeaker);
  (b) is the fundamental live-voice↔profile overlap → per-profile calibration
  (next priority).
- Centroid collapse is eliminated: pairs stay bounded (0.880 worst case, vs 0.958
  pre-fix at 1/3 the corrections) and 04-23 pairs are unchanged or move apart.

Spec changes encoded in unit tests (`EmbeddingBasedSpeakerTrackerTests`):
seeded-centroid formula test, gating test (label recorded, vector dropped), gradual
adaptation test (8 plausible corrections flip identify; immediate continuity after a
single correction is the Viterbi `confirmSpeaker`'s job, not the tracker's).
