# Tag-Based Participant Selection (PR 4)

## Purpose

会議開始前に、タグで登録済み話者を絞り込んでActive Speakersに一括追加する。
現在は単一タグ選択で即追加するだけの簡素なUI。これを複数タグ選択 + AND/OR + プレビュー + 一括追加のシートに置換する。

## UI Design

Settings → Active Speakers → "Add by Tag..." → シート表示:

```
┌─ Add Speakers by Tag ─────────────────┐
│                                        │
│  Tags:                                 │
│  [engineering✓] [marketing] [design✓]  │
│                                        │
│  Match: (●) Any selected  (○) All      │
│                                        │
│  Matching (3):                         │
│  ┌ David         12 sessions  [+Add] ┐ │
│  │ Eve            8 sessions  [+Add] │ │
│  │ Frank (added)              [    ] │ │
│  └                                   ┘ │
│                                        │
│  [Add All Matching]        [Done]      │
└────────────────────────────────────────┘
```

## Changes

### 1. `Views/TagFilterSheet.swift` (new)

SwiftUI View with:
- `selectedTags: Set<String>` — multi-tag selection using FlowLayout
- `matchMode: MatchMode` (.any / .all) — Picker toggle
- `matchingProfiles` computed property:
  - `.any`: profile has at least one selected tag
  - `.all`: profile has all selected tags
- Per-profile `[+Add]` button (disabled if already active)
- "Add All Matching" bulk button
- "Done" dismiss button

### 2. `Views/SettingsView.swift` (modify)

- Replace existing single-tag "Add by Tag" button (L294-299) with `.sheet` trigger for TagFilterSheet
- Remove `selectedTag` state (no longer needed in Active Speakers section)

### 3. `ViewModels/TranscriptionViewModel.swift` (modify)

- Add `addManualSpeakers(profileIds: [UUID])` bulk method
- Internally calls `addManualSpeaker(fromProfile:)` for each, skipping already-active profiles

### 4. Tests

- `addManualSpeakers(profileIds:)` bulk add: verifies all added, duplicates skipped
- TagFilterSheet filtering logic: AND vs OR with multiple tags
