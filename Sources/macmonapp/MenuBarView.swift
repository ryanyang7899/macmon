//
//  MenuBarView.swift
//  菜单栏下拉内容: 实时状态 + 快捷操作
//

import SwiftUI
import AppKit
import MacmonCore

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if monitoredDevices.isEmpty {
                // 未勾选被监控设备: 回退显示本机状态
                if let l = model.latest {
                    row("CPU", "\(Int(l.cpu.usage * 100))%", l.cpu.temp.map { String(format: "%.0f°C", $0) })
                    row("GPU", "\(Int((l.gpu.first?.utilization ?? 0) * 100))%", l.gpu.first?.temperature.map { String(format: "%.0f°C", $0) })
                    row("内存", String(format: "%.1f GB", l.memory.usedGB), "总 \(String(format: "%.0f GB", l.memory.totalGB))")
                    row("网络", String(format: "↓%.0f KB/s", l.network.rxBps / 1024), String(format: "↑%.0f KB/s", l.network.txBps / 1024))
                    row("电池", l.battery.present ? "\(Int(l.battery.chargePercent))%" : "—",
                        l.battery.present ? "健康 \(l.battery.health ?? 0)%" : nil)
                } else {
                    Text("尚未采集").foregroundColor(.secondary)
                }
            } else {
                // 已勾选被监控设备: 展示它们的实时状态
                ForEach(monitoredDevices, id: \.self) { name in
                    monitorSection(for: name)
                }
            }

            Divider()

            Text(model.statusText)
                .font(.caption)
                .foregroundColor(model.isConnected ? .green : .orange)

            Divider()

            Button("设置…") { openWindow(id: "main") }
            Button("立即采集") { model.collectNow() }
            Button("检查更新…") { model.checkForUpdates() }

            Divider()

            Button("退出 macmon") { NSApplication.shared.terminate(nil) }
        }
        .padding(8)
        .frame(width: 220)
    }

    /// 当前勾选的被监控设备名列表
    private var monitoredDevices: [String] {
        model.config.monitorDevices ?? []
    }

    /// 单个被监控设备的状态区块
    @ViewBuilder
    private func monitorSection(for name: String) -> some View {
        let entry = model.monitorSnapshots[name]
        HStack {
            Text(name).fontWeight(.semibold).font(.system(size: 12))
            Spacer()
            if let ls = entry?.last_seen, ls > 0 {
                Text("\(Int(Date().timeIntervalSince1970) - Int(ls))s 前")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        if let l = entry?.latest?.data {
            row("CPU", "\(Int(l.cpu.usage * 100))%", l.cpu.temp.map { String(format: "%.0f°C", $0) })
            row("GPU", "\(Int((l.gpu.first?.utilization ?? 0) * 100))%", l.gpu.first?.temperature.map { String(format: "%.0f°C", $0) })
            row("内存", String(format: "%.1f GB", l.memory.usedGB), "总 \(String(format: "%.0f GB", l.memory.totalGB))")
            row("网络", String(format: "↓%.0f KB/s", l.network.rxBps / 1024), String(format: "↑%.0f KB/s", l.network.txBps / 1024))
            row("电池", l.battery.present ? "\(Int(l.battery.chargePercent))%" : "—",
                l.battery.present ? "健康 \(l.battery.health ?? 0)%" : nil)
        } else {
            if entry?.suspended == true {
                Text("已挂起").foregroundColor(.orange).font(.caption)
            } else {
                Text("等待数据…").foregroundColor(.secondary).font(.caption)
            }
        }
        Divider()
    }

    private func row(_ name: String, _ value: String, _ sub: String?) -> some View {
        HStack {
            Text(name).frame(width: 36, alignment: .leading).foregroundColor(.secondary)
            Text(value).fontWeight(.medium)
            Spacer()
            if let sub { Text(sub).foregroundColor(.secondary).font(.caption) }
        }
        .font(.system(size: 13))
    }
}
