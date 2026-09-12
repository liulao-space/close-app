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

# 固定身份签名（signing/ 里的自签证书，已导入登录钥匙串）。
# 不用 ad-hoc（-）：ad-hoc 每次编译签名指纹都变，会导致系统设置里的
# 辅助功能授权失效；固定证书的签名身份稳定，重新编译后授权依然有效。
if security find-identity -v -p codesigning | grep -q '"CloseApps Dev"'; then
  codesign --force --sign "CloseApps Dev" "$APP_NAME"
else
  echo "警告: 未找到 CloseApps Dev 签名身份，退回 ad-hoc 签名（授权将无法跨构建保留）" >&2
  codesign --force --sign - "$APP_NAME"
fi
echo "构建完成: $(pwd)/$APP_NAME"
