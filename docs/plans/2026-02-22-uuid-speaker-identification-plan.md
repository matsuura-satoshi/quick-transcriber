# UUID-Based Speaker Identification Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace sessionLabel-based speaker identification with UUID-based identification to fix label/displayName inconsistency bugs.

**Architecture:** Change `SpeakerIdentification.label` to `.speakerId` (UUID), remove `ActiveSpeaker.sessionLabel`, store UUID strings in `ConfirmedSegment.speaker`, resolve display names via `speakerDisplayNames: [String: String]` (key=UUID string). Three layers: pipeline → ViewModel → Views.

**Tech Stack:** Swift, AppKit, SwiftUI

---

### Task 1: Pipeline UUID Migration

Migrate the diarization pipeline from label-based to UUID-based speaker identification. This includes SpeakerIdentification, EmbeddingBasedSpeakerTracker, ViterbiSpeakerSmoother, DiarizationPacer, ChunkedWhisperEngine, and TranscriptionService.

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/EmbeddingBasedSpeakerTracker.swift`
- Modify: `Sources/QuickTranscriber/Engines/SpeakerLabelTracker.swift` (ViterbiSpeakerSmoother)
- Modify: `Sources/QuickTranscriber/Engines/DiarizationPacer.swift`
- Modify: `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift`
- Modify: `Sources/QuickTranscriber/Services/TranscriptionService.swift`
- Modify: `Tests/QuickTranscriberTests/EmbeddingBasedSpeakerTrackerTests.swift`
- Modify: `Tests/QuickTranscriberTests/ViterbiSpeakerSmootherTests.swift`
- Modify: `Tests/QuickTranscriberTests/ChunkedWhisperEngineTests.swift`
- Modify: `Tests/QuickTranscriberTests/DiarizationPacerTests.swift`

**Step 1: Change SpeakerIdentification struct**

In `EmbeddingBasedSpeakerTracker.swift`, replace the `SpeakerIdentification` struct:

```swift
public struct SpeakerIdentification: Sendable, Equatable {
    public let speakerId: UUID
    public let confidence: Float
    public let embedding: [Float]?

    public init(speakerId: UUID, confidence: Float, embedding: [Float]? = nil) {
        self.speakerId = speakerId
        self.confidence = confidence
        self.embedding = embedding
    }
}
```

**Step 2: Change internal SpeakerProfile in EmbeddingBasedSpeakerTracker**

Replace:
```swift
public struct SpeakerProfile {
    public let label: String
    public var embedding: [Float]
    ...
}
```
with:
```swift
public struct SpeakerProfile {
    public let id: UUID
    public var embedding: [Float]
    public var hitCount: Int
    public var embeddingHistory: [WeightedEmbedding]
}
```

**Step 3: Update `identify()` method in EmbeddingBasedSpeakerTracker**

All `SpeakerIdentification(label:...)` → `SpeakerIdentification(speakerId:...)`
All `profiles[i].label` → `profiles[i].id`
New speaker registration: `let id = UUID()` instead of `LabelUtils.nextAvailableLabel(...)`
Remove `import` of LabelUtils if present.

**Step 4: Update `correctAssignment()` in EmbeddingBasedSpeakerTracker**

Change signature: `from oldLabel: String, to newLabel: String` → `from oldId: UUID, to newId: UUID`
Update internal logic: `$0.label == oldLabel` → `$0.id == oldId`, `$0.label == newLabel` → `$0.id == newId`

**Step 5: Update `exportProfiles()` in EmbeddingBasedSpeakerTracker**

Return type changes: `[(label: String, embedding: [Float])]` → `[(speakerId: UUID, embedding: [Float])]`
Tuple: `(label: p.label, ...)` → `(speakerId: p.id, ...)`

**Step 6: Update ViterbiSpeakerSmoother**

In `SpeakerLabelTracker.swift`:
- `stateLogProb: [String: Double]` → `stateLogProb: [UUID: Double]`
- `pendingLabel: String?` → `pendingSpeakerId: UUID?`
- `processLabel(_ identification:)` → `process(_ identification:)`
- All internal references to `.label` → `.speakerId`
- Comparison logic: `candidate == confirmed.label` → `candidate == confirmed.speakerId`

**Step 7: Update DiarizationPacer**

`lastResult: SpeakerIdentification?` — type is the same, no structural change needed. Only if `label` was accessed directly.

**Step 8: Update ChunkedWhisperEngine**

- `smoothedResult?.label` → `smoothedResult?.speakerId.uuidString` (stored in ConfirmedSegment.speaker)
- Retroactive updates: `result.label` → `result.speakerId.uuidString`
- `correctSpeakerAssignment(embedding:, from:, to:)` — change String params to UUID params or keep as String and convert
- `exportProfiles()` call: update tuple access from `.label` to `.speakerId`
- Session merge: `(label: p.label, ...)` → `(speakerId: p.speakerId, ...)`

**Step 9: Update TranscriptionService**

`correctSpeakerAssignment(embedding:, from oldLabel: String, to newLabel: String)` → accept UUID strings, convert internally:
```swift
public func correctSpeakerAssignment(embedding: [Float], from oldSpeaker: String, to newSpeaker: String) {
    guard let oldId = UUID(uuidString: oldSpeaker), let newId = UUID(uuidString: newSpeaker) else { return }
    engine.correctSpeakerAssignment(embedding: embedding, from: oldId, to: newId)
}
```

**Step 10: Update all pipeline tests**

- EmbeddingBasedSpeakerTrackerTests: `.label` → `.speakerId`, use UUID where needed
- ViterbiSpeakerSmootherTests: `SpeakerIdentification(label:...)` → `SpeakerIdentification(speakerId:...)`
- ChunkedWhisperEngineTests: Verify segments contain UUID strings
- DiarizationPacerTests: Update SpeakerIdentification construction

**Step 11: Run tests**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -20`
Expected: All tests pass (some tests in ViewModel/View may need temporary adjustments if they construct SpeakerIdentification directly)

**Step 12: Commit**

```bash
git add -A
git commit -m "refactor: migrate pipeline to UUID-based speaker identification"
```

---

### Task 2: ActiveSpeaker Model + ViewModel Refactor

Remove `sessionLabel` from ActiveSpeaker. Refactor TranscriptionViewModel to use UUID-based speaker identification. Replace `labelDisplayNames` with `speakerDisplayNames`.

**Files:**
- Modify: `Sources/QuickTranscriber/Models/ActiveSpeaker.swift`
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift`
- Modify: `Sources/QuickTranscriber/Models/SpeakerProfileStore.swift`
- Delete: `Sources/QuickTranscriber/Engines/LabelUtils.swift`
- Modify: `Tests/QuickTranscriberTests/TranscriptionViewModelTests.swift`
- Modify: `Tests/QuickTranscriberTests/LabelUtilsTests.swift` (delete)

**Step 1: Modify ActiveSpeaker**

Remove `sessionLabel`. Keep `id`, `speakerProfileId`, `displayName`, `source`:

```swift
public struct ActiveSpeaker: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let speakerProfileId: UUID?
    public var displayName: String?
    public let source: Source

    public enum Source: String, Equatable, Sendable {
        case manual
        case autoDetected
    }

    public init(
        id: UUID = UUID(),
        speakerProfileId: UUID? = nil,
        displayName: String? = nil,
        source: Source
    ) {
        self.id = id
        self.speakerProfileId = speakerProfileId
        self.displayName = displayName
        self.source = source
    }
}
```

**Step 2: Update TranscriptionViewModel properties**

Replace:
```swift
@Published public var labelDisplayNames: [String: String] = [:]
```
with:
```swift
@Published public var speakerDisplayNames: [String: String] = [:]  // key=UUID string
private var nextSpeakerNumber: Int = 1
```

Remove: `private var sessionRenamedLabels: Set<String> = []`

**Step 3: Update `speakerDisplayNames` management**

New method to update display names from activeSpeakers:
```swift
private func updateSpeakerDisplayNames() {
    var names: [String: String] = [:]
    for speaker in activeSpeakers {
        if let name = speaker.displayName {
            names[speaker.id.uuidString] = name
        }
    }
    speakerDisplayNames = names
}
```

**Step 4: Update `confirmedText` computed property**

```swift
public var confirmedText: String {
    guard !confirmedSegments.isEmpty else { return "" }
    return TranscriptionUtils.joinSegments(
        confirmedSegments,
        language: currentLanguage.rawValue,
        silenceThreshold: parametersStore.parameters.silenceLineBreakThreshold,
        speakerDisplayNames: speakerDisplayNames
    )
}
```

**Step 5: Update `availableSpeakers`**

Change `SpeakerMenuItem`:
```swift
public struct SpeakerMenuItem: Equatable {
    public let id: UUID
    public let displayName: String?
}
```

Update computed property — use `speaker.id.uuidString` for ordering:
```swift
public var availableSpeakers: [SpeakerMenuItem] {
    let activeIds = Set(activeSpeakers.map { $0.id.uuidString })
    let speakersById = Dictionary(
        uniqueKeysWithValues: activeSpeakers.map { ($0.id.uuidString, $0) }
    )

    var ordered: [SpeakerMenuItem] = []
    var seen = Set<String>()
    for idStr in speakerMenuOrder {
        guard activeIds.contains(idStr), !seen.contains(idStr),
              let speaker = speakersById[idStr] else { continue }
        ordered.append(SpeakerMenuItem(id: speaker.id, displayName: speaker.displayName))
        seen.insert(idStr)
    }
    for speaker in activeSpeakers where !seen.contains(speaker.id.uuidString) {
        ordered.append(SpeakerMenuItem(id: speaker.id, displayName: speaker.displayName))
    }
    return ordered
}
```

**Step 6: Update `renameActiveSpeaker`**

Change signature from `label: String` to `id: UUID`:
```swift
public func renameActiveSpeaker(id: UUID, displayName: String) {
    let name = displayName.isEmpty ? nil : displayName
    if let idx = activeSpeakers.firstIndex(where: { $0.id == id }) {
        activeSpeakers[idx].displayName = name
    }
    updateSpeakerDisplayNames()
    regenerateText()
}
```

**Step 7: Update `reassignSegment`, `reassignSpeakerForBlock`, `reassignSpeakerForSelection`**

`newSpeaker` parameter is now a UUID string (ActiveSpeaker.id.uuidString). The logic remains the same — it's still a String stored in ConfirmedSegment.speaker. Update `recordSpeakerSelection` calls to use UUID string.

**Step 8: Update `addManualSpeaker` methods**

From profile:
```swift
public func addManualSpeaker(fromProfile profileId: UUID) {
    guard let profile = speakerProfileStore.profiles.first(where: { $0.id == profileId }),
          !activeSpeakers.contains(where: { $0.speakerProfileId == profileId })
    else { return }
    let speaker = ActiveSpeaker(
        speakerProfileId: profileId,
        displayName: profile.displayName ?? profile.displayLabel,
        source: .manual
    )
    activeSpeakers.append(speaker)
    updateSpeakerDisplayNames()
}
```

With display name:
```swift
public func addManualSpeaker(displayName: String) {
    let name = displayName.isEmpty ? "Speaker-\(nextSpeakerNumber)" : displayName
    nextSpeakerNumber += 1
    let speaker = ActiveSpeaker(displayName: name, source: .manual)
    activeSpeakers.append(speaker)
    updateSpeakerDisplayNames()
}
```

**Step 9: Update `addAndReassignBlock` / `addAndReassignSelection`**

Use `speaker.id.uuidString` instead of `speaker.sessionLabel`:
```swift
public func addAndReassignBlock(profileId: UUID, segmentIndex: Int) {
    addManualSpeaker(fromProfile: profileId)
    guard let speaker = activeSpeakers.last(where: { $0.speakerProfileId == profileId }) else { return }
    reassignSpeakerForBlock(segmentIndex: segmentIndex, newSpeaker: speaker.id.uuidString)
}
```

**Step 10: Update `addAutoDetectedSpeaker`**

This method receives the pipeline-produced speakerId (now a UUID string from ConfirmedSegment.speaker). Instead of matching by label, match by UUID:

```swift
private func addAutoDetectedSpeaker(speakerId: String, embedding: [Float]?) {
    // Check if already active
    guard !activeSpeakers.contains(where: { $0.id.uuidString == speakerId }) else { return }

    // Try to match to existing stored profile by embedding
    var matchedProfileId: UUID? = nil
    if let embedding {
        var bestSimilarity: Float = -1
        for profile in speakerProfileStore.profiles {
            let sim = EmbeddingBasedSpeakerTracker.cosineSimilarity(embedding, profile.embedding)
            if sim >= Constants.Embedding.similarityThreshold && sim > bestSimilarity {
                bestSimilarity = sim
                matchedProfileId = profile.id
            }
        }
    }

    let displayName: String
    if let profileId = matchedProfileId,
       let profile = speakerProfileStore.profiles.first(where: { $0.id == profileId }) {
        displayName = profile.displayName ?? profile.displayLabel
    } else {
        displayName = "Speaker-\(nextSpeakerNumber)"
        nextSpeakerNumber += 1
    }

    let speaker = ActiveSpeaker(
        id: UUID(uuidString: speakerId) ?? UUID(),
        speakerProfileId: matchedProfileId,
        displayName: displayName,
        source: .autoDetected
    )
    activeSpeakers.append(speaker)
    updateSpeakerDisplayNames()
}
```

**Step 11: Remove or simplify `syncActiveSpeakerProfileIds`**

This method is no longer needed — profile linking happens in `addAutoDetectedSpeaker` via embedding matching. Remove the method and its call in `stopRecording()`.

**Step 12: Update `stopRecording` / session end**

- Remove `syncActiveSpeakerProfileIds()` call
- Update `mergeSessionProfiles` call — pass UUID-based profiles instead of label-based

**Step 13: Remove SpeakerProfileStore.labelDisplayNames**

Delete the `labelDisplayNames` computed property from `SpeakerProfileStore.swift`.
Update ViewModel init to NOT load from `profileStore.labelDisplayNames`.

**Step 14: Delete LabelUtils.swift**

```bash
rm Sources/QuickTranscriber/Engines/LabelUtils.swift
```

Also delete `Tests/QuickTranscriberTests/LabelUtilsTests.swift` if it exists.

**Step 15: Update all ViewModel tests**

- All `ActiveSpeaker(sessionLabel: "A", ...)` → `ActiveSpeaker(displayName: "Speaker-1", ...)`
- All `speaker.sessionLabel` → `speaker.id.uuidString` or `speaker.displayName`
- All `vm.labelDisplayNames` → `vm.speakerDisplayNames`
- All `SpeakerMenuItem.label` → `SpeakerMenuItem.id`
- Tests that check `confirmedSegments[i].speaker == "A"` → check for UUID string

**Step 16: Run tests**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -20`
Expected: All tests pass

**Step 17: Commit**

```bash
git add -A
git commit -m "refactor: remove sessionLabel, use UUID-based speaker identification in ViewModel"
```

---

### Task 3: View Layer Updates

Update all views to use UUID-based speaker identification and `speakerDisplayNames`.

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/TranscriptionUtils.swift`
- Modify: `Sources/QuickTranscriber/Views/TranscriptionTextView.swift`
- Modify: `Sources/QuickTranscriber/Views/ContentView.swift`
- Modify: `Sources/QuickTranscriber/Views/TranslationTextView.swift`
- Modify: `Sources/QuickTranscriber/Views/SettingsView.swift`
- Modify: `Sources/QuickTranscriber/Views/PostMeetingTagSheet.swift`
- Modify: `Tests/QuickTranscriberTests/TranscriptionUtilsTests.swift`
- Modify: `Tests/QuickTranscriberTests/TranscriptionTextViewTests.swift` (if exists)

**Step 1: Update TranscriptionUtils.joinSegments**

Rename parameter: `labelDisplayNames` → `speakerDisplayNames`
Update fallback: `speakerDisplayNames[speaker] ?? "Unknown"`

```swift
public static func joinSegments(
    _ segments: [ConfirmedSegment],
    language: String,
    silenceThreshold: TimeInterval = 1.0,
    speakerDisplayNames: [String: String] = [:]
) -> String {
    // ... existing logic ...
    // Change: let displayName = labelDisplayNames[speaker] ?? speaker
    // To:     let displayName = speakerDisplayNames[speaker] ?? "Unknown"
}
```

**Step 2: Update TranscriptionTextView**

**SpeakerMenuItem references** in InteractiveTranscriptionTextView:
- `availableSpeakers` is now `[SpeakerMenuItem]` with `id: UUID` instead of `label: String`

**BlockReassignInfo**: Change `label: String` to `speakerId: String` (UUID string)

**showSpeakerMenu**:
```swift
item.representedObject = BlockReassignInfo(segmentIndex: firstIdx, speakerId: speaker.id.uuidString)
```

**reassignBlockAction**:
```swift
let speakerId = info.speakerId
onReassignBlock?(segmentIndex, speakerId)
```

**menu(for:)** selection menu:
```swift
item.representedObject = speaker.id.uuidString
```

**menuTitle**: Use displayName only:
```swift
private static func menuTitle(for speaker: TranscriptionViewModel.SpeakerMenuItem) -> String {
    return speaker.displayName ?? "Unknown"
}
```

**buildAttributedStringFromSegments**: Rename `labelDisplayNames` → `speakerDisplayNames`
Update all: `labelDisplayNames[speaker] ?? speaker` → `speakerDisplayNames[speaker] ?? "Unknown"`

**TranscriptionTextView struct properties**:
- `labelDisplayNames` → `speakerDisplayNames`

**updateNSView**: Update property name

**Step 3: Update ContentView**

```swift
speakerDisplayNames: viewModel.speakerDisplayNames,
```

Update closures:
```swift
onReassignBlock: { segmentIndex, newSpeaker in
    viewModel.reassignSpeakerForBlock(segmentIndex: segmentIndex, newSpeaker: newSpeaker)
},
onReassignSelection: { range, newSpeaker, map in
    viewModel.reassignSpeakerForSelection(selectionRange: range, newSpeaker: newSpeaker, segmentMap: map)
}
```

**Step 4: Update TranslationTextView**

Rename `labelDisplayNames` parameter and usage to `speakerDisplayNames`.

**Step 5: Update SettingsView**

Replace all `speaker.sessionLabel` references:
- Display: `speaker.displayName ?? "Speaker"`
- Rename callback: `viewModel.renameActiveSpeaker(id: speaker.id, displayName: name)`

**Step 6: Update PostMeetingTagSheet**

Replace:
- `Text(speaker.displayName ?? "Speaker \(speaker.sessionLabel)")` → `Text(speaker.displayName ?? "Speaker")`
- `Text("(\(speaker.sessionLabel))")` → remove or replace with profile info

**Step 7: Update TranscriptionUtils tests and any view tests**

- `joinSegments` tests: rename parameter
- TranscriptionTextView tests: update SpeakerMenuItem construction

**Step 8: Run tests**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -20`
Expected: All tests pass

**Step 9: Commit**

```bash
git add -A
git commit -m "refactor: update views for UUID-based speaker identification"
```

---

### Task 4: SpeakerProfileStore Merge + Final Cleanup

Update session profile merging to use UUID-based data. Remove all remaining references to sessionLabel and LabelUtils.

**Files:**
- Modify: `Sources/QuickTranscriber/Models/SpeakerProfileStore.swift`
- Modify: `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift` (merge call)
- Modify: `Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift`

**Step 1: Update `mergeSessionProfiles` signature**

```swift
public func mergeSessionProfiles(_ sessionProfiles: [(speakerId: UUID, embedding: [Float])]) {
    // Same embedding-based matching logic
    // Change label handling: use speakerId for new profile label or generate one
}
```

When creating a new profile (no embedding match), generate a unique label:
```swift
let uniqueLabel = "S\(profiles.count + 1)"
```
(StoredSpeakerProfile.label is still needed for backward compatibility in storage, but is not used as an identifier)

**Step 2: Update ChunkedWhisperEngine.stopRecording merge call**

```swift
let profileData = diarizer.exportProfiles().map { (speakerId: $0.speakerId, embedding: $0.embedding) }
store.mergeSessionProfiles(profileData)
```

**Step 3: Remove SpeakerProfileStore.nextAvailableLabel() private method**

If it exists and uses LabelUtils, replace with simple counter.

**Step 4: Update tests**

- SpeakerProfileStoreTests: Update mergeSessionProfiles calls
- Verify profile matching still works by embedding similarity

**Step 5: Grep for any remaining references**

```bash
grep -r "sessionLabel\|labelDisplayNames\|LabelUtils" --include="*.swift" Sources/ Tests/
```

Fix any remaining references.

**Step 6: Run full test suite**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -20`
Expected: All tests pass

**Step 7: Build and verify**

Run: `swift build 2>&1 | tail -10`
Expected: Clean build

**Step 8: Commit**

```bash
git add -A
git commit -m "refactor: complete UUID-based speaker identification migration"
```
