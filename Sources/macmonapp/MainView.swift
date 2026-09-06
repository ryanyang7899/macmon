//
//  MainView.swift
//  主窗口: 顶部状态条 + 配置界面
//

import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部状态条
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isConnected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(model.statusText)
                    .font(.headline)
                Spacer()
                if let l = model.latest {
                    Text("CPU \(Int(l.cpu.usage * 100))% · GPU \(Int((l.gpu.first?.utilization ?? 0) * 100))% · 内存 \(String(format: "%.0f GB", l.memory.usedGB))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // 更新提示条
            if let upd = model.updateAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.blue)
                    Text("发现新版本 \(upd.version)")
                        .font(.callout)
                    Spacer()
                    Button("下载更新") { model.downloadUpdate() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.12))
                Divider()
            }

            SettingsView(model: model)
        }
        .frame(minWidth: 480, idealWidth: 500, minHeight: 500, idealHeight: 640)
        // 设置窗口打开期间占 Dock (regular), 关闭窗口即收回 (accessory), 后台继续运行
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}
