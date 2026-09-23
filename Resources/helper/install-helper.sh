#!/bin/bash
# 安装 macmonhelper: 把 root 特权 helper 注册成 LaunchDaemon
# 由 Macmon.app 通过 osascript "with administrator privileges" 以 root 调用
set -euo pipefail

LABEL="com.macmon.app.helper"
DEST="/Library/PrivilegedHelperTools/$LABEL"
PLIST_DEST="/Library/LaunchDaemons/$LABEL.plist"

# 脚本位于 Macmon.app/Contents/Resources/, 上一级即 Contents/
CONTENTS="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$CONTENTS/Library/PrivilegedHelperTools/$LABEL"
PLIST_SRC="$CONTENTS/Resources/$LABEL.plist"

if [ "$(id -u)" != "0" ]; then
    echo "需要管理员权限运行"
    exit 1
fi

for f in "$SRC" "$PLIST_SRC"; do
    if [ ! -f "$f" ]; then
        echo "缺少文件: $f"
        exit 1
    fi
done

echo "==> 安装 helper 到 $DEST"
install -d -m 755 /Library/PrivilegedHelperTools
install -m 755 -o root -g wheel "$SRC" "$DEST"
# 从 DMG 拷来的文件带 quarantine 属性, 会让 launchd 拒绝加载
xattr -c "$DEST" 2>/dev/null || true

echo "==> 写入 LaunchDaemon 配置"
install -m 644 -o root -g wheel "$PLIST_SRC" "$PLIST_DEST"
xattr -c "$PLIST_DEST" 2>/dev/null || true

echo "==> 注册并启动"
launchctl bootout system/"$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST_DEST"
launchctl enable system/"$LABEL"

echo "helper 安装完成"
