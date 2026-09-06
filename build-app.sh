#!/bin/bash
# 打包 macmon 菜单栏 App 为可分发 .app (ad-hoc 签名)
# 用法: ./build-app.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Macmon"
BUNDLE_ID="com.macmon.app"
VERSION="0.1.0"
ICON_PATH="$(pwd)/Resources/AppIcon.icns"

echo "==> 构建 release (含 macmonapp)"
swift build -c release

echo "==> 组装 .app bundle"
APP_DIR="dist/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

cp .build/release/macmonapp "$APP_DIR/Contents/MacOS/$APP_NAME"

if [[ -f "$ICON_PATH" ]]; then
    mkdir -p "$APP_DIR/Contents/Resources"
    cp "$ICON_PATH" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <!-- 内网服务器走 http 明文 (Tailscale), 必须豁免 ATS 否则 URLSession 拒绝连接 -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP_DIR"

echo "==> 制作 DMG (含 Applications 快捷方式 + 挂载盘图标)"
DMG_DIR="dist/dmg-staging"
DMG_PATH="dist/$APP_NAME-$VERSION.dmg"
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "$APP_DIR" "$DMG_DIR/"
ln -sf /Applications "$DMG_DIR/Applications"
# 挂载盘图标: .VolumeIcon.icns; custom icon 标志位需在挂载的卷根上设置
cp Resources/AppIcon.icns "$DMG_DIR/.VolumeIcon.icns"
rm -f "$DMG_PATH" dist/dmg-tmp.dmg
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_DIR" -ov -format UDRW dist/dmg-tmp.dmg > /dev/null
MNT=$(mktemp -d)
hdiutil attach dist/dmg-tmp.dmg -mountpoint "$MNT" -nobrowse -quiet
SetFile -a C "$MNT"
hdiutil detach "$MNT" -quiet
hdiutil convert dist/dmg-tmp.dmg -format UDZO -o "$DMG_PATH" > /dev/null
rm -rf "$DMG_DIR" dist/dmg-tmp.dmg "$MNT"

echo ""
echo "✅ 打包完成: $APP_DIR"
echo "   DMG:        $DMG_PATH"
echo "   本机运行:   open $APP_DIR"
echo "   分发给他人: 上传 DMG; 对方首次需右键->打开 (或先执行 xattr -dr com.apple.quarantine)"
