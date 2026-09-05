#!/bin/bash
# macmon Agent 安装脚本
#
# 常驻行为由客户决定 (开机自启 / 崩溃拉起 均可开关)。
#
# 用法:
#   ./install-agent.sh                             交互式安装
#   ./install-agent.sh --no-run-at-load            不开机自启
#   ./install-agent.sh --no-keep-alive             不崩溃拉起
#   ./install-agent.sh --server http://100.66.1.3:8080 --token xxxx   配置远程推送
#   ./install-agent.sh --configure                 重新生成并应用配置 (改开关/推送参数后)
#   ./install-agent.sh uninstall                   卸载
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$PROJECT_DIR/.build/release/macmon"
PLIST_DST="$HOME/Library/LaunchAgents/com.macmon.agent.plist"
LOG_DIR="$HOME/Library/Logs/macmon"
LOG_FILE="$LOG_DIR/agent.jsonl"

RUN_AT_LOAD=true
KEEP_ALIVE=true
INTERACTIVE=false
EXPLICIT=false
SERVER_URL=""
TOKEN=""

# ---- 卸载检测 (需在参数解析前) ----
for arg in "$@"; do
    if [[ "$arg" == "uninstall" ]]; then
        launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.macmon.agent.plist" 2>/dev/null || true
        rm -f "$HOME/Library/LaunchAgents/com.macmon.agent.plist"
        echo "✅ 已卸载 macmon Agent"
        exit 0
    fi
done

# ---- 解析参数 (用 while + shift, 避免 for 与 shift 错位) ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-at-load)    RUN_AT_LOAD=true;  EXPLICIT=true; shift ;;
        --no-run-at-load) RUN_AT_LOAD=false; EXPLICIT=true; shift ;;
        --keep-alive)     KEEP_ALIVE=true;   EXPLICIT=true; shift ;;
        --no-keep-alive)  KEEP_ALIVE=false;  EXPLICIT=true; shift ;;
        --interactive)    INTERACTIVE=true;  shift ;;
        --server)         SERVER_URL="${2:-}"; shift 2; EXPLICIT=true ;;
        --token)          TOKEN="${2:-}"; shift 2 ;;
        --configure)      shift ;;
        *)                shift ;;
    esac
done

# 没有显式开关参数时, 交互式询问 (仅当 stdin 是终端)
if [[ "$INTERACTIVE" == true ]] || { [[ "$EXPLICIT" == false && -t 0 ]]; }; then
    echo "macmon 常驻行为配置 (想改随时可再运行 $0 --configure)"
    read -p "是否「开机自动启动」? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" || "$ans" == "yes" ]] && RUN_AT_LOAD=true || RUN_AT_LOAD=false
    read -p "是否「崩溃后自动拉起」? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" || "$ans" == "yes" ]] && KEEP_ALIVE=true || KEEP_ALIVE=false
fi

# ---- 卸载 ----
if [[ "${1:-}" == "uninstall" ]]; then
    launchctl bootout "gui/$(id -u)" "$PLIST_DST" 2>/dev/null || true
    rm -f "$PLIST_DST"
    echo "✅ 已卸载 macmon Agent"
    exit 0
fi

echo "==> 构建 release 版本"
swift build -c release --package-path "$PROJECT_DIR"

echo "==> 生成 LaunchAgent (RunAtLoad=$RUN_AT_LOAD, KeepAlive=$KEEP_ALIVE)"
mkdir -p "$LOG_DIR"
mkdir -p "$HOME/Library/LaunchAgents"

# 组装 ProgramArguments
ARGS="<string>$BINARY</string>
  <string>--agent</string>"
if [[ -n "$SERVER_URL" ]]; then
    ARGS="$ARGS
  <string>--server</string>
  <string>$SERVER_URL</string>"
fi
if [[ -n "$TOKEN" ]]; then
    ARGS="$ARGS
  <string>--token</string>
  <string>$TOKEN</string>"
fi
ARGS="$ARGS
  <string>--out</string>
  <string>$LOG_FILE</string>"

cat > "$PLIST_DST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.macmon.agent</string>
    <key>ProgramArguments</key>
    <array>
  $ARGS
    </array>
    <key>RunAtLoad</key>
    <$RUN_AT_LOAD/>
    <key>KeepAlive</key>
    <$KEEP_ALIVE/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>
    <string>$LOG_FILE.err</string>
</dict>
</plist>
EOF

echo "==> 应用配置 (bootstrap)"
launchctl bootout "gui/$(id -u)" "$PLIST_DST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
launchctl enable "gui/$(id -u)/com.macmon.agent"

echo ""
echo "✅ macmon Agent 已安装"
echo "   二进制:     $BINARY"
echo "   日志输出:   $LOG_FILE"
echo "   开机自启:   $RUN_AT_LOAD"
echo "   崩溃拉起:   $KEEP_ALIVE"
if [[ -n "$SERVER_URL" ]]; then
    echo "   推送服务器: $SERVER_URL"
fi
echo ""
echo "   查看状态:   launchctl print gui/$(id -u)/com.macmon.agent"
echo "   修改配置:   $0 --configure"
echo "   卸载:       $0 uninstall"
echo ""
echo "   实时查看采集数据: tail -f $LOG_FILE"
