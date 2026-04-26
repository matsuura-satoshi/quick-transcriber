# Diarization Machinery Ablation Design

**Date**: 2026-04-27
**Status**: Draft — supersedes Stage 2 portion of `2026-04-24-parameter-re-evaluation-design.md`
**Predecessor**: `2026-04-24-parameter-re-evaluation-design.md` (Stage 1 transcription sweep remains in scope)

## Background

The 2026-04-24 spec optimized **parameter values** within the current diarization stack. The user, on 2026-04-27, refined the question: do the *mechanisms* added between 2026-02 and 2026-04-17 actually earn their complexity budget? If a single chunkDuration tweak would have delivered the same quality as the full Manual-mode learning + Viterbi-reset stack, the extra machinery is dead weight that hurts future development.

A pure parameter sweep cannot answer this. We need an ablation study: hold parameters fixed, remove mechanisms one by one, and measure the marginal impact of each.

## Problem Statement

Quantify the marginal contribution of each diarization machinery layer added since 2026-02 to:
- **Transcription quality** (CER)
- **Speaker labeling quality** (DER, label flips, speaker count accuracy)
- **Latency** (per-stage and end-to-end)

A "valuable" mechanism shows non-trivial improvement on at least one axis without harming the others. A "dead weight" mechanism produces results indistinguishable from its absence.

## Scope

### In scope

- Two real-session WAVs in `~/Documents/QuickTranscriber/real-sessions/`:
  - `2026-04-21_CERTインシデント情報共有/audio.wav` — 11.6 min, 4 active speakers, 1 silent registered participant (神野)
  - `2026-04-23_CERTインシデント情報共有/audio.wav` — 15.1 min, 5 active speakers, 1 silent registered participant (神野)
- Manual-mode operation reproduced via the user's actual `~/QuickTranscriber/speakers.json` (copied to a test fixture so production state stays untouched).
- 6 ablation configurations (A–F) varying which machinery layers are active.
- Quantitative metrics: CER (relative), DER, label flips, speaker count accuracy, p50/p95 latency.

### Out of scope

- Manual gold transcript (deferred per user — future work). Text quality is therefore measured **relative**, not absolute.
- HF dataset evaluation (carried in the predecessor spec's Stage 1 — out of scope for this document).
- Modifications to production `~/QuickTranscriber/speakers.json` (read-only fixture copy used).
- Speaker-correction simulation (no automated user-corrections inserted in ablation runs).

## Test Sessions

| Session | Duration | Active speakers (Zoom) | Silent-but-registered |
|---|---|---|---|
| 2026-04-21 | 11.6 min | 松浦, 今村, Y.Uehigashi, 佐々木 | 神野 |
| 2026-04-23 | 15.1 min | 松浦, 今村, Y.Uehigashi, Kento Mori, moriya | 神野 |

The "silent registered participant" 神野 is a feature, not a bug, of the test set: it is the simplest possible test of Manual-mode false-assignment. A correct system never emits 神野; a buggy system does.

## Speaker Name Mapping

Zoom uses verbose handles, the production speakers.json uses short names. Mapping is fixed and committed alongside the manifest:

| Short (speakers.json) | Zoom handle |
|---|---|
| 松浦 | `松浦 知史 / Science Tokyo CERT / MATSUURA Satoshi` |
| 今村 | `今村＠情報セキュリティ室` |
| 上東 | `Y.Uehigashi` |
| 佐々木 | `佐々木@情報セキュリティ室` |
| 森 | `Kento Mori` |
| 森谷 | `moriya` |
| 神野 | (never appears in Zoom — silent participant) |

Mapping is one-way (Zoom → short). DER computation maps predicted speaker IDs to Zoom turns via Hungarian assignment, then compares names through this table.

## Ablation Configurations

Six configs, applied in nested-removal order. Each removes one mechanism from the previous; together they trace the development history backwards.

| ID | Description | Remove vs prior |
|---|---|---|
| **A** | Full current stack (baseline) | — |
| **B** | A − post-hoc session learning | `applyPostHocLearning()` short-circuited |
| **C** | B − suppressLearning gate | identify() always updates profile (Manual behaves like Auto) |
| **D** | C − Viterbi reset on correction | Viterbi state preserved across reassignments (no resets) |
| **E** | D − Viterbi smoother itself | Raw cosine-similarity assignment, no temporal smoothing |
| **F** | E − userCorrectionConfidence dampening | Corrections add embedding at confidence 1.0 (pre-Apr-17 behavior) |

For this study **no user corrections are simulated**, so config differences in the correction-handling layers (B, D, F) only manifest if profile drift accumulates from identify() updates. C and E expose the largest behavioural deltas.

The "remove" semantics are implemented via existing toggles where present (`suppressLearning`) or via a new `AblationFlags` injection point that the engine reads (see Implementation).

## Metrics

### DER (Diarization Error Rate)
- **Source**: Zoom transcript timestamps + speaker turns.
- **Algorithm**: Existing `DiarizationMetrics.compute()` (Hungarian-matched). Predicted UUID → Zoom name via Hungarian, then DER computed per session.
- **Granularity**: 250 ms frames.

### Label flips
- Count of consecutive predicted-segment pairs where predicted speaker changes but ground-truth speaker does not.
- Normalized: `flips / total_segments`.

### Speaker count accuracy
- `|predicted_unique_speakers − ground_truth_unique_speakers|`.
- Specifically tracks: did the system emit 神野 (silent participant) at all? Count of false-神野 assignments is the headline metric.

### CER (relative)
- Reference: Zoom-stripped text. Pre-process Zoom transcript by removing `。` between non-sentence-boundary positions (regex: keep `。` only when followed by newline or end-of-segment; strip otherwise). This corrects Zoom's character-level period insertion artefact while preserving genuine sentence-end punctuation.
- Predicted: ablation run's full-session text concatenated.
- Levenshtein character distance / reference length.
- Caveat: Zoom ASR has its own errors (transcribes "東大" as "灯台" etc.); CER differences <2 percentage points are not interpretable. Report as ranking, not absolute.

### Latency
- LatencyInstrumentation drain at end of run.
- Per-utterance breakdown (StreamingLatencyHarness.perUtteranceLatency).
- Aggregates: p50/p95 of `t_total`, `t_inference`, `t_diarize`, `t_vad_wait`, `t_emit`.

### Composite weighted score
For ranking only (not for evidence):
```
score = 0.4 · DER_rel + 0.2 · CER_rel + 0.2 · false_神野_norm + 0.2 · t_total_p50_rel
```
Each component normalized to [0,1] across all configs in the same session, lower-is-better.

## Profile Reproducibility

Production `~/QuickTranscriber/speakers.json` (78 speakers, 256-d embeddings) contains real colleague names and voice embeddings. The repo is public, so the file **must not be committed**. The benchmark loader reads it live, in-memory only, with a hard read-only contract: no ablation run writes back to disk.

The fixture path `Tests/QuickTranscriberBenchmarks/Fixtures/` is `.gitignore`d in case anyone later snapshots it for offline use.

For each session, the relevant 5–7 profiles (松浦, 森, 今村, 森谷, 上東, 佐々木, 神野) are filtered into the diarizer's initial state by `displayName` whitelist. Other profiles are ignored.

## Implementation

### Reuse from predecessor work

- `LatencyInstrumentation` — already wired into the pipeline.
- `StreamingLatencyHarness.perUtteranceLatency` — reused as-is.
- `ParameterSweepRunner.Manifest` / `Config` / `RunResult` — schema reused; `executeSingle` gains an ablation branch.
- `DiarizationMetrics.compute()` — reused for DER.

### New code

1. **`AblationFlags`** struct (in `Sources/QuickTranscriber/Benchmark/`) — a 6-field bool record consumed by the diarizer/tracker code paths. Default = full stack (config A). Each field corresponds to one removed mechanism. Wiring: production code reads flags from a thread-local set by the ablation runner; flags are inert unless the runner sets them.
2. **`ZoomTranscriptParser`** (`Tests/QuickTranscriberBenchmarks/`) — parses `zoom_transcript.txt` into `[(speaker, start, end, text)]`. End time inferred from next entry's start; final entry uses session duration.
3. **`ZoomReferenceCleaner`** — Zoom-stripped text generator for CER reference.
4. **`AblationRunner`** — top-level driver: load fixture profiles, set ablation flags, run audio through pipeline, compute metrics, emit RunResult.
5. **Manifest**: `Tests/QuickTranscriberBenchmarks/Manifests/ablation.json` with 12 entries (6 configs × 2 sessions).

### Pipeline data flow

```
audio.wav (16 kHz int16)
    ↓
ChunkedWhisperEngine (with isEnabled = true on LatencyInstrumentation)
    ↓                   reads:
    ├─ ChunkTranscriber       → text per chunk
    ├─ FluidAudioSpeakerDiarizer (configured with ablation profiles + AblationFlags)
    │    ↓
    └─ EmbeddingBasedSpeakerTracker (gated by AblationFlags)
         ↓
    full transcript + per-segment (text, speakerId, timestamps)
    ↓
metric computation:
    ├─ DER vs Zoom turns
    ├─ flips
    ├─ count accuracy + false_神野 count
    ├─ CER vs Zoom-stripped
    └─ latency aggregates from drain()
```

## Hypotheses (pre-registered)

| H | Statement | Refutation criterion |
|---|---|---|
| H1 | post-hoc session learning (added 2026-04-17) does not affect within-session metrics | Config B vs A differ by <1pp DER, <50ms p50 latency |
| H2 | suppressLearning improves DER but increases label flips | Config C vs B: DER↑, flips↓; or no significant change |
| H3 | Viterbi reset on correction matters only when corrections are applied (none in this experiment) | Config D vs C effectively identical |
| H4 | The Viterbi smoother itself meaningfully reduces label flips | Config E vs D: flips↑ when smoother removed |
| H5 | userCorrectionConfidence dampening matters only when corrections are applied (none here) | Config F vs E effectively identical |
| H6 | False-神野 emissions occur in at least one config and reveal Manual-mode failure mode | At least one config emits 神野 ≥1× per session |

The combination of H1+H3+H5 (which we expect to confirm — "these mechanisms only matter under correction load") would justify a follow-up correction-injection study.

## Success Criteria

The study succeeds if:

1. All 12 runs (6 configs × 2 sessions) complete without crashes. Resumability via existing ParameterSweepRunner.
2. For each hypothesis H1–H6, the result is either confirmation or refutation with quantitative evidence.
3. The artefact is a single Markdown report with one decision table:
   | Mechanism | Earns its keep? | Evidence | Recommendation |
   - "Earns its keep" = "removing it harms metrics by ≥X" (X to be set per metric: DER 1pp, flips 5%, latency 50ms).
4. Recommendations are actionable: "remove mechanism Y" or "keep, but parameter-tune".
5. Raw RunResult JSONs and the report are committed to `docs/benchmarks/2026-04-27-ablation/`.

## Risks and Limitations

- **No clean text reference**: CER is relative only. A 5pp CER difference is meaningful, a 2pp difference is noise.
- **Two sessions only**: limited statistical power. A mechanism that helps on average but not on these two sessions could be wrongly judged dead-weight. Mitigation: report findings as "no benefit observed on this corpus" rather than "no benefit exists".
- **No correction simulation**: B/D/F configs may look identical to A/C/E since their delta is correction-handling. Acknowledged in hypotheses; correction-injection is a follow-up.
- **Zoom GT noise**: Zoom's own ASR/diarization is imperfect (silent-but-registered 神野 is invisible to Zoom). DER will have a small upper bound from Zoom error, but ranking remains valid.
- **speakers.json is a snapshot**: 78 profiles include many that should be ignored. Filtering by displayName (whitelist of session participants) is the safe approach; profile order/index is not relied upon.

## Phasing

1. **Pre-work** (~2 h): ZoomTranscriptParser, ZoomReferenceCleaner, AblationFlags scaffold, fixture copy of speakers.json.
2. **Manifest** (~30 min): ablation.json with 12 entries.
3. **Execution** (~1.5 h actual compute): 12 runs at 1× speed of audio = ~26.7 min × 6 configs = ~160 min worst-case (overlapping nothing).
4. **Analysis** (~1 h): extend `analyze_sweep.py` with ablation-specific renderers; produce report.
5. **Report write-up** (~30 min): single Markdown decision document.

Total: ~5–6 hours wall-clock, of which ~1.5 h is on-the-Mac compute.

## Out-of-scope follow-ups (not blocking this study)

- Correction-injection study (synthetic user corrections injected at known points to exercise B/D/F).
- Manual gold transcript for a 5–10 min subset to enable absolute CER.
- Parameter tuning sweep (Stage 1 of predecessor spec) on the slim baseline that emerges from this study.
- Cross-validation on HF datasets (Stage 2 of predecessor spec, deferred).
