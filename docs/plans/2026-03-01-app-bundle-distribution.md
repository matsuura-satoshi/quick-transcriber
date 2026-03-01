# .app バンドル配布 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** `swift build` の出力バイナリを .app バンドルとしてパッケージし、ZIPで配布可能にする

**Architecture:** ビルドスクリプト (`Scripts/build_app.sh`) が `swift build -c release` → .app バンドル構造作成 → アドホック署名 → ZIP圧縮を一括実行。Info.plist はスクリプト内でヒアドキュメントとして生成し、バージョンは Constants.swift から grep で抽出する。

**Tech Stack:** Swift Package Manager, codesign (ad-hoc), zip, bash

---

### Task 1: ビルドスクリプト作成

**Files:**
- Create: `Scripts/build_app.sh`

**Step 1: スクリプトを作成**

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# Constants.swift からバージョン情報を抽出
MAJOR=$(grep 'static let major' Sources/QuickTranscriber/Constants.swift | grep -o '[0-9]*')
MINOR=$(grep 'static let minor' Sources/QuickTranscriber/Constants.swift | grep -o '[0-9]*')
PATCH=$(grep 'static let patch' Sources/QuickTranscriber/Constants.swift | grep -o '[0-9]*')
VERSION="${MAJOR}.${MINOR}.${PATCH}"

APP_NAME="QuickTranscriber"
BUILD_DIR="${PROJECT_DIR}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"

echo "==> Building ${APP_NAME} v${VERSION} (release)..."
swift build -c release

echo "==> Creating app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# バイナリをコピー
cp .build/arm64-apple-macosx/release/${APP_NAME} "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Info.plist を生成
cat > "${APP_BUNDLE}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Quick Transcriber</string>
    <key>CFBundleIdentifier</key>
    <string>com.quicktranscriber.app</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Quick Transcriber needs microphone access for real-time transcription.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
</dict>
</plist>
PLIST

# アドホック署名
echo "==> Signing app bundle (ad-hoc)..."
codesign -s - --force --deep "${APP_BUNDLE}"

# ZIP作成
ZIP_NAME="${APP_NAME}-v${VERSION}.zip"
echo "==> Creating ${ZIP_NAME}..."
cd "${BUILD_DIR}"
rm -f "${ZIP_NAME}"
zip -r -y "${ZIP_NAME}" "${APP_NAME}.app"

echo ""
echo "==> Done!"
echo "    App:  ${APP_BUNDLE}"
echo "    ZIP:  ${BUILD_DIR}/${ZIP_NAME}"
echo "    Version: ${VERSION}"
```

**Step 2: 実行権限を付与して動作確認**

Run: `chmod +x Scripts/build_app.sh && ./Scripts/build_app.sh`
Expected: `build/QuickTranscriber.app` と `build/QuickTranscriber-v1.0.58.zip` が生成される

**Step 3: .app が起動することを確認**

Run: `open build/QuickTranscriber.app`
Expected: アプリが起動し、タイトルバーに「Quick Transcriber v1.0.58」と表示される

**Step 4: Commit**

```bash
git add Scripts/build_app.sh
git commit -m "feat: add build script for .app bundle distribution"
```

### Task 2: .gitignore に build/ を追加

**Files:**
- Modify: `.gitignore`

**Step 1: .gitignore に追記**

`.gitignore` の末尾に追加:
```
/build
```

**Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: ignore build output directory"
```

### Task 3: CLAUDE.md にビルド手順を追記

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Build & Run セクションにアプリビルド手順を追記**

`## Build & Run` セクションの末尾に追加:

````markdown
```bash
# .app バンドルをビルド（配布用）
./Scripts/build_app.sh
# → build/QuickTranscriber.app, build/QuickTranscriber-v{version}.zip
```
````

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add app bundle build instructions"
```
