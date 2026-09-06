//
//  AppModel.swift
//  macmonapp: 状态管理与采集/推送线程
//

import SwiftUI
import AppKit
import ServiceManagement
import MacmonCore

@MainActor
final class AppModel: ObservableObject {
    @Published var config: AgentConfig
    @Published var latest: ProbeResult?
    @Published var statusText = "未连接"
    @Published var isConnected = false
    @Published var error: String?
    @Published var isLaunchAtLogin = false
    @Published var updateAvailable: UpdateInfo?
    @Published var checkUpdateError: String?

    // 被监控机器 (菜单栏实时显示)
    @Published var monitorDeviceList: [MonitorDevice] = []
    @Published var monitorSnapshots: [String: MonitorEntry] = [:]
    @Published var monitorError: String?
    // 图表数据: 设备名 -> 时间序列 (环形缓冲, 最近 ~10 分钟)
    @Published var monitorHistory: [String: [MonitorPoint]] = [:]
    // 本机回退视图的图表数据
    @Published var localHistory: [MonitorPoint] = []

    private var timer: Timer?
    private var monitorTimer: Timer?
    private var transmitter: Transmitter?
    private let collectQueue = DispatchQueue(label: "macmon.collect", qos: .utility)

    /// 监控请求专用 session: 禁用系统代理, 避免内网请求被代理劫持 (与 Transmitter 一致)
    private static let monitorSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]   // 空字典 = 禁用系统代理
        cfg.timeoutIntervalForRequest = 5
        return URLSession(configuration: cfg)
    }()

    /// 写日志到 ~/Library/Logs/macmon-app.log (诊断用, 可从任意线程调用)
    nonisolated private func log(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("macmon-app.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }

    init() {
        self.config = AgentConfig.load()
        log("init: server=\(config.serverURL ?? "nil") token=\((config.token?.isEmpty == false) ? "set" : "nil")")
        if config.serverURL?.isEmpty == false, let token = config.token, !token.isEmpty {
            self.isConnected = true
            self.statusText = "已连接"
            // 已有配置时启动即自动恢复采集推送, 无需重新填写 (修复: 重启后不推送)
            log("init: 配置有效, 自动 start()")
            start()
        } else {
            log("init: 无有效配置, 跳过 start()")
        }
        self.isLaunchAtLogin = SMAppService.mainApp.status == .enabled
        // 若已勾选被监控设备, 启动菜单栏监控轮询
        if let sel = config.monitorDevices, !sel.isEmpty {
            log("init: 已勾选被监控设备 \(sel.joined(separator: ",")), 启动监控轮询")
            startMonitorTimer()
            Task { await refreshMonitor() }
        }
        checkForUpdates()
    }

    // MARK: - 被监控机器 (菜单栏实时显示)

    func loadMonitorDevices() async {
        monitorError = nil
        guard let base = config.serverURL, let url = URL(string: base),
              let token = config.token, !token.isEmpty else {
            monitorError = "未配置服务器"
            return
        }
        var req = URLRequest(url: url.appendingPathComponent("api/monitor/devices"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await Self.monitorSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                monitorError = "获取设备列表失败 (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1))"
                return
            }
            let list = try JSONDecoder().decode([MonitorDevice].self, from: data)
            self.monitorDeviceList = list
            // 清理已不存在设备的勾选, 避免菜单栏显示幽灵设备
            let names = Set(list.map(\.name))
            if let sel = config.monitorDevices {
                let valid = sel.filter { names.contains($0) }
                if valid != sel {
                    config.monitorDevices = valid
                    try? config.save()
                }
            }
        } catch {
            monitorError = "获取设备列表失败: \(error.localizedDescription)"
        }
    }

    /// 拉取勾选设备的实时快照 (5s 轮询), 并追加到图表缓冲
    func refreshMonitor() async {
        let devices = config.monitorDevices ?? []
        guard !devices.isEmpty, let base = config.serverURL, let url = URL(string: base),
              let token = config.token, !token.isEmpty else {
            monitorSnapshots = [:]
            return
        }
        var req = URLRequest(url: url.appendingPathComponent("api/monitor/snapshots"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONEncoder().encode(["devices": devices])
        do {
            let (data, resp) = try await Self.monitorSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            self.monitorSnapshots = try JSONDecoder().decode([String: MonitorEntry].self, from: data)
            // 追加图表缓冲
            for (name, entry) in monitorSnapshots {
                if let d = entry.latest?.data {
                    var buf = monitorHistory[name] ?? []
                    append(&buf, makePoint(from: d, ts: entry.latest!.ts))
                    monitorHistory[name] = buf
                }
            }
            // 清理已不再勾选设备的缓冲
            let sel = Set(devices)
            for key in monitorHistory.keys where !sel.contains(key) {
                monitorHistory.removeValue(forKey: key)
            }
        } catch {
            // 轮询失败静默, 等待下个周期; 不刷掉旧数据
        }
    }

    /// 从采样提取图表点
    private func makePoint(from d: ProbeResult, ts: Int64) -> MonitorPoint {
        MonitorPoint(ts: ts,
                     cpuUsage: d.cpu.usage,
                     cpuTemp: d.cpu.temp,
                     memUsed: d.memory.usedGB,
                     memTotal: d.memory.totalGB,
                     rxBps: d.network.rxBps,
                     txBps: d.network.txBps,
                     gpuUsage: d.gpu.first?.utilization,
                     gpuTemp: d.gpu.first?.temperature,
                     battery: d.battery.present ? d.battery.chargePercent : nil,
                     charging: d.battery.isCharging)
    }

    /// 追加图表点 (环形上限 historyCapacity)
    private func append(_ buffer: inout [MonitorPoint], _ p: MonitorPoint) {
        buffer.append(p)
        if buffer.count > Self.historyCapacity {
            buffer.removeFirst(buffer.count - Self.historyCapacity)
        }
    }

    /// 图表缓冲上限: 120 点 (5s 轮询 ≈ 10 分钟)
    static let historyCapacity = 120

    /// 设置/取消勾选的被监控设备, 持久化并管理轮询
    func setMonitorSelection(_ devices: [String]) {
        config.monitorDevices = devices
        try? config.save()
        log("setMonitorSelection: \(devices.joined(separator: ","))")
        if devices.isEmpty {
            stopMonitorTimer()
            monitorSnapshots = [:]
        } else {
            startMonitorTimer()
            Task { await refreshMonitor() }
        }
    }

    /// 设置菜单栏显示条目, 持久化
    func setMonitorItems(_ items: [String]) {
        config.monitorItems = items
        try? config.save()
        log("setMonitorItems: \(items.joined(separator: ","))")
    }

    private func startMonitorTimer() {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refreshMonitor() }
            }
        }
    }

    private func stopMonitorTimer() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    // MARK: - 自动更新

    func checkForUpdates() {
        Task {
            do {
                self.updateAvailable = try await AppUpdater.checkLatest()
            } catch {
                self.checkUpdateError = "检查更新失败: \(error.localizedDescription)"
            }
        }
    }

    /// 打开最新版本的 DMG 下载
    func downloadUpdate() {
        guard let u = updateAvailable else { return }
        NSWorkspace.shared.open(u.downloadURL)
    }

    /// 菜单栏图标显示 CPU 占用
    var statusLabel: String {
        guard let l = latest else { return "macmon" }
        return "\(Int(l.cpu.usage * 100))%"
    }

    // MARK: - 接入服务器

    /// 填写服务器地址 + 注册码, 注册设备并开始采集推送
    func saveAndConnect(server: String, deviceName: String, setupKey: String, interval: Double) async {
        error = nil
        guard let _ = URL(string: server), !server.isEmpty else {
            error = "服务器地址无效"
            return
        }
        var token = config.token ?? ""
        if !setupKey.isEmpty {
            do {
                token = try await register(server: server, deviceName: deviceName, setupKey: setupKey)
            } catch {
                self.error = "注册失败: \(error.localizedDescription)"
                return
            }
        }
        guard !token.isEmpty else {
            error = "缺少 token, 请填写注册码 (首次接入) 或已有 token"
            return
        }

        config.serverURL = server
        config.token = token
        config.deviceID = deviceName.isEmpty ? "mac-\(hostname())" : deviceName
        config.interval = max(2, interval)
        try? config.save()
        start()
    }

    private func register(server: String, deviceName: String, setupKey: String) async throws -> String {
        var req = URLRequest(url: URL(string: server)!.appendingPathComponent("api/register"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["setup_key": setupKey, "name": deviceName])
        let (data, resp) = try await Self.monitorSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        struct RegResp: Decodable { let token: String }
        return try JSONDecoder().decode(RegResp.self, from: data).token
    }

    // MARK: - 采集 / 推送

    func start() {
        guard let urlStr = config.serverURL, let url = URL(string: urlStr),
              let token = config.token, !token.isEmpty else {
            log("start: guard 失败, 无法启动 url=\(config.serverURL ?? "nil")")
            return
        }
        log("start: url=\(url.absoluteString) token=\(token)")
        stop()
        transmitter = Transmitter(serverURL: url, token: token, deviceID: config.deviceID)
        isConnected = true
        statusText = "已连接 · 采集中"
        collectNow()
        let interval = max(2, config.interval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.collectNow() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func collectNow() {
        let interval = max(2, config.interval)
        let tx = transmitter   // 在 MainActor 上下文捕获, 避免闭包内访问隔离属性
        collectQueue.async { [weak self] in
            guard let self else { return }
            let result = collectOnce(sampleIntervalSeconds: min(1.0, interval / 2))
            self.log("collect: 采集完成 cpu=\(String(format: "%.2f", result.cpu.usage)) 准备推送")
            tx?.send(result)
            DispatchQueue.main.async {
                self.latest = result
                self.statusText = "采集中"
                // 本机图表缓冲
                self.append(&self.localHistory, self.makePoint(from: result, ts: Int64(Date().timeIntervalSince1970)))
            }
        }
    }

    // MARK: - 开机自启

    func toggleLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isLaunchAtLogin = (SMAppService.mainApp.status == .enabled)
        } catch {
            self.error = "设置开机自启失败: \(error.localizedDescription)"
        }
    }

    private func hostname() -> String {
        var buf = [CChar](repeating: 0, count: 256)
        _ = gethostname(&buf, buf.count)
        return String(cString: buf)
    }
}

// MARK: - 监控数据模型 (server /api/monitor/*)

/// GET /api/monitor/devices 返回的设备条目
struct MonitorDevice: Decodable {
    let name: String
    let last_seen: Int64
    let suspended: Bool
}

/// 设备推送的一条原始采样 (与 MetricPayload 对应)
struct MonitorSnapshot: Decodable {
    let device_id: String
    let ts: Int64
    let data: ProbeResult
}

/// POST /api/monitor/snapshots 返回的某设备条目 (latest 可能为 null, 无数据时)
struct MonitorEntry: Decodable {
    let latest: MonitorSnapshot?
    let last_seen: Int64
    let suspended: Bool
}

/// 菜单栏图表的单个采样点 (从 ProbeResult 提取的字段子集)
struct MonitorPoint {
    let ts: Int64
    let cpuUsage: Double
    let cpuTemp: Double?
    let memUsed: Double
    let memTotal: Double
    let rxBps: Double
    let txBps: Double
    let gpuUsage: Double?
    let gpuTemp: Double?
    let battery: Double?
    let charging: Bool
}
