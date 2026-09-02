#!/bin/bash
# 构建 CloseApps.app（应用关闭面板）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CloseApps.app"
BIN_NAME="CloseApps"

rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/Contents/MacOS"

swiftc -swift-version 5 -O -framework AppKit src/main.swift -o "$APP_NAME/Contents/MacOS/$BIN_NAME"
cp src/Info.plist "$APP_NAME/Contents/Info.plist"
mkdir -p "$APP_NAME/Contents/Resources"
if [ -f assets/AppIcon.icns ]; then
  cp assets/AppIcon.icns "$APP_NAME/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$APP_NAME" >/dev/null 2>&1 || true

echo "构建完成: $(pwd)/$APP_NAME"
