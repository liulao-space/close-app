#!/bin/bash
# 构建 CloseApps.app（应用关闭面板）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CloseApps.app"
BIN_NAME="CloseApps"
SIGN_ID="CloseApps Dev"

rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/Contents/MacOS"

# 通用二进制（Apple Silicon + Intel）：分架构编译后用 lipo 合并，
# 任何人下载都能运行
SWIFT_FLAGS=(-swift-version 5 -O -framework AppKit)
if [ -d ThirdParty/Sparkle.framework ]; then
  SWIFT_FLAGS+=(-F ThirdParty -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
fi
swiftc "${SWIFT_FLAGS[@]}" -target arm64-apple-macos11.0 src/main.swift -o /tmp/closeapps_arm64
swiftc "${SWIFT_FLAGS[@]}" -target x86_64-apple-macos11.0 src/main.swift -o /tmp/closeapps_x64
lipo -create /tmp/closeapps_arm64 /tmp/closeapps_x64 -output "$APP_NAME/Contents/MacOS/$BIN_NAME"
rm -f /tmp/closeapps_arm64 /tmp/closeapps_x64

cp src/Info.plist "$APP_NAME/Contents/Info.plist"
mkdir -p "$APP_NAME/Contents/Resources"
if [ -f assets/AppIcon.icns ]; then
  cp assets/AppIcon.icns "$APP_NAME/Contents/Resources/AppIcon.icns"
fi

# 嵌入 Sparkle 框架（应用内自动更新）
if [ -d ThirdParty/Sparkle.framework ]; then
  mkdir -p "$APP_NAME/Contents/Frameworks"
  rm -rf "$APP_NAME/Contents/Frameworks/Sparkle.framework"
  cp -R ThirdParty/Sparkle.framework "$APP_NAME/Contents/Frameworks/"
fi

# 固定身份签名（signing/ 里的自签证书，已导入登录钥匙串）。
# 不用 ad-hoc（-）：ad-hoc 每次编译签名指纹都变，会导致系统设置里的
# 辅助功能授权失效；固定证书的签名身份稳定，重新编译后授权依然有效。
# 嵌入框架时先签框架（含内部 XPC 服务）再签最外层应用。
if ! security find-identity -v -p codesigning | grep -q "\"$SIGN_ID\""; then
  echo "警告: 未找到 $SIGN_ID 签名身份，退回 ad-hoc 签名（授权将无法跨构建保留）" >&2
  SIGN_ID="-"
fi
if [ -d "$APP_NAME/Contents/Frameworks/Sparkle.framework" ]; then
  codesign --force --deep --sign "$SIGN_ID" "$APP_NAME/Contents/Frameworks/Sparkle.framework"
fi
codesign --force --sign "$SIGN_ID" "$APP_NAME"
echo "构建完成: $(pwd)/$APP_NAME"
