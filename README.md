# macmon

macOS 系统监控与远程看板。在任何 M 芯片 Mac (macOS 13+) 上安装本 App,即可把 CPU / GPU / 内存 / 磁盘 / 网络 / 电池 / 117 个温度传感器等状态实时采集并推送到你自己的 NAS 服务器,通过网页远程查看。

```
┌─ macOS App (菜单栏 + 主窗口) ──┐      ┌─ NAS (Docker) ─────────────┐
│  采集: IOAccelerator / SMC /    │ 推送 │  macmon-server (Go)          │
│        mach / getifaddrs        │────►│   ├ 接收 + 存储 (SQLite/文件) │
│  推送: HTTP + token + 离线补传   │      │   ├ 鉴权 (token + 看板密码)   │
│  更新: GitHub release 自动检测   │      │   └ 网页看板 (ECharts)        │
└────────────────────────────────┘      └──────────────────────────────┘
```

## 功能

- **全量采集**:CPU 每核占用 / GPU 占用·温度 / 内存完整 vm 统计 / 磁盘 IO / 网络速率·WiFi / 电池健康·功耗 / 全部温度传感器
- **远程看板**:网页实时显示 + 历史曲线,任何虚拟局域网内设备浏览器可访问
- **多设备**:每台 Mac 装 App,填服务器地址 + 注册码即可接入
- **断线补传**:离线期间的采集数据自动缓存,恢复后补发
- **自动更新**:启动时检查 GitHub release,有新版本提示下载
- **开机自启**:内置开关 (SMAppService)

## 安装 (Mac)

1. 下载 [Releases](../../releases/latest) 里的 `Macmon-<version>.dmg`
2. 打开 DMG,把 **Macmon.app** 拖进「应用程序」
3. 首次打开:右键 →「打开」(未公证的个人签名)
4. 打开 App → 填:
   - 服务器地址:`http://<你的NAS>:8080`
   - 设备名称:可选
   - 注册码:服务器 `SETUP_KEY`

## 部署服务器 (NAS / 任意 Linux)

```bash
cd server
cp docker-compose.yml.example docker-compose.yml   # 填入真实 token/密码/注册码
docker compose up -d --build
```

## 开发

```bash
# CLI 探针 (单次采集)
swift run macmon

# 打包 App
./build-app.sh        # → dist/Macmon.app
./make-dmg.sh         # → dist/Macmon-<version>.dmg
```

## 目录结构

```
Sources/MacmonCore/   # 采集/推送核心库 (CLI 与 App 共用)
Sources/macmon/       # CLI 工具
Sources/macmonapp/    # 菜单栏 + 主窗口 App
server/               # Go 服务器 + 看板 (Docker)
```

## 许可证

[MIT](LICENSE)
