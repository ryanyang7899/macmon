//
//  SettingsView.swift
//  配置界面: 服务器地址 / 设备名 / 注册码 / 采集间隔 / 开机自启
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

    var body: some View {
        Form {
            Section("服务器") {
                TextField("服务器地址", text: $server)
                    .textFieldStyle(.roundedBorder)
                    .help("例如 http://100.66.1.3:8080")
                TextField("设备名称", text: $deviceName)
                    .textFieldStyle(.roundedBorder)
                    .help("留空则用主机名, 例如 mac-xxx")
                SecureField("注册码 (首次接入时填写)", text: $setupKey)
                    .textFieldStyle(.roundedBorder)
                    .help("在 NAS 服务器的 SETUP_KEY 环境变量中设置")
            }

            Section("采集") {
                Stepper("采集间隔: \(Int(interval)) 秒", value: $interval, in: 2...60)
            }

            Section("系统") {
                Toggle("登录时自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        model.toggleLaunchAtLogin(on)
                    }
            }

            if let err = model.error {
                Text(err).foregroundColor(.red).font(.caption)
            }

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
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            server = model.config.serverURL ?? ""
            deviceName = model.config.deviceID
            interval = model.config.interval
            launchAtLogin = model.isLaunchAtLogin
        }
    }
}
