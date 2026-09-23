//
//  FanCommandPoller.swift
//  远程风扇指令的接收端 (跑在被监控设备上)。
//
//  被监控设备在 NAT 后面, 服务器连不进来, 所以由设备主动轮询:
//    GET  /api/fan/commands  -> 取走待执行指令 (至多一次)
//    POST /api/fan/result    -> 回报执行结果
//
//  CLI agent 与 macmonapp 都会启动它 (谁在跑就由谁执行)。
//

import Foundation

/// 服务器下发的单条指令
public struct FanCommand: Codable {
    public let id: String
    public let fanID: Int
    public let action: String   // speed | auto | reset
    public let rpm: Int

    enum CodingKeys: String, CodingKey {
        case id
        case fanID = "fan_id"
        case action
        case rpm
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        fanID = try c.decode(Int.self, forKey: .fanID)
        action = try c.decode(String.self, forKey: .action)
        // rpm 必须容错: 服务器对 auto/reset 指令不下发 rpm 字段,
        // 非可选解码会让整个指令数组解析失败 —— 而服务器在 GET 时就把指令
        // 移出了队列, 解析失败等于指令永久丢失 (曾经真的踩过)。
        rpm = try c.decodeIfPresent(Int.self, forKey: .rpm) ?? 0
    }
}

public final class FanCommandPoller {
    private let serverURL: URL
    private let token: String
    private let deviceID: String
    private let interval: TimeInterval
    private let helper = HelperConnection()

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "macmon.fanpoll", qos: .utility)

    /// 本机当前被强制控制的风扇 (非空时需要持续发心跳维持, 否则 helper 会交还系统)
    private var forcedFans = Set<Int>()
    private let stateLock = NSLock()

    /// 禁用系统代理: 内网/Tailscale 请求不能被代理劫持 (与 Transmitter 一致)
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 6
        return URLSession(configuration: cfg)
    }()

    public init(serverURL: URL, token: String, deviceID: String, interval: TimeInterval = 2) {
        self.serverURL = serverURL
        self.token = token
        self.deviceID = deviceID
        self.interval = interval
    }

    // MARK: - 生命周期

    public func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: interval, leeway: .milliseconds(300))
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// 退出前同步复位本机风扇。
    ///
    /// 不论是谁强制的 (本地设置页还是远端指令), 进程退出即交还系统控制 ——
    /// 否则转速会被锁死在最后一次设定值。helper 自身也有 45s 心跳看门狗兜底。
    public static func shutdownHelper() {
        guard HelperConnection.isInstalled else { return }
        let semaphore = DispatchSemaphore(value: 0)
        let conn = HelperConnection()
        conn.resetAll(timeout: 4) { _ in semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 5)
    }

    /// 退出前把本机被强制的风扇交还系统
    public func resetLocalFans() {
        stateLock.lock()
        let forced = forcedFans
        stateLock.unlock()
        guard !forced.isEmpty else { return }
        let semaphore = DispatchSemaphore(value: 0)
        helper.resetAll(timeout: 4) { _ in semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 5)
        stateLock.lock()
        forcedFans.removeAll()
        stateLock.unlock()
    }

    // MARK: - 轮询

    private func tick() {
        // 维持强制状态: helper 45s 收不到心跳就会把风扇交还系统
        stateLock.lock()
        let needHeartbeat = !forcedFans.isEmpty
        stateLock.unlock()
        if needHeartbeat { helper.heartbeat() }

        guard let url = URL(string: "/api/fan/commands", relativeTo: serverURL) else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        Self.session.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            if let error {
                FileHandle.standardError.write(Data("[fanpoll] 拉取指令失败: \(error.localizedDescription)\n".utf8))
                return
            }
            guard let data, !data.isEmpty else { return }

            let commands: [FanCommand]
            do {
                commands = try JSONDecoder().decode([FanCommand].self, from: data)
            } catch {
                // 不能静默丢弃: 服务器取走指令后不会重发, 解析失败即永久丢失
                FileHandle.standardError.write(Data("[fanpoll] 指令解析失败: \(error)\n原始内容: \(String(data: data, encoding: .utf8) ?? "<非 UTF8>")\n".utf8))
                return
            }
            for command in commands {
                self.execute(command)
            }
        }.resume()
    }

    // MARK: - 执行

    private func execute(_ command: FanCommand) {
        switch command.action {
        case "speed":
            helper.setSpeed(id: command.fanID, rpm: command.rpm) { [weak self] error in
                guard let self else { return }
                if error == nil {
                    self.stateLock.lock()
                    self.forcedFans.insert(command.fanID)
                    self.stateLock.unlock()
                }
                self.report(command.id, error: error)
            }

        case "auto":
            helper.setAutomatic(id: command.fanID) { [weak self] error in
                guard let self else { return }
                if error == nil {
                    self.stateLock.lock()
                    self.forcedFans.remove(command.fanID)
                    self.stateLock.unlock()
                }
                self.report(command.id, error: error)
            }

        case "reset":
            helper.resetAll { [weak self] error in
                guard let self else { return }
                if error == nil {
                    self.stateLock.lock()
                    self.forcedFans.removeAll()
                    self.stateLock.unlock()
                }
                self.report(command.id, error: error)
            }

        default:
            report(command.id, error: FanError("未知指令 \(command.action)"))
        }
    }

    /// 把执行结果回报给服务器, App 据此显示失败原因
    private func report(_ commandID: String, error: FanError?) {
        guard let url = URL(string: "/api/fan/result", relativeTo: serverURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "command_id": commandID,
            "ok": error == nil,
            "error": error?.message ?? "",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        Self.session.dataTask(with: request).resume()
    }
}
