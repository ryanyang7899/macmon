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

## 鉴权说明:注册码、token 与看板密码

macmon 有三类凭证,分工不同:

| 凭证 | 属于谁 | 用途 | 存放在哪 |
|---|---|---|---|
| **共享注册码** (`SETUP_KEY`) | 服务器环境变量 | 首次接入时换取设备 token,一个服务器只有一个 | docker-compose.yml 的 `SETUP_KEY` |
| **设备 token** | 每台 Mac 一枚 | 设备推送数据时的身份凭证 (`Authorization: Bearer <token>`),丢失可轮换 | App 配置 (`~/Library/Application Support/macmon/config.json`) |
| **看板密码** (`WEB_PASSWORD`) | 管理员 | 登录网页看板 / 远程控制台 (`X-Auth-Token`),与设备 token 完全独立 | docker-compose.yml 的 `WEB_PASSWORD` |

**接入流程**:App 填 `服务器地址 + 注册码 (SETUP_KEY)` → 调 `POST /api/register` 换取本设备的 token → 之后所有推送用 token 鉴权,注册码不再需要。服务器没有配置 `SETUP_KEY` 时为开发模式(接受任意 token 自动注册),生产环境务必设置。

**逐设备注册码**(推荐多设备场景):在远程控制台的「待注册设备」里为一台设备生成专属注册码,把它填到该设备 App 的注册码栏即可——它本身就是这台设备的正式 token,无需 SETUP_KEY,且各设备独立、可单独轮换/吊销。

**注意**:设备 token 泄露时,在控制台对该设备执行「轮换」立即作废旧 token;设备被「注销/彻底删除」后,原 token 同时失效。

## 远程控制台 (网页看板 + 管理面板)

浏览器访问 `http://<你的NAS>:8080`,输入看板密码 (`WEB_PASSWORD`) 登录。

### 看板 (数据展示)

- 实时卡片:CPU / GPU / 内存 / 磁盘 / 网络 / 电池 / 温度传感器
- ECharts 历史曲线,可回看留存窗口内的数据
- 多设备切换,离线/禁用设备有状态标识

### 管理面板 (设备管理)

**待注册设备**:有未知 token 来推送时记录在此(含 IP / 首末次时间),用于审批:

- **生成注册码**:为该设备生成逐设备注册码(见上文),复制填入对方 App 即完成绑定
- **清空列表**:清理不再处理的记录

**已注册设备**,每台设备 6 个操作按钮:

| 按钮 | 作用 | 数据影响 |
|---|---|---|
| 复制 token | 复制该设备的 token,用于重装时免注册直接填回 App | 无 |
| 重命名 | 修改设备显示名,历史数据目录同步迁移 | 数据保留 |
| 轮换 | 立即作废旧 token 并生成新 token(旧 App 需更新 token 才能继续推送) | 数据保留 |
| 禁用 / 启用 | 暂停/恢复该设备的数据接收(推送返回 403) | 数据保留 |
| 注销 | 移除设备注册关系,原 token 失效 | **历史数据保留** |
| 彻底删除 | 移除设备并删除其全部历史数据 | **数据一并删除,不可恢复** |

**历史留存**:设置监控数据的保留天数(1–365 天,默认 1 天)。保存时二次确认,窗口外数据**立即删除**释放存储;后台每 10 分钟自动清理一次。

## 开发

```bash
# CLI 探针 (单次采集)
swift run macmon

# 打包 App (含 DMG: Applications 快捷方式 + 挂载盘图标)
./build-app.sh        # → dist/Macmon.app + dist/Macmon-<version>.dmg
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
