# Speaker Lock Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Registered speakerにロック機能を追加し、誤削除を防止する

**Architecture:** StoredSpeakerProfileにisLockedフラグを追加。ストア層の削除メソッドでlockedプロファイルをスキップ。UIはDisclosureGroup展開内にToggle、畳んだ行に鍵アイコン表示。

**Tech Stack:** Swift, SwiftUI, Codable

---

### Task 1: StoredSpeakerProfile に isLocked フィールド追加

**Files:**
- Modify: `Sources/QuickTranscriber/Models/StoredSpeakerProfile.swift`
- Test: `Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift`

**Step 1: Write the failing test**

```swift
func testIsLockedDefaultsToFalse() {
    let profile = StoredSpeakerProfile(displayName: "Test", embedding: [1, 2, 3])
    XCTAssertFalse(profile.isLocked)
}

func testIsLockedCanBeSetToTrue() {
    var profile = StoredSpeakerProfile(displayName: "Test", embedding: [1, 2, 3])
    profile.isLocked = true
    XCTAssertTrue(profile.isLocked)
}

func testIsLockedBackwardsCompatibleDecoding() throws {
    // JSON without isLocked field (existing data)
    let json = """
    {"id":"00000000-0000-0000-0000-000000000001","displayName":"Old","embedding":[1,2,3],"lastUsed":0,"sessionCount":1,"tags":[]}
    """.data(using: .utf8)!
    let profile = try JSONDecoder().decode(StoredSpeakerProfile.self, from: json)
    XCTAssertFalse(profile.isLocked)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: FAIL — `isLocked` property not found

**Step 3: Write minimal implementation**

`StoredSpeakerProfile.swift`にフィールド追加:
```swift
public var isLocked: Bool

// init に isLocked: Bool = false パラメータ追加
// CodingKeys + custom init(from:) で既存JSONとの互換性確保
```

具体的には:
```swift
public struct StoredSpeakerProfile: Codable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public var embedding: [Float]
    public var lastUsed: Date
    public var sessionCount: Int
    public var tags: [String]
    public var isLocked: Bool

    public init(id: UUID = UUID(), displayName: String, embedding: [Float], lastUsed: Date = Date(), sessionCount: Int = 1, tags: [String] = [], isLocked: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.embedding = embedding
        self.lastUsed = lastUsed
        self.sessionCount = sessionCount
        self.tags = tags
        self.isLocked = isLocked
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, embedding, lastUsed, sessionCount, tags, isLocked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        embedding = try container.decode([Float].self, forKey: .embedding)
        lastUsed = try container.decode(Date.self, forKey: .lastUsed)
        sessionCount = try container.decode(Int.self, forKey: .sessionCount)
        tags = try container.decode([String].self, forKey: .tags)
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Models/StoredSpeakerProfile.swift Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift
git commit -m "feat: add isLocked field to StoredSpeakerProfile"
```

---

### Task 2: SpeakerProfileStore に setLocked メソッド追加

**Files:**
- Modify: `Sources/QuickTranscriber/Models/SpeakerProfileStore.swift`
- Test: `Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift`

**Step 1: Write the failing test**

```swift
func testSetLockedTrue() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = SpeakerProfileStore(directory: dir)
    let profile = StoredSpeakerProfile(displayName: "Alice", embedding: [1, 2, 3])
    store.profiles = [profile]
    try store.save()

    try store.setLocked(id: profile.id, locked: true)
    XCTAssertTrue(store.profiles[0].isLocked)

    // Verify persisted
    let store2 = SpeakerProfileStore(directory: dir)
    try store2.load()
    XCTAssertTrue(store2.profiles[0].isLocked)
}

func testSetLockedNotFoundThrows() {
    let store = SpeakerProfileStore(directory: FileManager.default.temporaryDirectory)
    XCTAssertThrowsError(try store.setLocked(id: UUID(), locked: true))
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: FAIL — `setLocked` method not found

**Step 3: Write minimal implementation**

`SpeakerProfileStore.swift`に追加:
```swift
public func setLocked(id: UUID, locked: Bool) throws {
    guard let index = profiles.firstIndex(where: { $0.id == id }) else {
        throw SpeakerProfileStoreError.profileNotFound
    }
    profiles[index].isLocked = locked
    try save()
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Models/SpeakerProfileStore.swift Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift
git commit -m "feat: add setLocked method to SpeakerProfileStore"
```

---

### Task 3: 削除メソッドで locked プロファイルをスキップ

**Files:**
- Modify: `Sources/QuickTranscriber/Models/SpeakerProfileStore.swift`
- Test: `Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift`

**Step 1: Write the failing tests**

```swift
func testDeleteSkipsLockedProfile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = SpeakerProfileStore(directory: dir)
    let profile = StoredSpeakerProfile(displayName: "Alice", embedding: [1, 2, 3], isLocked: true)
    store.profiles = [profile]
    try store.save()

    try store.delete(id: profile.id)
    XCTAssertEqual(store.profiles.count, 1)
    XCTAssertEqual(store.profiles[0].id, profile.id)
}

func testDeleteMultipleSkipsLockedProfiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = SpeakerProfileStore(directory: dir)
    let locked = StoredSpeakerProfile(displayName: "Locked", embedding: [1, 2, 3], isLocked: true)
    let unlocked = StoredSpeakerProfile(displayName: "Unlocked", embedding: [4, 5, 6])
    store.profiles = [locked, unlocked]
    try store.save()

    try store.deleteMultiple(ids: Set([locked.id, unlocked.id]))
    XCTAssertEqual(store.profiles.count, 1)
    XCTAssertEqual(store.profiles[0].id, locked.id)
}

func testDeleteAllSkipsLockedProfiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = SpeakerProfileStore(directory: dir)
    let locked = StoredSpeakerProfile(displayName: "Locked", embedding: [1, 2, 3], isLocked: true)
    let unlocked = StoredSpeakerProfile(displayName: "Unlocked", embedding: [4, 5, 6])
    store.profiles = [locked, unlocked]
    try store.save()

    store.deleteAll()
    XCTAssertEqual(store.profiles.count, 1)
    XCTAssertEqual(store.profiles[0].id, locked.id)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: FAIL — locked profiles are deleted

**Step 3: Write minimal implementation**

`SpeakerProfileStore.swift`の3メソッドを修正:

```swift
public func delete(id: UUID) throws {
    guard let index = profiles.firstIndex(where: { $0.id == id }) else {
        throw SpeakerProfileStoreError.profileNotFound
    }
    guard !profiles[index].isLocked else { return }
    profiles.remove(at: index)
    try save()
}

public func deleteMultiple(ids: Set<UUID>) throws {
    guard !ids.isEmpty else { return }
    profiles.removeAll { ids.contains($0.id) && !$0.isLocked }
    try save()
}

public func deleteAll() {
    let hadProfiles = !profiles.isEmpty
    profiles.removeAll { !$0.isLocked }
    if profiles.isEmpty {
        try? FileManager.default.removeItem(at: fileURL)
    } else if hadProfiles {
        try? save()
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Models/SpeakerProfileStore.swift Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift
git commit -m "feat: skip locked profiles in delete operations"
```

---

### Task 4: TranscriptionViewModel に setLocked 追加

**Files:**
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift`
- Test: `Tests/QuickTranscriberTests/TranscriptionViewModelTests.swift`

**Step 1: Write the failing test**

```swift
func testSetLockedUpdatesProfile() throws {
    // Setup with temp directory (follow existing test patterns)
    let profile = StoredSpeakerProfile(displayName: "Alice", embedding: [1, 2, 3])
    viewModel.speakerProfileStore.profiles = [profile]
    try viewModel.speakerProfileStore.save()
    viewModel.speakerProfiles = viewModel.speakerProfileStore.profiles

    viewModel.setLocked(id: profile.id, locked: true)
    XCTAssertTrue(viewModel.speakerProfiles.first?.isLocked == true)
}
```

Note: 既存テストのセットアップパターンに従うこと。`viewModel`のSpeakerProfileStoreが一時ディレクトリを使用していることを確認。

**Step 2: Run test to verify it fails**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: FAIL — `setLocked` method not found on ViewModel

**Step 3: Write minimal implementation**

`TranscriptionViewModel.swift`に追加:
```swift
public func setLocked(id: UUID, locked: Bool) {
    do {
        try speakerProfileStore.setLocked(id: id, locked: locked)
    } catch {
        NSLog("[QuickTranscriber] Failed to set locked state for \(id): \(error)")
    }
    speakerProfiles = speakerProfileStore.profiles
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift Tests/QuickTranscriberTests/TranscriptionViewModelTests.swift
git commit -m "feat: add setLocked to TranscriptionViewModel"
```

---

### Task 5: UI — 鍵アイコン表示と Lock Toggle

**Files:**
- Modify: `Sources/QuickTranscriber/Views/SettingsView.swift`

**Step 1: SpeakerProfileSummaryView に鍵アイコン追加**

`SpeakerProfileSummaryView`のbodyで名前の前に鍵アイコンを条件表示:
```swift
var body: some View {
    HStack(spacing: 6) {
        if profile.isLocked {
            Image(systemName: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        Text(profile.displayName)
            .lineLimit(1)
        // ... 残りは既存のまま
    }
}
```

**Step 2: SpeakerProfileDetailView に Lock Toggle 追加**

プロパティ追加:
```swift
let onSetLocked: (Bool) -> Void
```

bodyの削除ボタンの上にToggle追加:
```swift
// Lock toggle
HStack {
    Toggle("Lock", isOn: Binding(
        get: { profile.isLocked },
        set: { onSetLocked($0) }
    ))
    .font(.caption)
}
```

**Step 3: DisclosureGroupのcallsite更新**

`registeredSpeakersSection`のDisclosureGroup内:
```swift
SpeakerProfileDetailView(
    profile: profile,
    allTags: viewModel.allTags,
    onRename: { name in viewModel.renameSpeaker(id: profile.id, to: name) },
    onDelete: { viewModel.deleteSpeaker(id: profile.id) },
    onAddTag: { tag in viewModel.addTag(tag, to: profile.id) },
    onRemoveTag: { tag in viewModel.removeTag(tag, from: profile.id) },
    onSetLocked: { locked in viewModel.setLocked(id: profile.id, locked: locked) }
)
```

`SpeakerProfileDetailView.init`も`onSetLocked`パラメータ追加。

**Step 4: Build to verify**

Run: `swift build 2>&1 | tail -3`
Expected: Build complete

**Step 5: Run all tests**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: All tests pass

**Step 6: Commit**

```bash
git add Sources/QuickTranscriber/Views/SettingsView.swift
git commit -m "feat: add lock icon and toggle to speaker settings UI"
```
