#!/usr/bin/env bash
# 生成 macOS App 图标：Assets/icon.svg → 1024px PNG → Assets/AppIcon.icns
# 依赖：rsvg-convert（brew install librsvg）、iconutil（系统自带）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/Assets/icon.svg"
PNG="$ROOT/Assets/AppIcon-1024.png"
ICONSET="$ROOT/Assets/AppIcon.iconset"
ICNS="$ROOT/Assets/AppIcon.icns"

command -v rsvg-convert >/dev/null || { echo "需要 rsvg-convert：brew install librsvg"; exit 1; }

# 1024 主图
rsvg-convert -w 1024 -h 1024 "$SVG" -o "$PNG"

# iconset 各尺寸（macOS 官方要求：16/32/128/256/512 及 @2x）
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  double=$((size * 2))
  rsvg-convert -w "$size" -h "$size" "$SVG" -o "$ICONSET/icon_${size}x${size}.png"
  rsvg-convert -w "$double" -h "$double" "$SVG" -o "$ICONSET/icon_${size}x${size}@2x.png"
done

# 合成 icns
rm -f "$ICNS"
iconutil -c icns "$ICONSET" -o "$ICNS"
rm -rf "$ICONSET"

echo "图标生成完成：${ICNS}（make bundle 会自动带入 .app）"
