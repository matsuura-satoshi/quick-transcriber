# UUID-Based Speaker Identification Design

## Date: 2026-02-22

## Problem

The system uses `sessionLabel` ("A", "B", "C") as speaker identifiers throughout the pipeline. These labels:
- Collide across sessions (Session 1's "A" ≠ Session 2's "A")
- Create inconsistency between `labelDisplayNames` (keyed by stored profile label) and `ConfirmedSegment.speaker` (session label)
- Cause wrong speaker selection in UI menus
- Corrupt embedding learning when labels are mismatched

## Solution

Replace sessionLabel-based identification with UUID-based identification at all layers. `ConfirmedSegment.speaker` stores `ActiveSpeaker.id.uuidString`. Display names are resolved via a `speakerDisplayNames: [String: String]` dictionary (key=UUID string).

## Design

### 1. Data Model Changes

#### ConfirmedSegment
- `speaker: String?` — type unchanged, value changes from "A" to UUID string
- `originalSpeaker: String?` — same treatment

#### ActiveSpeaker
- **Remove** `sessionLabel: String`
- `id: UUID` — sole identifier (already exists)
- `displayName: String?` — default: "Speaker-1", "Speaker-2" (sequential)
- `speakerProfileId: UUID?` — unchanged

#### SpeakerIdentification (pipeline output)
- `label: String` → `speakerId: UUID`
- `confidence: Float` — unchanged
- `embedding: [Float]?` — unchanged

#### SpeakerMenuItem
- `label: String` → `id: UUID`
- `displayName: String?` — unchanged (used for menu title)

#### speakerDisplayNames (replaces labelDisplayNames)
- Type: `[String: String]` (key=UUID string, value=display name)
- Built from activeSpeakers, not from stored profiles
- Updated when speakers are added, renamed, or auto-detected

#### speakerMenuOrder
- `[String]` — stores UUID strings instead of session labels

### 2. Pipeline Changes

#### EmbeddingBasedSpeakerTracker
- Internal `SpeakerProfile.label: String` → `SpeakerProfile.id: UUID`
- `identify()` returns `SpeakerIdentification(speakerId: UUID, ...)`
- New speaker: generates `UUID()` (no LabelUtils)
- `correctAssignment(embedding:, from: UUID, to: UUID)`

#### ViterbiSpeakerSmoother
- Transition table keys: `String` → `UUID`
- `processLabel()` → `process()` — works with UUID-based SpeakerIdentification

#### ChunkedWhisperEngine
- Stores `speakerId.uuidString` in `ConfirmedSegment.speaker`
- Retroactive updates use UUID string

#### TranscriptionService
- `correctSpeakerAssignment(embedding:, from: String, to: String)` — keeps String params (UUID strings)
- Internally converts to UUID for tracker

### 3. ViewModel Changes

#### TranscriptionViewModel
- `labelDisplayNames` → `speakerDisplayNames: [String: String]`
- `renameActiveSpeaker(label:, displayName:)` → `renameActiveSpeaker(id: UUID, displayName:)`
- `reassignSpeakerForBlock(segmentIndex:, newSpeaker:)` — newSpeaker is UUID string
- `recordSpeakerSelection(_ id: String)` — stores UUID string
- `availableSpeakers` — builds from activeSpeakers, sorts by speakerMenuOrder
- `addManualSpeaker(displayName:)` — generates UUID (no LabelUtils), displayName = provided or "Speaker-N"
- `addAutoDetectedSpeaker()` — uses embedding match only (no label match fallback)
- `syncActiveSpeakerProfileIds()` — removed or refactored (embedding-based only)
- Auto-generated display names: "Speaker-1", "Speaker-2", ... (sequential counter)

### 4. View Changes

#### TranscriptionTextView
- `SpeakerMenuItem(id: UUID, displayName: String)` — no label field
- Menu title: `displayName ?? "Unknown"`
- `reassignBlockAction`: passes `id.uuidString`
- `buildAttributedStringFromSegments`: uses `speakerDisplayNames[speaker]`

#### ContentView
- `labelDisplayNames` → `speakerDisplayNames`

#### TranscriptionUtils.joinSegments
- `labelDisplayNames` param → `speakerDisplayNames`
- Lookup: `speakerDisplayNames[speaker] ?? "Unknown"`

#### PostMeetingTagSheet
- Replace `speaker.sessionLabel` with `speaker.displayName ?? "Speaker-N"`

#### SettingsView
- Replace `speaker.sessionLabel` references with `speaker.displayName`

#### TranslationTextView
- `labelDisplayNames` → `speakerDisplayNames`

### 5. Storage Changes

#### SpeakerProfileStore
- `labelDisplayNames` computed property — remove (ViewModel manages directly)
- `label` field on StoredSpeakerProfile — keep for backward compatibility but not used for session matching
- `mergeSessionProfiles` — matching by embedding similarity only (no label fallback)

### 6. Deletions

- `LabelUtils.swift` — no longer needed (UUID replaces label generation)
- `ActiveSpeaker.sessionLabel` — removed
- `SpeakerProfileStore.labelDisplayNames` — removed
- `TranscriptionViewModel.sessionRenamedLabels` — no longer needed

### 7. Display Name Counter

New property in TranscriptionViewModel:
```swift
private var nextSpeakerNumber: Int = 1
```
Incremented each time a new speaker is auto-detected or manually added without a name.

## Impact Summary

| Component | Change Type |
|---|---|
| ConfirmedSegment | Value change (label → UUID string) |
| ActiveSpeaker | Remove sessionLabel, keep id/displayName |
| SpeakerIdentification | label → speakerId (UUID) |
| EmbeddingBasedSpeakerTracker | label → UUID internally |
| ViterbiSpeakerSmoother | String keys → UUID keys |
| ChunkedWhisperEngine | Use UUID string in segments |
| TranscriptionViewModel | Major refactor (displayNames, menu, reassign) |
| TranscriptionTextView | SpeakerMenuItem, callbacks, rendering |
| ContentView | Parameter rename |
| TranscriptionUtils | Parameter rename |
| SettingsView | sessionLabel → displayName |
| PostMeetingTagSheet | sessionLabel → displayName |
| LabelUtils | Delete |
| SpeakerProfileStore | Remove labelDisplayNames, simplify merge |
