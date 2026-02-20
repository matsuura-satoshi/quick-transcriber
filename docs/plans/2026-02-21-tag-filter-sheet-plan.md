# Tag Filter Sheet Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** タグで登録済み話者を絞り込んでActive Speakersに一括追加するTagFilterSheetを実装する

**Architecture:** SettingsView内の「Add by Tag...」ボタンからシート表示。TagFilterSheetは複数タグ選択(FlowLayout) + AND/ORトグル + マッチプレビュー + 個別/一括追加を提供。ViewModelに`addManualSpeakers(profileIds:)`一括追加メソッドを追加。

**Tech Stack:** SwiftUI, XCTest

---

### Task 1: ViewModel一括追加メソッド — テスト

**Files:**
- Test: `Tests/QuickTranscriberTests/TagTests.swift`

**Step 1: Write the failing test**

`TagTests.swift` の `TagViewModelTests` クラス末尾に追加:

```swift
func testAddManualSpeakersBulk() {
    let (vm, store) = makeViewModel()
    let id1 = UUID()
    let id2 = UUID()
    let id3 = UUID()
    store.profiles = [
        StoredSpeakerProfile(id: id1, label: "A", embedding: makeEmbedding(dominant: 0), displayName: "Alice"),
        StoredSpeakerProfile(id: id2, label: "B", embedding: makeEmbedding(dominant: 1), displayName: "Bob"),
        StoredSpeakerProfile(id: id3, label: "C", embedding: makeEmbedding(dominant: 2), displayName: "Charlie"),
    ]
    try? store.save()
    vm.speakerProfiles = store.profiles

    vm.addManualSpeakers(profileIds: [id1, id3])

    XCTAssertEqual(vm.activeSpeakers.count, 2)
    XCTAssertEqual(Set(vm.activeSpeakers.compactMap { $0.speakerProfileId }), Set([id1, id3]))
}

func testAddManualSpeakersBulkSkipsAlreadyActive() {
    let (vm, store) = makeViewModel()
    let id1 = UUID()
    let id2 = UUID()
    store.profiles = [
        StoredSpeakerProfile(id: id1, label: "A", embedding: makeEmbedding(dominant: 0), displayName: "Alice"),
        StoredSpeakerProfile(id: id2, label: "B", embedding: makeEmbedding(dominant: 1), displayName: "Bob"),
    ]
    try? store.save()
    vm.speakerProfiles = store.profiles

    vm.addManualSpeaker(fromProfile: id1)
    vm.addManualSpeakers(profileIds: [id1, id2])

    XCTAssertEqual(vm.activeSpeakers.count, 2)
}

func testAddManualSpeakersBulkEmptyArrayNoOp() {
    let (vm, _) = makeViewModel()

    vm.addManualSpeakers(profileIds: [])

    XCTAssertEqual(vm.activeSpeakers.count, 0)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter QuickTranscriberTests.TagViewModelTests/testAddManualSpeakersBulk 2>&1 | tail -5`
Expected: FAIL — `addManualSpeakers(profileIds:)` does not exist

---

### Task 2: ViewModel一括追加メソッド — 実装

**Files:**
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift:458-463`

**Step 3: Write minimal implementation**

`addManualSpeakersByTag` の直後（L463の後）に追加:

```swift
public func addManualSpeakers(profileIds: [UUID]) {
    for id in profileIds {
        addManualSpeaker(fromProfile: id)
    }
}
```

Note: `addManualSpeaker(fromProfile:)` は既にduplicateチェック済み（L469）。

**Step 4: Run tests to verify they pass**

Run: `swift test --filter QuickTranscriberTests.TagViewModelTests 2>&1 | tail -5`
Expected: All TagViewModelTests PASS

**Step 5: Commit**

```bash
git add Tests/QuickTranscriberTests/TagTests.swift Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift
git commit -m "feat: add bulk addManualSpeakers(profileIds:) method"
```

---

### Task 3: TagFilterSheet — テスト

**Files:**
- Create: `Tests/QuickTranscriberTests/TagFilterSheetTests.swift`

**Step 1: Write the failing tests**

TagFilterSheetのフィルタロジックをテスト可能にするため、フィルタ関数をstatic関数として切り出す。まずテストを書く:

```swift
import XCTest
@testable import QuickTranscriberLib

final class TagFilterSheetTests: XCTestCase {

    private let profiles: [RegisteredSpeakerInfo] = [
        RegisteredSpeakerInfo(profileId: UUID(), label: "A", displayName: "Alice", tags: ["eng", "backend"], isAlreadyActive: false),
        RegisteredSpeakerInfo(profileId: UUID(), label: "B", displayName: "Bob", tags: ["eng", "frontend"], isAlreadyActive: false),
        RegisteredSpeakerInfo(profileId: UUID(), label: "C", displayName: "Charlie", tags: ["design"], isAlreadyActive: false),
        RegisteredSpeakerInfo(profileId: UUID(), label: "D", displayName: "Dave", tags: ["eng", "backend"], isAlreadyActive: true),
    ]

    func testFilterAnyTag() {
        let result = TagFilterSheet.filterProfiles(
            profiles, selectedTags: Set(["backend"]), matchMode: .any
        )
        // Alice + Dave match "backend", but Dave is already active
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.filter { !$0.isAlreadyActive }.count, 2)
    }

    func testFilterAllTags() {
        let result = TagFilterSheet.filterProfiles(
            profiles, selectedTags: Set(["eng", "backend"]), matchMode: .all
        )
        // Alice + Dave have both "eng" AND "backend"
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map { $0.label }), Set(["A", "D"]))
    }

    func testFilterNoTagsReturnsAll() {
        let result = TagFilterSheet.filterProfiles(
            profiles, selectedTags: Set(), matchMode: .any
        )
        XCTAssertEqual(result.count, 4)
    }

    func testFilterAnyMultipleTags() {
        let result = TagFilterSheet.filterProfiles(
            profiles, selectedTags: Set(["backend", "design"]), matchMode: .any
        )
        // Alice(backend), Charlie(design), Dave(backend)
        XCTAssertEqual(result.count, 3)
    }

    func testFilterAllNoMatch() {
        let result = TagFilterSheet.filterProfiles(
            profiles, selectedTags: Set(["eng", "design"]), matchMode: .all
        )
        // Nobody has both "eng" AND "design"
        XCTAssertEqual(result.count, 0)
    }

    func testAddableProfiles() {
        let result = TagFilterSheet.filterProfiles(
            profiles, selectedTags: Set(["eng"]), matchMode: .any
        )
        let addable = result.filter { !$0.isAlreadyActive }
        // Alice + Bob are addable, Dave is already active
        XCTAssertEqual(addable.count, 2)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter QuickTranscriberTests.TagFilterSheetTests 2>&1 | tail -5`
Expected: FAIL — `TagFilterSheet` does not exist

---

### Task 4: TagFilterSheet — 実装

**Files:**
- Create: `Sources/QuickTranscriber/Views/TagFilterSheet.swift`

**Step 3: Write implementation**

```swift
import SwiftUI

enum TagMatchMode: String, CaseIterable {
    case any = "Any selected"
    case all = "All selected"
}

struct TagFilterSheet: View {
    let allTags: [String]
    let profiles: [RegisteredSpeakerInfo]
    let onAdd: (UUID) -> Void
    let onBulkAdd: ([UUID]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTags: Set<String> = []
    @State private var matchMode: TagMatchMode = .any

    static func filterProfiles(
        _ profiles: [RegisteredSpeakerInfo],
        selectedTags: Set<String>,
        matchMode: TagMatchMode
    ) -> [RegisteredSpeakerInfo] {
        guard !selectedTags.isEmpty else { return profiles }
        return profiles.filter { profile in
            switch matchMode {
            case .any:
                return !selectedTags.isDisjoint(with: profile.tags)
            case .all:
                return selectedTags.isSubset(of: Set(profile.tags))
            }
        }
    }

    private var matchingProfiles: [RegisteredSpeakerInfo] {
        Self.filterProfiles(profiles, selectedTags: selectedTags, matchMode: matchMode)
    }

    private var addableProfiles: [RegisteredSpeakerInfo] {
        matchingProfiles.filter { !$0.isAlreadyActive }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Speakers by Tag")
                .font(.headline)

            FlowLayout(spacing: 6) {
                ForEach(allTags, id: \.self) { tag in
                    TagFilterPill(label: tag, isSelected: selectedTags.contains(tag)) {
                        if selectedTags.contains(tag) {
                            selectedTags.remove(tag)
                        } else {
                            selectedTags.insert(tag)
                        }
                    }
                }
            }

            if !selectedTags.isEmpty {
                Picker("Match", selection: $matchMode) {
                    ForEach(TagMatchMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 250)
            }

            Divider()

            if matchingProfiles.isEmpty {
                Text("No matching speakers")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                Text("Matching (\(matchingProfiles.count)):")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                List {
                    ForEach(matchingProfiles) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.displayName ?? profile.label)
                                if !profile.tags.isEmpty {
                                    Text(profile.tags.joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if profile.isAlreadyActive {
                                Text("Added")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Button("+ Add") {
                                    onAdd(profile.profileId)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .frame(minHeight: 100, maxHeight: 250)
            }

            HStack {
                Button("Add All Matching") {
                    onBulkAdd(addableProfiles.map { $0.profileId })
                }
                .disabled(addableProfiles.isEmpty)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 380, minHeight: 200)
    }
}
```

Note: `FlowLayout` と `TagFilterPill` は `SettingsView.swift` で `private` 定義されている。これらを `internal` に変更するか、TagFilterSheet内で再利用可能にする必要がある。

**Step 3b: FlowLayoutとTagFilterPillのアクセス修飾子変更**

`Sources/QuickTranscriber/Views/SettingsView.swift` で:
- L678: `private struct TagFilterPill` → `struct TagFilterPill`
- L697: `private struct FlowLayout` → `struct FlowLayout`

**Step 4: Run tests to verify they pass**

Run: `swift test --filter QuickTranscriberTests.TagFilterSheetTests 2>&1 | tail -5`
Expected: All TagFilterSheetTests PASS

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Views/TagFilterSheet.swift Sources/QuickTranscriber/Views/SettingsView.swift Tests/QuickTranscriberTests/TagFilterSheetTests.swift
git commit -m "feat: add TagFilterSheet with AND/OR multi-tag filtering"
```

---

### Task 5: SettingsView統合

**Files:**
- Modify: `Sources/QuickTranscriber/Views/SettingsView.swift:140-167, 274-301`

**Step 1: Add state and sheet trigger**

`SpeakersSettingsTab` に `@State private var showTagFilter = false` を追加（L147付近）。

Active Speakersセクションのボタン行（L227-241）に「Add by Tag...」ボタンを追加:

```swift
HStack(spacing: 8) {
    Button("Add from Registered...") {
        showAddFromRegistered = true
    }
    .disabled(viewModel.speakerProfiles.isEmpty)
    Button("Add by Tag...") {
        showTagFilter = true
    }
    .disabled(viewModel.allTags.isEmpty)
    Button("New Speaker...") {
        newSpeakerName = ""
        showNewSpeakerAlert = true
    }
    // ... existing Clear All
}
```

**Step 2: Add sheet modifier**

`SpeakersSettingsTab` の `.sheet(isPresented: $showAddFromRegistered)` の後に追加:

```swift
.sheet(isPresented: $showTagFilter) {
    TagFilterSheet(
        allTags: viewModel.allTags,
        profiles: viewModel.registeredSpeakersForMenu,
        onAdd: { profileId in
            viewModel.addManualSpeaker(fromProfile: profileId)
        },
        onBulkAdd: { profileIds in
            viewModel.addManualSpeakers(profileIds: profileIds)
        }
    )
}
```

**Step 3: Registered Speakersセクションの「Add by Tag」ボタンを削除**

L294-299 の条件分岐（`if let tag = selectedTag { Button("Add by Tag") ... }`）を削除。Active Speakersセクションにボタンを移動したため不要。

**Step 4: Run full test suite**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -10`
Expected: All tests PASS

**Step 5: Build and verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 6: Commit**

```bash
git add Sources/QuickTranscriber/Views/SettingsView.swift
git commit -m "feat: integrate TagFilterSheet into Settings Active Speakers section"
```

---

### Task 6: 全体検証

**Step 1: Run full test suite**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -10`
Expected: All tests PASS (440+ tests)

**Step 2: Build and run**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 3: Final commit (if any fixups needed)**

Verify git status is clean. If not, commit fixups.
