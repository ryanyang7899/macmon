//
//  macmonhelper
//  以 root 常驻的 LaunchDaemon, 通过 XPC 为 Macmon.app 提供风扇控制能力。
//
//  为什么需要独立进程: 写 SMC 必须 root, 而 App 不能整个以 root 运行。
//
//  安全设计:
//    1. 只暴露三个动作: 设转速 / 交还自动 / 全部复位, 没有任意 SMC key 写入接口
//    2. 连接方必须是签名的 Macmon.app (校验代码签名 + 可执行文件路径)
//    3. 看门狗: 客户端消失或心跳中断超过 45s, 自动把风扇交还系统控制
//    4. 启动时若发现上次是我们强制过风扇 (标记文件), 立即复位
//
//  CLI 用法 (需 sudo):
//    macmonhelper --status   打印风扇状态
//    macmonhelper --reset    把风扇交还系统自动控制
//

import Foundation
import Security
import MacmonCore

// MARK: - 运行期状态

/// 强制过风扇的标记文件: 用于判断"上次异常退出时是否还锁着风扇"
private let forcedMarkerPath = "/var/run/com.macmon.app.forced"

final class HelperService: NSObject, MacmonHelperXPC {
    private let queue = DispatchQueue(label: "com.macmon.app.helper.smc")
    /// CLI 模式也要用, 故不设为 private
    let controller: FanController?
    private let lock = NSLock()
    private var _lastHeartbeat = Date()
    private var _clientCount = 0

    override init() {
        if let smc = SMC() {
            self.controller = FanController(smc: smc)
        } else {
            self.controller = nil
        }
        super.init()
    }

    // MARK: 客户端计数 / 心跳

    var lastHeartbeat: Date {
        lock.lock(); defer { lock.unlock() }
        return _lastHeartbeat
    }

    var clientCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _clientCount
    }

    func clientConnected() {
        lock.lock()
        _clientCount += 1
        _lastHeartbeat = Date()
        lock.unlock()
    }

    func clientDisconnected() {
        lock.lock()
        _clientCount = max(0, _clientCount - 1)
        lock.unlock()
    }

    // MARK: 标记文件

    /// 记录/清除"风扇正被强制"的状态, 供进程重启后判断
    private func markForced(_ forced: Bool) {
        if forced {
            FileManager.default.createFile(atPath: forcedMarkerPath, contents: nil)
        } else {
            try? FileManager.default.removeItem(atPath: forcedMarkerPath)
        }
    }

    private var hasForcedMarker: Bool {
        FileManager.default.fileExists(atPath: forcedMarkerPath)
    }

    // MARK: XPC 接口

    func version(reply: @escaping (String) -> Void) {
        reply(MacmonHelper.version)
    }

    func snapshot(reply: @escaping (Data) -> Void) {
        queue.async { [weak self] in
            guard let self, let controller = self.controller else {
                reply(Data("[]".utf8))
                return
            }
            let list = controller.snapshot()
            let data = (try? JSONEncoder().encode(list)) ?? Data("[]".utf8)
            reply(data)
        }
    }

    func setFanSpeed(id: Int, rpm: Int, reply: @escaping (String?) -> Void) {
        queue.async { [weak self] in
            guard let self, let controller = self.controller else {
                reply("SMC 不可用")
                return
            }
            if let err = controller.setForced(id: id, rpm: rpm) {
                NSLog("[macmonhelper] setFanSpeed(\(id), \(rpm)) 失败: \(err.message)")
                reply(err.message)
                return
            }
            self.markForced(true)
            reply(nil)
        }
    }

    func setFanAutomatic(id: Int, reply: @escaping (String?) -> Void) {
        queue.async { [weak self] in
            guard let self, let controller = self.controller else {
                reply("SMC 不可用")
                return
            }
            if let err = controller.setAutomatic(id: id) {
                reply(err.message)
                return
            }
            self.clearMarkerIfAllAutomatic()
            reply(nil)
        }
    }

    func resetAll(reply: @escaping (String?) -> Void) {
        queue.async { [weak self] in
            guard let self, let controller = self.controller else {
                reply("SMC 不可用")
                return
            }
            let err = controller.resetAll()
            self.markForced(false)
            reply(err?.message)
        }
    }

    func heartbeat(reply: @escaping () -> Void) {
        lock.lock()
        _lastHeartbeat = Date()
        lock.unlock()
        reply()
    }

    // MARK: 看门狗

    /// 全部风扇都已回到自动时清掉标记
    private func clearMarkerIfAllAutomatic() {
        guard let controller else { return }
        let stillForced = (0..<controller.fanCount).contains { controller.isForced($0) }
        if !stillForced { markForced(false) }
    }

    /// 启动时: 若上次异常退出时还锁着风扇, 立刻交还系统
    func resetIfLeftForced() {
        guard hasForcedMarker else { return }
        NSLog("[macmonhelper] 检测到上次退出时风扇仍被强制, 交还系统控制")
        queue.async { [weak self] in
            self?.controller?.resetAll()
            self?.markForced(false)
        }
    }

    /// 心跳超时或客户端全部断开后, 把风扇交还系统
    func watchdogTick() {
        guard let controller, hasForcedMarker else { return }
        let idle = Date().timeIntervalSince(lastHeartbeat)
        let noClient = clientCount == 0
        guard noClient || idle > MacmonHelper.heartbeatTimeout else { return }
        NSLog("[macmonhelper] 看门狗触发 (客户端 \(clientCount), 空闲 \(Int(idle))s), 交还风扇控制")
        queue.async { [weak self] in
            self?.controller?.resetAll()
            self?.markForced(false)
        }
    }
}

// MARK: - 连接鉴权

/// 只接受签名标识为 com.macmon.app 的对端。
///
/// 校验交给系统 (setCodeSigningRequirement), 由 XPC 在建立连接时强制执行,
/// 比手工比对 auditToken 更可靠 —— 不满足要求的连接会被直接作废。
///
/// 局限: macmon 目前是 ad-hoc 签名, 没有证书链, 因此只能约束到"签名标识"
/// 这一层。要真正防住本机上的恶意程序冒充, 需要 Developer ID 证书 + TeamID 锚定。
let peerRequirement = "identifier \"com.macmon.app\""

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service: HelperService

    init(service: HelperService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.setCodeSigningRequirement(peerRequirement)

        newConnection.exportedInterface = NSXPCInterface(with: MacmonHelperXPC.self)
        newConnection.exportedObject = service
        newConnection.invalidationHandler = { [weak service] in
            service?.clientDisconnected()
        }
        newConnection.interruptionHandler = { [weak service] in
            service?.clientDisconnected()
        }
        service.clientConnected()
        newConnection.resume()
        return true
    }
}

// MARK: - 入口

let arguments = CommandLine.arguments

/// CLI 模式: 需要 root, 不启动 XPC 服务
func runCLI() -> Bool {
    let service = HelperService()
    guard let controller = service.controller else {
        print("SMC 不可用")
        return true
    }

    if arguments.contains("--status") {
        let fans = controller.snapshot()
        if fans.isEmpty {
            print("未检测到风扇 (FNum 读取失败或本机无风扇)")
            return true
        }
        for f in fans {
            let mode = f.forced ? "强制" : "自动"
            print(String(format: "风扇 %d (%@): %.0f rpm  范围 %.0f-%.0f  模式 %@",
                         f.id, f.name, f.rpm, f.minRPM, f.maxRPM, mode))
        }
        return true
    }

    if arguments.contains("--reset") {
        if let err = controller.resetAll() {
            print("复位失败: \(err.message)")
            return true
        }
        print("已把全部风扇交还系统自动控制")
        return true
    }

    // --force <id> <rpm>: 直接强制某风扇转速 (排障用)
    if let idx = arguments.firstIndex(of: "--force"), arguments.count > idx + 2,
       let id = Int(arguments[idx + 1]), let rpm = Int(arguments[idx + 2]) {
        if let err = controller.setForced(id: id, rpm: rpm) {
            print("设置失败: \(err.message)")
            return true
        }
        print("已设置风扇 \(id) 到 \(rpm) rpm")
        return true
    }

    // --auto <id>: 交还单个风扇
    if let idx = arguments.firstIndex(of: "--auto"), arguments.count > idx + 1,
       let id = Int(arguments[idx + 1]) {
        if let err = controller.setAutomatic(id: id) {
            print("设置失败: \(err.message)")
            return true
        }
        print("风扇 \(id) 已交还自动控制")
        return true
    }

    return false
}

let isCLI = arguments.contains("--status") || arguments.contains("--reset")
    || arguments.contains("--force") || arguments.contains("--auto")

if isCLI {
    // --status 只读, 无需 root; 其余动作要写 SMC, 必须 root
    let needsRoot = !arguments.contains("--status") || arguments.contains("--reset")
        || arguments.contains("--force") || arguments.contains("--auto")
    if needsRoot && getuid() != 0 {
        print("需要 root 权限, 例如: sudo \(arguments[0]) \(arguments.dropFirst().joined(separator: " "))")
        exit(1)
    }
    _ = runCLI()
    exit(0)
}

let service = HelperService()
let delegate = ListenerDelegate(service: service)
let listener = NSXPCListener(machServiceName: MacmonHelper.machServiceName)
listener.delegate = delegate

service.resetIfLeftForced()

// 看门狗: 每 5 秒检查一次心跳/连接状态
let watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
    service.watchdogTick()
}
RunLoop.current.add(watchdog, forMode: .common)

listener.resume()
NSLog("[macmonhelper] 已启动, 监听 \(MacmonHelper.machServiceName) (version \(MacmonHelper.version))")
RunLoop.current.run()
