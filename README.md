# macmon

macOS 系统监控与远程看板。在任何 M 芯片 Mac (macOS 13+) 上安装本 App,即可把 CPU / GPU / 内存 / 磁盘 / 网络 / 电池 / 117 个温度传感器等状态实时采集并推送到你自己的 NAS 服务器,通过网页远程查看。

```
┌─ macOS App (菜单栏 + 主窗口) ──┐      ┌─ NAS (Docker) ─────────────┐
│  采集: IOAccelerator / SMC /    │ 推送 │  macmon-server (Go)          │
│        mach / getifaddrs        │────►│   ├ 接收 + 存储 (文件)        │
│  推送: HTTP + token + 离线补传   │      │   ├ 鉴权 (token + 看板密码)   │
│  更新: GitHub release 自动检测   │      │   └ 网页看板 (ECharts)        │
└────────────────────────────────┘      └──────────────────────────────┘
```

## 它是什么 / 适合谁用

- 你家里/工作室有多台 Mac(比如一台 MacBook + 一台 Mac mini),想在一台机器的浏览器或菜单栏上看到**所有机器**的运行状态。
- 数据全部存在**你自己的服务器**上,不经过任何第三方云服务。
- 由两部分组成:
  - **Macmon.app**(装在每台要被监控的 Mac 上):负责采集 + 推送,常驻菜单栏
  - **macmon-server**(部署在 NAS 或任意 Linux 机器上):负责接收、存储、提供网页看板

## 功能

- **全量采集**:CPU 每核占用 / GPU 占用·温度 / 内存完整 vm 统计 / 磁盘 IO / 网络速率·WiFi / 电池健康·功耗 / 全部温度传感器
- **远程看板**:网页实时显示 + 历史曲线,任何虚拟局域网内设备浏览器可访问
- **菜单栏图表**:App 菜单栏弹窗以「图表 + 数据」实时展示本机或被监控设备状态,显示哪些条目、什么顺序均可自定义
- **多设备**:每台 Mac 装 App,填服务器地址 + 注册码即可接入
- **断线补传**:离线期间的采集数据自动缓存,恢复后补发
- **自动更新**:启动时检查 GitHub release,有新版本提示下载
- **开机自启**:内置开关 (SMAppService)

---

## 快速开始 (三步走)

```
① 部署服务器 (NAS/Linux, 一次性)  →  ② Mac 安装 App 接入  →  ③ 浏览器/菜单栏查看
```

---

## 第 ① 步:部署服务器 (NAS / 任意 Linux)

> **前置条件**:NAS 或 Linux 机器上已安装 **Docker** 和 **Docker Compose**
> (群晖:套件中心安装 Container Manager;威联通:Container Station;Ubuntu:`sudo apt install docker.io docker-compose-v2`)

### 1. 把代码弄到服务器上

最简单的方式是在 NAS 上直接下载(无需 git):

```bash
# SSH 登录你的 NAS / Linux 后:
wget https://github.com/ryanyang7899/macmon/archive/refs/heads/main.zip
unzip main.zip && cd macmon-main/server
```

也可以 `git clone https://github.com/ryanyang7899/macmon.git` 后 `cd macmon/server`。

### 2. 复制配置模板并填入你自己的密钥

```bash
cp docker-compose.yml.example docker-compose.yml
```

> **为什么先复制?** Docker Compose 只读取名为 `docker-compose.yml` 的文件;
> 而 `.example` 模板里的值都是占位符,且真实的 `docker-compose.yml` 含密码、
> 已被 `.gitignore` 排除,永远不会提交到 GitHub 泄露。

然后用任意编辑器(如 `vi docker-compose.yml`)把三个 `change-me-...` 改成你自己的:

```yaml
services:
  macmon-server:
    build: .
    container_name: macmon-server
    restart: always                    # 开机自启 / 崩溃自动重启
    ports:
      - "8080:8080"                    # 冒号左边是宿主机端口, 被占用可改成别的, 如 "9090:8080"
    environment:
      - DATA_DIR=/data
      - RETENTION_DAYS=7               # 历史数据保留天数 (之后可在网页管理面板修改)
      - MACMON_DEVICES=my-mac=change-me-token   # 预配设备 (可选, 见下方说明)
      - WEB_PASSWORD=change-me-password         # ← 必改: 网页看板/管理面板登录密码
      - SETUP_KEY=change-me-setup-key           # ← 必改: 新设备注册码 (App 接入用)
    volumes:
      - macmon-data:/data              # 所有监控数据存在这个 Docker 卷里, 重建容器不丢数据
```

| 变量 | 必填 | 说明 |
|---|---|---|
| `WEB_PASSWORD` | ✅ | 登录网页看板与管理面板的密码,生产环境必设 |
| `SETUP_KEY` | ✅ | 共享注册码,Mac App 首次接入时填它换取设备 token;不设则为开发模式(任意 token 自动注册,不安全) |
| `RETENTION_DAYS` | 可选 | 历史数据保留天数,默认 1 天;之后可在管理面板随时改 |
| `MACMON_DEVICES` | 可选 | 预配设备 `名字=token`,多台用 `;` 分隔。**新手可直接留空**——设备接入后在管理面板管理即可 |

### 3. 构建并启动

```bash
docker compose up -d --build
```

- `--build`:按 `Dockerfile` 现场编译 Go 服务器并打包成容器镜像(首次约 1 分钟)
- `-d`:后台运行,不占用当前终端

启动完成后验证:

```bash
docker compose ps                 # 状态应为 running
curl http://localhost:8080/       # 返回网页 HTML 即正常
```

浏览器访问 `http://<NAS的IP>:8080`,输入 `WEB_PASSWORD` 登录,看到看板即部署成功。

> **升级服务器版本**:以后更新只需 `git pull`(或重新下载)后再执行一次
> `docker compose up -d --build`,数据存在 Docker 卷里不会丢失。

---

## 第 ② 步:Mac 安装 App 并接入

### 安装

1. 打开 [Releases 页面](../../releases/latest),下载最新版 `Macmon-<版本号>.dmg`
2. 双击打开 DMG,把 **Macmon.app** 拖到旁边的「Applications」快捷方式上
3. 首次打开:在「应用程序」里**右键 → 打开**(未公证的个人签名,直接双击会被 Gatekeeper 拦截;只需操作一次)
4. 打开后 App 常驻顶部菜单栏(图标是一个 CPU + 百分比数字)

### 接入服务器

点击菜单栏图标 → **设置…**,填写:

| 字段 | 填什么 |
|---|---|
| 服务器地址 | `http://<NAS的IP>:8080`(和上面部署时开放的端口一致) |
| 设备名称 | 可选,给这台 Mac 起个名字(如 `MacBook Air`);留空则自动用主机名 |
| 注册码 | 服务器 `SETUP_KEY` 的值 |

点击 **「连接并开始采集」**,提示"已连接"即成功。回到 NAS 网页看板,应该马上能看到这台 Mac 的实时数据了。

> **多台 Mac?** 每台都重复上面步骤,注册码相同。更安全的做法是在管理面板
> 「待注册设备 → 生成注册码」为每台设备生成专属注册码(详见下文)。

### 菜单栏弹窗

点击菜单栏图标即可查看:

- **本机模式**:未勾选任何被监控设备时,显示本机 CPU/内存/网络/电池等
- **监控模式**:在设置 →「被监控机器」勾选其他设备后,菜单栏直接显示它们的实时状态
- 显示条目(CPU/内存/温度/网络/电池/GPU)可在设置里勾选开关,**拖动右侧 ≡ 把手自定义顺序**

---

## 第 ③ 步:远程控制台 (网页看板 + 管理面板)

浏览器访问 `http://<NAS的IP>:8080`,输入看板密码 (`WEB_PASSWORD`) 登录。

### 看板 (数据展示)

- 实时卡片:CPU / GPU / 内存 / 磁盘 / 网络 / 电池 / 温度传感器
- ECharts 历史曲线,可回看留存窗口内的数据
- 多设备切换,离线/禁用设备有状态标识

### 管理面板 (设备管理)

**待注册设备**:有未知 token 来推送时记录在此(含 IP / 首末次时间),用于审批:

- **生成注册码**:为该设备生成逐设备注册码(见下文),复制填入对方 App 即完成绑定
- **清空列表**:清理不再处理的记录

**已注册设备**,每台设备 6 个操作按钮:

| 按钮 | 作用 | 数据影响 |
|---|---|---|
| 复制 token | 复制该设备的 token,重装系统后填回 App 可免注册 | 无 |
| 重命名 | 修改设备显示名,历史数据目录同步迁移 | 数据保留 |
| 轮换 | 立即作废旧 token 并生成新 token(旧 App 需更新 token 才能继续推送) | 数据保留 |
| 禁用 / 启用 | 暂停/恢复该设备的数据接收 | 数据保留 |
| 注销 | 移除设备注册关系,原 token 失效 | **历史数据保留** |
| 彻底删除 | 移除设备并删除其全部历史数据 | **数据一并删除,不可恢复** |

**历史留存**:设置监控数据的保留天数(1–365 天,默认 1 天)。保存时二次确认,窗口外数据**立即删除**释放存储;后台每 10 分钟自动清理一次。

---

## 鉴权说明:注册码、token 与看板密码

macmon 有三类凭证,分工不同:

| 凭证 | 属于谁 | 用途 | 存放在哪 |
|---|---|---|---|
| **共享注册码** (`SETUP_KEY`) | 服务器环境变量 | 首次接入时换取设备 token,一个服务器只有一个 | docker-compose.yml 的 `SETUP_KEY` |
| **设备 token** | 每台 Mac 一枚 | 设备推送数据时的身份凭证 (`Authorization: Bearer <token>`),丢失可轮换 | App 配置 (`~/Library/Application Support/macmon/config.json`) |
| **看板密码** (`WEB_PASSWORD`) | 管理员 | 登录网页看板 / 远程控制台 (`X-Auth-Token`),与设备 token 完全独立 | docker-compose.yml 的 `WEB_PASSWORD` |

**接入流程**:App 填 `服务器地址 + 注册码` → 调 `POST /api/register` 换取本设备的 token → 之后所有推送用 token 鉴权,注册码不再需要。

**逐设备注册码**(推荐多设备场景):在远程控制台的「待注册设备」里为一台设备生成专属注册码,填到该设备 App 的注册码栏即可——它本身就是这台设备的正式 token,无需 SETUP_KEY,且各设备独立、可单独轮换/吊销。

**注意**:设备 token 泄露时,在控制台对该设备执行「轮换」立即作废旧 token;设备被「注销/彻底删除」后,原 token 同时失效。

**安全建议**:macmon 默认走 HTTP 明文,建议在**局域网或 Tailscale/WireGuard 等虚拟局域网内**使用,不要直接暴露到公网;如需公网访问,请在前面加反向代理 + HTTPS。

---

## 常见问题 (FAQ)

**Q: 提示"未连接" / 看板上看不到设备?**
依次检查:① NAS 上 `docker compose ps` 容器是否 running;② App 服务器地址端口是否一致;③ Mac 与 NAS 是否在同一网络(或 Tailscale 已连通);④ 防火墙是否放行 8080。

**Q: 首次打开 DMG 安装的 App 提示"已损坏"或被拦截?**
App 是未公证的个人签名。到「系统设置 → 隐私与安全性」点"仍要打开",或终端执行 `xattr -dr com.apple.quarantine /Applications/Macmon.app` 后再打开。

**Q: 重装系统 / 换机后原 token 还能用吗?**
App 配置在 `~/Library/Application Support/macmon/config.json`,备份该文件即可原样恢复;或直接在管理面板「复制 token」后填回新 App 的注册码栏(它本身就是 token)。

**Q: 数据会占多少磁盘?**
取决于留存天数和设备数。默认留存 1 天时,单设备每天约几百 KB;可在管理面板把留存窗口调大或调小。

**Q: 磁盘被 Docker 卷占满了想重建?**
`docker compose down -v` 会**删除全部监控数据**并移除数据卷,慎用;只想升级程序请用 `docker compose up -d --build`(不带 `-v`)。

---

## 开发

```bash
# CLI 探针 (单次采集, 直接在终端看 JSON 输出)
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
