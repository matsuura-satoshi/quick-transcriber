#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESOURCES_DIR="${PROJECT_DIR}/Resources"
SVG_FILE="${RESOURCES_DIR}/AppIcon.svg"
ICONSET_DIR="${RESOURCES_DIR}/AppIcon.iconset"
ICNS_FILE="${RESOURCES_DIR}/AppIcon.icns"

if [ ! -f "$SVG_FILE" ]; then
    echo "Error: ${SVG_FILE} not found"
    exit 1
fi

echo "==> Generating app icon from SVG..."

# 一時ディレクトリで作業
TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# SVG → 1024px PNG（qlmanageで変換）
echo "    Converting SVG to PNG..."
qlmanage -t -s 1024 -o "$TMPDIR_WORK" "$SVG_FILE" > /dev/null 2>&1
SRC_PNG="${TMPDIR_WORK}/AppIcon.svg.png"

if [ ! -f "$SRC_PNG" ]; then
    echo "Error: PNG conversion failed"
    exit 1
fi

# iconset ディレクトリ作成
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# 各サイズのPNG生成
# macOS iconset requires: 16, 32, 64, 128, 256, 512, 1024
declare -a SIZES=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)

for entry in "${SIZES[@]}"; do
    SIZE="${entry%%:*}"
    FILENAME="${entry##*:}"
    echo "    ${FILENAME} (${SIZE}x${SIZE})"
    cp "$SRC_PNG" "${ICONSET_DIR}/${FILENAME}"
    sips -z "$SIZE" "$SIZE" "${ICONSET_DIR}/${FILENAME}" > /dev/null 2>&1
done

# iconutil で .icns 生成
echo "    Converting to .icns..."
iconutil --convert icns --output "$ICNS_FILE" "$ICONSET_DIR"

# iconset ディレクトリを削除
rm -rf "$ICONSET_DIR"

echo ""
echo "==> Done! ${ICNS_FILE}"
