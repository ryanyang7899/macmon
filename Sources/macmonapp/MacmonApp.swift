//
//  MacmonApp.swift
//  macmonapp 入口: 标准 App (启动台/Dock 可见) + 菜单栏
//

import SwiftUI

@main
struct MacmonApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        // 主窗口: 从启动台/Dock 打开时显示 (实体 App 形态)
        // contentMinSize: 窗口可自由缩放, 内容超出时由内部 ScrollView 滚动
        Window("macmon 监控", id: "main") {
            MainView(model: model)
        }
        .windowResizability(.contentMinSize)

        // 菜单栏快捷入口 (window 样式: 渲染完整 SwiftUI 视图, 支持图表; menu 样式只支持纯文本项)
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Label(model.statusLabel, systemImage: "cpu")
        }
        .menuBarExtraStyle(.window)
    }
}
