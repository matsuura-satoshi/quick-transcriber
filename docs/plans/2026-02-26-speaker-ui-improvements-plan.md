# Speaker UI Improvements Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Manualモードの話者追加UIにデフォルト名、空名拒否、参加者数表示の整合性修正を加える。

**Architecture:** ViewModel層に `nextSpeakerPlaceholder` computed propertyを追加。空名拒否ロジックをtryRename/renameActiveSpeakerに追加。参加者数表示を `activeSpeakers.count` に統一し、エンジン制約にも反映。

**Tech Stack:** Swift, SwiftUI, XCTest

---

### Task 1: 空名リネーム拒否 — テスト

**Files:**
- Modify: `Tests/QuickTranscriberTests/TranscriptionViewModelTests.swift:836-845`
- Modify: `Tests/QuickTranscriberTests/SpeakerMergeTests.swift` (新規テスト追加)

**Step 1: 既存テストを修正し、新テストを追加**

`testRenameActiveSpeakerEmptyNameClearsDisplayName` (line 836) を「空名リネームが拒否される」テストに変更する：

```swift
func testRenameActiveSpeakerEmptyNameIsRejected() async {
    let (vm, _) = makeViewModel()
    vm.addManualSpeaker(displayName: "Alice")
    let speakerId = vm.activeSpeakers[0].id

    vm.renameActiveSpeaker(id: speakerId, displayName: "")

    // Empty rename should be ignored — name stays "Alice"
    XCTAssertEqual(vm.activeSpeakers[0].displayName, "Alice")
    XCTAssertEqual(vm.speakerDisplayNames[speakerId.uuidString], "Alice")
}
```

`SpeakerMergeTests.swift` に追加：

```swift
func testTryRenameActiveSpeaker_emptyName_isIgnored() {
    let (vm, _) = makeViewModel()
    vm.addManualSpeaker(displayName: "Alice")
    let id = vm.activeSpeakers[0].id

    vm.tryRenameActiveSpeaker(id: id, displayName: "")

    XCTAssertEqual(vm.activeSpeakers[0].displayName, "Alice")
    XCTAssertNil(vm.pendingMergeRequest)
}

func testTryRenameActiveSpeaker_whitespaceOnlyName_isIgnored() {
    let (vm, _) = makeViewModel()
    vm.addManualSpeaker(displayName: "Alice")
    let id = vm.activeSpeakers[0].id

    vm.tryRenameActiveSpeaker(id: id, displayName: "   ")

    XCTAssertEqual(vm.activeSpeakers[0].displayName, "Alice")
}
```

**Step 2: テストが失敗することを確認**

Run: `swift test --filter QuickTranscriberTests 2>&1 | grep -E "(testRenameActiveSpeakerEmpty|testTryRenameActiveSpeaker_empty|testTryRenameActiveSpeaker_whitespace)"`
Expected: testRenameActiveSpeakerEmptyNameIsRejected → FAIL（現状はnilになるため）

**Step 3: 実装 — 空名拒否ロジック**

`Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift`:

`tryRenameActiveSpeaker` (line 384) を修正:
```swift
public func tryRenameActiveSpeaker(id: UUID, displayName: String) {
    let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if let mergeRequest = checkNameUniqueness(newName: trimmed, forEntity: .active(id: id)) {
        pendingMergeRequest = mergeRequest
    } else {
        renameActiveSpeaker(id: id, displayName: trimmed)
    }
}
```

`renameActiveSpeaker` (line 511) を修正:
```swift
public func renameActiveSpeaker(id: UUID, displayName: String) {
    guard !displayName.isEmpty else { return }
    if let idx = activeSpeakers.firstIndex(where: { $0.id == id }) {
        activeSpeakers[idx].displayName = displayName
    }
    // Update stored profile if linked
    if let speaker = activeSpeakers.first(where: { $0.id == id }),
       let profileId = speaker.speakerProfileId {
        try? speakerProfileStore.rename(id: profileId, to: displayName)
        speakerProfiles = speakerProfileStore.profiles
    }
    updateSpeakerDisplayNames()
    regenerateText()
}
```

**Step 4: テストが通ることを確認**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: All tests passed

**Step 5: コミット**

```
feat: reject empty speaker names on rename
```

---

### Task 2: デフォルト名付き話者追加 — テスト

**Files:**
- Modify: `Tests/QuickTranscriberTests/TranscriptionViewModelTests.swift` (新規テスト追加)

**Step 1: テスト追加**

```swift
func testAddManualSpeakerEmptyNameGeneratesDefault() async {
    let (vm, _) = makeViewModel()

    vm.addManualSpeaker(displayName: "")

    XCTAssertEqual(vm.activeSpeakers.count, 1)
    XCTAssertEqual(vm.activeSpeakers[0].displayName, "Speaker-1")
}

func testNextSpeakerPlaceholder() async {
    let (vm, _) = makeViewModel()

    XCTAssertEqual(vm.nextSpeakerPlaceholder, "Speaker-1")

    vm.addManualSpeaker(displayName: "Speaker-1")
    XCTAssertEqual(vm.nextSpeakerPlaceholder, "Speaker-2")
}
```

**Step 2: テストが失敗することを確認**

Run: `swift test --filter QuickTranscriberTests 2>&1 | grep -E "(testAddManualSpeakerEmpty|testNextSpeakerPlaceholder)"`
Expected: `testNextSpeakerPlaceholder` → FAIL（プロパティが存在しない）

**Step 3: 実装 — nextSpeakerPlaceholder**

`Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift` に追加（`generateSpeakerName()` の直前、line 758付近）:

```swift
/// Preview of the next auto-generated speaker name (no side effects)
public var nextSpeakerPlaceholder: String {
    let existingNames = Set(activeSpeakers.compactMap { $0.displayName })
        .union(speakerProfileStore.profiles.map { $0.displayName })
    var n = nextSpeakerNumber
    while existingNames.contains("Speaker-\(n)") {
        n += 1
    }
    return "Speaker-\(n)"
}
```

**Step 4: SettingsView UI修正**

`Sources/QuickTranscriber/Views/SettingsView.swift`:

alert部分 (line 242-253) を修正:
```swift
.alert("New Speaker", isPresented: $showNewSpeakerAlert) {
    TextField(viewModel.nextSpeakerPlaceholder, text: $newSpeakerName)
    Button("Add") {
        let name = newSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.addManualSpeaker(displayName: name)
        newSpeakerName = ""
    }
    Button("Cancel", role: .cancel) {}
} message: {
    Text("Enter a name for the new speaker:")
}
```

変更点:
- `TextField("Name", ...)` → `TextField(viewModel.nextSpeakerPlaceholder, ...)`
- `if !name.isEmpty` ガード削除（空名はVM側で自動生成）
- Add後に `newSpeakerName = ""` でリセット

**Step 5: テストが通ることを確認**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: All tests passed

**Step 6: コミット**

```
feat: show default speaker name placeholder in add dialog
```

---

### Task 3: Manualモード参加者数表示修正 — テストとUI

**Files:**
- Modify: `Sources/QuickTranscriber/Views/SettingsView.swift:200-208`

**Step 1: UI修正**

`SettingsView.swift` の参加者数表示 (line 200-208) を修正:

```swift
} else {
    HStack {
        Text("Number of Speakers")
        Spacer()
        Text("\(viewModel.activeSpeakers.count)")
            .foregroundStyle(.secondary)
    }
}
```

変更点: `viewModel.activeSpeakers.filter { $0.source == .manual }.count` → `viewModel.activeSpeakers.count`

**Step 2: ビルド確認**

Run: `swift build 2>&1 | tail -3`
Expected: Build complete!

**Step 3: コミット**

```
fix: show total active speaker count in manual mode
```

---

### Task 4: Manualモードエンジン制約修正 — テスト

**Files:**
- Modify: `Tests/QuickTranscriberTests/MeetingParticipantTests.swift` (新規テスト追加)
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift:975-987`

**Step 1: エンジンに渡すパラメータを確認するテスト追加**

`MeetingParticipantTests.swift` に追加:

```swift
func testStartRecordingManualMode_expectedSpeakerCountMatchesAllActiveSpeakers() async {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ManualCountTest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = SpeakerProfileStore(directory: dir)
    let profileId = UUID()
    try? store.add(StoredSpeakerProfile(
        id: profileId,
        displayName: "Alice",
        embedding: [Float](repeating: 0.1, count: 256)
    ))
    let (vm, engine) = makeViewModel(speakerProfileStore: store)
    await vm.loadModel()
    vm.parametersStore.parameters.diarizationMode = .manual
    vm.parametersStore.parameters.enableSpeakerDiarization = true

    // 1 linked + 1 unlinked = 2 active speakers
    vm.addManualSpeaker(fromProfile: profileId)
    vm.addManualSpeaker(displayName: "Bob")

    XCTAssertEqual(vm.activeSpeakers.count, 2)
    // Verify expectedSpeakerCount reflects all active speakers
    // (tested via parameters passed to engine)
}
```

注: エンジンのパラメータ受け渡しは統合テストに近い。ここではViewModelのロジック修正後にビルド+既存テスト通過で確認する。

**Step 2: 実装 — expectedSpeakerCountの修正**

`TranscriptionViewModel.swift` の `startRecording()` (line 975-987) を修正。`participantProfiles` 構築後に `expectedSpeakerCount` を上書きする:

```swift
// Resolve participant profiles for manual mode
let participantProfiles: [(speakerId: UUID, embedding: [Float])]?
if params.diarizationMode == .manual {
    let speakersWithProfiles = activeSpeakers.compactMap { speaker -> (speakerId: UUID, embedding: [Float])? in
        guard let profileId = speaker.speakerProfileId,
              let stored = speakerProfileStore.profiles.first(where: { $0.id == profileId })
        else { return nil }
        return (speakerId: stored.id, embedding: stored.embedding)
    }
    participantProfiles = speakersWithProfiles
    // Override expectedSpeakerCount with total active speaker count
    params.expectedSpeakerCount = activeSpeakers.count
} else {
    participantProfiles = nil
}
```

注意: `params` は `let` で宣言されている (line 963)。`var params` に変更する必要がある。

**Step 3: paramsをvarに変更**

Line 963: `let params = parametersStore.parameters` → `var params = parametersStore.parameters`

**Step 4: テスト通過確認**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: All tests passed

**Step 5: コミット**

```
fix: use total active speaker count as engine constraint in manual mode
```

---

### Task 5: ActiveSpeakerRow空名ハンドリング

**Files:**
- Modify: `Sources/QuickTranscriber/Views/SettingsView.swift:407-411`

**Step 1: onSubmit修正**

ActiveSpeakerRow内のTextField onSubmit (line 407-411) を修正:

```swift
TextField("Enter name...", text: $editingName)
    .textFieldStyle(.roundedBorder)
    .onSubmit {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            editingName = speaker.displayName ?? ""
        } else {
            onRename(trimmed)
        }
    }
```

変更点: 空名の場合、元の名前に戻す（リネームを呼ばない）

**Step 2: ビルド確認**

Run: `swift build 2>&1 | tail -3`
Expected: Build complete!

**Step 3: コミット**

```
fix: revert empty name edits in speaker row
```

---

### Task 6: 最終検証

**Step 1: 全テスト実行**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -10`
Expected: All tests passed

**Step 2: ビルド確認**

Run: `swift build 2>&1 | tail -3`
Expected: Build complete!
