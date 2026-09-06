//
//  MacmonApp.swift
//  macmonapp 入口: 菜单栏常驻 + 按需打开的设置窗口
//
//  行为:
//  - 启动不打开设置窗口 (macOS 15+ suppressed; 更早系统由 accessory 策略隐藏)
//  - 默认不占 Dock (accessory); 打开设置窗口时出现 Dock 图标, 关闭即消失
//  - 关闭设置窗口后 App 仍在后台运行, 菜单栏图标常驻
//

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动即为 accessory: 不占 Dock, 菜单栏图标照常显示
        NSApp.setActivationPolicy(.accessory)
        // SwiftUI Window 场景启动时会自动创建主窗口: 立即关掉,
        // 之后由菜单栏"设置…"按需打开 (openWindow 会重新显示)
        DispatchQueue.main.async {
            NSApp.windows
                .filter { $0.title == "macmon 监控" }
                .forEach { $0.orderOut(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // 关闭设置窗口后继续后台运行 (采集推送不停)
    }
}

@main
struct MacmonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        // 菜单栏常驻入口 (window 样式: 渲染完整 SwiftUI 视图, 支持图表)
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Label(model.statusLabel, systemImage: "cpu")
        }
        .menuBarExtraStyle(.window)

        // 设置窗口: 启动时由 AppDelegate 立即收起, 由菜单栏"设置…"按钮按需打开
        settingsWindow

        // 窗口模式: 监控内容显示为标准窗口, 可固定置顶 (仅由"窗口模式"按钮打开, 不随启动创建)
        Window("实时监控", id: "monitor") {
            MonitorWindowView(model: model)
        }
        .windowResizability(.contentMinSize)
    }

    private var settingsWindow: some Scene {
        Window("macmon 监控", id: "main") {
            MainView(model: model)
        }
        .windowResizability(.contentMinSize)
    }
}
