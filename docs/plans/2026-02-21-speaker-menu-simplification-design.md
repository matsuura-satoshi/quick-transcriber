# Speaker Menu Simplification Design

## Date: 2026-02-21

## Problem

The current speaker reassignment menu has too many steps:
1. Click speaker label
2. Click "Add Speaker..."
3. Search, filter, and click ADD in the popover

This multi-step flow is burdensome, especially for right-click selection reassignment.
The original simple flat list was better UX, but showed too many speakers.

## Solution

Simplify the menu to show **only active speakers** in a flat list, sorted by **most recently selected**.

## Design

### 1. New State: `speakerMenuOrder`

Add to `TranscriptionViewModel`:
- `speakerMenuOrder: [String]` — ordered list of sessionLabels, most recently selected first
- `recordSpeakerSelection(_ label: String)` — moves label to front of the array

### 2. Modified `availableSpeakers`

Current: sorted alphabetically by sessionLabel (A, B, C...)

New: sorted by `speakerMenuOrder`, with unselected speakers appended in registration order.

```
availableSpeakers = orderedByMenu + unorderedRemainder
```

Where:
- `orderedByMenu`: active speakers whose label is in `speakerMenuOrder`, in that order
- `unorderedRemainder`: active speakers not in `speakerMenuOrder`, in original array order

### 3. Menu Simplification

Remove from `TranscriptionTextView`:
- "Add Speaker..." menu item and `addSpeakerForBlockAction()` / `addSpeakerForSelectionAction()`
- "New Speaker..." menu item and `newSpeakerForBlockAction()` / `newSpeakerForSelectionAction()`
- `promptForNewSpeaker()` method
- Separator line
- Properties: `registeredSpeakers`, `allTags`, `onAddAndReassignBlock`, `onAddAndReassignSelection`

Result: flat list of active speakers only.

### 4. Sort Update Trigger

Call `recordSpeakerSelection()` inside:
- `reassignSpeakerForBlock()`
- `reassignSpeakerForSelection()`

### 5. File Deletions

- `AddSpeakerPopover.swift` — no longer used from any UI

### 6. Edge Cases

- **New auto-detected speaker**: not in `speakerMenuOrder`, appears at end of menu
- **Speaker removed from active list**: skipped when building `availableSpeakers`
- **Empty `speakerMenuOrder`**: all speakers shown in registration (array) order

## Files Changed

| File | Changes |
|---|---|
| `TranscriptionViewModel.swift` | Add `speakerMenuOrder`, `recordSpeakerSelection()`, update `availableSpeakers` |
| `TranscriptionTextView.swift` | Remove Add/New Speaker items, remove unused properties/methods |
| `ContentView.swift` | Remove Add/New Speaker callback bindings |
| `AddSpeakerPopover.swift` | Delete file |
| `RegisteredSpeakerInfo.swift` | Potentially unused (check if referenced elsewhere) |
