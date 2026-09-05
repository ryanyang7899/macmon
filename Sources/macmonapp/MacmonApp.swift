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
        Window("macmon 监控", id: "main") {
            MainView(model: model)
        }
        .windowResizability(.contentSize)

        // 菜单栏快捷入口
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Label(model.statusLabel, systemImage: "cpu")
        }
        .menuBarExtraStyle(.menu)
    }
}
