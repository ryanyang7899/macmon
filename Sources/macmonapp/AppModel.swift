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

    private var timer: Timer?
    private var transmitter: Transmitter?
    private let collectQueue = DispatchQueue(label: "macmon.collect", qos: .utility)

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
        checkForUpdates()
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
        let (data, resp) = try await URLSession.shared.data(for: req)
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
                self.statusText = "采集中 · CPU \(Int(result.cpu.usage * 100))%"
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
