# Speaker Label Removal Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove `StoredSpeakerProfile.label` field and make `displayName` non-optional, fixing broken display and search in Settings.

**Architecture:** Remove the `label` field from StoredSpeakerProfile, change `displayName` from `String?` to `String`. Pass displayName from ActiveSpeaker through the merge pipeline (ViewModel → Service → Engine → Store). Delete `displayLabel`, `nextAvailableLabel()`, `displayName(for:)`.

**Tech Stack:** Swift, SwiftUI, XCTest

---

### Task 1: StoredSpeakerProfile — remove label, make displayName non-optional

**Files:**
- Modify: `Sources/QuickTranscriber/Models/StoredSpeakerProfile.swift`
- Test: `Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift`

**Step 1: Update tests for new StoredSpeakerProfile API**

Update all tests that create `StoredSpeakerProfile` to use the new API (no `label`, `displayName` is required `String`). Delete tests for removed functionality.

Delete these tests:
- `testDisplayNameNilByDefault` — displayName is no longer optional
- `testDisplayNameBackwardCompatibility` — no backward compat needed
- `testDisplayLabelWithDisplayName` — displayLabel removed
- `testDisplayLabelWithoutDisplayName` — displayLabel removed
- `testDisplayLabelWithEmptyDisplayName` — displayLabel removed
- `testDisplayNameForLabelWithDisplayName` — displayName(for:) removed
- `testDisplayNameForLabelWithoutDisplayName` — displayName(for:) removed
- `testDisplayNameForUnknownLabel` — displayName(for:) removed
- `testMergeNewProfileWithDuplicateLabelGetsUniqueLabel` — label collision no longer applies
- `testMergeNewProfileSkipsUsedLabels` — label collision no longer applies
- `testMergeMatchingProfileKeepsOriginalLabel` — label no longer exists
- `testNextAvailableLabelWrapsAround` — nextAvailableLabel removed

Update all remaining tests that construct `StoredSpeakerProfile`:
- Remove `label:` parameter
- Add `displayName:` parameter (required String)

Example — `testStoredSpeakerProfileCodable`:

```swift
func testStoredSpeakerProfileCodable() throws {
    let profile = StoredSpeakerProfile(
        id: UUID(),
        displayName: "Speaker-1",
        embedding: [Float](repeating: 0.1, count: 256),
        lastUsed: Date(),
        sessionCount: 3
    )
    let data = try JSONEncoder().encode(profile)
    let decoded = try JSONDecoder().decode(StoredSpeakerProfile.self, from: data)
    XCTAssertEqual(profile.id, decoded.id)
    XCTAssertEqual(profile.displayName, decoded.displayName)
    XCTAssertEqual(profile.embedding, decoded.embedding)
    XCTAssertEqual(profile.sessionCount, decoded.sessionCount)
}
```

Example — `testDisplayNameCodable`:

```swift
func testDisplayNameCodable() throws {
    let profile = StoredSpeakerProfile(
        displayName: "Alice",
        embedding: [Float](repeating: 0.1, count: 256)
    )
    let data = try JSONEncoder().encode(profile)
    let decoded = try JSONDecoder().decode(StoredSpeakerProfile.self, from: data)
    XCTAssertEqual(decoded.displayName, "Alice")
}
```

For every test that uses `StoredSpeakerProfile(label: "X", ...)`, replace with `StoredSpeakerProfile(displayName: "Speaker-X", ...)`. Remove all assertions on `.label` and `.displayLabel`.

**Step 2: Run tests to verify they fail**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: Compilation errors (label parameter doesn't exist yet)

**Step 3: Update StoredSpeakerProfile implementation**

Replace the entire `StoredSpeakerProfile.swift` with:

```swift
import Foundation

public struct StoredSpeakerProfile: Codable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public var embedding: [Float]
    public var lastUsed: Date
    public var sessionCount: Int
    public var tags: [String]

    public init(id: UUID = UUID(), displayName: String, embedding: [Float], lastUsed: Date = Date(), sessionCount: Int = 1, tags: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.embedding = embedding
        self.lastUsed = lastUsed
        self.sessionCount = sessionCount
        self.tags = tags
    }
}
```

No custom `init(from decoder:)` needed — auto-synthesized Codable is fine since all fields are now non-optional standard types (tags has no backward compat needed since we clear speakers.json).

**Step 4: Run tests to verify they pass**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: Tests still fail (SpeakerProfileStore and other files still reference `.label`)

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Models/StoredSpeakerProfile.swift Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift
git commit -m "refactor: remove label from StoredSpeakerProfile, make displayName non-optional"
```

---

### Task 2: SpeakerProfileStore — update mergeSessionProfiles and remove label-related methods

**Files:**
- Modify: `Sources/QuickTranscriber/Models/SpeakerProfileStore.swift`
- Modify: `Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift`

**Step 1: Update tests for new mergeSessionProfiles signature**

The new signature is:
```swift
func mergeSessionProfiles(_ sessionProfiles: [(speakerId: UUID, embedding: [Float], displayName: String)])
```

Update `testMergeMatchingProfileUpdatesExisting`:
```swift
func testMergeMatchingProfileUpdatesExisting() throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = SpeakerProfileStore(directory: dir)
    let existingEmb = makeEmbedding(dominant: 0)
    store.profiles = [StoredSpeakerProfile(displayName: "Speaker-1", embedding: existingEmb, sessionCount: 2)]

    var sessionEmb = makeEmbedding(dominant: 0)
    sessionEmb[1] = 0.15
    store.mergeSessionProfiles([(speakerId: UUID(), embedding: sessionEmb, displayName: "Speaker-1")])

    XCTAssertEqual(store.profiles.count, 1, "Should update, not add")
    XCTAssertEqual(store.profiles[0].sessionCount, 3)
    XCTAssertNotEqual(store.profiles[0].embedding, existingEmb)
}
```

Update `testMergeNewProfileAddsToStore`:
```swift
func testMergeNewProfileAddsToStore() throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = SpeakerProfileStore(directory: dir)
    store.profiles = [StoredSpeakerProfile(displayName: "Speaker-1", embedding: makeEmbedding(dominant: 0))]

    store.mergeSessionProfiles([(speakerId: UUID(), embedding: makeEmbedding(dominant: 1), displayName: "Speaker-2")])

    XCTAssertEqual(store.profiles.count, 2)
    XCTAssertEqual(store.profiles[1].displayName, "Speaker-2")
    XCTAssertEqual(store.profiles[1].sessionCount, 1)
}
```

Update `testMergeUpdatesLastUsed`:
```swift
func testMergeUpdatesLastUsed() throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = SpeakerProfileStore(directory: dir)
    let oldDate = Date.distantPast
    store.profiles = [StoredSpeakerProfile(
        displayName: "Speaker-1", embedding: makeEmbedding(dominant: 0),
        lastUsed: oldDate, sessionCount: 1
    )]

    store.mergeSessionProfiles([(speakerId: UUID(), embedding: makeEmbedding(dominant: 0), displayName: "Speaker-1")])

    XCTAssertGreaterThan(store.profiles[0].lastUsed, oldDate)
}
```

Update `testMergeEmptySessionDoesNothing`:
```swift
func testMergeEmptySessionDoesNothing() throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = SpeakerProfileStore(directory: dir)
    store.profiles = [StoredSpeakerProfile(displayName: "Speaker-1", embedding: makeEmbedding(dominant: 0))]

    store.mergeSessionProfiles([])
    XCTAssertEqual(store.profiles.count, 1)
}
```

Add test for merge preserving existing displayName (when user has renamed):
```swift
func testMergeMatchingProfilePreservesExistingDisplayName() throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = SpeakerProfileStore(directory: dir)
    store.profiles = [StoredSpeakerProfile(displayName: "Alice", embedding: makeEmbedding(dominant: 0))]

    store.mergeSessionProfiles([(speakerId: UUID(), embedding: makeEmbedding(dominant: 0), displayName: "Speaker-1")])

    XCTAssertEqual(store.profiles.count, 1)
    XCTAssertEqual(store.profiles[0].displayName, "Alice", "Should preserve user-set displayName")
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: Compilation errors (mergeSessionProfiles signature mismatch)

**Step 3: Update SpeakerProfileStore implementation**

In `SpeakerProfileStore.swift`:

1. Change `mergeSessionProfiles` signature and body:
```swift
public func mergeSessionProfiles(_ sessionProfiles: [(speakerId: UUID, embedding: [Float], displayName: String)]) {
    for (_, embedding, displayName) in sessionProfiles {
        var bestIndex = -1
        var bestSimilarity: Float = -1

        for (i, stored) in profiles.enumerated() {
            let sim = EmbeddingBasedSpeakerTracker.cosineSimilarity(embedding, stored.embedding)
            if sim > bestSimilarity {
                bestSimilarity = sim
                bestIndex = i
            }
        }

        if bestIndex >= 0 && bestSimilarity >= mergeThreshold {
            let alpha = updateAlpha
            profiles[bestIndex].embedding = zip(profiles[bestIndex].embedding, embedding).map { old, new in
                (1 - alpha) * old + alpha * new
            }
            profiles[bestIndex].lastUsed = Date()
            profiles[bestIndex].sessionCount += 1
            // Do NOT update displayName — user may have renamed
        } else {
            profiles.append(StoredSpeakerProfile(displayName: displayName, embedding: embedding))
        }
    }
}
```

2. Delete `nextAvailableLabel()` method (lines 110-125)

3. Delete `displayName(for:)` method (lines 59-65)

4. Update `rename` method — when name is empty, set a fallback instead of nil:
```swift
public func rename(id: UUID, to name: String) throws {
    guard let index = profiles.firstIndex(where: { $0.id == id }) else {
        throw SpeakerProfileStoreError.profileNotFound
    }
    profiles[index].displayName = name.isEmpty ? profiles[index].displayName : name
    try save()
}
```

5. Update `profiles(matching:)` — remove `.label` reference:
```swift
public func profiles(matching search: String) -> [StoredSpeakerProfile] {
    guard !search.isEmpty else { return profiles }
    return profiles.filter {
        $0.displayName.localizedCaseInsensitiveContains(search)
        || $0.tags.contains { $0.localizedCaseInsensitiveContains(search) }
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: Tests still fail (ChunkedWhisperEngine, SettingsView etc. still reference label)

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Models/SpeakerProfileStore.swift Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift
git commit -m "refactor: update mergeSessionProfiles to use displayName, remove label-related methods"
```

---

### Task 3: Pipeline — pass displayName through Service and Engine

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/TranscriptionEngine.swift:34` — add `speakerDisplayNames` parameter to `stopStreaming`
- Modify: `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift:118-164` — accept and use `speakerDisplayNames`
- Modify: `Sources/QuickTranscriber/Services/TranscriptionService.swift:45-47` — pass through `speakerDisplayNames`
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift:720-731` — pass `speakerDisplayNames` to service

**Step 1: Update TranscriptionEngine protocol**

In `TranscriptionEngine.swift`, change:
```swift
func stopStreaming() async
```
to:
```swift
func stopStreaming(speakerDisplayNames: [String: String]) async
```

Update the extension default if needed.

**Step 2: Update ChunkedWhisperEngine.stopStreaming**

Change signature to:
```swift
public func stopStreaming(speakerDisplayNames: [String: String]) async
```

In the merge section (around line 154), replace:
```swift
let mergeProfiles = filteredProfiles.map { (label: $0.speakerId.uuidString, embedding: $0.embedding) }
store.mergeSessionProfiles(mergeProfiles)
```
with:
```swift
let mergeProfiles = filteredProfiles.map { profile in
    (
        speakerId: profile.speakerId,
        embedding: profile.embedding,
        displayName: speakerDisplayNames[profile.speakerId.uuidString] ?? "Speaker"
    )
}
store.mergeSessionProfiles(mergeProfiles)
```

**Step 3: Update TranscriptionService**

Change:
```swift
public func stopTranscription() async {
    await engine.stopStreaming()
}
```
to:
```swift
public func stopTranscription(speakerDisplayNames: [String: String] = [:]) async {
    await engine.stopStreaming(speakerDisplayNames: speakerDisplayNames)
}
```

**Step 4: Update TranscriptionViewModel.stopRecording**

Change:
```swift
private func stopRecording() {
    isRecording = false
    saveUnconfirmedText()
    fileWriter.updateText(confirmedText)
    Task {
        await service.stopTranscription()
        ...
    }
}
```
to:
```swift
private func stopRecording() {
    isRecording = false
    saveUnconfirmedText()
    fileWriter.updateText(confirmedText)
    Task {
        await service.stopTranscription(speakerDisplayNames: speakerDisplayNames)
        ...
    }
}
```

**Step 5: Build to verify compilation**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds (or shows remaining errors in Views)

**Step 6: Commit**

```bash
git add Sources/QuickTranscriber/Engines/TranscriptionEngine.swift Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift Sources/QuickTranscriber/Services/TranscriptionService.swift Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift
git commit -m "feat: pass speakerDisplayNames through pipeline for profile merge"
```

---

### Task 4: View layer — replace displayLabel with displayName, fix search

**Files:**
- Modify: `Sources/QuickTranscriber/Views/SettingsView.swift`
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift` — `addManualSpeaker(fromProfile:)` line 486

**Step 1: Update SettingsView**

1. In `filteredProfiles` (line 244-247), replace:
```swift
($0.displayName ?? "").localizedCaseInsensitiveContains(searchText)
|| $0.label.localizedCaseInsensitiveContains(searchText)
```
with:
```swift
$0.displayName.localizedCaseInsensitiveContains(searchText)
```

2. In `SpeakerProfileSummaryView` (line 507), replace:
```swift
Text(profile.displayLabel)
```
with:
```swift
Text(profile.displayName)
```

3. In `SpeakerProfileDetailView` (line 555), replace:
```swift
self._editingName = State(initialValue: profile.displayName ?? "")
```
with:
```swift
self._editingName = State(initialValue: profile.displayName)
```

4. In `SpeakerProfileDetailView` (line 576), replace:
```swift
TextField("Display name for \(profile.label)...", text: $editingName)
```
with:
```swift
TextField("Display name...", text: $editingName)
```

**Step 2: Update TranscriptionViewModel.addManualSpeaker(fromProfile:)**

Line 486, replace:
```swift
displayName: profile.displayName ?? profile.displayLabel,
```
with:
```swift
displayName: profile.displayName,
```

Line 578, replace:
```swift
displayName = profile.displayName ?? profile.displayLabel
```
with:
```swift
displayName = profile.displayName
```

**Step 3: Build and run tests**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: All tests pass

**Step 4: Commit**

```bash
git add Sources/QuickTranscriber/Views/SettingsView.swift Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift
git commit -m "refactor: replace displayLabel with displayName in views"
```

---

### Task 5: Clean up remaining label references and verify

**Files:**
- Modify: Any remaining files referencing `.label` on StoredSpeakerProfile
- Modify: `Tests/QuickTranscriberTests/` — any remaining test references

**Step 1: Search for remaining references**

Run: `grep -rn '\.label' Sources/ Tests/ --include='*.swift' | grep -v 'labelRange\|labelEntry\|labelColor\|labelsHidden\|\.labels\|sessionLabel\|speakerLabel'`

Fix any remaining references.

**Step 2: Full build and test**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds with no errors

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: All tests pass

**Step 3: Commit any remaining fixes**

```bash
git add -A
git commit -m "chore: clean up remaining label references"
```
