# Settings UI Restructure Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Registered Speakersセクションを100名規模で快適に操作できるよう、LazyVStack + DisclosureGroupに最適化する。

**Architecture:** `Form > Section > ForEach`の`SpeakerProfileRow`を`ScrollView > LazyVStack > DisclosureGroup`に置き換え。行を折りたたみ時の`SpeakerProfileSummaryView`(名前+タグ)と展開時の`SpeakerProfileDetailView`(編集UI)に分割。displayName設定済みプロファイルではlabel非表示。

**Tech Stack:** SwiftUI (macOS 15+), DisclosureGroup, LazyVStack

---

### Task 1: displayName表示ロジックのテスト追加

**Files:**
- Modify: `Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift`

**Step 1: displayNameFallback表示ロジックのテストを書く**

`StoredSpeakerProfile`に`displayLabel`計算プロパティを追加するためのテスト。

```swift
// SpeakerProfileStoreTests.swift に追加
func testDisplayLabelWithDisplayName() {
    let profile = StoredSpeakerProfile(
        id: UUID(), label: "A", embedding: [0.1],
        lastUsed: Date(), sessionCount: 3,
        displayName: "Alice", tags: []
    )
    XCTAssertEqual(profile.displayLabel, "Alice")
}

func testDisplayLabelWithoutDisplayName() {
    let profile = StoredSpeakerProfile(
        id: UUID(), label: "A", embedding: [0.1],
        lastUsed: Date(), sessionCount: 3,
        displayName: nil, tags: []
    )
    XCTAssertEqual(profile.displayLabel, "Speaker A")
}

func testDisplayLabelWithEmptyDisplayName() {
    let profile = StoredSpeakerProfile(
        id: UUID(), label: "B", embedding: [0.1],
        lastUsed: Date(), sessionCount: 1,
        displayName: "", tags: []
    )
    XCTAssertEqual(profile.displayLabel, "Speaker B")
}
```

**Step 2: テストが失敗することを確認**

Run: `swift test --filter QuickTranscriberTests.SpeakerProfileStoreTests/testDisplayLabel 2>&1 | tail -5`
Expected: FAIL — `displayLabel`プロパティが存在しない

**Step 3: displayLabel計算プロパティを実装**

```swift
// Sources/QuickTranscriberLib/Models/StoredSpeakerProfile.swift に追加
public var displayLabel: String {
    if let name = displayName, !name.isEmpty {
        return name
    }
    return "Speaker \(label)"
}
```

**Step 4: テストがパスすることを確認**

Run: `swift test --filter QuickTranscriberTests.SpeakerProfileStoreTests/testDisplayLabel 2>&1 | tail -5`
Expected: PASS

**Step 5: コミット**

```bash
git add Sources/QuickTranscriberLib/Models/StoredSpeakerProfile.swift Tests/QuickTranscriberTests/SpeakerProfileStoreTests.swift
git commit -m "feat: add displayLabel computed property to StoredSpeakerProfile"
```

---

### Task 2: SpeakerProfileRowをDisclosureGroup + Summary/Detailに分割

**Files:**
- Modify: `Sources/QuickTranscriber/Views/SettingsView.swift` (lines 544-666: `SpeakerProfileRow`)

**Step 1: SpeakerProfileRowをSpeakerProfileSummaryView + SpeakerProfileDetailViewに置き換え**

`SpeakerProfileRow`(L544-666)を削除し、以下の2つのビューに置き換える。

**SpeakerProfileSummaryView** (折りたたみラベル):
```swift
private struct SpeakerProfileSummaryView: View {
    let profile: StoredSpeakerProfile

    var body: some View {
        HStack(spacing: 6) {
            Text(profile.displayLabel)
                .lineLimit(1)
            ForEach(profile.tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}
```

**SpeakerProfileDetailView** (展開コンテンツ):
```swift
private struct SpeakerProfileDetailView: View {
    let profile: StoredSpeakerProfile
    let allTags: [String]
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onAddTag: (String) -> Void
    let onRemoveTag: (String) -> Void

    @State private var editingName: String
    @State private var showTagPopover = false
    @State private var newTagText = ""

    init(profile: StoredSpeakerProfile, allTags: [String],
         onRename: @escaping (String) -> Void,
         onDelete: @escaping () -> Void,
         onAddTag: @escaping (String) -> Void,
         onRemoveTag: @escaping (String) -> Void) {
        self.profile = profile
        self.allTags = allTags
        self.onRename = onRename
        self.onDelete = onDelete
        self.onAddTag = onAddTag
        self.onRemoveTag = onRemoveTag
        self._editingName = State(initialValue: profile.displayName ?? "")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private var suggestedTags: [String] {
        allTags.filter { !profile.tags.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Name editing
            HStack {
                Text("Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Enter name...", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onRename(editingName) }
            }

            // Session info
            HStack(spacing: 4) {
                Text("\(profile.sessionCount) sessions")
                Text("\u{00B7}")
                Text("Last: \(Self.dateFormatter.string(from: profile.lastUsed))")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            // Tag editing
            HStack(spacing: 4) {
                Text("Tags")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(profile.tags, id: \.self) { tag in
                    TagPill(tag: tag) { onRemoveTag(tag) }
                }
                Button {
                    newTagText = ""
                    showTagPopover = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showTagPopover) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("New tag...", text: $newTagText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                            .onSubmit {
                                let trimmed = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    onAddTag(trimmed)
                                    showTagPopover = false
                                }
                            }
                        if !suggestedTags.isEmpty {
                            Text("Existing tags:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            FlowLayout(spacing: 4) {
                                ForEach(suggestedTags, id: \.self) { tag in
                                    Button(tag) {
                                        onAddTag(tag)
                                        showTagPopover = false
                                    }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
            }

            // Delete button
            HStack {
                Spacer()
                Button("Delete Profile", role: .destructive) {
                    onDelete()
                }
                .font(.caption)
            }
        }
        .padding(.leading, 4)
    }
}
```

**Step 2: ビルド確認**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 3: コミット**

```bash
git add Sources/QuickTranscriber/Views/SettingsView.swift
git commit -m "refactor: split SpeakerProfileRow into Summary and Detail views with DisclosureGroup"
```

---

### Task 3: registeredSpeakersSectionをScrollView + LazyVStackに変更

**Files:**
- Modify: `Sources/QuickTranscriber/Views/SettingsView.swift` (lines 291-348: `registeredSpeakersSection`)

**Step 1: ForEachをScrollView + LazyVStack + DisclosureGroupに置き換え**

`registeredSpeakersSection`内の`ForEach(filteredProfiles...)`ブロック(L315-333)を以下に置き換える:

```swift
private var registeredSpeakersSection: some View {
    Section("Registered Speakers (\(viewModel.speakerProfiles.count))") {
        if viewModel.speakerProfiles.isEmpty {
            Text("No speakers registered yet.")
                .foregroundStyle(.secondary)
        } else {
            TextField("Search speakers...", text: $searchText)
                .textFieldStyle(.roundedBorder)

            if !viewModel.allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        TagFilterPill(label: "All", isSelected: selectedTag == nil) {
                            selectedTag = nil
                        }
                        ForEach(viewModel.allTags, id: \.self) { tag in
                            TagFilterPill(label: tag, isSelected: selectedTag == tag) {
                                selectedTag = selectedTag == tag ? nil : tag
                            }
                        }
                    }
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredProfiles, id: \.id) { profile in
                        DisclosureGroup {
                            SpeakerProfileDetailView(
                                profile: profile,
                                allTags: viewModel.allTags,
                                onRename: { name in viewModel.renameSpeaker(id: profile.id, to: name) },
                                onDelete: { viewModel.deleteSpeaker(id: profile.id) },
                                onAddTag: { tag in viewModel.addTag(tag, to: profile.id) },
                                onRemoveTag: { tag in viewModel.removeTag(tag, from: profile.id) }
                            )
                        } label: {
                            SpeakerProfileSummaryView(profile: profile)
                        }
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 350)

            Button("Delete All Profiles", role: .destructive) {
                showDeleteAllConfirmation = true
            }
            .confirmationDialog(
                "Delete all speaker profiles?",
                isPresented: $showDeleteAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    viewModel.deleteAllSpeakers()
                }
            }
        }
    }
}
```

**Step 2: 古いSpeakerProfileRowの参照・定義がないことを確認**

`SpeakerProfileRow`がファイル内に残っていないことを確認。

**Step 3: ビルド確認**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 4: コミット**

```bash
git add Sources/QuickTranscriber/Views/SettingsView.swift
git commit -m "feat: optimize registered speakers with LazyVStack + DisclosureGroup"
```

---

### Task 4: 全テスト実行と最終検証

**Step 1: 全ユニットテスト実行**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -20`
Expected: All tests passed

**Step 2: ビルド確認**

Run: `swift build 2>&1 | tail -3`
Expected: Build succeeded

**Step 3: 最終コミット（必要な場合のみ）**

テスト修正が必要だった場合のみ追加コミット。
