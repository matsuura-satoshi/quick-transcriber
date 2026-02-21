# Speaker Menu Simplification Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Simplify speaker assignment menus to show only active speakers in a flat list, sorted by most recently selected.

**Architecture:** Add `speakerMenuOrder: [String]` to ViewModel for tracking selection recency. Modify `availableSpeakers` to use this order. Remove Add Speaker/New Speaker menu items, AddSpeakerPopover, and RegisteredSpeakerInfo from the menu flow.

**Tech Stack:** Swift, AppKit (NSMenu), SwiftUI

---

### Task 1: Add `speakerMenuOrder` and `recordSpeakerSelection()` to ViewModel

**Files:**
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift:251-255`
- Test: `Tests/QuickTranscriberTests/TranscriptionViewModelTests.swift`

**Step 1: Write failing tests for `recordSpeakerSelection` and new sort order**

Add to `TranscriptionViewModelTests.swift` after the existing `testAvailableSpeakersEmptyWhenNoActiveSpeakers` test (~line 735):

```swift
// MARK: - Speaker Menu Order

func testRecordSpeakerSelectionMovesLabelToFront() async {
    let (vm, _) = makeViewModel()
    vm.addManualSpeaker(displayName: "Alice")  // A
    vm.addManualSpeaker(displayName: "Bob")    // B
    vm.addManualSpeaker(displayName: "Carol")  // C

    vm.recordSpeakerSelection("C")
    XCTAssertEqual(vm.speakerMenuOrder, ["C"])

    vm.recordSpeakerSelection("A")
    XCTAssertEqual(vm.speakerMenuOrder, ["A", "C"])

    vm.recordSpeakerSelection("C")
    XCTAssertEqual(vm.speakerMenuOrder, ["C", "A"])
}

func testAvailableSpeakersSortedByMenuOrder() async {
    let (vm, _) = makeViewModel()
    vm.addManualSpeaker(displayName: "Alice")  // A
    vm.addManualSpeaker(displayName: "Bob")    // B
    vm.addManualSpeaker(displayName: "Carol")  // C

    // Default: registration order (A, B, C)
    XCTAssertEqual(vm.availableSpeakers.map(\.label), ["A", "B", "C"])

    vm.recordSpeakerSelection("C")
    // C first, then remaining in registration order (A, B)
    XCTAssertEqual(vm.availableSpeakers.map(\.label), ["C", "A", "B"])

    vm.recordSpeakerSelection("B")
    // B, C first, then remaining (A)
    XCTAssertEqual(vm.availableSpeakers.map(\.label), ["B", "C", "A"])
}

func testAvailableSpeakersIgnoresStaleMenuOrder() async {
    let (vm, _) = makeViewModel()
    vm.addManualSpeaker(displayName: "Alice")  // A
    vm.speakerMenuOrder = ["Z", "A"]  // Z doesn't exist
    XCTAssertEqual(vm.availableSpeakers.map(\.label), ["A"])
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -20`
Expected: Compilation error — `speakerMenuOrder` and `recordSpeakerSelection` not found

**Step 3: Implement `speakerMenuOrder` and update `availableSpeakers`**

In `TranscriptionViewModel.swift`, add after `@Published public var activeSpeakers` (around line 30):

```swift
public var speakerMenuOrder: [String] = []
```

Add method (after the `availableSpeakers` computed property block):

```swift
public func recordSpeakerSelection(_ label: String) {
    speakerMenuOrder.removeAll { $0 == label }
    speakerMenuOrder.insert(label, at: 0)
}
```

Replace the `availableSpeakers` computed property (lines 251-255):

```swift
public var availableSpeakers: [SpeakerMenuItem] {
    let activeLabels = Set(activeSpeakers.map { $0.sessionLabel })
    let speakersByLabel = Dictionary(
        uniqueKeysWithValues: activeSpeakers.map { ($0.sessionLabel, $0) }
    )

    // Ordered speakers: those in speakerMenuOrder first (preserving that order)
    var ordered: [SpeakerMenuItem] = []
    var seen = Set<String>()
    for label in speakerMenuOrder {
        guard activeLabels.contains(label), !seen.contains(label),
              let speaker = speakersByLabel[label] else { continue }
        ordered.append(SpeakerMenuItem(label: speaker.sessionLabel, displayName: speaker.displayName))
        seen.insert(label)
    }
    // Remaining in registration (array) order
    for speaker in activeSpeakers where !seen.contains(speaker.sessionLabel) {
        ordered.append(SpeakerMenuItem(label: speaker.sessionLabel, displayName: speaker.displayName))
    }
    return ordered
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -20`
Expected: All tests pass

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift Tests/QuickTranscriberTests/TranscriptionViewModelTests.swift
git commit -m "feat: add speakerMenuOrder for recency-based menu sorting"
```

---

### Task 2: Call `recordSpeakerSelection` from reassign methods

**Files:**
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift:330-398`
- Test: `Tests/QuickTranscriberTests/TranscriptionViewModelTests.swift`

**Step 1: Write failing tests**

```swift
func testReassignSpeakerForBlockRecordsSpeakerSelection() async {
    let (vm, _) = makeViewModel()
    vm.addManualSpeaker(displayName: "Alice")  // A
    vm.addManualSpeaker(displayName: "Bob")    // B
    vm.confirmedSegments = [
        ConfirmedSegment(text: "Hello", speaker: "A"),
        ConfirmedSegment(text: "World", speaker: "A"),
    ]
    vm.reassignSpeakerForBlock(segmentIndex: 0, newSpeaker: "B")
    XCTAssertEqual(vm.speakerMenuOrder.first, "B")
}

func testReassignSpeakerForSelectionRecordsSpeakerSelection() async {
    let (vm, _) = makeViewModel()
    vm.addManualSpeaker(displayName: "Alice")  // A
    vm.addManualSpeaker(displayName: "Bob")    // B
    vm.confirmedSegments = [
        ConfirmedSegment(text: "Hello", speaker: "A"),
    ]
    let map = SegmentCharacterMap(entries: [
        SegmentCharacterMap.Entry(segmentIndex: 0, characterRange: NSRange(location: 0, length: 5), labelRange: nil)
    ])
    vm.reassignSpeakerForSelection(selectionRange: NSRange(location: 0, length: 5), newSpeaker: "B", segmentMap: map)
    XCTAssertEqual(vm.speakerMenuOrder.first, "B")
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -20`
Expected: FAIL — `speakerMenuOrder` is empty after reassign

**Step 3: Add `recordSpeakerSelection` calls**

In `reassignSpeakerForBlock()` (line ~348, before `regenerateText()`):

```swift
recordSpeakerSelection(newSpeaker)
```

In `reassignSpeakerForSelection()` (line ~396, before `regenerateText()`):

```swift
recordSpeakerSelection(newSpeaker)
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -20`
Expected: All tests pass

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift Tests/QuickTranscriberTests/TranscriptionViewModelTests.swift
git commit -m "feat: record speaker selection on reassign for menu ordering"
```

---

### Task 3: Simplify menus in TranscriptionTextView

**Files:**
- Modify: `Sources/QuickTranscriber/Views/TranscriptionTextView.swift`

**Step 1: Simplify `showSpeakerMenu()` — remove Add/New Speaker items**

Replace lines 140-166 (`showSpeakerMenu`):

```swift
private func showSpeakerMenu(for blockIndices: [Int], at event: NSEvent) {
    guard let firstIdx = blockIndices.first else { return }
    let menu = NSMenu()

    for speaker in availableSpeakers {
        let title = Self.menuTitle(for: speaker)
        let item = NSMenuItem(title: title, action: #selector(reassignBlockAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = BlockReassignInfo(segmentIndex: firstIdx, label: speaker.label)
        menu.addItem(item)
    }

    let point = convert(event.locationInWindow, from: nil)
    lastEventLocation = point
    menu.popUp(positioning: nil, at: point, in: self)
}
```

**Step 2: Simplify `menu(for:)` — remove Add/New Speaker items**

Replace lines 114-131 (speaker menu construction in `menu(for:)`):

```swift
let speakerMenu = NSMenu()
for speaker in availableSpeakers {
    let title = Self.menuTitle(for: speaker)
    let item = NSMenuItem(title: title, action: #selector(reassignSelectionAction(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = speaker.label
    speakerMenu.addItem(item)
}
```

**Step 3: Remove unused methods and properties**

Delete these methods:
- `newSpeakerForBlockAction(_:)` (lines 190-195)
- `newSpeakerForSelectionAction(_:)` (lines 197-204)
- `promptForNewSpeaker(completion:)` (lines 206-227)
- `addSpeakerForBlockAction(_:)` (lines 229-234)
- `addSpeakerForSelectionAction(_:)` (lines 236-243)
- `showAddSpeakerPopover(onSelect:)` (lines 245-268)

Delete these properties from `InteractiveTranscriptionTextView`:
- `registeredSpeakers` (line 65)
- `allTags` (line 66)
- `onAddAndReassignBlock` (line 67)
- `onAddAndReassignSelection` (line 68)
- `currentPopover` (line 70)

Delete these properties from `TranscriptionTextView` struct:
- `registeredSpeakers` (line 280)
- `allTags` (line 281)
- `onAddAndReassignBlock` (line 284)
- `onAddAndReassignSelection` (line 285)

Remove from `updateNSView`:
- `interactiveView.registeredSpeakers = registeredSpeakers` (line 327)
- `interactiveView.allTags = allTags` (line 328)
- `interactiveView.onAddAndReassignBlock = onAddAndReassignBlock` (line 331)
- `interactiveView.onAddAndReassignSelection = onAddAndReassignSelection` (line 332)

Remove `import SwiftUI` if only used by AddSpeakerPopover (check first — it's likely used by NSViewRepresentable so keep it).

**Step 4: Run tests to verify nothing breaks**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -20`
Expected: All tests pass (may need compilation fixes in ContentView first — see Task 4)

**Step 5: Commit**

```bash
git add Sources/QuickTranscriber/Views/TranscriptionTextView.swift
git commit -m "refactor: simplify speaker menu to active speakers only"
```

---

### Task 4: Update ContentView bindings

**Files:**
- Modify: `Sources/QuickTranscriber/Views/ContentView.swift:167-197`

**Step 1: Remove Add/New Speaker bindings from transcriptionArea**

Replace lines 167-197 (`transcriptionArea`):

```swift
private var transcriptionArea: some View {
    TranscriptionTextView(
        confirmedText: viewModel.confirmedText,
        unconfirmedText: viewModel.unconfirmedText,
        fontSize: viewModel.fontSize,
        confirmedSegments: viewModel.confirmedSegments,
        language: viewModel.currentLanguage.rawValue,
        silenceThreshold: viewModel.silenceLineBreakThreshold,
        labelDisplayNames: viewModel.labelDisplayNames,
        availableSpeakers: viewModel.availableSpeakers,
        onReassignBlock: { segmentIndex, newSpeaker, displayName in
            if let displayName {
                viewModel.renameActiveSpeaker(label: newSpeaker, displayName: displayName)
            }
            viewModel.reassignSpeakerForBlock(segmentIndex: segmentIndex, newSpeaker: newSpeaker)
        },
        onReassignSelection: { range, newSpeaker, displayName, map in
            if let displayName {
                viewModel.renameActiveSpeaker(label: newSpeaker, displayName: displayName)
            }
            viewModel.reassignSpeakerForSelection(selectionRange: range, newSpeaker: newSpeaker, segmentMap: map)
        }
    )
    .frame(maxHeight: .infinity)
}
```

Note: `onReassignBlock` and `onReassignSelection` still accept `displayName` parameter but it will always be `nil` from the simplified menu. The callbacks remain compatible — the `displayName` handling is harmless and will simply never trigger.

**Step 2: Build to verify**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/QuickTranscriber/Views/ContentView.swift
git commit -m "refactor: remove Add/New Speaker bindings from ContentView"
```

---

### Task 5: Clean up unused callback signatures

**Files:**
- Modify: `Sources/QuickTranscriber/Views/TranscriptionTextView.swift`
- Modify: `Sources/QuickTranscriber/Views/ContentView.swift`

Since the `displayName` parameter in `onReassignBlock` and `onReassignSelection` is now always nil (no more New Speaker dialog), simplify the signatures.

**Step 1: Simplify callback signatures**

In `InteractiveTranscriptionTextView`, change:
```swift
internal var onReassignBlock: ((Int, String, String?) -> Void)?
internal var onReassignSelection: ((NSRange, String, String?, SegmentCharacterMap) -> Void)?
```
to:
```swift
internal var onReassignBlock: ((Int, String) -> Void)?
internal var onReassignSelection: ((NSRange, String, SegmentCharacterMap) -> Void)?
```

In `TranscriptionTextView` struct, change:
```swift
var onReassignBlock: ((Int, String, String?) -> Void)?
var onReassignSelection: ((NSRange, String, String?, SegmentCharacterMap) -> Void)?
```
to:
```swift
var onReassignBlock: ((Int, String) -> Void)?
var onReassignSelection: ((NSRange, String, SegmentCharacterMap) -> Void)?
```

Update `reassignBlockAction`:
```swift
onReassignBlock?(segmentIndex, label)
```

Update `reassignSelectionAction`:
```swift
onReassignSelection?(range, label, map)
```

Update ContentView:
```swift
onReassignBlock: { segmentIndex, newSpeaker in
    viewModel.reassignSpeakerForBlock(segmentIndex: segmentIndex, newSpeaker: newSpeaker)
},
onReassignSelection: { range, newSpeaker, map in
    viewModel.reassignSpeakerForSelection(selectionRange: range, newSpeaker: newSpeaker, segmentMap: map)
}
```

**Step 2: Build and test**

Run: `swift build 2>&1 | tail -10 && swift test --filter QuickTranscriberTests 2>&1 | tail -20`
Expected: Build and all tests pass

**Step 3: Commit**

```bash
git add Sources/QuickTranscriber/Views/TranscriptionTextView.swift Sources/QuickTranscriber/Views/ContentView.swift
git commit -m "refactor: simplify reassign callback signatures (remove unused displayName)"
```

---

### Task 6: Delete unused files and clean up ViewModel

**Files:**
- Delete: `Sources/QuickTranscriber/Views/AddSpeakerPopover.swift`
- Delete: `Sources/QuickTranscriber/Models/RegisteredSpeakerInfo.swift`
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift`
- Modify: `Tests/QuickTranscriberTests/TranscriptionViewModelTests.swift`

**Step 1: Delete files**

```bash
rm Sources/QuickTranscriber/Views/AddSpeakerPopover.swift
rm Sources/QuickTranscriber/Models/RegisteredSpeakerInfo.swift
```

**Step 2: Remove `registeredSpeakersForMenu` from ViewModel**

Delete the `registeredSpeakersForMenu` computed property (lines 262-273 of TranscriptionViewModel.swift).

**Step 3: Remove or update tests**

- Delete `testRegisteredSpeakersForMenuExcludesActiveSpeakers` test
- Update `testAvailableSpeakersFromActiveSpeakers` to verify registration order (not alphabetical)

Updated test:
```swift
func testAvailableSpeakersFromActiveSpeakers() async {
    let (vm, _) = makeViewModel()
    vm.addManualSpeaker(displayName: "Alice")  // A
    vm.addManualSpeaker(displayName: "Bob")    // B

    let speakers = vm.availableSpeakers
    XCTAssertEqual(speakers.count, 2)
    // Registration order (not alphabetical)
    XCTAssertEqual(speakers[0].label, "A")
    XCTAssertEqual(speakers[0].displayName, "Alice")
    XCTAssertEqual(speakers[1].label, "B")
    XCTAssertEqual(speakers[1].displayName, "Bob")
}
```

Note: `addAndReassignBlock`, `addAndReassignSelection`, `addManualSpeaker` methods stay in ViewModel — they may still be useful for Settings UI bulk operations. Only remove the menu-specific integration.

**Step 4: Build and test**

Run: `swift build 2>&1 | tail -10 && swift test --filter QuickTranscriberTests 2>&1 | tail -20`
Expected: Build and all tests pass

**Step 5: Commit**

```bash
git add -A
git commit -m "refactor: delete AddSpeakerPopover, RegisteredSpeakerInfo, and registeredSpeakersForMenu"
```

---

### Task 7: Final verification

**Step 1: Full test suite**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -20`
Expected: All tests pass

**Step 2: Build and run**

Run: `swift build 2>&1 | tail -10`
Expected: Clean build

**Step 3: Manual smoke test**

Run app, verify:
1. Click speaker label → flat menu of active speakers only (no Add/New Speaker)
2. Select text + right-click → Assign Speaker submenu shows same flat list
3. After selecting a speaker, that speaker appears first in next menu open
4. Menu order persists across multiple reassignments
