//
//  MenuBarView.swift
//  菜单栏下拉内容: 图表 + 数据结合展示, 条目由设置页勾选
//

import SwiftUI
import AppKit
import MacmonCore

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MonitorContentView(model: model)

            Divider()

            Button {
                openWindow(id: "monitor")
            } label: {
                Label("窗口模式 (可固定置顶)", systemImage: "macwindow.on.rectangle")
                    .frame(maxWidth: .infinity)
            }

            HStack {
                Button("设置…") { openWindow(id: "main") }
                Spacer()
                Button("立即采集") { model.collectNow() }
                Spacer()
                Button("检查更新…") { model.checkForUpdates() }
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
            }

            Divider()
        }
        .padding(10)
        .frame(width: 300)
    }
}

/// 监控内容视图: 菜单栏弹窗与"窗口模式"共用
struct MonitorContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if monitoredDevices.isEmpty {
                // 未勾选被监控设备: 回退显示本机状态 (同样图表化)
                if let l = model.latest {
                    localSection(l)
                } else {
                    Text("尚未采集").foregroundColor(.secondary)
                }
            } else {
                // 已勾选被监控设备: 展示它们的实时状态
                ForEach(monitoredDevices, id: \.self) { name in
                    monitorSection(for: name)
                }
            }
        }
    }

    /// 当前勾选的被监控设备名列表
    private var monitoredDevices: [String] {
        model.config.monitorDevices ?? []
    }

    /// 当前勾选的显示条目 (按用户自定义顺序)
    private var enabledItems: [String] {
        (model.config.monitorItems ?? AgentConfig.allItems).filter { AgentConfig.allItems.contains($0) }
    }

    // MARK: - 本机回退区块

    @ViewBuilder
    private func localSection(_ l: ProbeResult) -> some View {
        header(name: "本机", lastSeen: nil, battery: l.battery.present ? l.battery.chargePercent : nil,
               charging: l.battery.isCharging)
        if let p = model.localHistory.last {
            statTiles(p)
        }
        itemCharts(history: model.localHistory)
        Divider()
    }

    // MARK: - 单个被监控设备区块

    @ViewBuilder
    private func monitorSection(for name: String) -> some View {
        let entry = model.monitorSnapshots[name]
        header(name: name,
               lastSeen: entry?.last_seen,
               battery: entry?.latest?.data.battery.present == true ? entry?.latest?.data.battery.chargePercent : nil,
               charging: entry?.latest?.data.battery.isCharging ?? false)
        if entry?.suspended == true {
            Text("已挂起").foregroundColor(.orange).font(.caption)
        } else if let p = model.monitorHistory[name]?.last {
            statTiles(p)
            itemCharts(history: model.monitorHistory[name] ?? [])
        } else {
            Text("等待数据…").foregroundColor(.secondary).font(.caption)
        }
        Divider()
    }

    // MARK: - 区块组件

    /// 头部: 设备名 + 电池徽标 + 连接状态 + 更新时间
    private func header(name: String, lastSeen: Int64?, battery: Double?, charging: Bool) -> some View {
        HStack {
            Text(name).fontWeight(.semibold).font(.system(size: 13))
            if let b = battery {
                Text("\(Int(b))%\(charging ? " ⚡" : "")")
                    .font(.caption2)
                    .foregroundColor(b >= 20 || charging ? .green : .red)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.green.opacity(0.12)))
            }
            Text(model.statusText)
                .font(.caption2)
                .foregroundColor(model.isConnected ? .green : .orange)
            Spacer()
            if let ls = lastSeen, ls > 0 {
                Text("\(Int(Date().timeIntervalSince1970) - Int(ls))s 前")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    /// 三张紧凑状态卡: GPU / 内存 / CPU (底纹按占用百分比渲染)
    private func statTiles(_ p: MonitorPoint) -> some View {
        HStack(spacing: 6) {
            tile("GPU", p.gpuUsage.map { String(format: "%.0f%%", $0 * 100) } ?? "—",
                 color: .pink, pct: p.gpuUsage)
            tile("内存", String(format: "%.1fG", p.memUsed), sub: String(format: "/%.0fG", p.memTotal),
                 color: .purple, pct: p.memTotal > 0 ? p.memUsed / p.memTotal : nil)
            tile("CPU", String(format: "%.0f%%", p.cpuUsage * 100),
                 color: .blue, pct: p.cpuUsage)
        }
    }

    private func tile(_ title: String, _ value: String, sub: String? = nil, color: Color, pct: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value).font(.system(size: 13, weight: .semibold)).foregroundColor(color)
                if let sub { Text(sub).font(.caption2).foregroundColor(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            // 底纹: 浅色打底 + 按百分比从左向右填充
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.08))
                    if let pct {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(color.opacity(0.28))
                            .frame(width: geo.size.width * max(0, min(1, pct)))
                    }
                }
            }
        )
    }

    /// 按勾选条目渲染: 条目名 + 当前值 + 图表
    /// 无电池的台式机 (采样中 battery == nil) 自动跳过电池条目, 节省空间
    @ViewBuilder
    private func itemCharts(history: [MonitorPoint]) -> some View {
        ForEach(enabledItems, id: \.self) { item in
            if item != "battery" || history.last?.battery != nil {
                itemRow(item, history: history)
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: String, history: [MonitorPoint]) -> some View {
        let last = history.last
        VStack(alignment: .leading, spacing: 2) {
            itemLabel(item, last: last)
            if history.count < 2 {
                Text("采集中…").font(.caption2).foregroundColor(.secondary)
                    .frame(height: 46, alignment: .center)
                    .frame(maxWidth: .infinity)
            } else {
                chart(for: item, history: history)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func itemLabel(_ item: String, last: MonitorPoint?) -> some View {
        switch item {
        case "cpu":
            HStack {
                Text("CPU").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", (last?.cpuUsage ?? 0) * 100)).font(.caption).fontWeight(.medium)
                if let t = last?.cpuTemp { Text(String(format: "%.0f°C", t)).font(.caption2).foregroundColor(.secondary) }
            }
        case "memory":
            HStack {
                Text("内存").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.1f GB / %.0f GB", last?.memUsed ?? 0, last?.memTotal ?? 0))
                    .font(.caption).fontWeight(.medium)
            }
        case "temp":
            HStack {
                Text("温度").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(last?.cpuTemp.map { String(format: "%.1f°C", $0) } ?? "—").font(.caption).fontWeight(.medium)
            }
        case "network":
            HStack {
                Text("网络").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text("↓\(speed(last?.rxBps ?? 0)) ↑\(speed(last?.txBps ?? 0))").font(.caption).fontWeight(.medium)
            }
        case "battery":
            HStack {
                Text("电池").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(last?.battery.map { "\(Int($0))%" + ((last?.charging ?? false) ? " · 充电中" : "") } ?? "—")
                    .font(.caption).fontWeight(.medium)
            }
        case "gpu":
            HStack {
                Text("GPU").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(last?.gpuUsage.map { String(format: "%.0f%%", $0 * 100) } ?? "—").font(.caption).fontWeight(.medium)
                if let t = last?.gpuTemp { Text(String(format: "%.0f°C", t)).font(.caption2).foregroundColor(.secondary) }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func chart(for item: String, history: [MonitorPoint]) -> some View {
        switch item {
        case "cpu":
            MetricChart(points: history.map { ($0.ts, $0.cpuUsage * 100) }, color: .blue)
        case "memory":
            MetricChart(points: history.map { ($0.ts, $0.memUsed) }, color: .purple)
        case "temp":
            MetricChart(points: history.compactMap { p in p.cpuTemp.map { (p.ts, $0) } }, color: .orange)
        case "network":
            NetworkChart(points: history.map { ($0.ts, $0.rxBps, $0.txBps) })
        case "battery":
            MetricChart(points: history.compactMap { p in p.battery.map { (p.ts, $0) } }, color: .green)
        case "gpu":
            MetricChart(points: history.compactMap { p in p.gpuUsage.map { (p.ts, $0 * 100) } }, color: .pink)
        default:
            EmptyView()
        }
    }

    /// 速率格式化: KB/s 或 MB/s
    private func speed(_ bps: Double) -> String {
        bps >= 1024 * 1024 ? String(format: "%.1fM/s", bps / 1024 / 1024)
                           : String(format: "%.0fK/s", bps / 1024)
    }
}
