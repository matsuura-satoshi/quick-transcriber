# Reassignment Menu Improvement Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add "Add Speaker..." popover to the speaker reassignment menu so users can add a registered speaker and immediately reassign a segment, without navigating to Settings.

**Architecture:** The menu currently shows only active speakers (from PR 1). This PR adds a new menu item "Add Speaker..." that opens an NSPopover hosting a SwiftUI view with search, tag filter, and registered speaker list. Selecting a speaker adds them to activeSpeakers and reassigns the target segment in one action. A new `RegisteredSpeakerInfo` struct provides a lightweight view model for the popover. The same popover is used for both left-click block menus and right-click selection menus.

**Tech Stack:** SwiftUI (AddSpeakerPopover), AppKit (NSPopover + NSHostingView), XCTest

---

### Task 1: RegisteredSpeakerInfo model

**Files:**
- Create: `Sources/QuickTranscriber/Models/RegisteredSpeakerInfo.swift`
- Test: `Tests/QuickTranscriberTests/TranscriptionViewModelTests.swift`

**Step 1: Write the failing test**

```swift
func testRegisteredSpeakersForMenuExcludesActiveSpeakers() {
    let profileId = UUID()
    let store = SpeakerProfileStore(directory: tempDir)
    store.profiles = [
        StoredSpeakerProfile(id: profileId, label: "A", embedding: Array(repeating: 0.1, count: 256), displayName: "Alice", tags: ["eng"]),
        StoredSpeakerProfile(id: UUID(), label: "B", embedding: Array(repeating: 0.2, count: 256), displayName: "Bob", tags: [])
    ]
    let vm = TranscriptionViewModel(engine: MockEngine(), speakerProfileStore: store)
    vm.activeSpeakers = [
        ActiveSpeaker(speakerProfileId: profileId, sessionLabel: "A", displayName: "Alice", source: .manual)
    ]
    let menuItems = vm.registeredSpeakersForMenu
    XCTAssertEqual(menuItems.count, 2)
    XCTAssertTrue(menuItems.first { $0.profileId == profileId }!.isAlreadyActive)
    XCTAssertFalse(menuItems.first { $0.profileId != profileId }!.isAlreadyActive)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter QuickTranscriberTests.TranscriptionViewModelTests/testRegisteredSpeakersForMenuExcludesActiveSpeakers`
Expected: FAIL — `RegisteredSpeakerInfo` and `registeredSpeakersForMenu` not defined

**Step 3: Write minimal implementation**

`Sources/QuickTranscriber/Models/RegisteredSpeakerInfo.swift`:
```swift
public struct RegisteredSpeakerInfo: Identifiable, Equatable {
    public let profileId: UUID
    public let label: String
    public let displayName: String?
    public let tags: [String]
    public let isAlreadyActive: Bool

    public var id: UUID { profileId }
}
```

In `TranscriptionViewModel.swift`, add computed property:
```swift
public var registeredSpeakersForMenu: [RegisteredSpeakerInfo] {
    let activeIds = Set(activeSpeakers.compactMap { $0.speakerProfileId })
    return speakerProfileStore.profiles.map {
        RegisteredSpeakerInfo(
            profileId: $0.id,
            label: $0.label,
            displayName: $0.displayName,
            tags: $0.tags,
            isAlreadyActive: activeIds.contains($0.id)
        )
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter QuickTranscriberTests.TranscriptionViewModelTests/testRegisteredSpeakersForMenuExcludesActiveSpeakers`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Models/RegisteredSpeakerInfo.swift Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift Tests/QuickTranscriberTests/TranscriptionViewModelTests.swift
git commit -m "feat: add RegisteredSpeakerInfo and registeredSpeakersForMenu"
```

---

### Task 2: addAndReassign method

**Files:**
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift`
- Test: `Tests/QuickTranscriberTests/TranscriptionViewModelTests.swift`

**Step 1: Write the failing test**

```swift
func testAddAndReassignBlockAddsActiveSpeakerAndReassigns() {
    let profileId = UUID()
    let store = SpeakerProfileStore(directory: tempDir)
    store.profiles = [
        StoredSpeakerProfile(id: profileId, label: "X", embedding: Array(repeating: 0.1, count: 256), displayName: "Alice")
    ]
    let vm = TranscriptionViewModel(engine: MockEngine(), speakerProfileStore: store)
    vm.confirmedSegments = [
        ConfirmedSegment(text: "Hello", speaker: "A"),
        ConfirmedSegment(text: "World", speaker: "A")
    ]

    vm.addAndReassignBlock(profileId: profileId, segmentIndex: 0)

    // Should have added an active speaker
    XCTAssertEqual(vm.activeSpeakers.count, 1)
    XCTAssertEqual(vm.activeSpeakers[0].speakerProfileId, profileId)
    // Segments in the block should be reassigned to the new label
    let newLabel = vm.activeSpeakers[0].sessionLabel
    XCTAssertEqual(vm.confirmedSegments[0].speaker, newLabel)
    XCTAssertEqual(vm.confirmedSegments[1].speaker, newLabel)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter QuickTranscriberTests.TranscriptionViewModelTests/testAddAndReassignBlockAddsActiveSpeakerAndReassigns`
Expected: FAIL — `addAndReassignBlock` not defined

**Step 3: Write minimal implementation**

```swift
public func addAndReassignBlock(profileId: UUID, segmentIndex: Int) {
    addManualSpeaker(fromProfile: profileId)
    guard let speaker = activeSpeakers.last(where: { $0.speakerProfileId == profileId }) else { return }
    reassignSpeakerForBlock(segmentIndex: segmentIndex, newSpeaker: speaker.sessionLabel)
}

public func addAndReassignSelection(profileId: UUID, selectionRange: NSRange, segmentMap: SegmentCharacterMap) {
    addManualSpeaker(fromProfile: profileId)
    guard let speaker = activeSpeakers.last(where: { $0.speakerProfileId == profileId }) else { return }
    reassignSpeakerForSelection(selectionRange: selectionRange, newSpeaker: speaker.sessionLabel, segmentMap: segmentMap)
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter QuickTranscriberTests.TranscriptionViewModelTests/testAddAndReassignBlockAddsActiveSpeakerAndReassigns`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift Tests/QuickTranscriberTests/TranscriptionViewModelTests.swift
git commit -m "feat: add addAndReassignBlock/Selection methods"
```

---

### Task 3: AddSpeakerPopover SwiftUI view

**Files:**
- Create: `Sources/QuickTranscriber/Views/AddSpeakerPopover.swift`
- Test: (UI — manual verification)

**Step 1: Create the SwiftUI view**

```swift
import SwiftUI

struct AddSpeakerPopover: View {
    let speakers: [RegisteredSpeakerInfo]
    let allTags: [String]
    let onSelect: (UUID) -> Void
    let onDismiss: () -> Void

    @State private var searchText: String = ""
    @State private var selectedTags: Set<String> = []

    var filteredSpeakers: [RegisteredSpeakerInfo] {
        speakers.filter { speaker in
            if speaker.isAlreadyActive { return false }
            let matchesSearch = searchText.isEmpty
                || (speaker.displayName?.localizedCaseInsensitiveContains(searchText) ?? false)
                || speaker.label.localizedCaseInsensitiveContains(searchText)
            let matchesTags = selectedTags.isEmpty
                || !selectedTags.isDisjoint(with: speaker.tags)
            return matchesSearch && matchesTags
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            // Search field
            TextField("Search speakers...", text: $searchText)
                .textFieldStyle(.roundedBorder)

            // Tag filter
            if !allTags.isEmpty {
                tagFilter
            }

            Divider()

            // Speaker list
            if filteredSpeakers.isEmpty {
                Text("No matching speakers")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredSpeakers) { speaker in
                            speakerRow(speaker)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private var tagFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(allTags, id: \.self) { tag in
                    Button {
                        if selectedTags.contains(tag) {
                            selectedTags.remove(tag)
                        } else {
                            selectedTags.insert(tag)
                        }
                    } label: {
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(selectedTags.contains(tag) ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func speakerRow(_ speaker: RegisteredSpeakerInfo) -> some View {
        Button {
            onSelect(speaker.profileId)
            onDismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(speaker.displayName ?? speaker.label)
                        .font(.body)
                    if let displayName = speaker.displayName, displayName != speaker.label {
                        Text(speaker.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !speaker.tags.isEmpty {
                    Text(speaker.tags.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}
```

**Step 2: Build to verify compilation**

Run: `swift build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/QuickTranscriber/Views/AddSpeakerPopover.swift
git commit -m "feat: add AddSpeakerPopover SwiftUI view"
```

---

### Task 4: Wire "Add Speaker..." into InteractiveTranscriptionTextView

**Files:**
- Modify: `Sources/QuickTranscriber/Views/TranscriptionTextView.swift`

**Step 1: Add properties to InteractiveTranscriptionTextView**

Add to the class:
```swift
internal var registeredSpeakers: [RegisteredSpeakerInfo] = []
internal var allTags: [String] = []
internal var onAddAndReassignBlock: ((UUID, Int) -> Void)?
internal var onAddAndReassignSelection: ((UUID, NSRange, SegmentCharacterMap) -> Void)?
```

**Step 2: Add "Add Speaker..." to showSpeakerMenu()**

After `menu.addItem(NSMenuItem.separator())` and before "New Speaker...", add:
```swift
if !registeredSpeakers.isEmpty {
    let addItem = NSMenuItem(title: "Add Speaker...", action: #selector(addSpeakerForBlockAction(_:)), keyEquivalent: "")
    addItem.target = self
    addItem.representedObject = firstIdx
    menu.addItem(addItem)
}
```

**Step 3: Add "Add Speaker..." to right-click menu**

In `menu(for:)`, after the existing speaker items and before "New Speaker...":
```swift
if !registeredSpeakers.isEmpty {
    let addItem = NSMenuItem(title: "Add Speaker...", action: #selector(addSpeakerForSelectionAction(_:)), keyEquivalent: "")
    addItem.target = self
    speakerMenu.addItem(addItem)
}
```

**Step 4: Implement NSPopover actions**

```swift
@objc private func addSpeakerForBlockAction(_ sender: NSMenuItem) {
    guard let segmentIndex = sender.representedObject as? Int else { return }
    showAddSpeakerPopover { [weak self] profileId in
        self?.onAddAndReassignBlock?(profileId, segmentIndex)
    }
}

@objc private func addSpeakerForSelectionAction(_ sender: NSMenuItem) {
    guard let map = segmentMap else { return }
    let range = selectedRange()
    guard range.length > 0 else { return }
    showAddSpeakerPopover { [weak self] profileId in
        self?.onAddAndReassignSelection?(profileId, range, map)
    }
}

private var currentPopover: NSPopover?

private func showAddSpeakerPopover(onSelect: @escaping (UUID) -> Void) {
    currentPopover?.close()

    let popover = NSPopover()
    popover.behavior = .transient
    popover.contentSize = NSSize(width: 260, height: 300)

    let view = AddSpeakerPopover(
        speakers: registeredSpeakers,
        allTags: allTags,
        onSelect: { profileId in
            onSelect(profileId)
            popover.close()
        },
        onDismiss: {
            popover.close()
        }
    )
    popover.contentViewController = NSHostingController(rootView: view)

    let rect = NSRect(
        x: bounds.midX, y: bounds.midY,
        width: 1, height: 1
    )
    popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
    currentPopover = popover
}
```

**Step 5: Update TranscriptionTextView (NSViewRepresentable) to pass properties**

Add to the struct:
```swift
var registeredSpeakers: [RegisteredSpeakerInfo] = []
var allTags: [String] = []
var onAddAndReassignBlock: ((UUID, Int) -> Void)?
var onAddAndReassignSelection: ((UUID, NSRange, SegmentCharacterMap) -> Void)?
```

In `updateNSView`, add:
```swift
interactiveView.registeredSpeakers = registeredSpeakers
interactiveView.allTags = allTags
interactiveView.onAddAndReassignBlock = onAddAndReassignBlock
interactiveView.onAddAndReassignSelection = onAddAndReassignSelection
```

**Step 6: Build to verify compilation**

Run: `swift build`
Expected: BUILD SUCCEEDED

**Step 7: Commit**

```bash
git add Sources/QuickTranscriber/Views/TranscriptionTextView.swift
git commit -m "feat: wire Add Speaker popover into reassignment menus"
```

---

### Task 5: Connect ContentView to the new menu features

**Files:**
- Modify: `Sources/QuickTranscriber/Views/ContentView.swift`

**Step 1: Update transcriptionArea**

Add the new parameters to the TranscriptionTextView call:
```swift
registeredSpeakers: viewModel.registeredSpeakersForMenu,
allTags: viewModel.allTags,
onAddAndReassignBlock: { profileId, segmentIndex in
    viewModel.addAndReassignBlock(profileId: profileId, segmentIndex: segmentIndex)
},
onAddAndReassignSelection: { profileId, range, map in
    viewModel.addAndReassignSelection(profileId: profileId, selectionRange: range, segmentMap: map)
}
```

**Step 2: Build and run existing tests**

Run: `swift build && swift test --filter QuickTranscriberTests`
Expected: BUILD SUCCEEDED, all tests pass

**Step 3: Commit**

```bash
git add Sources/QuickTranscriber/Views/ContentView.swift
git commit -m "feat: connect Add Speaker popover through ContentView"
```

---

### Task 6: Popover positioning improvement

**Files:**
- Modify: `Sources/QuickTranscriber/Views/TranscriptionTextView.swift`

**Step 1: Store last event location for popover positioning**

The popover should appear near where the user clicked, not at the center of the text view. Store the last click/right-click location and use it as the popover anchor.

```swift
private var lastEventLocation: NSPoint = .zero

// In showSpeakerMenu: capture the event location
lastEventLocation = convert(event.locationInWindow, from: nil)

// In showAddSpeakerPopover: use lastEventLocation
let rect = NSRect(x: lastEventLocation.x, y: lastEventLocation.y, width: 1, height: 1)
```

**Step 2: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/QuickTranscriber/Views/TranscriptionTextView.swift
git commit -m "fix: position Add Speaker popover near click location"
```

---

### Task 7: Full test suite verification

**Step 1: Run all unit tests**

Run: `swift test --filter QuickTranscriberTests`
Expected: All tests pass (438+ tests)

**Step 2: Verify build succeeds**

Run: `swift build`
Expected: BUILD SUCCEEDED
