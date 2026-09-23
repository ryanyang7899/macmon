//
//  HelperConnection.swift
//  macmonhelper (root LaunchDaemon) 的 XPC 客户端。
//
//  放在 MacmonCore 里是因为两个进程都要用:
//    - macmonapp : 本地设置页的组件安装/自检
//    - macmon CLI agent: 执行服务器下发的远程风扇指令
//

import Foundation

public final class HelperConnection {
    private var connection: NSXPCConnection?
    private let lock = NSLock()
    /// 最近一次连接失败原因, 用于把"无响应"这种模糊报错换成真实原因
    /// (最常见的是签名标识不符, 系统直接拒绝建立连接)
    private var lastError: String?

    public init() {}

    deinit {
        connection?.invalidate()
    }

    /// 组件是否已安装 (只看文件存在, 不建连接)
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: MacmonHelper.installedPath)
    }

    // MARK: - 连接

    private func proxy() -> MacmonHelperXPC? {
        lock.lock()
        if let connection, let p = connection.remoteObjectProxy as? MacmonHelperXPC {
            lock.unlock()
            return p
        }
        let stale = connection
        connection = nil
        lock.unlock()
        stale?.invalidate()

        // 系统域 LaunchDaemon (/Library/LaunchDaemons) 必须用 privileged
        let conn = NSXPCConnection(machServiceName: MacmonHelper.machServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: MacmonHelperXPC.self)
        conn.invalidationHandler = { [weak self, weak conn] in
            self?.dropConnection(conn)
        }
        conn.resume()

        let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self, weak conn] error in
            guard let self else { return }
            self.lock.lock()
            self.lastError = error.localizedDescription
            self.lock.unlock()
            self.dropConnection(conn)
        } as? MacmonHelperXPC

        lock.lock()
        connection = conn
        lock.unlock()
        return proxy
    }

    /// 丢弃缓存的连接 (下次调用时重建)。
    /// invalidate 必须在锁外调用: invalidationHandler 会回来抢同一把非递归锁。
    private func dropConnection(_ target: NSXPCConnection? = nil) {
        lock.lock()
        let cached = connection
        let shouldDrop = target == nil || cached === target
        if shouldDrop { connection = nil }
        lock.unlock()
        if shouldDrop { cached?.invalidate() }
    }

    /// 连接失败时的报错文案: 有真实原因就用真实原因
    private func failureText() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let lastError else { return "辅助组件无响应" }
        return "辅助组件无响应 (\(lastError))"
    }

    /// 超时兜底: 取回原因后丢弃连接, 让下一次调用重建 (否则会一直复用一个哑掉的 proxy)
    private func timeoutFallback() -> FanError {
        let text = failureText()
        dropConnection()
        return FanError(text)
    }

    // MARK: - 调用

    /// 读取全部风扇状态
    public func snapshot(timeout: TimeInterval = 4, completion: @escaping ([FanInfo]) -> Void) {
        guard let p = proxy() else {
            completion([])
            return
        }
        let box = ReplyBox<[FanInfo]>(default: { [] }, completion: completion)
        p.snapshot { data in
            let list = (try? JSONDecoder().decode([FanInfo].self, from: data)) ?? []
            box.finish(list)
        }
        box.arm(timeout: timeout)
    }

    /// 设置转速 (helper 侧会 clamp 到 [Mn, Mx])
    public func setSpeed(id: Int, rpm: Int, timeout: TimeInterval = 12,
                         completion: @escaping (FanError?) -> Void) {
        guard let p = proxy() else {
            completion(FanError("辅助组件未安装"))
            return
        }
        let box = ReplyBox<FanError?>(default: { [weak self] in self?.timeoutFallback() ?? FanError("辅助组件无响应") },
                                completion: completion)
        p.setFanSpeed(id: id, rpm: rpm) { error in
            box.finish(error.map { FanError($0) })
        }
        box.arm(timeout: timeout)
    }

    /// 交还自动控制
    public func setAutomatic(id: Int, timeout: TimeInterval = 12,
                             completion: @escaping (FanError?) -> Void) {
        guard let p = proxy() else {
            completion(FanError("辅助组件未安装"))
            return
        }
        let box = ReplyBox<FanError?>(default: { [weak self] in self?.timeoutFallback() ?? FanError("辅助组件无响应") },
                                completion: completion)
        p.setFanAutomatic(id: id) { error in
            box.finish(error.map { FanError($0) })
        }
        box.arm(timeout: timeout)
    }

    /// 全部交还自动控制
    public func resetAll(timeout: TimeInterval = 12, completion: @escaping (FanError?) -> Void) {
        guard let p = proxy() else {
            completion(FanError("辅助组件未安装"))
            return
        }
        let box = ReplyBox<FanError?>(default: { [weak self] in self?.timeoutFallback() ?? FanError("辅助组件无响应") },
                                completion: completion)
        p.resetAll { error in
            box.finish(error.map { FanError($0) })
        }
        box.arm(timeout: timeout)
    }

    /// 心跳: 维持强制状态 (helper 45s 收不到心跳会自行交还系统)
    public func heartbeat() {
        proxy()?.heartbeat { }
    }
}

/// 保证回调只触发一次 (XPC 不回复时由超时兜底)
private final class ReplyBox<T> {
    private let lock = NSLock()
    private var done = false
    private let fallback: () -> T
    private let completion: (T) -> Void

    init(default fallback: @escaping () -> T, completion: @escaping (T) -> Void) {
        self.fallback = fallback
        self.completion = completion
    }

    func finish(_ value: T) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        lock.unlock()
        completion(value)
    }

    func arm(timeout: TimeInterval) {
        // 必须强引用 self: XPC 连不上时回复闭包根本不会被调用, 也就没有任何东西
        // 持有 box —— 弱引用会让超时兜底变成空操作, 回调永不触发, 错误静默丢失。
        // 定时器到期前 box 存活, finish 只生效一次, 之后自然释放。
        //
        // fallback 必须拖到点才算, 不能在 arm 时就求值: 它带副作用 ——
        // setSpeed/setAutomatic 的兜底会丢弃连接。提前求值等于请求刚发出去就
        // invalidate 掉承载它的那条连接, 消息当场作废, 回复永远不来,
        // 表现为"已发出但超时", 而同样的请求用裸连接却能成功。
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
            finish(fallback())
        }
    }
}
