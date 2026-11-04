#!/bin/bash
# 打真机测试包（Debug 配置，便于实机排查；可改 CONFIG=Release）
#
# 前置条件：
#   1) Xcode → Settings(Settings/Preferences) → Accounts 里已登录 Apple ID
#      （免费账号即可，真机安装有效期 7 天；付费账号 1 年）
#   2) 设备已用数据线连接并被 Xcode 识别（首次会在 Xcode 里自动登记 UDID）
#
# 用法：./package-ipa.sh          → 产出 build/ipa/KPLBoard-iOS.ipa
set -e
cd "$(dirname "$0")"

SCHEME="KPLBoard-iOS"
CONFIG="${CONFIG:-Debug}"
# 开发团队（Apple ID 个人团队；付费团队请覆盖：TEAM=XXXXXXXXXX ./package-ipa.sh）
TEAM="${TEAM:-FLHHT427Q9}"
ROOT="$PWD"
ARCHIVE="$ROOT/build/KPLBoard-iOS.xcarchive"
EXPORT_DIR="$ROOT/build/ipa"

rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

echo "==> 1/2 归档（$CONFIG）…"
xcodebuild \
  -project "KPLBoard-iOS.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM" \
  -allowProvisioningUpdates \
  archive

echo "==> 2/2 导出 ipa…"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$ROOT/ExportOptions.plist" \
  -allowProvisioningUpdates

echo "==> 完成：$EXPORT_DIR/$(ls "$EXPORT_DIR" | grep ipa | head -1)"
echo "安装方式："
echo "  · Xcode → Devices and Simulators → 选中设备 → 点 + 选该 ipa"
echo "  · 或 把 ipa 拖到 访达/Finder 的设备列表 / Apple Configurator"
