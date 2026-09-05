//
//  IOKitGPU.swift
//  GPU 采集: 读 IOKit 里 IOAccelerator 服务发布到 IORegistry 的私有属性
//
//  参照 exelban/stats Modules/GPU/reader.swift (MIT License)。
//  核心: PerformanceStatistics 字典, 字段为 Apple GPU 驱动的未文档化 key,
//  会随 macOS 版本变化, 因此同一指标保留多个 fallback key。
//

import Foundation
import IOKit

struct GPUStats {
    var ioClass: String
    var model: String
    var utilization: Double?        // 0.0 ~ 1.0
    var renderUtilization: Double?
    var tilerUtilization: Double?
    var temperature: Double?
    var coreClockMHz: Double?
    var memoryClockMHz: Double?
    var fanSpeedPercent: Double?
    var poweredOffByAGC: Bool?
    var rawStats: [String: Any]     // 保留全部原始字段, 便于排查
}

// 读取所有 IOAccelerator 服务的注册表属性
public func ioAcceleratorProperties() -> [[String: Any]] {
    var result: [[String: Any]] = []
    let matching = IOServiceMatching("IOAccelerator")
    var iterator: io_iterator_t = 0

    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
        return result
    }
    defer { IOObjectRelease(iterator) }

    var service = IOIteratorNext(iterator)
    while service != 0 {
        var cfProps: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &cfProps, kCFAllocatorDefault, 0)
        if kr == kIOReturnSuccess,
           let props = cfProps?.takeRetainedValue() as? [String: Any] {
            result.append(props)
        }
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
    return result
}

// "model" 属性可能是 ASCII Data 或 String, 统一转成字符串
public func decodeModelData(_ value: Any?) -> String {
    if let data = value as? Data,
       let s = String(data: data, encoding: .ascii) {
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
    }
    if let str = value as? String {
        return str.trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
    }
    return ""
}

func collectGPUStats() -> [GPUStats] {
    var list: [GPUStats] = []
    for props in ioAcceleratorProperties() {
        let ioClass = (props["IOClass"] as? String) ?? "unknown"
        guard let perfStats = props["PerformanceStatistics"] as? [String: Any] else {
            continue
        }

        // 同一指标多个 fallback key (字段随 macOS 版本变化)
        func intFrom(_ keys: [String]) -> Double? {
            for k in keys {
                if let v = perfStats[k] as? Int { return Double(v) }
                if let v = perfStats[k] as? NSNumber { return v.doubleValue }
            }
            return nil
        }

        var gpu = GPUStats(
            ioClass: ioClass,
            model: decodeModelData(props["model"]),
            utilization: intFrom(["Device Utilization %", "GPU Activity(%)", "GPU Activity", "device utilization %"]),
            renderUtilization: intFrom(["Renderer Utilization %"]),
            tilerUtilization: intFrom(["Tiler Utilization %"]),
            temperature: intFrom(["Temperature(C)", "Temperature (C)", "GPU Temperature"]),
            coreClockMHz: intFrom(["Core Clock(MHz)", "Core Clock (MHz)"]),
            memoryClockMHz: intFrom(["Memory Clock(MHz)", "Memory Clock (MHz)"]),
            fanSpeedPercent: intFrom(["Fan Speed(%)"]),
            poweredOffByAGC: (props["AGCInfo"] as? [String: Any])?["poweredOffByAGC"] as? Int == 1,
            rawStats: perfStats
        )

        // Intel 集成显卡等场景 "model" 为空, 用 IOClass 兜底
        if gpu.model.isEmpty {
            gpu.model = ioClass
        }

        // 利用率超 100 截断
        if let u = gpu.utilization { gpu.utilization = min(u, 100) }
        if let r = gpu.renderUtilization { gpu.renderUtilization = min(r, 100) }
        if let t = gpu.tilerUtilization { gpu.tilerUtilization = min(t, 100) }

        list.append(gpu)
    }
    return list
}
