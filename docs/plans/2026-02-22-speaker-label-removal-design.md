# Speaker Label Removal Design

## Problem

PR #37 (UUID Speaker Identification) replaced session labels ("A", "B", "C") with UUIDs but left `StoredSpeakerProfile.label` intact. This causes:

1. **Long display names**: Settings shows "Speaker 3F2504E0-4F89-..." instead of "Speaker-1"
2. **Broken search**: Searching "speaker" doesn't match because `displayName` is nil and `label` is a UUID string
3. **Lost display names**: ActiveSpeaker's "Speaker-1" displayName is never propagated to StoredSpeakerProfile

## Design

### 1. StoredSpeakerProfile Changes

Remove `label` field entirely. Change `displayName` from `String?` to `String` (non-optional, always has a value).

**Before:**
```swift
struct StoredSpeakerProfile {
    let id: UUID
    var label: String           // UUID string (useless)
    var displayName: String?    // usually nil
    var displayLabel: String { displayName ?? "Speaker \(label)" }
    ...
}
```

**After:**
```swift
struct StoredSpeakerProfile {
    let id: UUID
    var displayName: String     // always set, e.g. "Speaker-1"
    ...
}
```

Remove: `label`, `displayLabel` computed property.

### 2. mergeSessionProfiles Signature Change

Pass displayName from ActiveSpeaker through the merge pipeline.

**Before:** `mergeSessionProfiles([(label: String, embedding: [Float])])`
**After:** `mergeSessionProfiles([(speakerId: UUID, embedding: [Float], displayName: String)])`

- New profile: use provided `displayName`
- Existing profile update: keep existing `displayName` (user may have renamed)

### 3. DisplayName Propagation: ChunkedWhisperEngine → SpeakerProfileStore

ChunkedWhisperEngine doesn't have access to ActiveSpeaker displayNames. Pass them via:

```
ViewModel.stopRecording()
  → TranscriptionService.stopTranscription(speakerDisplayNames: [String: String])
    → ChunkedWhisperEngine.stopStreaming(speakerDisplayNames: [String: String])
      → store.mergeSessionProfiles([(speakerId, embedding, displayName)])
```

Key: `speakerDisplayNames` maps UUID string → display name (e.g. "Speaker-1").

### 4. Deletions

- `StoredSpeakerProfile.label` field
- `StoredSpeakerProfile.displayLabel` computed property
- `SpeakerProfileStore.nextAvailableLabel()` method
- `SpeakerProfileStore.displayName(for:)` method
- All references to `.label` on StoredSpeakerProfile
- All references to `.displayLabel` (replace with `.displayName`)

### 5. Search Logic Fix

```swift
func profiles(matching search: String) -> [StoredSpeakerProfile] {
    profiles.filter {
        $0.displayName.localizedCaseInsensitiveContains(search)
        || $0.tags.contains { $0.localizedCaseInsensitiveContains(search) }
    }
}
```

### 6. Out of Scope

- `EmbeddingHistoryEntry.label` — separate concept, not affected
- Old speakers.json migration — user approved full clear
