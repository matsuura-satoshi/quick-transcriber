# Separability diagnostic — the ceiling is the Zoom far-end acoustic path, not the model (2026-07-14)

**Question (spec `docs/superpowers/specs/2026-07-14-separability-diagnostic-design.md`):**
the 2026-07-09 calibration-ceiling diagnostic proved no score/profile engineering can
separate the real-session voices — is the upstream culprit (a) the FluidAudio embedding
model, (b) the acoustic conditions (Zoom far-end + meeting room), or (c) other-speaker
contamination of the production 15 s rolling window?

**Answer: (b), decisively.** On GT-pure single-speaker spans the same model separates
AMI meeting-room speakers essentially perfectly (99.4 % LOO, margin +0.527) while the
real sessions stay broken (70.7 %, margin +0.100). Window contamination (c) is refuted
directly: removing it leaves the real sessions almost as inseparable as before. A
secondary gradient exists — degraded channels (telephone) hurt, Japanese slightly more —
but it is far too small to explain the real-session gap.

## Method

Unified protocol across four conditions (details in the spec):

1. `PureSpanExtractor` (unit-tested): merge same-speaker GT segments across gaps ≤ 1 s,
   subtract every other-speaker interval, trim 0.25 s per side, keep 5–15 s slices.
2. Each span embedded independently via `OfflineDiarizerManager.process()`; dominant
   internal cluster's duration-weighted mean embedding.
3. LOO day-centroid identification per recording (speakers with ≥ 5 spans, ≥ 2 such
   speakers): own = cos to own LOO centroid, impostor = best other centroid,
   margin = own − impostor (> 0 ⇔ correct).

Artifacts: `/tmp/separability_<dataset>.json` (SeparabilityBenchmarkTests);
analysis: `separability_analysis.py` (this directory).

## Results

| Condition | Data | LOO acc | own cos med | impostor med | margin q1/med/q3 | negative |
|---|---|---|---|---|---|---|
| A: Zoom far-end + meeting room, ja | real-sessions ×2 | **70.7 %** | 0.758 | **0.567** | −0.092 / **+0.100** / +0.252 | **29/99 (29 %)** |
| B: meeting-room mics, en | AMI ×7 (4 spk) | **99.4 %** | 0.849 | 0.316 | +0.404 / **+0.527** / +0.618 | 3/536 (0.6 %) |
| C: telephone, ja | callhome_ja ×3 (2 spk) | 86.0 % | 0.787 | 0.616 | +0.077 / +0.194 / +0.285 | 7/50 (14 %) |
| D: telephone, en | callhome_en ×5 (2 spk) | 92.0 % | 0.797 | 0.460 | +0.127 / +0.323 / +0.523 | 11/138 (8 %) |

Real-session confusions on pure spans mirror the lived pairs: 04-21 松浦↔上東
(13/41 wrong), 04-23 森谷→松浦 8 + 松浦→森谷 5 (+ 上東→松浦 2) of 58.

## Reading

1. **The model is healthy.** Four speakers in a meeting room (AMI) separate at 99.4 %
   with a margin distribution (q1 +0.404) that does not even touch zero. "FluidAudio
   cannot tell meeting voices apart" is refuted.
2. **Window contamination is a minor, secondary factor.** The 2026-07-09 LOO on
   production window embeddings (contaminated 15 s windows) was ≈ 60 % accurate;
   GT-pure spans recover only to 70.7 %, vs AMI's 99.4 %. Cleaning the window buys
   ~10 points; the remaining ~29-point gap is acoustic. (Methodological caveat: the
   07-09 LOO identified variable-length chunks, not 5–15 s spans, so the ~10-point
   delta is indicative, not exact.)
3. **The dominant culprit is the Zoom far-end path.** Remote participants' voices reach
   the QT microphone as codec-compressed audio played through a room speaker and
   re-recorded with room reverb — a shared transfer function that makes *different
   remote speakers resemble each other*. This also explains the 2026-06-10 observation
   that 松浦 (in-room, direct mic) had the highest own-voice cos while remote voices
   collapsed toward broad centroids.
4. **A real but small language/channel gradient exists** (ja telephone 86 % < en
   telephone 92 % < en room 99 %; ja impostor median 0.616 is the highest of all
   conditions). Japanese on degraded channels erodes margins faster, amplifying —
   but not causing — the real-session problem.

## Implications for the next lever

The only routes that move this ceiling change the audio reaching the embedder:

- **Capture the far-end signal digitally** (system-audio loopback, e.g. ScreenCaptureKit,
  or per-participant audio where the meeting platform exposes it) instead of re-recording
  it through speaker + room + mic. This removes the shared transfer function that fuses
  remote voices — and as a by-product cleanly splits in-room (mic) from remote (loopback)
  speech, which is itself a strong diarization signal.
- Acoustic preprocessing (dereverb/denoise before embedding) is the weaker fallback —
  it cannot undo codec loss and speaker coloration already shared across voices.
- Model swaps are NOT indicated: any embedding model faces the same fused input.

## Limitations

- callhome eligibility is thin (ja 3/10, en 5/10 conversations have ≥ 2 speakers with
  ≥ 5 pure spans; short conversations rarely yield 5 s pure spans per speaker) — the
  C/D rows are indicative, and the ja < en gradient rests on 50 spans.
- Roster sizes differ (2–6 speakers); cross-condition comparison leans on margins and
  cos levels, not raw accuracy. Note AMI separates near-perfectly with FOUR speakers,
  a harder roster than callhome's two.
- Zoom GT timing carries ±sub-second error; the 0.25 s trim + overlap subtraction is
  the purity guard, but real-session spans may retain slight edge contamination —
  which would bias condition A pessimistically, not change the verdict's direction
  (the 07-09 report's fully-contaminated LOO shows the same pairs failing).
- AMI here is the HF-mirrored mix used by `download_datasets.py`; per-speaker headset
  channels are not used (the mixed channel is the comparable condition).

## Repro

```bash
swift test --filter SeparabilityBenchmarkTests   # ~6 min with models; writes /tmp/separability_*.json
python3 docs/benchmarks/2026-07-14-separability/separability_analysis.py
swift test --filter PureSpanExtractorTests       # model-free unit tests
```
