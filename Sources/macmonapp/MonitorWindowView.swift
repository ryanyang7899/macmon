//
//  MonitorWindowView.swift
//  窗口模式: 把菜单栏弹窗的监控内容显示为标准桌面窗口
//  外观: 与菜单栏弹窗一致的磨砂玻璃效果 (macOS 26 用 NSGlassEffectView 液态玻璃, 低版本回退 NSVisualEffectView)
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
            // 迷你控制行: 仅固定/关闭按钮 (标题文字移除, 系统标题栏预留区已被吃掉)
            HStack(spacing: 6) {
                Spacer()
                Button {
                    pinned.toggle()
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(pinned ? "取消固定 (不再置顶)" : "固定在所有窗口最上层")
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("关闭窗口")
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 2)

            ScrollView {
                MonitorContentView(model: model)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .frame(width: 320)
        // 玻璃背景铺满整窗
        .background(FrostedGlassBackground().ignoresSafeArea())
        .background(WindowAccessor(window: $window, configure: configureWindow))
        .onChange(of: pinned) { _ in applyLevel() }
        .onAppear { applyLevel() }
    }

    /// 无边框窗口: 彻底移除系统标题栏 (红绿灯区域不复存在), 玻璃背景铺满, 背景可拖动
    private func configureWindow(_ w: NSWindow) {
        w.styleMask = [.borderless, .resizable]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.isMovableByWindowBackground = true
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

/// 磨砂玻璃背景: macOS 26 液态玻璃, 低版本回退自适应磨砂
struct FrostedGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            return NSGlassEffectView()
        } else {
            let v = NSVisualEffectView()
            v.material = .menu               // 自适应明暗, 与菜单栏弹窗观感一致
            v.blendingMode = .behindWindow
            v.state = .active
            return v
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 拿到宿主 NSWindow 引用并做一次性配置
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?
    var configure: ((NSWindow) -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let w = v.window {
                configure?(w)
                window = w
            }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
