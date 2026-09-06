//
//  Probe.swift
//  数据源验证探针: 复刻 Stats 全部模块的采集, 输出完整 JSON
//

import Foundation
import Darwin

/// 筛选 SMC 温度 key: T 开头的传感器类 key
public func isTemperatureKey(_ key: String) -> Bool {
    key.hasPrefix("T") && key.count >= 3
}

/// 筛选 SMC 风扇 key: F 开头 (FNum, F0Ac, F0Mn, F0Mx ...)
public func isFanKey(_ key: String) -> Bool {
    key.hasPrefix("F") && key.count >= 2
}

public struct ProbeResult: Codable {
    public var device: DeviceInfo
    public var cpu: CPUResult
    public var memory: MemoryResult
    public var disk: DiskResult
    public var network: NetworkResult
    public var gpu: [GPUResult]
    public var battery: BatteryResult
    public var temps: [String: Double]
    public var fans: [String: Double]

    public struct DeviceInfo: Codable {
        public var model: String
        public var chip: String
        public var os: String
        public var uptimeSeconds: Double
        public var cores: Int
        public var perfCores: Int?
        public var effCores: Int?
        /// 本机首选 IP (优先 Tailscale 100.x, 否则局域网 IP)。用于 server 识别设备来源,
        /// 因为 NAS 上 Tailscale 用户空间转发会把连接源 IP 改写成 127.0.0.1
        public var localIP: String?
    }

    public struct CPUResult: Codable {
        public var usage: Double                 // 总占用 0~1
        public var usagePerCore: [Double]        // 每逻辑核占用 0~1
        public var eCoreUsage: Double?           // 效率核平均 (Apple Silicon, 近似)
        public var pCoreUsage: Double?           // 性能核平均 (Apple Silicon, 近似)
        public var systemLoad: Double
        public var userLoad: Double
        public var idleLoad: Double
        public var load: [Double]
        public var freqMHz: Int64?
        public var temp: Double?
    }

    public struct MemoryResult: Codable {
        public var totalGB: Double
        public var usedGB: Double
        public var freeGB: Double
        public var activeGB: Double
        public var inactiveGB: Double
        public var wiredGB: Double
        public var compressedGB: Double
        public var purgeableGB: Double
        public var speculativeGB: Double
        public var externalGB: Double
        public var appGB: Double
        public var cacheGB: Double
        public var swapTotalGB: Double
        public var swapUsedGB: Double
        public var swapFreeGB: Double
        public var swapins: UInt64
        public var swapouts: UInt64
        public var pressureLevel: String
    }

    public struct VolumeResult: Codable {
        public var path: String
        public var name: String
        public var totalGB: Double
        public var freeGB: Double
    }

    public struct DiskResult: Codable {
        public var volumes: [VolumeResult]
        public var readBps: Double
        public var writeBps: Double
    }

    public struct NetworkResult: Codable {
        public var interface: String?
        public var status: Bool
        public var rxBps: Double
        public var txBps: Double
        public var rxTotalBytes: UInt64
        public var txTotalBytes: UInt64
        public var localIP: String?
        public var wifiRateMbps: Double?
    }

    public struct GPUResult: Codable {
        public var model: String
        public var ioClass: String
        public var utilization: Double?          // 0~1
        public var renderUtilization: Double?
        public var tilerUtilization: Double?
        public var temperature: Double?
        public var coreClockMHz: Double?
        public var memoryClockMHz: Double?
        public var poweredOffByAGC: Bool?
    }

    public struct BatteryResult: Codable {
        public var present: Bool
        public var powerSource: String
        public var isCharging: Bool
        public var chargePercent: Double
        public var timeToEmptyMinutes: Int?
        public var timeToFullMinutes: Int?
        public var cycles: Int?
        public var maxCapacity: Int?
        public var designedCapacity: Int?
        public var health: Int?
        public var voltage: Double?
        public var amperage: Int?
        public var temperature: Double?
        public var batteryPower: Double?
        public var adapterPower: Double?
        public var acAdapterWatts: Int?
    }
}

public func runProbe(sampleIntervalSeconds: Double = 1.0) -> ProbeResult {
    // 复用采集逻辑: 两次采样算差值
    return collectOnce(sampleIntervalSeconds: sampleIntervalSeconds)
}

/// 核心采集函数: 两次采样计算差值指标, 返回完整快照 (Agent 循环复用)
public func collectOnce(sampleIntervalSeconds: Double = 1.0) -> ProbeResult {
    // ---- 采样 1 ----
    let cpuTicksBefore = samplePerCoreTicks()
    let netBefore = sampleNetworkSnapshot()
    let diskIOBefore = sampleDiskIOBytes()

    Thread.sleep(forTimeInterval: sampleIntervalSeconds)

    // ---- 采样 2 ----
    let cpuTicksAfter = samplePerCoreTicks()
    let netAfter = sampleNetworkSnapshot()
    let diskIOAfter = sampleDiskIOBytes()

    let interval = sampleIntervalSeconds

    // CPU: 总占用 + 每核占用
    var usage = 0.0
    var usagePerCore: [Double] = []
    var systemLoad = 0.0
    var userLoad = 0.0
    var idleLoad = 0.0
    if let before = cpuTicksBefore, let after = cpuTicksAfter, before.count == after.count {
        usage = cpuUsage(from: aggregate(before), to: aggregate(after))
        for (b, a) in zip(before, after) {
            let dt = a.total - b.total
            if dt > 0 {
                let busy = (a.user + a.system + a.nice) - (b.user + b.system + b.nice)
                usagePerCore.append(Double(busy) / Double(dt))
            } else {
                usagePerCore.append(0)
            }
        }
        let aggBefore = aggregate(before)
        let aggAfter = aggregate(after)
        let dt = aggAfter.total - aggBefore.total
        if dt > 0 {
            systemLoad = Double(aggAfter.system - aggBefore.system) / Double(dt)
            userLoad = Double(aggAfter.user - aggBefore.user) / Double(dt)
            idleLoad = Double(aggAfter.idle - aggBefore.idle) / Double(dt)
        }
    }

    // 性能核/效率核平均 (Apple Silicon 逻辑核顺序: E 核在前, P 核在后)
    var eCoreUsage: Double?
    var pCoreUsage: Double?
    let perfCount = Int(sysctlInt("hw.perflevel0.physicalcpu") ?? 0)
    let effCount = Int(sysctlInt("hw.perflevel1.physicalcpu") ?? 0)
    if perfCount + effCount == usagePerCore.count, !usagePerCore.isEmpty {
        if effCount > 0 {
            eCoreUsage = usagePerCore[0..<effCount].reduce(0, +) / Double(effCount)
        }
        if perfCount > 0 {
            pCoreUsage = usagePerCore[usagePerCore.count - perfCount..<usagePerCore.count].reduce(0, +) / Double(perfCount)
        }
    }

    // SMC 传感器
    var temps: [String: Double] = [:]
    var fans: [String: Double] = [:]
    if let smc = SMC() {
        for key in smc.getAllKeys() {
            if isTemperatureKey(key), let v = smc.getValue(key) {
                temps[key] = v
            } else if isFanKey(key), let v = smc.getValue(key) {
                fans[key] = v
            }
        }
    }

    // 温度聚合 (M 系列新机型 GPU 温度不在 PerformanceStatistics, 靠 SMC 补齐)
    func avg(_ prefix: String) -> Double? {
        let values = temps.filter { $0.key.hasPrefix(prefix) && $0.value > 0 }
        guard !values.isEmpty else { return nil }
        return values.values.reduce(0, +) / Double(values.count)
    }
    let cpuTemp = avg("Tp") ?? avg("TC")
    let gpuTemp = avg("Tg")

    // GPU (利用率读 PerformanceStatistics, 温度融合 SMC)
    let gpus = collectGPUStats().map { g -> ProbeResult.GPUResult in
        ProbeResult.GPUResult(
            model: g.model,
            ioClass: g.ioClass,
            utilization: g.utilization.map { $0 / 100 },
            renderUtilization: g.renderUtilization.map { $0 / 100 },
            tilerUtilization: g.tilerUtilization.map { $0 / 100 },
            temperature: g.temperature ?? gpuTemp,
            coreClockMHz: g.coreClockMHz,
            memoryClockMHz: g.memoryClockMHz,
            poweredOffByAGC: g.poweredOffByAGC
        )
    }

    let mem = collectMemory()
    let volumes = collectVolumes().map {
        ProbeResult.VolumeResult(path: $0.path, name: $0.name, totalGB: $0.totalGB, freeGB: $0.freeGB)
    }
    let battery = collectBattery()

    return ProbeResult(
        device: ProbeResult.DeviceInfo(
            model: sysctlString("hw.model") ?? "unknown",
            chip: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            cores: Int(sysctlInt("hw.ncpu") ?? 0),
            perfCores: perfCount,
            effCores: effCount,
            localIP: primaryLocalIP()
        ),
        cpu: ProbeResult.CPUResult(
            usage: usage,
            usagePerCore: usagePerCore,
            eCoreUsage: eCoreUsage,
            pCoreUsage: pCoreUsage,
            systemLoad: systemLoad,
            userLoad: userLoad,
            idleLoad: idleLoad,
            load: loadAverages(),
            freqMHz: sysctlInt("hw.cpufrequency") ?? 0,
            temp: cpuTemp
        ),
        memory: ProbeResult.MemoryResult(
            totalGB: mem?.totalGB ?? 0,
            usedGB: mem?.usedGB ?? 0,
            freeGB: mem?.freeGB ?? 0,
            activeGB: mem?.activeGB ?? 0,
            inactiveGB: mem?.inactiveGB ?? 0,
            wiredGB: mem?.wiredGB ?? 0,
            compressedGB: mem?.compressedGB ?? 0,
            purgeableGB: mem?.purgeableGB ?? 0,
            speculativeGB: mem?.speculativeGB ?? 0,
            externalGB: mem?.externalGB ?? 0,
            appGB: mem?.appGB ?? 0,
            cacheGB: mem?.cacheGB ?? 0,
            swapTotalGB: mem?.swapTotalGB ?? 0,
            swapUsedGB: mem?.swapUsedGB ?? 0,
            swapFreeGB: mem?.swapFreeGB ?? 0,
            swapins: mem?.swapins ?? 0,
            swapouts: mem?.swapouts ?? 0,
            pressureLevel: mem?.pressureLevel ?? "unknown"
        ),
        disk: ProbeResult.DiskResult(
            volumes: volumes,
            readBps: Double(diskIOAfter.readBytes - diskIOBefore.readBytes) / interval,
            writeBps: Double(diskIOAfter.writeBytes - diskIOBefore.writeBytes) / interval
        ),
        network: ProbeResult.NetworkResult(
            interface: netAfter.interface,
            status: netAfter.status,
            rxBps: Double(netAfter.rxBytes - netBefore.rxBytes) / interval,
            txBps: Double(netAfter.txBytes - netBefore.txBytes) / interval,
            rxTotalBytes: netAfter.rxBytes,
            txTotalBytes: netAfter.txBytes,
            localIP: netAfter.localIP,
            wifiRateMbps: netAfter.wifiRateMbps
        ),
        gpu: gpus,
        battery: ProbeResult.BatteryResult(
            present: battery.present,
            powerSource: battery.powerSource,
            isCharging: battery.isCharging,
            chargePercent: battery.chargePercent,
            timeToEmptyMinutes: battery.timeToEmptyMinutes,
            timeToFullMinutes: battery.timeToFullMinutes,
            cycles: battery.cycles,
            maxCapacity: battery.maxCapacity,
            designedCapacity: battery.designedCapacity,
            health: battery.health,
            voltage: battery.voltage,
            amperage: battery.amperage,
            temperature: battery.temperature,
            batteryPower: battery.batteryPower,
            adapterPower: battery.adapterPower,
            acAdapterWatts: battery.acAdapterWatts
        ),
        temps: temps,
        fans: fans
    )
}

private func aggregate(_ cores: [CPUTicks]) -> CPUTicks {
    var total = CPUTicks()
    for c in cores {
        total.user += c.user
        total.system += c.system
        total.idle += c.idle
        total.nice += c.nice
    }
    return total
}

/// 获取本机首选 IP: 优先 Tailscale 地址 (100.64.0.0/10), 否则第一个非回环 IPv4
func primaryLocalIP() -> String? {
    var addrs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
    defer { freeifaddrs(addrs) }

    var fallback: String?
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let ifa = p.pointee
        guard ifa.ifa_addr != nil, ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        if String(cString: ifa.ifa_name) == "lo0" { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                       &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) != 0 { continue }
        let ip = String(cString: host)
        // Tailscale 用户空间使用的 CGNAT 段 100.64.0.0/10
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts[0] == 100, (64...127).contains(parts[1]) {
            return ip
        }
        if fallback == nil { fallback = ip }
    }
    return fallback
}
