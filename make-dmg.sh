#!/bin/bash
# 制作 Macmon 安装包 DMG (含卷图标)
# 用法: ./make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-0.0.1}"
APP="dist/Macmon.app"
DMG="dist/Macmon-${VERSION}.dmg"
ICON="Resources/AppIcon.icns"
STAGE="/tmp/macmon-dmg-stage"

[[ -d "$APP" ]] || { echo "缺少 $APP, 先运行 ./build-app.sh"; exit 1; }

echo "==> 准备 DMG 暂存目录"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# 卷图标: .VolumeIcon.icns + 自定义图标位
cp "$ICON" "$STAGE/.VolumeIcon.icns"

echo "==> 创建临时镜像"
hdiutil create -volname "Macmon" -srcfolder "$STAGE" -ov -format UDRW /tmp/macmon-tmp.dmg >/dev/null

echo "==> 设置卷图标位"
MOUNT_POINT=$(hdiutil attach /tmp/macmon-tmp.dmg | grep -o '/Volumes/.*' | head -1)
SetFile -a C "$MOUNT_POINT"
hdiutil detach "$MOUNT_POINT" >/dev/null

echo "==> 压缩为最终 DMG"
hdiutil convert /tmp/macmon-tmp.dmg -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f /tmp/macmon-tmp.dmg

echo ""
echo "✅ DMG 已生成: $DMG"
ls -lh "$DMG" | awk '{print "   大小:", $5}'
