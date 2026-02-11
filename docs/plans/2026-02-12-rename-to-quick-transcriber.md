# Rename MyTranscriber → Quick Transcriber Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** アプリ名・モジュール名・リポジトリ名を MyTranscriber から Quick Transcriber に統一的にリネームする。

**Architecture:** ディレクトリリネーム → Package.swift更新 → コード内参照の一括置換 → ドキュメント更新 → リポジトリリネーム の順で実行。既存データのマイグレーションは不要。

**Tech Stack:** Swift, SwiftUI, WhisperKit, GitHub CLI

---

### Task 1: ソースディレクトリのリネーム

**Files:**
- Rename: `Sources/MyTranscriber/` → `Sources/QuickTranscriber/`
- Rename: `Sources/MyTranscriberApp/` → `Sources/QuickTranscriberApp/`
- Rename: `Sources/MyTranscriberApp/MyTranscriberApp.swift` → `Sources/QuickTranscriberApp/QuickTranscriberApp.swift`
- Rename: `Tests/MyTranscriberTests/` → `Tests/QuickTranscriberTests/`
- Rename: `Tests/MyTranscriberTests/MyTranscriberTests.swift` → `Tests/QuickTranscriberTests/QuickTranscriberTests.swift`
- Rename: `Tests/MyTranscriberBenchmarks/` → `Tests/QuickTranscriberBenchmarks/`

**Step 1: ディレクトリとファイルをリネーム**

```bash
git mv Sources/MyTranscriber Sources/QuickTranscriber
git mv Sources/MyTranscriberApp/MyTranscriberApp.swift Sources/MyTranscriberApp/QuickTranscriberApp.swift
git mv Sources/MyTranscriberApp Sources/QuickTranscriberApp
git mv Tests/MyTranscriberTests/MyTranscriberTests.swift Tests/MyTranscriberTests/QuickTranscriberTests.swift
git mv Tests/MyTranscriberTests Tests/QuickTranscriberTests
git mv Tests/MyTranscriberBenchmarks Tests/QuickTranscriberBenchmarks
```

**Step 2: コミット**

```bash
git commit -m "rename: move directories and files from MyTranscriber to QuickTranscriber"
```

---

### Task 2: Package.swift とコード内参照の一括置換

**Files:**
- Modify: `Package.swift`
- Modify: All `.swift` files in `Sources/` and `Tests/`
- Modify: `Scripts/download_datasets.py`
- Modify: `Scripts/generate_test_audio.sh`

**Step 1: Package.swift の更新**

以下の置換をすべて実施:
- `"MyTranscriberLib"` → `"QuickTranscriberLib"`
- `"MyTranscriber"` (executable) → `"QuickTranscriber"`
- `"MyTranscriberTests"` → `"QuickTranscriberTests"`
- `"MyTranscriberBenchmarks"` → `"QuickTranscriberBenchmarks"`
- `path: "Sources/MyTranscriber"` → `path: "Sources/QuickTranscriber"`
- `path: "Sources/MyTranscriberApp"` → `path: "Sources/QuickTranscriberApp"`
- `path: "Tests/MyTranscriberTests"` → `path: "Tests/QuickTranscriberTests"`
- `path: "Tests/MyTranscriberBenchmarks"` → `path: "Tests/QuickTranscriberBenchmarks"`

**Step 2: Swift ソースコード内の置換**

全 `.swift` ファイルに対して以下の置換:
- `import MyTranscriberLib` → `import QuickTranscriberLib`
- `@testable import MyTranscriberLib` → `@testable import QuickTranscriberLib`
- `struct MyTranscriberApp` → `struct QuickTranscriberApp`
- `"About MyTranscriber"` → `"About Quick Transcriber"`
- `"MyTranscriber"` (navigationTitle) → `"Quick Transcriber"`
- `Text("MyTranscriber")` → `Text("Quick Transcriber")`
- `NSLog("[MyTranscriber]` → `NSLog("[QuickTranscriber]`
- `Notification.Name("MyTranscriber.` → `Notification.Name("QuickTranscriber.`
- `.init("MyTranscriber.` → `.init("QuickTranscriber.`
- `"MyTranscriber/Models"` → `"QuickTranscriber/Models"`
- `/tmp/mytranscriber_` → `/tmp/quicktranscriber_`
- `Documents/MyTranscriber/test-audio` → `Documents/QuickTranscriber/test-audio`
- `MyTranscriberBenchmarks` → `QuickTranscriberBenchmarks` (テストスクリプト内)

**Step 3: Python/Bash スクリプト内の置換**

- `Scripts/download_datasets.py`: `MyTranscriber` → `QuickTranscriber`
- `Scripts/generate_test_audio.sh`: `MyTranscriberBenchmarks` → `QuickTranscriberBenchmarks`

**Step 4: テストアサーション内の置換**

`Tests/QuickTranscriberTests/WhisperKitModelLoaderTests.swift`:
- `"MyTranscriber/Models"` → `"QuickTranscriber/Models"`

**Step 5: ビルド確認**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete!

**Step 6: テスト実行**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: All 80 tests passed

**Step 7: コミット**

```bash
git add -A && git commit -m "rename: update all code references from MyTranscriber to QuickTranscriber"
```

---

### Task 3: ドキュメント更新

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Step 1: CLAUDE.md の更新**

- タイトル: `# MyTranscriber` → `# Quick Transcriber`
- コマンド: `swift run MyTranscriber` → `swift run QuickTranscriber`
- テスト: `MyTranscriberTests` → `QuickTranscriberTests`, `MyTranscriberBenchmarks` → `QuickTranscriberBenchmarks`
- ターゲット: `MyTranscriberLib` → `QuickTranscriberLib`, `MyTranscriber` → `QuickTranscriber`
- データパス: `~/Documents/MyTranscriber/` → `~/Documents/QuickTranscriber/`

**Step 2: README.md の更新**

- `# MyTranscriber` → `# Quick Transcriber`
- `swift run MyTranscriber` → `swift run QuickTranscriber`

**Step 3: コミット**

```bash
git add CLAUDE.md README.md && git commit -m "docs: update documentation for Quick Transcriber rename"
```

---

### Task 4: 最終検証とPR

**Step 1: 残骸チェック**

```bash
grep -r "MyTranscriber" Sources/ Tests/ Package.swift Scripts/ CLAUDE.md README.md --include="*.swift" --include="*.py" --include="*.sh" --include="*.md" -l
```

Expected: `docs/plans/` 内の歴史的文書のみ（リネーム対象外）

**Step 2: ビルドとテスト**

```bash
swift build 2>&1 | tail -5
swift test --filter QuickTranscriberTests 2>&1 | tail -5
```

Expected: Build complete, 80 tests passed

**Step 3: PR作成・マージ**

```bash
git push -u origin feature/rename-to-quick-transcriber
gh pr create --title "Rename MyTranscriber to Quick Transcriber" --body "..."
gh pr merge <PR_NUMBER> --merge --delete-branch
git checkout main && git pull
```

---

### Task 5: リポジトリとローカルフォルダのリネーム（PR マージ後）

**Step 1: GitHubリポジトリ名の変更**

```bash
gh repo rename quick-transcriber
```

**Step 2: ローカルフォルダ名の変更**

```bash
cd ..
mv my-transcriber quick-transcriber
cd quick-transcriber
```

**Step 3: リモートURL確認**

```bash
git remote -v
```

GitHub が自動リダイレクトするため、URL更新は通常不要。ただし明示的に変更する場合:
```bash
git remote set-url origin https://github.com/matsuura-satoshi/quick-transcriber.git
```
