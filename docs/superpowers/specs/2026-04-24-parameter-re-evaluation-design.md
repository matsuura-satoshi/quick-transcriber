# Parameter Re-Evaluation Design

**Date**: 2026-04-24
**Status**: Draft — pending user review

## Background

Recent development (Apr 8–17, 2026) has concentrated on speaker diarization stability: 7+ commits touching embedding learning, Viterbi state reset, post-hoc learning, and new embedding constants (`userCorrectionConfidence`, `sessionLearningAlphaMax`, `tieBreakerEpsilon`). The user reports a subjective regression in transcription accuracy and end-to-end response latency, and suspects that parameters have been over-tuned in pursuit of speaker-labeling stability.

This document defines a systematic re-evaluation that treats three axes as co-equal:
1. **Transcription accuracy** (WER / CER)
2. **Speaker labeling accuracy** (DER, label flips)
3. **Response latency** (end-to-end wall-clock time perceived by the user)

The goal is not to find the single best configuration but to produce a defensible Pareto-ranked recommendation the user can choose from.

## Scope

### In scope

- Streaming mode (chunked real-time transcription). File-mode parameters are out of scope.
- HuggingFace datasets downloaded via `Scripts/download_datasets.py` (fleurs_en, fleurs_ja, librispeech_test_other, reazonspeech_test, callhome_en, callhome_ja, ami).
- Two evaluation stages:
  - **Stage 1**: Transcription only, diarization disabled.
  - **Stage 2**: Diarization enabled in **Auto** mode (Stage 1 winner fixed, diarization-layer parameters swept).
- Pipeline latency instrumentation: per-stage wall-clock decomposition.
- OAT (one-at-a-time) sensitivity sweep plus a small number of 2-way interaction grids for parameters known or suspected to be coupled.
- Comparison against two baselines per parameter: current `main` default and historical stable default (if different).

### Out of scope (deferred)

- Manual mode evaluation on real-session data (`~/Documents/QuickTranscriber/real-sessions/`). Will be re-visited after Stage 1 + Stage 2 Auto results land.
- File mode (`chunkDuration = 25.0s`) parameter re-tuning.
- Model-level changes (Whisper model size, language selection logic).
- VAD algorithm replacement; only its thresholds are swept.

## Baselines

For each parameter, two baseline values are recorded in the comparison table:

- **Current baseline**: Default as of `main` on 2026-04-24.
- **Historical baseline**: Default just before the Apr 8 diarization-stability churn began (commit SHA to be resolved during Stage 1 setup; candidate: the commit immediately preceding `7dfb9b7` "Trust manual labels in Manual mode"). For parameters that did not exist before the churn (e.g., `userCorrectionConfidence`, `sessionLearningAlphaMax`, `tieBreakerEpsilon`), the historical baseline is recorded as "N/A (introduced during churn)".

The reason for carrying the historical baseline is not nostalgia but diagnostic power: if a sweep shows the historical value Pareto-dominates the current value, "revert" becomes a viable recommendation rather than an intuition.

## Stage 1: Transcription-Only Sweep

### Parameters swept

| Parameter | File:Line | Current | Historical | Sweep Values |
|---|---|---|---|---|
| `chunkDuration` | TranscriptionParameters.swift:49 | 8.0 | 8.0 | {6.0, 8.0, 10.0, 12.0} |
| `silenceCutoffDuration` | TranscriptionParameters.swift:50 | 0.6 | 0.6 | {0.4, 0.6, 0.8, 1.0} |
| `silenceEnergyThreshold` | TranscriptionParameters.swift:51 | 0.01 | 0.01 | {0.005, 0.01, 0.02, 0.05} |
| `speechOnsetThreshold` | TranscriptionParameters.swift:52 | 0.02 | 0.02 | {0.02, 0.05, 0.1} |
| `preRollDuration` | TranscriptionParameters.swift:53 | 0.3 | 0.3 | {0.2, 0.3, 0.5} |
| `sampleLength` | TranscriptionParameters.swift:47 | 224 | 224 | {128, 192, 224} |
| `concurrentWorkerCount` | TranscriptionParameters.swift:48 | 4 | 4 | {2, 4, 8} |
| `temperatureFallbackCount` | TranscriptionParameters.swift:46 | 0 | 0 | {0, 2} |

### 2-way interaction grids (Stage 1)

Chosen because the axes are physically coupled (VAD timing ↔ chunk-size, inference compute budget ↔ worker count):

- `chunkDuration × silenceCutoffDuration` — 4 × 4 = 16 configurations
- `sampleLength × concurrentWorkerCount` — 3 × 3 = 9 configurations

For axes **not** covered by a 2-way grid (`silenceEnergyThreshold`, `speechOnsetThreshold`, `preRollDuration`, `temperatureFallbackCount`), an OAT sweep is run: each non-baseline value becomes one configuration, i.e. (4−1)+(3−1)+(3−1)+(2−1) = 8 OAT configurations. Adding the shared baseline (counted once) gives 16 + 9 + 8 + 1 = **34 unique configurations per dataset**. (Baselines inside each 2-way grid coincide with the shared baseline and are de-duplicated.)

### Datasets

- `fleurs_en` (English, clean, ~350 utterances) — WER baseline.
- `fleurs_ja` (Japanese, clean, ~350 utterances) — CER baseline.
- `librispeech_test_other` (English, challenging, 200 utterances) — WER stress.
- `reazonspeech_test` (Japanese, challenging, 200 utterances) — CER stress.

To keep runtime tractable, a fixed 100-utterance **subset** of each dataset is used for the full sweep. After sweep completes, the top-5 configurations by weighted score are re-run on the **full** dataset to confirm the ranking is stable. Subset seed is fixed (`SEED=20260424`) for reproducibility.

### Metrics

- **Transcription quality**:
  - WER for English datasets (word-level Levenshtein).
  - CER for Japanese datasets (character-level Levenshtein).
- **Latency decomposition** (from new instrumentation — see Implementation):
  - `T_vad_wait`: time from user stops speaking to VAD confirms silence (`silenceCutoffDuration` satisfied).
  - `T_inference`: WhisperKit model forward pass.
  - `T_emit`: post-processing to UI-ready text.
  - `T_total`: end-to-end perceived latency = `T_vad_wait + T_inference + T_emit`.
- **Throughput**: RTF (real-time factor) = audio_duration / total_processing_wall_time.

### Streaming simulation

Datasets are utterance-level; to measure streaming latency realistically, utterances are **concatenated** with 1.2 s of synthetic silence between them (exceeds the default `silenceCutoffDuration` by a safe margin) and fed into the real pipeline at 1× playback speed. Each utterance boundary produces one latency sample. WER/CER is computed per utterance.

### Weighted score (Stage 1)

A single ordering over configurations is produced for downstream Stage 2 selection:

```
score = 0.5 · WER_norm + 0.5 · T_total_norm
```

where both terms are normalized to `[0, 1]` by dividing by the worst observed value in the sweep (lower is better for both). Per-language scores are averaged.

## Stage 2: + Diarization (Auto)

### Freezing Stage 1 winner

The top-1 Stage 1 configuration (by weighted score) is **frozen** for all Stage 2 runs. This prevents the parameter space from exploding and isolates the diarization layer's contribution.

If the top-1 and top-2 Stage 1 configurations are within 2 % of each other on both WER and latency, both are carried into Stage 2 and evaluated in parallel. Otherwise, top-1 only.

### Parameters swept

| Parameter | File:Line | Current | Historical | Sweep Values |
|---|---|---|---|---|
| `similarityThreshold` | EmbeddingBasedSpeakerTracker.swift:91 | 0.5 | 0.5 | {0.4, 0.5, 0.6, 0.7} |
| `speakerTransitionPenalty` | TranscriptionParameters.swift:58 | 0.8 | 0.9 | {0.7, 0.8, 0.9, 0.95} |
| `diarizationChunkDuration` | FluidAudioSpeakerDiarizer.swift:74 | 7.0 | 7.0 | {3.0, 5.0, 7.0, 10.0} |
| `windowDuration` | FluidAudioSpeakerDiarizer.swift:73 | 15.0 | 15.0 | {10.0, 15.0, 20.0} |
| `profileStrategy` | EmbeddingBasedSpeakerTracker.swift:91 | .none | .none | {.none, .culling(10,2), .merging(0.85)} |

Note: the historical baseline for `speakerTransitionPenalty` is 0.9 (pre-churn it was tighter; it was relaxed to 0.8 to reduce stickiness in Manual corrections). This axis is a prime candidate for the "over-tuning" investigation.

### 2-way interaction grid (Stage 2)

- `similarityThreshold × speakerTransitionPenalty` — 4 × 4 = 16 configurations.

For axes not covered by the grid (`diarizationChunkDuration`, `windowDuration`, `profileStrategy`), OAT adds (4−1)+(3−1)+(3−1) = 7 configurations. Total Stage 2: 16 + 7 + 1 baseline = **24 unique configurations per dataset**.

### Datasets

- `callhome_en` (~50 conversations, 2–6 speakers).
- `callhome_ja` (~50 conversations, 2–6 speakers).
- `ami` (~16 meetings, 3–5 speakers).

Same subset-then-confirm protocol as Stage 1: fixed 20-conversation subset for the sweep, full corpus re-run for top-5.

### Metrics

- **DER** (Diarization Error Rate, Hungarian-matched, existing `DiarizationMetrics.swift`).
- **Chunk accuracy**: fraction of diarization chunks whose majority-labeled speaker matches ground truth.
- **Label flips**: count of consecutive-chunk speaker label changes where ground truth does not change.
- **Speaker count accuracy**: |predicted_count − ground_truth_count|.
- **Incremental latency**: `T_diarize` (diarization processing wall-clock per chunk), added to Stage 1's `T_total`.

### Weighted score (Stage 2)

```
score = 0.4 · WER_norm + 0.3 · DER_norm + 0.3 · T_total_norm
```

This ratio matches the three-axes-co-equal design goal (transcription accuracy weighted slightly higher because it is the user-visible primary output).

## Latency Instrumentation

A new module `LatencyInstrumentation` is added to `Sources/QuickTranscriberLib/`. Responsibilities:

- Timestamp pipeline stage transitions using `DispatchTime.now()` (monotonic, nanosecond resolution).
- Stage labels: `vad_onset`, `vad_confirm_silence`, `chunk_dispatched`, `inference_start`, `inference_end`, `diarize_start`, `diarize_end`, `emit_to_ui`.
- Emit per-utterance latency records to a ring buffer; benchmark harness drains the buffer at the end of each run and writes it as part of the result JSON.
- Zero overhead when `LatencyInstrumentation.isEnabled = false` (default off in production).

Instrumentation is added at ≤ 8 call sites in `ChunkedWhisperEngine`, `AudioCaptureService`, `ChunkTranscriber`, and `FluidAudioSpeakerDiarizer`. Each call site is a single statement (`LatencyInstrumentation.mark(.stageName)`); this keeps production code readable.

## Parameter Sweep Runner

A new test target `ParameterSweepRunner` (under `Tests/QuickTranscriberBenchmarks/`) orchestrates the sweep:

- **Input**: a YAML or JSON manifest listing configurations (id, parameter overrides, dataset, subset seed).
- **Behavior**: for each config, construct `TranscriptionParameters`, run the existing benchmark harness on the specified dataset, collect metrics + latency records, append to output JSON.
- **Output**: one JSON file per stage (`stage1_results.json`, `stage2_results.json`) in `docs/benchmarks/2026-04-24/`.
- **Resumability**: if a run crashes, the runner reads the output JSON, skips already-completed config-ids, and resumes. This matters because Stage 1 is ~6–10 hours.

The runner reuses `BenchmarkTestBase` so WER/CER/DER computation is unchanged.

## Analysis & Reporting

A Python script `Scripts/analyze_sweep.py` reads the JSON outputs and produces:

1. **Sensitivity curves (1D)**: for each OAT axis, a plot of WER, DER, `T_total` versus parameter value. Highlights non-monotonic axes.
2. **Pareto frontier**: scatter plot of accuracy (WER or DER) vs. `T_total`, with the frontier highlighted. Marks current-baseline and historical-baseline points.
3. **Current-vs-optimal diff table**: per parameter, columns `current | optimal_Pareto | Δscore | recommendation (keep / revert / adjust)`. This is the primary artifact the user will act on.
4. **Three-axis leaderboard**: top 10 configurations by weighted score, with WER, DER, latency columns broken out.

Markdown reports are committed to `docs/benchmarks/2026-04-24/report.md`.

## Implementation Order

1. Add `LatencyInstrumentation` + call sites. Unit-test that timestamps are ordered and overhead is ≤ 1 % with instrumentation enabled.
2. Add `ParameterSweepRunner` + manifest format. Smoke test: single-config run end-to-end.
3. Author Stage 1 manifest (OAT + 2 grids, 34 configs × 4 datasets = 136 runs).
4. Run Stage 1 sweep. Abort-and-resume tested at least once.
5. Author `Scripts/analyze_sweep.py`. Produce Stage 1 report.
6. Resolve Stage 1 winner. Author Stage 2 manifest (24 configs × 3 datasets = 72 runs).
7. Run Stage 2 sweep.
8. Produce Stage 2 report + recommendation.

## Success Criteria

The re-evaluation succeeds if:

- For every swept parameter, we can state whether the current value is Pareto-dominated, matched, or dominant versus alternatives at a significance level of ≥ 5 % metric difference.
- We produce a concrete recommendation table: which parameters to keep, which to revert, which to adjust (with target value).
- The recommended configuration is validated on full (non-subsetted) datasets and retains its ranking.
- All raw JSONs, analysis notebooks, and plots are committed to `docs/benchmarks/2026-04-24/` for reproducibility.

## Risks

- **Runtime underestimate**: Stage 1 projected 6–10 h but could stretch to 24+ h if WhisperKit `cpuAndGPU` compute is slower than expected on mid-range Macs. Mitigation: resumability + checkpoint after each dataset.
- **Noise in latency**: macOS thermal throttling can skew latency by ±20 %. Mitigation: run on AC power, disable background apps, repeat each config 3× and report median.
- **Dataset bias**: HF datasets are short utterances; they do not exercise long-form continuity or speaker-count scaling realistically. Mitigation is limited in this spec; the deferred real-session Manual mode stage fills this gap.
- **2-way grid blind spots**: OAT + selected 2-way grids will miss higher-order interactions. Explicitly accepted trade-off; noted in the final report.
