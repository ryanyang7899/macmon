//
//  SettingsView.swift
//  配置界面: 服务器 / 采集 / 菜单栏监控 / 显示条目 / 系统
//  布局: ScrollView 分组卡片 (支持滚轮滚动), 连接状态与按钮固定底部
//

import SwiftUI
import MacmonCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var server = ""
    @State private var deviceName = ""
    @State private var setupKey = ""
    @State private var interval = 5.0
    @State private var launchAtLogin = false
    @State private var monitorSelection: Set<String> = []
    @State private var itemSelection: Set<String> = []
    @State private var itemOrder: [String] = []
    @State private var draggingItem: String?

    var body: some View {
        VStack(spacing: 0) {
            // 可滚动内容区 (支持鼠标滚轮)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    serverSection
                    collectSection
                    monitorDevicesSection
                    monitorItemsSection
                    systemSection
                    if let err = model.error {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
                .padding(20)
            }

            Divider()

            // 固定底部: 连接状态 + 连接按钮
            HStack {
                if model.isConnected {
                    Label("已连接 · \(model.config.serverURL ?? "")", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                } else {
                    Label("未连接", systemImage: "circle.dashed")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
                Spacer()
                Button("连接并开始采集") {
                    Task { await model.saveAndConnect(server: server, deviceName: deviceName,
                                                      setupKey: setupKey, interval: interval) }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onAppear {
            server = model.config.serverURL ?? ""
            deviceName = model.config.deviceID
            interval = model.config.interval
            launchAtLogin = model.isLaunchAtLogin
            monitorSelection = Set(model.config.monitorDevices ?? [])
            itemOrder = model.config.monitorItems ?? AgentConfig.allItems
            itemSelection = Set(itemOrder)
            Task { await model.loadMonitorDevices() }
        }
    }

    // MARK: - 分组卡片

    private func section<Content: View>(_ title: String, icon: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        } label: {
            Label(title, systemImage: icon)
                .font(.headline)
                .padding(.bottom, 2)
        }
    }

    /// 标签 + 输入框的行
    private func fieldRow(_ label: String, help: String = "", @ViewBuilder field: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(width: 72, alignment: .leading)
            field()
        }
        .help(help)
    }

    // MARK: - 服务器

    private var serverSection: some View {
        section("服务器", icon: "server.rack") {
            fieldRow("服务器地址", help: "例如 http://100.66.1.3:8080") {
                TextField("http://", text: $server)
                    .textFieldStyle(.roundedBorder)
            }
            fieldRow("设备名称", help: "留空则用主机名, 例如 mac-xxx") {
                TextField("留空用主机名", text: $deviceName)
                    .textFieldStyle(.roundedBorder)
            }
            fieldRow("注册码", help: "在 NAS 服务器的 SETUP_KEY 环境变量中设置") {
                SecureField("首次接入时填写", text: $setupKey)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - 采集

    private var collectSection: some View {
        section("采集", icon: "timer") {
            Stepper(value: $interval, in: 2...60) {
                HStack {
                    Text("采集间隔").font(.callout).foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(interval)) 秒").fontWeight(.medium)
                }
            }
            .help("两次采集推送之间的间隔")
        }
    }

    // MARK: - 被监控机器

    private var monitorDevicesSection: some View {
        section("被监控机器 (菜单栏实时显示)", icon: "display") {
            if model.monitorDeviceList.isEmpty {
                if let err = model.monitorError {
                    Text(err).font(.caption).foregroundColor(.red)
                } else {
                    Text("正在加载设备列表…").font(.caption).foregroundColor(.secondary)
                }
            } else {
                ForEach(model.monitorDeviceList, id: \.name) { dev in
                    Toggle(dev.name, isOn: monitorBinding(for: dev.name))
                }
            }
            HStack {
                Spacer()
                Button("刷新设备列表") {
                    Task { await model.loadMonitorDevices() }
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - 菜单栏显示条目

    private var monitorItemsSection: some View {
        section("菜单栏显示条目 (勾选显示, 拖动右侧 ≡ 排序)", icon: "chart.xyaxis.line") {
            ForEach(itemOrder, id: \.self) { item in
                HStack {
                    Toggle(Self.itemName(item), isOn: itemBinding(for: item))
                    Spacer()
                    Image(systemName: "line.3.horizontal")
                        .foregroundColor(.secondary)
                        .help("拖动调整顺序")
                        .onDrag {
                            draggingItem = item
                            return NSItemProvider(object: item as NSString)
                        }
                }
                .onDrop(of: [.text], delegate: ItemDropDelegate(
                    itemOrder: $itemOrder,
                    target: item,
                    draggingItem: $draggingItem,
                    onChange: { syncItems() }
                ))
            }
            if itemSelection.isEmpty {
                Text("未勾选任何条目, 菜单栏将只显示状态卡")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 系统

    private var systemSection: some View {
        section("系统", icon: "gearshape") {
            Toggle("登录时自动启动", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { on in
                    model.toggleLaunchAtLogin(on)
                }
        }
    }

    // MARK: - 数据绑定

    /// 条目显示名
    private static func itemName(_ item: String) -> String {
        switch item {
        case "cpu": return "CPU 占用"
        case "memory": return "内存"
        case "temp": return "温度"
        case "network": return "网络速率"
        case "battery": return "电池"
        case "gpu": return "GPU"
        default: return item
        }
    }

    /// 设备勾选的 Binding: 变化时同步到 model 并持久化
    private func monitorBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { monitorSelection.contains(name) },
            set: { on in
                if on {
                    monitorSelection.insert(name)
                } else {
                    monitorSelection.remove(name)
                }
                model.setMonitorSelection(Array(monitorSelection))
            }
        )
    }

    /// 条目勾选的 Binding: 变化时同步到 model 并持久化 (顺序按 itemOrder)
    private func itemBinding(for item: String) -> Binding<Bool> {
        Binding(
            get: { itemSelection.contains(item) },
            set: { on in
                if on { itemSelection.insert(item) } else { itemSelection.remove(item) }
                syncItems()
            }
        )
    }

    /// 把当前顺序 + 勾选状态持久化
    private func syncItems() {
        model.setMonitorItems(itemOrder.filter { itemSelection.contains($0) })
    }
}

/// 条目拖放排序委托: 拖动经过目标行时实时移动顺序
private struct ItemDropDelegate: DropDelegate {
    @Binding var itemOrder: [String]
    let target: String
    @Binding var draggingItem: String?
    let onChange: () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingItem, dragging != target,
              let from = itemOrder.firstIndex(of: dragging),
              let to = itemOrder.firstIndex(of: target) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            itemOrder.move(fromOffsets: IndexSet(integer: from),
                           toOffset: to > from ? to + 1 : to)
        }
        onChange()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingItem = nil
        onChange()
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggingItem != nil
    }
}
