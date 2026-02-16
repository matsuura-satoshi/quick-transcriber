# Phase 2a: SpeakerProfileStore Design

## Goal

Persist speaker embedding profiles across sessions so that known speakers are recognized immediately without a warm-up period.

## Scope

- SpeakerProfileStore (persistence layer)
- Auto-save on session end (recording stop)
- Auto-load all profiles on session start (recording start)
- Profiles saved as "Speaker A", "Speaker B" (no name editing UI)
- Merge strategy for updating existing profiles

## Out of Scope (YAGNI)

- Name editing UI (future phase)
- Participant selection UI before recording (future phase)
- Voice enrollment recording ("please speak into the mic")
- Multi-device profile sync
- Profile quality management (separate follow-up)

## Data Model

```swift
/// Persistent speaker profile stored across sessions.
public struct StoredSpeakerProfile: Codable, Equatable {
    public let id: UUID
    public var label: String          // "A", "B", "C", ...
    public var embedding: [Float]     // 256-dim
    public var lastUsed: Date
    public var sessionCount: Int      // number of sessions this profile appeared in
}
```

## Storage

- File: `~/QuickTranscriber/speakers.json`
- Format: JSON array of `StoredSpeakerProfile`
- Single file for simplicity (profile count expected < 50)

## SpeakerProfileStore

```swift
public final class SpeakerProfileStore {
    private let fileURL: URL
    private(set) var profiles: [StoredSpeakerProfile]

    init(directory: URL? = nil)  // defaults to ~/QuickTranscriber/
    func load()                  // read from disk
    func save()                  // write to disk
    func mergeSessionProfiles(_ sessionProfiles: [(label: String, embedding: [Float])])
    func deleteAll()
}
```

### Merge Strategy (`mergeSessionProfiles`)

When a session ends, the tracker's current profiles are merged with the store:

1. For each session profile, compute cosine similarity against all stored profiles
2. If best match >= 0.5: update stored profile's embedding (moving average, alpha=0.3), update `lastUsed`, increment `sessionCount`
3. If no match >= 0.5: create new `StoredSpeakerProfile` with a new UUID, `sessionCount=1`
4. Save to disk

This ensures that the same person across sessions converges to a stable profile.

## Integration Points

### EmbeddingBasedSpeakerTracker Changes

Add two methods:

```swift
/// Export current session profiles for persistence.
func exportProfiles() -> [(label: String, embedding: [Float])]

/// Load persisted profiles as initial state.
/// Resets tracker and populates with given profiles.
func loadProfiles(_ profiles: [(label: String, embedding: [Float])])
```

`loadProfiles` sets `nextLabelIndex` to `profiles.count` so new speakers get the next available label.

### SpeakerDiarizer Protocol Changes

```swift
public protocol SpeakerDiarizer: AnyObject, Sendable {
    func setup() async throws
    func identifySpeaker(audioChunk: [Float]) async -> String?
    func updateExpectedSpeakerCount(_ count: Int?)
    // New:
    func exportSpeakerProfiles() -> [(label: String, embedding: [Float])]
    func loadSpeakerProfiles(_ profiles: [(label: String, embedding: [Float])])
}
```

### FluidAudioSpeakerDiarizer Changes

Implement the two new protocol methods by delegating to `speakerTracker`:

```swift
public func exportSpeakerProfiles() -> [(label: String, embedding: [Float])] {
    speakerTracker.exportProfiles()
}

public func loadSpeakerProfiles(_ profiles: [(label: String, embedding: [Float])]) {
    speakerTracker.loadProfiles(profiles)
    // Also reset the rolling buffer and pacer for clean session start
    lock.withLock {
        rollingBuffer = []
        pacer = DiarizationPacer(
            diarizationChunkDuration: pacer.diarizationChunkDuration,
            sampleRate: 16000
        )
    }
}
```

### ChunkedWhisperEngine Changes

**`startStreaming()`**: After resetting state, load profiles from store into diarizer:

```swift
if let diarizer, parameters.enableSpeakerDiarization {
    let stored = speakerProfileStore.profiles
    let profiles = stored.map { ($0.label, $0.embedding) }
    diarizer.loadSpeakerProfiles(profiles)
}
```

**`stopStreaming()`**: After flushing remaining audio, export and save profiles:

```swift
if let diarizer, currentParameters.enableSpeakerDiarization {
    let sessionProfiles = diarizer.exportSpeakerProfiles()
    speakerProfileStore.mergeSessionProfiles(sessionProfiles)
}
```

### TranscriptionViewModel Changes

- Pass `SpeakerProfileStore` instance to `ChunkedWhisperEngine` (via init or through service layer)
- No UI changes in this phase

## Data Flow

```
App Launch
  └─ SpeakerProfileStore.load()  ← reads ~/QuickTranscriber/speakers.json

Recording Start
  └─ ChunkedWhisperEngine.startStreaming()
       └─ diarizer.loadSpeakerProfiles(store.profiles)
            └─ speakerTracker.loadProfiles(...)  ← pre-populated with known speakers

Recording (each chunk)
  └─ speakerTracker.identify(embedding:)  ← matches against known + new profiles

Recording Stop
  └─ ChunkedWhisperEngine.stopStreaming()
       └─ diarizer.exportSpeakerProfiles()
       └─ speakerProfileStore.mergeSessionProfiles(...)
       └─ speakerProfileStore.save()  ← writes ~/QuickTranscriber/speakers.json
```

## Dependency Injection

`SpeakerProfileStore` is created once and shared:

- **Production**: `TranscriptionViewModel` creates store, passes to engine
- **Tests**: Tests inject a store pointing to a temp directory (no disk side effects)

The store is passed through the chain:
`TranscriptionViewModel` → `ChunkedWhisperEngine` (new `profileStore` parameter)

## Testing Strategy

### Unit Tests (SpeakerProfileStoreTests)
- `testSaveAndLoad`: save profiles, create new store instance, load, verify equality
- `testMergeMatchingProfile`: merge session profile with high similarity → updates existing
- `testMergeNewProfile`: merge session profile with low similarity → adds new
- `testMergeUpdatesLastUsedAndSessionCount`: verify metadata updates
- `testEmptyStore`: load from nonexistent file returns empty array

### Unit Tests (EmbeddingBasedSpeakerTrackerTests)
- `testExportProfiles`: register speakers, export, verify labels and embeddings
- `testLoadProfiles`: load 2 profiles, identify with similar embedding → matches loaded profile
- `testLoadProfilesNextLabelContinues`: load 2 profiles, register new → gets label "C"

### Integration Tests
- `testFullSessionCycle`: start→process chunks→stop→verify profiles saved
- `testCrossSessionRecognition`: session1 creates profiles, session2 loads and recognizes same speakers

## File Structure

```
Sources/QuickTranscriber/
  Models/
    StoredSpeakerProfile.swift     (new)
    SpeakerProfileStore.swift      (new)
  Engines/
    EmbeddingBasedSpeakerTracker.swift  (modified: +exportProfiles, +loadProfiles)
    SpeakerDiarizer.swift               (modified: +protocol methods)
    ChunkedWhisperEngine.swift          (modified: +profile load/save)
Tests/QuickTranscriberTests/
  SpeakerProfileStoreTests.swift        (new)
  EmbeddingBasedSpeakerTrackerTests.swift (modified: +export/load tests)
```
