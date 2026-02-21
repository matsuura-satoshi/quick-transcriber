# PostMeetingTagSheet Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 録音停止後に表示されるシートで、セッション中の話者全員に一括タグ付与する機能を実装する

**Architecture:** TranscriptionViewModel に `showPostMeetingTagging` フラグと `bulkAddTag` メソッドを追加。ContentView で `.sheet` 修飾子を使って PostMeetingTagSheet を表示。Settings > Output にON/OFFトグル追加。

**Tech Stack:** SwiftUI, @AppStorage, @Published

---

### Task 1: bulkAddTag メソッド（ViewModel）

**Files:**
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift:434-469` (MARK: - Tags セクション)
- Test: `Tests/QuickTranscriberTests/TagTests.swift`

**Step 1: Write the failing tests**

`Tests/QuickTranscriberTests/TagTests.swift` の末尾（306行目の `}` の後）に追加:

```swift
// MARK: - PostMeetingTagSheet Tests

@MainActor
final class PostMeetingTagTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "selectedLanguage")
        UserDefaults.standard.removeObject(forKey: "isRecording")
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PostMeetingTagTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private func makeEmbedding(dominant dim: Int, dimensions: Int = 256) -> [Float] {
        var v = [Float](repeating: 0.01, count: dimensions)
        v[dim] = 1.0
        return v
    }

    private func makeViewModel() -> (TranscriptionViewModel, SpeakerProfileStore) {
        let engine = MockTranscriptionEngine()
        let store = SpeakerProfileStore(directory: tmpDir)
        let vm = TranscriptionViewModel(
            engine: engine,
            modelName: "test-model",
            speakerProfileStore: store
        )
        return (vm, store)
    }

    func testBulkAddTagAppliesTagToMultipleProfiles() {
        let (vm, store) = makeViewModel()
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: id1, label: "A", embedding: makeEmbedding(dominant: 0)),
            StoredSpeakerProfile(id: id2, label: "B", embedding: makeEmbedding(dominant: 1)),
            StoredSpeakerProfile(id: id3, label: "C", embedding: makeEmbedding(dominant: 2)),
        ]
        try? store.save()
        vm.speakerProfiles = store.profiles

        vm.bulkAddTag("standup", to: [id1, id2])

        XCTAssertEqual(vm.speakerProfiles[0].tags, ["standup"])
        XCTAssertEqual(vm.speakerProfiles[1].tags, ["standup"])
        XCTAssertEqual(vm.speakerProfiles[2].tags, [])
    }

    func testBulkAddTagEmptyTagIsNoOp() {
        let (vm, store) = makeViewModel()
        let id = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: id, label: "A", embedding: makeEmbedding(dominant: 0)),
        ]
        try? store.save()
        vm.speakerProfiles = store.profiles

        vm.bulkAddTag("", to: [id])

        XCTAssertEqual(vm.speakerProfiles[0].tags, [])
    }

    func testBulkAddTagWhitespaceOnlyIsNoOp() {
        let (vm, store) = makeViewModel()
        let id = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: id, label: "A", embedding: makeEmbedding(dominant: 0)),
        ]
        try? store.save()
        vm.speakerProfiles = store.profiles

        vm.bulkAddTag("   ", to: [id])

        XCTAssertEqual(vm.speakerProfiles[0].tags, [])
    }

    func testBulkAddTagEmptyProfileIdsIsNoOp() {
        let (vm, store) = makeViewModel()
        store.profiles = [
            StoredSpeakerProfile(label: "A", embedding: makeEmbedding(dominant: 0)),
        ]
        try? store.save()
        vm.speakerProfiles = store.profiles

        vm.bulkAddTag("standup", to: [])

        XCTAssertEqual(vm.speakerProfiles[0].tags, [])
    }

    func testBulkAddTagSkipsDuplicates() {
        let (vm, store) = makeViewModel()
        let id = UUID()
        store.profiles = [
            StoredSpeakerProfile(id: id, label: "A", embedding: makeEmbedding(dominant: 0), tags: ["standup"]),
        ]
        try? store.save()
        vm.speakerProfiles = store.profiles

        vm.bulkAddTag("standup", to: [id])

        XCTAssertEqual(vm.speakerProfiles[0].tags, ["standup"])
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter PostMeetingTagTests 2>&1 | tail -20`
Expected: FAIL — `bulkAddTag` メソッドが存在しない

**Step 3: Write minimal implementation**

`TranscriptionViewModel.swift` の `addManualSpeakers(profileIds:)` メソッドの後（469行目の `}` の後、`// MARK: - Active Speaker Management` の前）に追加:

```swift
    public func bulkAddTag(_ tag: String, to profileIds: [UUID]) {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !profileIds.isEmpty else { return }
        for id in profileIds {
            addTag(trimmed, to: id)
        }
    }
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter PostMeetingTagTests 2>&1 | tail -20`
Expected: PASS — 5 tests

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift Tests/QuickTranscriberTests/TagTests.swift
git commit -m "feat: add bulkAddTag method to TranscriptionViewModel"
```

---

### Task 2: showPostMeetingTagging フラグ + Settings トグル

**Files:**
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift:39` (@Published 宣言部)
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift:676-712` (stopRecording)
- Modify: `Sources/QuickTranscriber/Views/SettingsView.swift:474-536` (OutputSettingsTab)
- Test: `Tests/QuickTranscriberTests/TagTests.swift`

**Step 1: Write the failing test**

`PostMeetingTagTests` クラス内の末尾に追加:

```swift
    func testShowPostMeetingTaggingDefaultsFalse() {
        let (vm, _) = makeViewModel()
        XCTAssertFalse(vm.showPostMeetingTagging)
    }
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter PostMeetingTagTests/testShowPostMeetingTaggingDefaultsFalse 2>&1 | tail -10`
Expected: FAIL — プロパティが存在しない

**Step 3: Write minimal implementation**

`TranscriptionViewModel.swift` の `@Published public var activeSpeakers` (39行目) の後に追加:

```swift
    @Published public var showPostMeetingTagging: Bool = false
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter PostMeetingTagTests/testShowPostMeetingTaggingDefaultsFalse 2>&1 | tail -10`
Expected: PASS

**Step 5: Add stopRecording integration**

`stopRecording()` メソッド（676行目〜）の末尾、`self.labelDisplayNames = ...` (710行目) の後に追加:

```swift
            if UserDefaults.standard.bool(forKey: "showPostMeetingSheet") {
                self.showPostMeetingTagging = true
            }
```

注意: `@AppStorage` はViewでしか使えないため、ViewModelでは `UserDefaults.standard` を直接参照する。デフォルト値はOutputSettingsTabの `@AppStorage` で `true` に設定される（初回起動前は `false` になるが、Settings表示時に `true` が書き込まれる）。ただし、`@AppStorage` のデフォルト値書き込みの問題を回避するため、`UserDefaults.standard.register(defaults:)` を使うパターンを採用する。

`TranscriptionViewModel.init` の先頭（69行目、`let resolvedStore = ...` の前）に追加:

```swift
        UserDefaults.standard.register(defaults: ["showPostMeetingSheet": true])
```

**Step 6: Add Settings toggle**

`SettingsView.swift` の `OutputSettingsTab` (474行目〜) に追加。`@AppStorage("isRecording")` (476行目) の後に:

```swift
    @AppStorage("showPostMeetingSheet") private var showPostMeetingSheet: Bool = true
```

`Section("Transcript Output")` の閉じ括弧（514行目）の後、`Section {` (515行目) の前に新しいセクションを追加:

```swift
            Section("After Recording") {
                Toggle("Show tag sheet after stopping recording", isOn: $showPostMeetingSheet)
            }
```

**Step 7: Run all tests**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -10`
Expected: PASS

**Step 8: Commit**

```bash
git add Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift Sources/QuickTranscriber/Views/SettingsView.swift
git commit -m "feat: add showPostMeetingTagging flag with Settings toggle"
```

---

### Task 3: PostMeetingTagSheet ビュー

**Files:**
- Create: `Sources/QuickTranscriber/Views/PostMeetingTagSheet.swift`

**Step 1: Create the view**

既存の `TagFilterSheet.swift` のパターンを参考に作成。`FlowLayout` と `TagFilterPill` は `SettingsView.swift:689-755` に定義済み。

```swift
import SwiftUI

struct PostMeetingTagSheet: View {
    let activeSpeakers: [ActiveSpeaker]
    let allTags: [String]
    let onApply: (String, [UUID]) -> Void
    let onSkip: () -> Void

    @State private var tag: String = ""
    @State private var selectedSpeakerIds: Set<UUID>

    init(
        activeSpeakers: [ActiveSpeaker],
        allTags: [String],
        onApply: @escaping (String, [UUID]) -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.activeSpeakers = activeSpeakers
        self.allTags = allTags
        self.onApply = onApply
        self.onSkip = onSkip
        self._selectedSpeakerIds = State(
            initialValue: Set(activeSpeakers.compactMap { $0.speakerProfileId })
        )
    }

    private var selectedProfileIds: [UUID] {
        activeSpeakers
            .filter { selectedSpeakerIds.contains($0.id) }
            .compactMap { $0.speakerProfileId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tag Session Speakers")
                .font(.headline)

            Text("\(activeSpeakers.count) speakers in this session:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            speakerList

            Divider()

            tagInput

            if !allTags.isEmpty {
                tagSuggestions
            }

            actionButtons
        }
        .padding()
        .frame(minWidth: 380, maxWidth: 380, minHeight: 200)
    }

    private var speakerList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(activeSpeakers) { speaker in
                HStack {
                    Toggle(isOn: Binding(
                        get: { selectedSpeakerIds.contains(speaker.id) },
                        set: { isOn in
                            if isOn {
                                selectedSpeakerIds.insert(speaker.id)
                            } else {
                                selectedSpeakerIds.remove(speaker.id)
                            }
                        }
                    )) {
                        HStack(spacing: 6) {
                            Text(speaker.displayName ?? "Speaker \(speaker.sessionLabel)")
                            Text("(\(speaker.sessionLabel))")
                                .foregroundStyle(.secondary)
                            if speaker.speakerProfileId == nil {
                                Text("new")
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.blue.opacity(0.15))
                                    .foregroundStyle(.blue)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private var tagInput: some View {
        HStack {
            Text("Tag:")
            TextField("Enter tag name", text: $tag)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var tagSuggestions: some View {
        FlowLayout(spacing: 6) {
            ForEach(allTags, id: \.self) { existingTag in
                Button(existingTag) {
                    tag = existingTag
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var actionButtons: some View {
        HStack {
            Button("Apply") {
                onApply(tag, selectedProfileIds)
            }
            .disabled(tag.trimmingCharacters(in: .whitespaces).isEmpty)
            .keyboardShortcut(.defaultAction)

            Spacer()

            Button("Skip") {
                onSkip()
            }
            .keyboardShortcut(.cancelAction)
        }
    }
}
```

**Step 2: Verify it builds**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 3: Commit**

```bash
git add Sources/QuickTranscriber/Views/PostMeetingTagSheet.swift
git commit -m "feat: add PostMeetingTagSheet view component"
```

---

### Task 4: ContentView でシート表示を接続

**Files:**
- Modify: `Sources/QuickTranscriber/Views/ContentView.swift:97` (body の閉じ括弧の前)

**Step 1: Add sheet modifier**

ContentView の `body` 内、最後の `.onReceive` (92-96行目) の後、`}` (97行目) の前に追加:

```swift
        .sheet(isPresented: $viewModel.showPostMeetingTagging) {
            PostMeetingTagSheet(
                activeSpeakers: viewModel.activeSpeakers,
                allTags: viewModel.allTags,
                onApply: { tag, profileIds in
                    viewModel.bulkAddTag(tag, to: profileIds)
                    viewModel.showPostMeetingTagging = false
                },
                onSkip: {
                    viewModel.showPostMeetingTagging = false
                }
            )
        }
```

**Step 2: Verify it builds**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 3: Run all tests**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -10`
Expected: All tests pass

**Step 4: Commit**

```bash
git add Sources/QuickTranscriber/Views/ContentView.swift
git commit -m "feat: integrate PostMeetingTagSheet into ContentView"
```

---

### Task 5: 全テスト実行 + 最終検証

**Step 1: Run full test suite**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -20`
Expected: All tests pass (449 + 5 new = 454 tests)

**Step 2: Build and verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 3: Squash commits for PR**

最後にPR作成前にコミット履歴を確認し、必要に応じて整理。
