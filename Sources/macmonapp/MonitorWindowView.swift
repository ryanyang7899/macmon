//
//  MonitorWindowView.swift
//  窗口模式: 把菜单栏弹窗的监控内容显示为标准桌面窗口
//  可通过 📌 固定按钮置顶 (浮动层级 + 跨所有空间), 随时监控无需点开菜单栏
//

import SwiftUI
import AppKit
import MacmonCore

struct MonitorWindowView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pinned = false
    @State private var window: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏行: 标题 + 固定/关闭按钮
            HStack(spacing: 10) {
                Text("实时监控")
                    .font(.headline)
                Spacer()
                Button {
                    pinned.toggle()
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help(pinned ? "取消固定 (不再置顶)" : "固定在所有窗口最上层")
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("关闭窗口")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                MonitorContentView(model: model)
                    .padding(12)
            }
        }
        .frame(width: 320)
        .background(WindowAccessor(window: $window))
        .onChange(of: pinned) { _ in applyLevel() }
        .onAppear { applyLevel() }
    }

    /// 应用固定层级: 置顶 = 浮动窗口 + 跨所有空间
    private func applyLevel() {
        guard let w = window else { return }
        if pinned {
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            w.level = .normal
            w.collectionBehavior = []
        }
    }
}

/// 拿到宿主 NSWindow 引用
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { self.window = v.window }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { self.window = nsView.window }
    }
}
