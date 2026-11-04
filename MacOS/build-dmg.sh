#!/bin/bash
# KPLBoard-MacOS 一键打包脚本
#
# 用途：签名配置好后，一条命令产出 .dmg（比手动 Archive → Organizer 快，也便于自动化）。
#
# 用法：
#   ./build-dmg.sh                       # 用 Xcode 工程里已配置的签名（CODE_SIGN_STYLE=Automatic）
#   ./build-dmg.sh -t ABCDE12345         # 指定开发团队
#   ./build-dmg.sh -n                    # 只归档导出 .app，不压 dmg（本地直接双击运行用这个）
#
# 前置：Xcode 已登录 Apple ID（Xcode → Settings… → Accounts）。
#       未签名也能本地跑：Xcode 里 ⌘R 会以 "Sign to Run Locally"（ad-hoc）运行。

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="KPLBoard-MacOS.xcodeproj"
SCHEME="KPLBoard-MacOS"
CONFIGURATION="Release"

# 版本号从 Info.plist 读取，避免改了版本却打出旧名字的 dmg
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$(cd "$(dirname "$0")" && pwd)/KPLBoard-MacOS/Info.plist" 2>/dev/null || true)"
[ -z "$VERSION" ] && VERSION="1.0.0"

TEAM_ID=""
NO_DMG=0

while getopts "t:nh" opt; do
  case "$opt" in
    t) TEAM_ID="$OPTARG" ;;
    n) NO_DMG=1 ;;
    h) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "用法: $0 [-t TEAM_ID] [-n]"; exit 1 ;;
  esac
done

OUT_DIR="$PROJECT_DIR/build"
ARCHIVE="$OUT_DIR/KPLBoard-MacOS.xcarchive"
STAGING="$OUT_DIR/dmg"
EXPORT_DIR="$OUT_DIR/export"

rm -rf "$ARCHIVE" "$STAGING" "$EXPORT_DIR"
mkdir -p "$STAGING" "$EXPORT_DIR"

ARCHIVE_ARGS=(
  -project "$PROJECT_DIR/$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "generic/platform=macOS"
  -archivePath "$ARCHIVE"
  archive
)
if [ -n "$TEAM_ID" ]; then
  ARCHIVE_ARGS+=("DEVELOPMENT_TEAM=$TEAM_ID")
fi

echo "==> 1/3 归档中…"
xcodebuild "${ARCHIVE_ARGS[@]}" | tail -5

APP="$ARCHIVE/Products/Applications/KPLBoard-MacOS.app"
if [ ! -d "$APP" ]; then
  echo "!! 未找到归档产物：$APP（检查上方签名报错）"
  exit 1
fi

echo "==> 2/3 导出 .app…"
cp -R "$APP" "$EXPORT_DIR/"
cp -R "$APP" "$STAGING/"
ln -sf /Applications "$STAGING/Applications"

echo "   .app：$EXPORT_DIR/KPLBoard-MacOS.app"

if [ "$NO_DMG" -eq 1 ]; then
  echo
  echo "✅ 完成（未压 dmg）：$EXPORT_DIR/KPLBoard-MacOS.app"
  exit 0
fi

echo "==> 3/3 压制 dmg…"
DMG="$OUT_DIR/KPLBoard-MacOS-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -volname "KPL 比分看板 ${VERSION}" \
  -srcfolder "$STAGING" \
  -ov -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null

# 校验值：便于分发后核对完整性（shasum -c 可直接校验的格式）
(cd "$OUT_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo
echo "✅ 完成：$DMG"
echo "   SHA256：$(cat "${DMG}.sha256")"
echo "   安装方式：打开 dmg，把 KPLBoard-MacOS.app 拖进 Applications。"
