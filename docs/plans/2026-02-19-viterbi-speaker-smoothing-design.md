# Phase C-2: Viterbi Speaker Smoothing Design

## Background

### Problem

AMI Meeting Corpus benchmarks show 57.8 label flips vs 5.6 for CALLHOME (10x more).
The current `SpeakerLabelTracker` uses a simple confirmation threshold (count=2) that:
- Treats all speaker changes equally regardless of confidence
- Does not model transition probabilities
- Provides insufficient smoothing for 3-5 speaker meetings

### Current Architecture

```
rawSpeakerResult (from EmbeddingBasedSpeakerTracker)
    ↓
SpeakerLabelTracker.processLabel()
    - If same speaker: return confirmed
    - If different: count consecutive occurrences
    - If count >= 2: confirm change
    - Else: return nil (pending)
    ↓
smoothedResult → ConfirmedSegment.speaker
```

### Benchmark Data (Phase 0, 2026-02-16)

| Dataset | Config | Accuracy | Flips |
|---------|--------|----------|-------|
| CALLHOME EN | 5s+7s, 15s | 0.793 | 5.6 |
| CALLHOME JA | 5s+7s, 15s | 0.657 | 13.4 |
| AMI | 5s+7s, 15s | 0.748 | 57.8 |

## Approach: Forward-Only Viterbi

Replace `SpeakerLabelTracker` with `ViterbiSpeakerSmoother`.
Drop-in replacement with the same interface (`processLabel(_:) -> SpeakerIdentification?`).

### Algorithm

Maintain log-probability for each speaker being the current speaker.
On each observation, perform a Viterbi forward step:

```
State: stateLogProbs[speaker] = log P(speaker is current)

Transition model:
  P(stay)   = 1 - transitionProb
  P(switch) = transitionProb / (N-1)

Observation model:
  P(obs | speaker=X) = cosine_similarity(chunk_embedding, profile_X)
  P(obs | speaker≠X) = 1 - cosine_similarity

Update (for each speaker X):
  newLogProb[X] = log(P(obs|X)) + max(
    stateLogProb[X] + log(P(stay)),
    max_over_Y≠X(stateLogProb[Y] + log(P(switch)))
  )
```

### Advantages Over Threshold-Based

| Aspect | Threshold (current) | Viterbi |
|--------|---------------------|---------|
| Decision basis | Count only | Confidence x transition probability |
| High-confidence change (0.9) | Wait 2 chunks | Can confirm in 1 |
| Low-confidence change (0.3) | Wait 2 chunks | Suppressed by transition cost |
| Parameter | confirmationThreshold (int) | transitionPenalty (continuous) |

## Component Design

### ViterbiSpeakerSmoother

Replaces `SpeakerLabelTracker`. Same public interface.

```swift
struct ViterbiSpeakerSmoother {
    // Parameters
    let transitionPenalty: Double  // log(P(switch)/P(stay)), negative value

    // State
    private var stateLogProbs: [String: Double]  // speaker label → log prob
    private var confirmedResult: SpeakerIdentification?

    // Stability detection
    private var pendingNewBest: String?
    private var pendingCount: Int
    let stabilityThreshold: Int  // default: 1

    // Public interface (same as SpeakerLabelTracker)
    mutating func processLabel(_ id: SpeakerIdentification?) -> SpeakerIdentification?
    mutating func reset()
}
```

**Confirmation logic:**
1. First speaker: confirm immediately
2. Same speaker continues: update probabilities, return confirmed
3. Best speaker changes:
   - If probability gap is large: confirm immediately
   - If gap is small: wait for stabilityThreshold consecutive confirmations
   - During pending: return nil (triggers retroactive update later)
4. Pending resets if best changes again

### Parameter: transitionPenalty

- Type: `Double` (log-space, negative value)
- Default: TBD via benchmark sweep
- Sweep values: [-1.0, -1.5, -2.0, -2.3, -3.0, -4.0]
- Meaning: `log(P(switch) / P(stay))`
  - -2.3 ≈ P(switch)=0.1, P(stay)=0.9
  - -4.0 ≈ P(switch)=0.018, P(stay)=0.982

Added to `TranscriptionParameters` but NOT exposed in Settings UI (advanced parameter).

## Integration

### Files Changed

```
Replace:
  SpeakerLabelTracker.swift → ViterbiSpeakerSmoother.swift

Modify:
  ChunkedWhisperEngine.swift     (labelTracker → viterbiSmoother)
  FluidAudioSpeakerDiarizer.swift (labelTracker → viterbiSmoother)
  TranscriptionParameters.swift   (add transitionPenalty)
  DiarizationBenchmarkTests.swift  (add transitionPenalty sweep)

Unchanged:
  EmbeddingBasedSpeakerTracker.swift
  DiarizationPacer.swift
  ConfirmedSegment.swift
  TranscriptionTextView / InteractiveTranscriptionTextView
  TranscriptFileWriter
  SpeakerProfileStore
```

### Data Flow (unchanged pipeline)

```
ChunkedWhisperEngine.processChunk():
  rawResult = diarizer.identifySpeaker(chunk)
  smoothedResult = viterbiSmoother.processLabel(rawResult)  // was: labelTracker

  if smoothedResult == nil:
    segment.speaker = nil (pending)
    track pendingSegmentStartIndex

  if smoothedResult != nil && pendingSegmentStartIndex:
    retroactive update (same logic as current)
```

## Benchmark Plan

### Sweep: transitionPenalty

- Values: [-1.0, -1.5, -2.0, -2.3, -3.0, -4.0]
- Datasets: CALLHOME EN (5), CALLHOME JA (5), AMI (5)
- Fixed params: chunk=5s, accum=7s, window=15s, expectedSpeakerCount=GT
- Metrics: accuracy, labelFlips, speakerCountAccuracy

### Success Criteria

- AMI label flips reduced significantly (target: <30, from 57.8)
- CALLHOME accuracy maintained or improved
- CALLHOME flips not increased

## Test Plan

### Unit Tests (ViterbiSpeakerSmootherTests)

1. First speaker confirmed immediately
2. Same speaker returns confirmed with updated confidence
3. High-confidence switch confirmed quickly
4. Low-confidence switch suppressed
5. Transition penalty effect (higher penalty = fewer switches)
6. Reset clears state
7. nil input returns current best
8. Retroactive update compatibility (pending → confirm flow)

### Migration from SpeakerLabelTrackerTests

Port existing test cases to verify behavioral compatibility.

## Out of Scope

- Full backward-tracking Viterbi (not needed for real-time)
- Settings UI for transitionPenalty (advanced parameter)
- Changes to EmbeddingBasedSpeakerTracker or DiarizationPacer
