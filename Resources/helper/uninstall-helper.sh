#!/bin/bash
# 卸载 macmonhelper: 先把风扇交还系统控制, 再删除 LaunchDaemon 与二进制
# 由 Macmon.app 通过 osascript "with administrator privileges" 以 root 调用
set -uo pipefail

LABEL="com.macmon.app.helper"
DEST="/Library/PrivilegedHelperTools/$LABEL"
PLIST_DEST="/Library/LaunchDaemons/$LABEL.plist"

if [ "$(id -u)" != "0" ]; then
    echo "需要管理员权限运行"
    exit 1
fi

# 关键: 卸载前必须让风扇回到系统自动控制, 否则转速会被锁死在最后一次设定值
if [ -x "$DEST" ]; then
    echo "==> 交还风扇控制权"
    "$DEST" --reset || echo "复位失败 (风扇可能已由系统接管)"
fi

echo "==> 停止并移除 daemon"
launchctl bootout system/"$LABEL" 2>/dev/null || true
rm -f "$PLIST_DEST" "$DEST"
rm -f /var/run/com.macmon.app.forced

echo "helper 已卸载"
