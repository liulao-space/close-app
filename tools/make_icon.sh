#!/bin/bash
# 生成应用图标：绘制 1024 底图 -> sips 缩放出全套尺寸 -> iconutil 打包 .icns
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p assets
swift tools/make_icon.swift assets/icon_1024.png

DIR="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$DIR"

for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon_1024.png --out "$DIR/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d assets/icon_1024.png --out "$DIR/icon_${s}x${s}@2x.png" >/dev/null
done

iconutil -c icns "$DIR" -o assets/AppIcon.icns
echo "已生成 assets/AppIcon.icns"
