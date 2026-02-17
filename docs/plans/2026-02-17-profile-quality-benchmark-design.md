# Phase 2b: Profile Quality Management Benchmark

## Problem

EmbeddingBasedSpeakerTracker registers new speaker profiles unconditionally when no match exceeds the similarity threshold. Early low-quality embeddings (from mixed-speaker segments or noisy audio) waste profile slots, causing:

- **Within-session**: Speaker over-detection (AMI: 4 people → 5-9 detected, speakerCountAccuracy=0%)
- **Cross-session**: Low-quality profiles saved to SpeakerProfileStore contaminate future sessions

## Goal

Benchmark multiple profile maintenance strategies to find the best approach for improving speaker count accuracy and cross-session re-identification, without regressing chunk accuracy or label stability.

## Design

### 1. EmbeddingBasedSpeakerTracker Changes

**Add hitCount to SpeakerProfile:**

```swift
public struct SpeakerProfile {
    public let label: String
    public var embedding: [Float]
    public var hitCount: Int = 0
}
```

**Add ProfileStrategy enum:**

```swift
public enum ProfileStrategy: Sendable {
    case none
    case culling(interval: Int, minHits: Int)
    case merging(interval: Int, threshold: Float)
    case registrationGate(minSeparation: Float)
    case combined(cullInterval: Int, minHits: Int, mergeThreshold: Float)
}
```

**Modify identify():**

- Increment `hitCount` on match
- Track `identifyCount` (total calls)
- Call `maintainProfiles()` based on strategy at intervals
- `.registrationGate`: before registering new speaker, check if max similarity to all existing profiles >= minSeparation; if so, assign to most similar instead of creating new

**Add maintainProfiles():**

- `.culling`: every `interval` calls, remove profiles with `hitCount < minHits`
- `.merging`: every `interval` calls, merge profile pairs with similarity >= `threshold` (keep higher hitCount, moving-average embeddings)
- `.combined`: culling then merging

### 2. FluidAudioSpeakerDiarizer Changes

Add `profileStrategy` parameter to init, pass through to EmbeddingBasedSpeakerTracker.

### 3. Benchmark Infrastructure Changes

**Add profileStrategy to runDiarizationBenchmark():**

```swift
func runDiarizationBenchmark(
    ...,
    profileStrategy: ProfileStrategy = .none,
    ...
)
```

**New test class: ProfileStrategyBenchmarkTests**

Output: `/tmp/quicktranscriber_profile_strategy_results.json`

All tests use app default parameters: chunk 5s, accum 7s, window 15s.

### 4. Strategies to Benchmark

| Label | Strategy | Parameters |
|---|---|---|
| baseline | .none | — |
| cull_10_2 | .culling | interval=10, minHits=2 |
| cull_5_1 | .culling | interval=5, minHits=1 |
| merge_10_06 | .merging | interval=10, threshold=0.6 |
| merge_10_07 | .merging | interval=10, threshold=0.7 |
| gate_03 | .registrationGate | minSeparation=0.3 |
| gate_04 | .registrationGate | minSeparation=0.4 |
| combined | .combined | cull(10,2) + merge(0.6) |

8 strategies × 3 datasets (CALLHOME EN/JA + AMI) = 24 test cases.

AMI uses expectedSpeakerCount=-1 (ground truth per conversation).
CALLHOME uses expectedSpeakerCount=2.

### 5. Evaluation Metrics

- **chunkAccuracy**: percentage of correctly labeled chunks (must not regress)
- **labelFlips**: consecutive label changes (lower is better)
- **speakerCountAccuracy**: detected vs actual speaker count (primary improvement target)

### 6. What Does NOT Change

- Default runtime behavior (strategy: .none)
- Settings UI
- SpeakerProfileStore API
- Public API of FluidAudioSpeakerDiarizer (strategy is init-only parameter)

## Success Criteria

At least one strategy shows significant improvement in speakerCountAccuracy on AMI (currently 0.20 with expectedSpeakerCount=GT) without degrading chunkAccuracy below 0.70.
