#!/bin/bash
# 一键发版：构建 → DMG → EdDSA 签名 → 更新 appcast → 提交推送 → GitHub Release
#
# 前置（脚本会自己校验）：
#   1. src/Info.plist 已升版本号（CFBundleShortVersionString = 要发的版本）
#   2. CHANGELOG.md 已补本版条目
#   3. 本机钥匙串里有 "CloseApps Dev" 代码签名身份；signing/sparkle_ed25519.key
#      是 Sparkle 更新签名私钥（两者都不在仓库里，换机器要手动带过去）
#
# 用法：
#   ./tools/release.sh v1.3.0 "本次更新的一句话说明"
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?用法: ./tools/release.sh vX.Y.Z [发布说明]}"
NOTES="${2:-}"
VERSION="${TAG#v}"
APP_NAME="CloseApps.app"

# ── 0. 校验 ─────────────────────────────────────────────
PLIST_V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" src/Info.plist)
if [ "$PLIST_V" != "$VERSION" ]; then
  echo "错误: src/Info.plist 版本($PLIST_V) != ${VERSION}。先升版本号再发版。" >&2
  exit 1
fi
git diff --quiet || { echo "错误: 工作区有未提交改动，先提交。"; exit 1; }
command -v gh >/dev/null || { echo "错误: 需要 gh CLI。"; exit 1; }

# ── 1. sign_update 工具（本地有就用，没有则下载固定版本） ──
SPARKLE_VER="2.10.0"
SIGN_UPDATE=""
for c in "$(command -v sign_update || true)" \
         "/tmp/sparkle-x-$SPARKLE_VER/bin/sign_update" \
         "/tmp/sparkle-x/bin/sign_update"; do
  [ -n "$c" ] && [ -x "$c" ] && SIGN_UPDATE="$c" && break
done
if [ -z "$SIGN_UPDATE" ]; then
  echo "下载 Sparkle $SPARKLE_VER 工具包…"
  curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VER/Sparkle-$SPARKLE_VER.tar.xz" \
       -o /tmp/sparkle.tar.xz
  rm -rf "/tmp/sparkle-x-$SPARKLE_VER" && mkdir -p "/tmp/sparkle-x-$SPARKLE_VER"
  tar -xf /tmp/sparkle.tar.xz -C "/tmp/sparkle-x-$SPARKLE_VER"
  SIGN_UPDATE="/tmp/sparkle-x-$SPARKLE_VER/bin/sign_update"
fi

# ── 2. 构建 + DMG ───────────────────────────────────────
./build.sh
rm -f "$APP_NAME.dmg"
STAGE=$(mktemp -d)
cp -R "$APP_NAME" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -volname CloseApps -srcfolder "$STAGE" -ov -format UDZO "$APP_NAME.dmg" >/dev/null
rm -rf "$STAGE"

# ── 3. EdDSA 签名 + 重新生成 appcast.xml ────────────────
KEY="signing/sparkle_ed25519.key"
[ -f "$KEY" ] || { echo "错误: 找不到 ${KEY}（Sparkle 私钥）"; exit 1; }
SIG_LINE=$("$SIGN_UPDATE" -f "$KEY" "$APP_NAME.dmg")
SIG=$(echo "$SIG_LINE" | grep -o 'edSignature="[^"]*"' | cut -d'"' -f2)
LEN=$(echo "$SIG_LINE" | grep -o 'length="[0-9]*"' | grep -o '[0-9]*')
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" src/Info.plist)
DATE=$(date "+%a, %d %b %Y %H:%M:%S %z")
ENCLOSURE="https://github.com/liulao-space/close-app/releases/download/$TAG/$APP_NAME.dmg"

cat > appcast.xml <<EOF
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
<channel>
<title>CloseApps 应用关闭面板</title>
<link>https://github.com/liulao-space/close-app</link>
<description>CloseApps 更新分发</description>
<language>zh</language>
<item>
<title>Version $VERSION</title>
<pubDate>$DATE</pubDate>
<sparkle:version>$BUILD</sparkle:version>
<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>11.0</sparkle:minimumSystemVersion>
<enclosure url="$ENCLOSURE" sparkle:edSignature="$SIG" sparkle:version="$BUILD" sparkle:shortVersionString="$VERSION" length="$LEN" type="application/x-apple-diskimage"/>
<description><![CDATA[<p>${NOTES:-Version $VERSION}</p>]]></description>
</item>
</channel>
</rss>
EOF

# ── 4. 提交推送 + Release ───────────────────────────────
git add appcast.xml
git commit -m "$TAG appcast（build ${BUILD}）"
git push origin main
gh release create "$TAG" "$APP_NAME.dmg" \
  --title "CloseApps $TAG" \
  --notes "${NOTES:-Version $VERSION}"

echo ""
echo "✅ 发版完成：$TAG"
echo "   appcast → https://raw.githubusercontent.com/liulao-space/close-app/main/appcast.xml"
echo "   老用户会在面板横幅里看到新版本，点一下即可应用内升级。"
