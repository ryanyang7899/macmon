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
            // 迷你控制行: 仅固定/关闭按钮 (位于安全区内, 不会被系统标题栏层遮挡)
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
            .padding(.top, 2)
            .padding(.bottom, 2)

            ScrollView {
                MonitorContentView(model: model)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        // 自适应宽度: 跟随窗口横向大小, 最小 300
        .frame(minWidth: 300, idealWidth: 340, maxWidth: .infinity)
        // 右下角拖拽把手: 无边框窗口没有边缘热区, 用把手拖拽调整窗口大小
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip(minWidth: 300, minHeight: 220)
                .frame(width: 18, height: 18)
                .padding(3)
        }
        // 玻璃背景铺满整窗 (含标题栏区域, 标题栏已透明化)
        .background(FrostedGlassBackground().ignoresSafeArea())
        .background(WindowAccessor(window: $window, configure: configureWindow))
        .onChange(of: pinned) { _ in applyLevel() }
        .onAppear { applyLevel() }
    }

    /// 无边框窗口: 无系统标题栏 (用户明确偏好, 可接受获焦时的矩形描边)
    /// 玻璃背景铺满, 背景可拖动
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

/// 拖拽调整窗口大小的把手 (无边框窗口没有边缘热区, 需自行实现)
/// 放在右下角, 按住拖动即可横/纵向调整; 拖动期间锚定窗口左上角
struct ResizeGrip: NSViewRepresentable {
    var minWidth: CGFloat
    var minHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        GripView(minWidth: minWidth, minHeight: minHeight)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class GripView: NSView {
        let minWidth: CGFloat
        let minHeight: CGFloat
        private var startFrame: NSRect?
        private var startLoc: NSPoint?

        init(minWidth: CGFloat, minHeight: CGFloat) {
            self.minWidth = minWidth
            self.minHeight = minHeight
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

        // 拖把手时不要触发窗口整体拖动 (isMovableByWindowBackground)
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            startFrame = window?.frame
            startLoc = NSEvent.mouseLocation
        }

        override func mouseDragged(with event: NSEvent) {
            guard let w = window, let sf = startFrame, let sl = startLoc else { return }
            let cur = NSEvent.mouseLocation
            var f = sf
            // 宽度: 光标水平位移直接加到宽度上
            f.size.width = max(minWidth, sf.width + (cur.x - sl.x))
            // 高度: 光标下移 = 缩小, 同时保持窗口顶边不动
            let newHeight = max(minHeight, sf.height - (cur.y - sl.y))
            f.origin.y = sf.origin.y + sf.height - newHeight
            f.size.height = newHeight
            w.setFrame(f, display: true, animate: false)
        }

        override func mouseUp(with event: NSEvent) {
            startFrame = nil
            startLoc = nil
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }
}
