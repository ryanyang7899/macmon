//
//  FanControl.swift
//  Apple Silicon / Intel 风扇控制 (SMC 写入)
//
//  SMC 写操作需要 root, 所以这套逻辑只在 macmonhelper (root LaunchDaemon) 里跑,
//  App 侧通过 XPC 调用。键位处理与解锁流程参考 exelban/stats (MIT License)。
//
//  涉及的 SMC key:
//    FNum      风扇数量
//    F<i>Ac    当前转速 (只读)
//    F<i>Mn    最低转速 (clamp 下限)
//    F<i>Mx    最高转速 (clamp 上限)
//    F<i>Tg    目标转速 —— 实际写入点, 类型 flt / fpe2
//    F<i>md    风扇模式 (arm64 小写), F<i>Md (Intel/大写)  0=自动 1=强制
//    Ftst      Apple Silicon 解锁键 (M1-M4 需要, M5+ 已无此键)
//

import Foundation

// MARK: - 常量

public enum MacmonHelper {
    /// XPC Mach service 名 (与 LaunchDaemon plist 中的 MachServices 一致)
    public static let machServiceName = "com.macmon.app.helper"
    /// LaunchDaemon label
    public static let label = "com.macmon.app.helper"
    /// 安装后的 helper 二进制路径
    public static let installedPath = "/Library/PrivilegedHelperTools/com.macmon.app.helper"
    /// LaunchDaemon plist 路径
    public static let plistPath = "/Library/LaunchDaemons/com.macmon.app.helper.plist"
    /// helper 版本: 与 App 不一致时提示重装。
    /// v2: 写入后改为轮询回读校验 (v1 只读一次, SMC 异步更新导致假失败)
    public static let version = "2"
    /// 心跳超时 (秒): 超过这么久没有客户端心跳且风扇仍被强制, 自动交还系统控制
    public static let heartbeatTimeout: TimeInterval = 45
}

// MARK: - 数据模型

/// 单个风扇的状态快照 (XPC 以 JSON Data 传输)
public struct FanInfo: Codable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let rpm: Double        // 当前转速
    public let minRPM: Double     // 下限
    public let maxRPM: Double     // 上限
    public let forced: Bool       // true = 手动/强制, false = 系统自动

    public init(id: Int, name: String, rpm: Double, minRPM: Double, maxRPM: Double, forced: Bool) {
        self.id = id
        self.name = name
        self.rpm = rpm
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.forced = forced
    }
}

extension ProbeResult {
    /// 从上报的原始 SMC key 还原风扇列表。
    /// 远端设备的风扇状态直接来自它的遥测数据, 因此转速刷新与监控刷新同频。
    public var fanSnapshots: [FanInfo] {
        let count = Int(fans["FNum"] ?? 0)
        guard count > 0, count < 64 else { return [] }
        return (0..<count).map { i in
            // arm64 用 F<i>md, Intel 用 F<i>Md, 1 = 强制/手动
            let mode = fans["F\(i)md"] ?? fans["F\(i)Md"] ?? 0
            return FanInfo(
                id: i,
                name: count == 2 ? (i == 0 ? "左侧风扇" : "右侧风扇") : "风扇 \(i + 1)",
                rpm: fans["F\(i)Ac"] ?? 0,
                minRPM: fans["F\(i)Mn"] ?? 0,
                maxRPM: fans["F\(i)Mx"] ?? 0,
                forced: mode == 1
            )
        }
    }
}

public struct FanError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

// MARK: - XPC 协议

@objc public protocol MacmonHelperXPC {
    /// helper 版本号, 用于判断是否需要重装
    func version(reply: @escaping (String) -> Void)
    /// 全部风扇状态 (JSON 编码的 [FanInfo])
    func snapshot(reply: @escaping (Data) -> Void)
    /// 强制某个风扇到指定转速 (会 clamp 到 [Mn, Mx])
    func setFanSpeed(id: Int, rpm: Int, reply: @escaping (String?) -> Void)
    /// 交还某个风扇给系统自动控制
    func setFanAutomatic(id: Int, reply: @escaping (String?) -> Void)
    /// 全部交还自动控制
    func resetAll(reply: @escaping (String?) -> Void)
    /// 心跳: 维持强制状态, 停止心跳超过 45s 后 helper 自动复位
    func heartbeat(reply: @escaping () -> Void)
}

// MARK: - 控制器 (只在 helper 进程内使用)

/// 风扇读写与安全约束。所有写入都做 clamp + 回读校验。
public final class FanController {
    private let smc: SMC
    /// arm64 上模式键可能是小写 md, 首次探测后缓存
    private var modeKeyIsLower: Bool?

    public init(smc: SMC) {
        self.smc = smc
    }

    // MARK: 只读

    public var fanCount: Int {
        guard let n = smc.getValue("FNum") else { return 0 }
        return Int(n)
    }

    /// 模式键名: arm64 先探测 F0md 是否存在, 否则用 F0Md
    public func modeKey(_ id: Int) -> String {
        if modeKeyIsLower == nil {
            if let probe = smc.read("F0md"), probe.dataSize > 0 {
                modeKeyIsLower = true
            } else {
                modeKeyIsLower = false
            }
        }
        return modeKeyIsLower! ? "F\(id)md" : "F\(id)Md"
    }

    public func isForced(_ id: Int) -> Bool {
        guard let v = smc.read(modeKey(id)), let first = v.bytes.first else { return false }
        return first == 1
    }

    public func fanName(_ id: Int) -> String {
        if fanCount == 2 {
            return id == 0 ? "左侧风扇" : "右侧风扇"
        }
        return "风扇 \(id + 1)"
    }

    public func snapshot() -> [FanInfo] {
        (0..<fanCount).map { id in
            FanInfo(
                id: id,
                name: fanName(id),
                rpm: smc.getValue("F\(id)Ac") ?? 0,
                minRPM: smc.getValue("F\(id)Mn") ?? 0,
                maxRPM: smc.getValue("F\(id)Mx") ?? 0,
                forced: isForced(id)
            )
        }
    }

    // MARK: 写入

    /// 把某个风扇设为强制转速。返回 nil 表示成功, 否则返回错误说明。
    ///
    /// 安全约束: 转速一律 clamp 到 [Mn, Mx]; 永远不写 0 (Stats 的 off 按钮直接写 0,
    /// 在 Apple Silicon 上可能导致风扇停转, 这里改为交还自动控制)。
    public func setForced(id: Int, rpm: Int) -> FanError? {
        guard id >= 0 && id < fanCount else {
            return FanError("风扇 \(id) 不存在")
        }
        let minRPM = Int(smc.getValue("F\(id)Mn") ?? 0)
        let maxRPM = Int(smc.getValue("F\(id)Mx") ?? 0)
        guard maxRPM > 0 else {
            return FanError("读取 F\(id)Mx 失败, 无法确定转速上限")
        }
        // 下限兜底: Mn 读不到时不允许低于 800rpm, 绝不允许 0
        let floor = minRPM > 0 ? minRPM : 800
        let target = Swift.max(floor, Swift.min(rpm, maxRPM))

        if let err = ensureForced(id) { return err }
        return writeSpeed(id, target: target)
    }

    /// 交还系统自动控制
    public func setAutomatic(id: Int) -> FanError? {
        guard id >= 0 && id < fanCount else {
            return FanError("风扇 \(id) 不存在")
        }
        let key = modeKey(id)
        guard let v = smc.read(key), let first = v.bytes.first else {
            return FanError("读取 \(key) 失败")
        }
        if first == 0 { return nil }   // 已经是自动
        guard writeBytes(key, bytes: [0], size: v.dataSize) else {
            return FanError("写入 \(key) 失败")
        }
        return nil
    }

    /// 全部交还自动控制。优先复位 Ftst, 无此键 (M5+) 则逐个复位模式键。
    @discardableResult
    public func resetAll() -> FanError? {
        if let v = smc.read("Ftst"), v.dataSize > 0 {
            if v.bytes.first == 0 { return nil }
            if writeBytes("Ftst", bytes: [0], size: v.dataSize) { return nil }
            return FanError("复位 Ftst 失败")
        }
        var firstError: FanError?
        for id in 0..<fanCount {
            if let err = setAutomatic(id: id), firstError == nil {
                firstError = err
            }
        }
        return firstError
    }

    // MARK: 私有

    /// 确保风扇进入强制模式。M1-M4 需要先写 Ftst 解锁, 从 thermalmonitord 手里拿控制权。
    private func ensureForced(_ id: Int) -> FanError? {
        if isForced(id) { return nil }

        let key = modeKey(id)
        guard let v = smc.read(key), let _ = v.bytes.first else {
            return FanError("读取 \(key) 失败")
        }

        // M5+ / 部分机型: 直接写模式键即可
        if writeBytes(key, bytes: [1], size: v.dataSize, attempts: 10) {
            return nil
        }

        // 回退: Ftst 解锁流程
        guard let ftst = smc.read("Ftst"), ftst.dataSize > 0 else {
            return FanError("写入 \(key) 失败, 且本机无 Ftst 解锁键")
        }
        if ftst.bytes.first != 1 {
            guard writeBytes("Ftst", bytes: [1], size: ftst.dataSize, attempts: 20) else {
                return FanError("写入 Ftst 失败")
            }
            // 等 thermalmonitord 让出控制权
            usleep(1_500_000)
        }
        // 解锁后模式键需要反复重试才写得进去
        if writeBytes(key, bytes: [1], size: v.dataSize, attempts: 30, delayMicros: 100_000) {
            return nil
        }
        return FanError("解锁后写入 \(key) 仍失败")
    }

    /// 写目标转速, 按该 key 的实际数据类型编码
    private func writeSpeed(_ id: Int, target: Int) -> FanError? {
        let key = "F\(id)Tg"
        guard let v = smc.read(key), let _ = v.bytes.first else {
            return FanError("读取 \(key) 失败")
        }

        let bytes: [UInt8]
        switch v.dataType {
        case SMCDataType.FLT.rawValue:
            bytes = Float(target).bytes
        case SMCDataType.FPE2.rawValue:
            bytes = [UInt8(target >> 6), UInt8((target << 2) ^ ((target >> 6) << 8))]
        case SMCDataType.UI16.rawValue:
            bytes = [UInt8((target >> 8) & 0xff), UInt8(target & 0xff)]
        default:
            return FanError("\(key) 数据类型 \(v.dataType) 不支持写入")
        }

        guard writeBytes(key, bytes: bytes, size: v.dataSize, attempts: 3) else {
            return FanError("写入 \(key) 失败")
        }

        // 回读校验: 内核可能返回成功但固件实际拒绝。
        // 必须轮询而不是只读一次 —— SMC 固件异步更新 F<i>Tg, 写完立即回读会拿到
        // 旧值, 于是出现"风扇明明已经转到 2500 却报写入未生效"的假失败。
        let tolerance = Swift.max(50.0, Double(target) * 0.1)
        var lastActual: Double?
        for i in 0..<12 {
            if i > 0 { usleep(150_000) }
            guard let actual = smc.getValue(key) else { continue }
            lastActual = actual
            if abs(actual - Double(target)) <= tolerance { return nil }
        }
        let actualText = lastActual.map { String(Int($0)) } ?? "读不到"
        return FanError("\(key) 写入未生效 (目标 \(target), 实际 \(actualText))")
    }

    /// 带重试的原始写入
    private func writeBytes(_ key: String, bytes: [UInt8], size: UInt32,
                            attempts: Int = 10, delayMicros: UInt32 = 50_000) -> Bool {
        for i in 0..<attempts {
            if smc.write(key, bytes: bytes, dataSize: size) == kIOReturnSuccess {
                return true
            }
            if i < attempts - 1 { usleep(delayMicros) }
        }
        return false
    }
}

extension Float {
    /// IEEE754 小端四字节 (SMC "flt " 类型)
    var bytes: [UInt8] {
        withUnsafeBytes(of: self) { Array($0) }
    }
}
