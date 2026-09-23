//
//  FanControlSection.swift
//  设置页的"风扇控制组件"分区: 只负责本机组件的安装与自检。
//
//  实际调速在菜单栏弹窗 / 窗口模式里 (RemoteFanControl), 操作对象是
//  当前被监控的那台设备 —— 可能是本机, 也可能是远端机器。
//

import SwiftUI
import MacmonCore

struct FanControlSection: View {
    @ObservedObject var helper: HelperManager

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                statusRow

                if helper.state.isUsable {
                    if helper.localFans.isEmpty {
                        Text("本机未检测到风扇")
                            .font(.caption).foregroundColor(.secondary)
                    } else {
                        ForEach(helper.localFans) { fan in
                            HStack {
                                Text(fan.name).font(.callout)
                                Spacer()
                                Text("\(Int(fan.rpm)) rpm")
                                    .font(.callout).monospacedDigit()
                                Text(fan.forced ? "手动" : "自动")
                                    .font(.caption)
                                    .foregroundColor(fan.forced ? .orange : .secondary)
                            }
                        }
                    }
                    HStack {
                        Text("调速请用菜单栏弹窗, 操作对象是当前被监控的设备")
                            .font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        Button("卸载组件") { helper.uninstall() }
                            .controlSize(.small)
                            .disabled(helper.isBusy)
                    }
                } else {
                    Text("远程风扇调速需要被监控设备各自安装这个辅助组件 —— "
                         + "写 SMC 必须 root 权限, 这是 macOS 的限制, 监控本身不需要它。")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("在本机安装组件") { helper.install() }
                            .controlSize(.small)
                            .disabled(helper.isBusy)
                        if helper.isBusy { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                }

                if let err = helper.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundColor(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label("风扇控制组件 (本机)", systemImage: "fan")
                .font(.headline)
                .padding(.bottom, 2)
        }
        .onAppear { helper.refresh() }
    }

    private var statusRow: some View {
        HStack {
            Text("组件状态").font(.callout).foregroundColor(.secondary)
            Spacer()
            Circle()
                .fill(helper.state.isUsable ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(helper.state.label).font(.callout)
        }
    }
}
