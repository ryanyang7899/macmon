//
//  Transmitter.swift
//  推送模块: 把采集快照 POST 到远程服务器
//  - Bearer token 鉴权
//  - 发送失败 → 入内存队列, 下次发送前先补传 (最多保留 1000 条 ≈ 4 小时)
//  - HTTP 短连接, 无需长连接管理; 服务器不可达时自动退避 (每次失败等待翻倍, 上限 60s)
//

import Foundation

struct MetricPayload: Encodable {
    let device_id: String
    let ts: Int64
    let data: ProbeResult
}

// 仅在单串行采集队列中调用, 标记 Sendable 以满足并发检查
public final class Transmitter: @unchecked Sendable {
    private let serverURL: URL
    private let token: String
    private let deviceID: String
    private var queue: [Data] = []
    private var backoffSeconds: TimeInterval = 1.0
    private let maxQueueSize = 1000

    public init(serverURL: URL, token: String, deviceID: String) {
        // 服务器指标接口固定在 /api/metrics; 允许用户传完整地址
        if serverURL.absoluteString.hasSuffix("/api/metrics") {
            self.serverURL = serverURL
        } else {
            self.serverURL = serverURL.appendingPathComponent("api/metrics")
        }
        self.token = token
        self.deviceID = deviceID
    }

    public var isConfigured: Bool { !token.isEmpty }

    /// 发送一条快照; 失败则缓存待补传
    public func send(_ snapshot: ProbeResult) {
        let ts = Int64(Date().timeIntervalSince1970)
        let payload = MetricPayload(device_id: deviceID, ts: ts, data: snapshot)
        guard let body = try? JSONEncoder().encode(payload) else { return }

        // 先补传积压的数据
        if !queue.isEmpty {
            flushQueue()
        }

        if post(body) {
            backoffSeconds = 1.0
        } else {
            enqueue(body)
            let wait = backoffSeconds
            backoffSeconds = min(backoffSeconds * 2, 60.0)
            Thread.sleep(forTimeInterval: wait)
        }
    }

    // MARK: - 内部

    private func flushQueue() {
        // 每次补传一条, 失败立即停 (服务器未恢复)
        while !queue.isEmpty {
            if post(queue[0]) {
                queue.removeFirst()
            } else {
                break
            }
        }
    }

    private func enqueue(_ data: Data) {
        queue.append(data)
        if queue.count > maxQueueSize {
            queue.removeFirst(queue.count - maxQueueSize)
        }
    }

    // 服务器在内网 (Tailscale), 不走系统代理: 代理默认不转发私有网段,
    // 会让 URLSession 的推送静默失败 (curl 不受影响, 故表现为 App 无数据)
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]   // 空字典 = 禁用系统代理
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

    private func post(_ body: Data) -> Bool {
        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        request.timeoutInterval = 5

        var done = false
        var success = false
        let sema = DispatchSemaphore(value: 0)

        let task = Transmitter.session.dataTask(with: request) { data, response, error in
            if error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200 {
                success = true
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let err = error?.localizedDescription ?? "none"
                Transmitter.log("post 失败 status=\(status) err=\(err) body=\(body.count)B")
            }
            done = true
            sema.signal()
        }
        task.resume()
        _ = sema.wait(timeout: .now() + 8)
        if !done {
            task.cancel()
        }
        return success
    }

    private static func log(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        if let data = line.data(using: .utf8),
           let handle = FileHandle(forWritingAtPath: logPath) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: logPath))
        }
    }

    private static let logPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/macmon-app.log")
        .path
}
