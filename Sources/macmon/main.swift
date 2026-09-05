//
//  main.swift
//  macmon M0 数据源验证探针
//
//  用法:
//    macmon                    单次采集全部指标并输出 JSON
//    macmon --sleep <秒>       采样间隔 (默认 1 秒, 用于算 CPU 占用/网络速率)
//    macmon --dump-smc         枚举本机全部 SMC 传感器 key (探测用)
//    macmon --raw-gpu          输出 IOAccelerator 原始 PerformanceStatistics
//

import Foundation
import MacmonCore

let args = CommandLine.arguments
var sleepSeconds = 1.0
var agentMode = false
var agentInterval: Double = 5.0
var outFile: String?
var serverURL: String?
var token: String?

var i = 1
while i < args.count {
    switch args[i] {
    case "--sleep":
        if i + 1 < args.count, let v = Double(args[i + 1]) { sleepSeconds = v }
        i += 2
    case "--agent":
        agentMode = true
        i += 1
    case "--interval":
        if i + 1 < args.count, let v = Double(args[i + 1]) { agentInterval = v }
        i += 2
    case "--out":
        if i + 1 < args.count { outFile = args[i + 1] }
        i += 2
    case "--server":
        if i + 1 < args.count { serverURL = args[i + 1] }
        i += 2
    case "--token":
        if i + 1 < args.count { token = args[i + 1] }
        i += 2
    case "--dump-smc":
        dumpSMCKeys()
        exit(0)
    case "--raw-gpu":
        dumpRawGPU()
        exit(0)
    default:
        i += 1
    }
}

if agentMode {
    // M1: 常驻 Agent
    var config = AgentConfig.load()
    config.interval = agentInterval
    if let serverURL { config.serverURL = serverURL }
    if let token { config.token = token }
    try? config.save()
    let agent = Agent(config: config, outFile: outFile, verbose: true)
    agent.run()
    exit(0)
}

// 单次探针
let result = runProbe(sampleIntervalSeconds: sleepSeconds)

// 转 JSON 输出
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
if let data = try? encoder.encode(result),
   let json = String(data: data, encoding: .utf8) {
    print(json)
}

// MARK: - 辅助: 枚举 SMC key

func dumpSMCKeys() {
    guard let smc = SMC() else {
        print("无法打开 SMC")
        exit(1)
    }
    let keys = smc.getAllKeys()
    print("共 \(keys.count) 个 SMC key\n")

    print("== 温度类 (T*) ==")
    for key in keys where isTemperatureKey(key) {
        let v = smc.getValue(key)
        let type = smc.read(key)?.dataType ?? "?"
        print(String(format: "  %@  %8.2f  (%@)", key, v ?? -1, type))
    }

    print("\n== 风扇类 (F*) ==")
    for key in keys where isFanKey(key) {
        let v = smc.getValue(key)
        let type = smc.read(key)?.dataType ?? "?"
        print(String(format: "  %@  %8.2f  (%@)", key, v ?? -1, type))
    }
}

// MARK: - 辅助: 输出 GPU 原始字段

func dumpRawGPU() {
    for props in ioAcceleratorProperties() {
        let ioClass = (props["IOClass"] as? String) ?? "?"
        print("=== IOAccelerator: \(ioClass) ===")
        if let model = props["model"] {
            print("  model: \(decodeModelData(model))")
        }
        print("  全部属性:")
        for (k, v) in props.sorted(by: { $0.key < $1.key }) {
            print("    \(k) = \(v)")
        }
        print("")
    }
}
