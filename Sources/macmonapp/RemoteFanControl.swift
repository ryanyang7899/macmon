//
//  RemoteFanControl.swift
//  App 侧远程风扇控制: 把指令发给服务器, 由被监控设备拉取执行。
//
//  App 不直接连被监控设备 (对方在 NAT 后面), 走的是服务器中转:
//    POST /api/fan/command  -> 入队
//    GET  /api/fan/state    -> 读回执行结果 (失败原因要显示给用户)
//
//  转速本身不在这里取 —— 直接来自设备遥测 (ProbeResult.fans),
//  因此刷新频率与监控数据完全同步。
//

import Foundation
import MacmonCore

@MainActor
final class RemoteFanControl: ObservableObject {
    /// 设备名 -> 最近一次执行失败原因 (成功则清空)
    @Published var errors: [String: String] = [:]
    /// "设备名|风扇号" -> 已下发但还没在遥测里看到生效
    @Published var pending: Set<String> = []

    private var serverURL: String?
    private var token: String?
    private var lastCommandAt: [String: Date] = [:]

    /// 禁用系统代理, 避免内网请求被代理劫持 (与 Transmitter 一致)
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 6
        return URLSession(configuration: cfg)
    }()

    func configure(serverURL: String?, token: String?) {
        self.serverURL = serverURL
        self.token = token
    }

    var isConfigured: Bool {
        serverURL?.isEmpty == false && token?.isEmpty == false
    }

    // MARK: - 下发指令

    func send(device: String, fanID: Int, action: String, rpm: Int = 0) {
        guard isConfigured, let base = serverURL, let url = URL(string: base + "/api/fan/command") else {
            errors[device] = "未配置服务器, 无法下发指令"
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["device": device, "fan_id": fanID, "action": action]
        if action == "speed" { body["rpm"] = rpm }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let key = "\(device)|\(fanID)"
        pending.insert(key)
        lastCommandAt[device] = Date()

        Self.session.dataTask(with: request) { [weak self] _, response, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.errors[device] = "下发失败: \(error.localizedDescription)"
                    self.pending.remove(key)
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    self.errors[device] = Self.message(for: http.statusCode)
                    self.pending.remove(key)
                }
            }
        }.resume()
    }

    // MARK: - 读回结果

    /// 拉取各设备最近一次执行结果; 失败原因会保留在 errors 里供 UI 显示
    func pollResults(devices: [String]) {
        guard isConfigured, let base = serverURL else { return }
        for device in devices {
            let encoded = device.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? device
            guard let url = URL(string: base + "/api/fan/state?device=" + encoded) else { continue }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")

            Self.session.dataTask(with: request) { [weak self] data, _, _ in
                guard let data,
                      let state = try? JSONDecoder().decode(FanStateResponse.self, from: data) else { return }
                Task { @MainActor in
                    guard let self else { return }
                    // 只关心最近 30 秒内那条指令的结果, 避免陈年错误一直挂着
                    guard let at = state.at, Date().timeIntervalSince1970 - Double(at) < 30 else { return }
                    if state.ok == true {
                        self.errors[device] = nil
                        self.clearPending(device: device)
                    } else if let msg = state.error, !msg.isEmpty {
                        self.errors[device] = msg
                        self.clearPending(device: device)
                    }
                }
            }.resume()
        }
    }

    /// 遥测里已经能看到目标状态时, 清掉"下发中"标记
    func settlePending(device: String, fanID: Int) {
        let key = "\(device)|\(fanID)"
        guard pending.contains(key), let sent = lastCommandAt[device] else { return }
        // 给设备 2s 拉取 + 执行的时间, 之后看到的状态才算数
        if Date().timeIntervalSince(sent) > 2 {
            pending.remove(key)
        }
    }

    private func clearPending(device: String) {
        pending = pending.filter { !$0.hasPrefix(device + "|") }
    }

    private static func message(for status: Int) -> String {
        switch status {
        case 401: return "鉴权失败, 请检查设备 token"
        case 404: return "服务器上没有这台设备"
        case 409: return "该设备已被挂起"
        default: return "服务器返回 \(status)"
        }
    }
}

/// GET /api/fan/state 的响应 (无结果时是空对象, 全部字段可选)
struct FanStateResponse: Decodable {
    let command_id: String?
    let ok: Bool?
    let error: String?
    let at: Int64?
}
