//
//  SystemInfo.swift
//  系统信息采集: CPU / 内存 / 网络 / 磁盘 / 负载 (全用户态, 无需 root)
//
//  复刻 exelban/stats 的数据源:
//  - CPU: host_processor_info 逐核 tick (Stats Modules/CPU/readers.swift)
//  - RAM: vm_statistics64 完整字段 + vm.swapusage + memory pressure
//  - Disk: statfs 各卷容量
//  - 网络: 接口速率见 NetworkReader.swift
//

import Foundation
import Darwin

// MARK: - sysctl 辅助

func sysctlInt(_ name: String) -> Int64? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    let r = sysctlbyname(name, &value, &size, nil, 0)
    return r == 0 ? value : nil
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    guard size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buf, &size, nil, 0)
    return String(cString: buf)
}

// MARK: - CPU

/// CPU 运行状态累计 tick (user/system/idle/nice), 对应 CPU_STATE_USER/SYSTEM/IDLE/NICE
struct CPUTicks {
    var user: UInt64 = 0
    var system: UInt64 = 0
    var idle: UInt64 = 0
    var nice: UInt64 = 0
    var total: UInt64 { user + system + idle + nice }
}

/// 读取每个 CPU 核心的累计 tick (总核数 = 每核数之和)
func samplePerCoreTicks() -> [CPUTicks]? {
    var cpuInfo: processor_info_array_t?
    var numCpuInfo: mach_msg_type_number_t = 0
    var numCPUs: natural_t = 0

    let result = host_processor_info(mach_host_self(),
                                     PROCESSOR_CPU_LOAD_INFO,
                                     &numCPUs,
                                     &cpuInfo,
                                     &numCpuInfo)
    guard result == KERN_SUCCESS, let info = cpuInfo else { return nil }
    defer {
        vm_deallocate(mach_task_self_,
                      vm_address_t(UInt(bitPattern: info)),
                      vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size))
    }

    let ptr = UnsafeMutablePointer<processor_cpu_load_info>(OpaquePointer(info))
    var list: [CPUTicks] = []
    list.reserveCapacity(Int(numCPUs))
    for i in 0..<Int(numCPUs) {
        let t = ptr[i].cpu_ticks
        list.append(CPUTicks(user: UInt64(t.0),
                             system: UInt64(t.1),
                             idle: UInt64(t.2),
                             nice: UInt64(t.3)))
    }
    return list
}

/// 全部核心 tick 求和
func sampleCPUTicks() -> CPUTicks? {
    guard let cores = samplePerCoreTicks() else { return nil }
    var total = CPUTicks()
    for c in cores {
        total.user += c.user
        total.system += c.system
        total.idle += c.idle
        total.nice += c.nice
    }
    return total
}

/// 两次采样差值计算占用率 (0~1)
func cpuUsage(from before: CPUTicks, to after: CPUTicks) -> Double {
    let dt = after.total - before.total
    guard dt > 0 else { return 0 }
    let busy = (after.user + after.system + after.nice) - (before.user + before.system + before.nice)
    return Double(busy) / Double(dt)
}

// MARK: - 内存 (完整 vm 统计)

struct MemoryInfo {
    var totalGB: Double
    var usedGB: Double
    var freeGB: Double
    var activeGB: Double
    var inactiveGB: Double
    var wiredGB: Double
    var compressedGB: Double
    var purgeableGB: Double
    var speculativeGB: Double
    var externalGB: Double
    var appGB: Double          // used - wired - compressed
    var cacheGB: Double        // purgeable + external
    var swapTotalGB: Double
    var swapUsedGB: Double
    var swapFreeGB: Double
    var swapins: UInt64
    var swapouts: UInt64
    var pressureLevel: String  // NORMAL / WARNING / CRITICAL
}

/// 内存压力等级映射 (kern.memorystatus_vm_pressure_level)
func memoryPressureLevel() -> String {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
        return "unknown"
    }
    switch level {
    case 0: return "normal"
    case 1: return "warning"
    case 2: return "critical"
    case 4: return "termination"
    default: return "level\(level)"
    }
}

func collectMemory() -> MemoryInfo? {
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }

    let pageSize = Double(vm_page_size)
    guard let totalBytes = sysctlInt("hw.memsize"), totalBytes > 0 else { return nil }

    let totalGB = Double(totalBytes) / 1e9
    func gb(_ pages: natural_t) -> Double { Double(pages) * pageSize / 1e9 }

    let activeGB = gb(stats.active_count)
    let speculativeGB = gb(stats.speculative_count)
    let inactiveGB = gb(stats.inactive_count)
    let wiredGB = gb(stats.wire_count)
    let compressedGB = gb(stats.compressor_page_count)
    let purgeableGB = gb(stats.purgeable_count)
    let externalGB = gb(stats.external_page_count)

    let usedGB = activeGB + inactiveGB + speculativeGB + wiredGB + compressedGB - purgeableGB - externalGB
    let freeGB = totalGB - usedGB
    let appGB = usedGB - wiredGB - compressedGB
    let cacheGB = purgeableGB + externalGB

    var swapTotalGB = 0.0
    var swapUsedGB = 0.0
    var swapFreeGB = 0.0
    var xsw = xsw_usage()
    var xswSize = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &xsw, &xswSize, nil, 0) == 0 {
        swapTotalGB = Double(xsw.xsu_total) / 1e9
        swapUsedGB = Double(xsw.xsu_used) / 1e9
        swapFreeGB = Double(xsw.xsu_avail) / 1e9
    }

    return MemoryInfo(totalGB: totalGB,
                      usedGB: usedGB,
                      freeGB: freeGB,
                      activeGB: activeGB,
                      inactiveGB: inactiveGB,
                      wiredGB: wiredGB,
                      compressedGB: compressedGB,
                      purgeableGB: purgeableGB,
                      speculativeGB: speculativeGB,
                      externalGB: externalGB,
                      appGB: appGB,
                      cacheGB: cacheGB,
                      swapTotalGB: swapTotalGB,
                      swapUsedGB: swapUsedGB,
                      swapFreeGB: swapFreeGB,
                      swapins: UInt64(stats.swapins),
                      swapouts: UInt64(stats.swapouts),
                      pressureLevel: memoryPressureLevel())
}

// MARK: - 磁盘容量 (各挂载卷)

struct VolumeInfo {
    var path: String
    var name: String
    var totalGB: Double
    var freeGB: Double
}

/// 枚举所有挂载卷的容量 (FileManager + statfs)
func collectVolumes() -> [VolumeInfo] {
    var list: [VolumeInfo] = []
    let keys: [URLResourceKey] = [.volumeNameKey]
    let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []

    for url in urls {
        var st = statfs()
        guard statfs(url.path, &st) == 0 else { continue }
        let total = UInt64(st.f_blocks) * UInt64(st.f_bsize)
        let free = UInt64(st.f_bavail) * UInt64(st.f_bsize)
        let name = (try? url.resourceValues(forKeys: Set(keys)).volumeName) ?? url.lastPathComponent
        list.append(VolumeInfo(path: url.path,
                               name: name.isEmpty ? url.path : name,
                               totalGB: Double(total) / 1e9,
                               freeGB: Double(free) / 1e9))
    }
    return list
}

// MARK: - 负载

func loadAverages() -> [Double] {
    var loads = [Double](repeating: 0, count: 3)
    getloadavg(&loads, 3)
    return loads
}
