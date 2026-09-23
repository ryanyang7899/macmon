//
//  FanControlBlock.swift
//  菜单栏弹窗 / 窗口模式里的风扇控制组件。
//
//  操作对象是"当前被监控的这台设备" —— 可能是本机, 也可能是远端机器。
//  当前转速直接取自该设备的遥测快照, 所以刷新频率与监控数据完全同步。
//

import SwiftUI
import MacmonCore

struct FanControlBlock: View {
    let device: String
    let data: ProbeResult
    @ObservedObject var remote: RemoteFanControl

    var body: some View {
        let fans = data.fanSnapshots
        if fans.isEmpty {
            // 无风扇的机器 (或读不到 FNum) 整块不显示, 与电池的处理一致
            EmptyView()
        } else if let cap = data.fanControl {
            if cap.helper {
                if cap.version == MacmonHelper.version {
                    controls(fans)
                } else {
                    notice("组件版本不一致, 需在该设备上重新安装", icon: "arrow.triangle.2.circlepath")
                }
            } else {
                notice("被监控设备未安装组件", icon: "exclamationmark.triangle")
            }
        } else {
            // 旧版 macmon 不上报 fanControl 字段
            notice("该设备 macmon 版本过旧, 升级后可用风扇控制", icon: "arrow.up.circle")
        }
    }

    @ViewBuilder
    private func notice(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption2)
            Spacer()
        }
        .foregroundColor(.orange)
        .padding(.top, 2)
    }

    private func controls(_ fans: [FanInfo]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("风扇").font(.caption).foregroundColor(.secondary)
                Spacer()
                if let err = remote.errors[device] {
                    Text(err).font(.caption2).foregroundColor(.orange).lineLimit(1)
                }
            }
            ForEach(fans) { fan in
                FanRow(device: device, fan: fan, remote: remote)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassPanel(cornerRadius: 10)
    }
}

/// 单个风扇: 自动/手动切换 + 转速滑杆
private struct FanRow: View {
    let device: String
    let fan: FanInfo
    @ObservedObject var remote: RemoteFanControl

    @State private var draft: Double = 0
    @State private var dragging = false
    /// 本地乐观状态: 遥测有 2-7 秒延迟, 用它在等待期间先反映用户操作
    @State private var override: Bool?
    @State private var overrideAt = Date()

    private var isManual: Bool {
        if let override, Date().timeIntervalSince(overrideAt) < 12 { return override }
        return fan.forced
    }

    private var range: ClosedRange<Double> {
        let low = fan.minRPM > 0 ? fan.minRPM : 800
        let high = fan.maxRPM > low ? fan.maxRPM : low + 1000
        return low...high
    }

    private var isPending: Bool {
        remote.pending.contains("\(device)|\(fan.id)")
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Text(fan.name)
                    .font(.caption)
                    .frame(width: 54, alignment: .leading)

                // 系统的 segmented picker 选中态是固定灰底, 无法做成液态玻璃, 故自绘
                GlassSegmentedPicker(options: [(value: false, label: "自动"),
                                               (value: true, label: "手动")],
                                     selection: modeBinding,
                                     width: 78)

                Text("\(Int(fan.rpm))")
                    .font(.caption).monospacedDigit()
                    .foregroundColor(isPending ? .orange : .secondary)
                    .frame(width: 46, alignment: .trailing)
                    .help(isPending ? "指令下发中…" : "当前转速")
            }

            if isManual {
                HStack(spacing: 6) {
                    Slider(value: $draft, in: range, step: 25) { editing in
                        dragging = editing
                        if !editing {
                            remote.send(device: device, fanID: fan.id, action: "speed", rpm: Int(draft))
                        }
                    }
                    Text("\(Int(draft))")
                        .font(.caption2).monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }
        }
        .onAppear { draft = fan.rpm }
        // 遥测刷新时同步滑杆 (用户正在拖动则不打断)
        .onChange(of: fan.rpm) { value in
            if !dragging { draft = value }
        }
        // 遥测已经反映出手动状态后, 撤掉本地乐观值
        .onChange(of: fan.forced) { forced in
            if override == forced { override = nil }
        }
    }

    private var modeBinding: Binding<Bool> {
        Binding(
            get: { isManual },
            set: { manual in
                override = manual
                overrideAt = Date()
                if manual {
                    let target = Int(draft > 0 ? draft : fan.rpm)
                    remote.send(device: device, fanID: fan.id, action: "speed", rpm: target)
                } else {
                    remote.send(device: device, fanID: fan.id, action: "auto")
                }
            }
        )
    }
}
