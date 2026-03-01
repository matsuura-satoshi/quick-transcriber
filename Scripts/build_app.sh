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
