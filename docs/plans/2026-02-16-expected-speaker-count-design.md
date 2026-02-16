# Phase 1: Expected Speaker Count

## Problem

`EmbeddingBasedSpeakerTracker` registers new speakers when cosine similarity < 0.5, even if caused by noise or voice variation. AMI benchmark shows 0% speaker count accuracy (detects 5-9 speakers when actual is 4).

## Design

### Parameter Addition

`TranscriptionParameters.expectedSpeakerCount: Int?` (nil = Auto, default)

### Core Logic Change

In `EmbeddingBasedSpeakerTracker.identify()`:
- When `profiles.count >= expectedSpeakerCount`: assign to most similar existing speaker instead of creating new profile
- When `expectedSpeakerCount` is nil: current behavior (unlimited)

### Parameter Propagation

```
TranscriptionParameters.expectedSpeakerCount
  → TranscriptionViewModel
    → ChunkedWhisperEngine.startStreaming()
      → FluidAudioSpeakerDiarizer(expectedSpeakerCount:)
        → EmbeddingBasedSpeakerTracker(expectedSpeakerCount:)
```

### Settings UI

Speaker Detection section in SettingsView:
- "Number of Speakers" Picker: Auto / 2 / 3 / 4 / 5
- Disabled when `enableSpeakerDiarization` is OFF

### Files to Change

1. `TranscriptionParameters.swift` - add field
2. `EmbeddingBasedSpeakerTracker.swift` - add constraint logic
3. `SpeakerDiarizer.swift` - pass parameter
4. `ChunkedWhisperEngine.swift` - pass parameter to diarizer
5. `SettingsView.swift` - add picker UI

### Tests

- Unit: `EmbeddingBasedSpeakerTrackerTests` - capacity limiting
- Benchmark: CALLHOME/AMI with expectedSpeakerCount vs Auto
