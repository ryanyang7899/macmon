//
//  BatteryReader.swift
//  电池采集: 复刻 exelban/stats Modules/Battery/readers.swift 的数据源
//  - AppleSmartBattery (IOKit): 循环/容量/健康/电压/电流/温度
//  - IOPowerSources (IOPS): 电源状态/电量/是否充电
//  - SMC: 电池功耗 (PPBR) / 适配器功耗 (PDTR) / AC 适配器瓦数
//

import Foundation
import IOKit
import IOKit.ps

struct BatteryInfo {
    var present: Bool
    var powerSource: String            // "AC Power" / "Battery Power"
    var isCharging: Bool
    var chargePercent: Double          // 0~100
    var timeToEmptyMinutes: Int?
    var timeToFullMinutes: Int?
    var cycles: Int?
    var maxCapacity: Int?
    var designedCapacity: Int?
    var health: Int?                   // % (max/designed)
    var voltage: Double?               // 伏
    var amperage: Int?                 // mA
    var temperature: Double?           // 摄氏度
    var batteryPower: Double?          // 瓦 (电池功耗)
    var adapterPower: Double?          // 瓦 (适配器功耗)
    var acAdapterWatts: Int?           // 适配器额定瓦数
}

func collectBattery() -> BatteryInfo {
    var info = BatteryInfo(present: false, powerSource: "unknown", isCharging: false, chargePercent: 0)

    // ---- IOPowerSources: 电源状态 / 电量 / 充电 ----
    if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
       let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
       let first = list.first,
       let desc = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any] {

        info.present = true
        info.powerSource = desc[kIOPSPowerSourceStateKey] as? String ?? "unknown"
        info.isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false

        let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = desc[kIOPSMaxCapacityKey] as? Int ?? 1
        if max > 0 { info.chargePercent = Double(current) / Double(max) * 100 }

        if let empty = desc[kIOPSTimeToEmptyKey] as? Int, empty > 0 {
            info.timeToEmptyMinutes = empty
        }
        if let full = desc[kIOPSTimeToFullChargeKey] as? Int, full > 0 {
            info.timeToFullMinutes = full
        }
    }

    // ---- AppleSmartBattery (IOKit): 硬件属性 ----
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return info }
    defer { IOObjectRelease(service) }

    func prop(_ key: String) -> Any? {
        var cf: Unmanaged<CFTypeRef>?
        let kr = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
        if kr != nil { cf = kr }
        return cf?.takeRetainedValue()
    }
    // CFNumber 可能以带符号存储 (Amperage 放电为负), 统一按 Int64 读
    func intProp(_ key: String) -> Int? {
        if let v = prop(key) as? Int64 { return Int(v) }
        if let v = prop(key) as? Int { return v }
        return nil
    }

    info.cycles = intProp("CycleCount")

    // M 系列: MaxCapacity 是百分比 (100), 真实 mAh 容量在 AppleRawMaxCapacity
    info.designedCapacity = intProp("DesignCapacity")
    let rawMax = intProp("AppleRawMaxCapacity")
    if let raw = rawMax {
        info.maxCapacity = raw
    } else {
        info.maxCapacity = intProp("MaxCapacity")
    }
    if let max = info.maxCapacity, let designed = info.designedCapacity, designed > 0 {
        info.health = Int((100.0 * Double(max) / Double(designed)).rounded())
    }

    // 电压 (mV -> V)
    if let mv = intProp("Voltage") {
        info.voltage = Double(mv) / 1000.0
    }
    info.amperage = intProp("Amperage")

    // 温度: SMC TB1T/TB2T 优先, 回退 AppleSmartBattery "Temperature" (0.1°C 存储)
    let tbSensors = ["TB1T", "TB2T"].compactMap { SMC()?.getValue($0) }.filter { $0 > 0 }
    if !tbSensors.isEmpty {
        info.temperature = tbSensors.reduce(0, +) / Double(tbSensors.count)
    } else if let t = intProp("Temperature") {
        info.temperature = Double(t) / 100.0
    }

    // 功耗: SMC PPBR (电池功耗, ARM) / PDTR (适配器功耗), 回退 电压×电流
    if let smc = SMC() {
        if let ppbr = smc.getValue("PPBR"), ppbr > 0 {
            info.batteryPower = ppbr
        } else if let v = info.voltage, let a = info.amperage {
            info.batteryPower = v * (Double(a) / 1000.0)
        }
        let pdtr = smc.getValue("PDTR") ?? 0
        if pdtr > 0 { info.adapterPower = pdtr }
    }

    // AC 适配器额定瓦数
    if let acDetails = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
        info.acAdapterWatts = acDetails[kIOPSPowerAdapterWattsKey] as? Int
    }

    return info
}
