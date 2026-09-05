//
//  Config.swift
//  Agent 配置: 持久化到 ~/Library/Application Support/macmon/config.json
//  deviceID 首次运行自动生成, 用于服务器端区分机器
//

import Foundation

public struct AgentConfig: Codable {
    public var deviceID: String
    public var interval: Double          // 采集周期 (秒)
    public var serverURL: String?        // 推送服务器地址
    public var token: String?            // 设备鉴权 token
    public var monitorDevices: [String]? // 勾选的被监控设备 (菜单栏实时显示), nil=未设置

    public static func load() -> AgentConfig {
        let file = configFileURL()
        if let data = try? Data(contentsOf: file),
           var cfg = try? JSONDecoder().decode(AgentConfig.self, from: data) {
            if cfg.monitorDevices == nil { cfg.monitorDevices = [] }   // 兼容旧配置
            return cfg
        }
        // 首次运行: 生成配置
        let cfg = AgentConfig(deviceID: UUID().uuidString,
                              interval: 5.0,
                              serverURL: nil,
                              token: nil,
                              monitorDevices: [])
        try? cfg.save()
        return cfg
    }

    public func save() throws {
        let file = Self.configFileURL()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: file)
    }

    public static func configFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
        return base!.appendingPathComponent("macmon/config.json")
    }
}
