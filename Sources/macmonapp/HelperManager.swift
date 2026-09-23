//
//  HelperManager.swift
//  本机 macmonhelper (root 组件) 的安装 / 卸载 / 状态自检。
//
//  注意分工:
//    - 本文件只管"这台机器"的组件 —— 远程风扇控制需要被监控设备各自安装
//    - 远端风扇的下发在 RemoteFanControl.swift
//

import Foundation
import MacmonCore
import SwiftUI

enum HelperState: Equatable {
    case unknown            // 还没探测
    case notInstalled       // 未安装
    case running            // 已安装且在跑
    case versionMismatch    // 已安装但协议版本不一致, 需要重装
    case failed(String)     // 安装/连接失败

    var label: String {
        switch self {
        case .unknown: return "检测中…"
        case .notInstalled: return "未安装"
        case .running: return "已安装"
        case .versionMismatch: return "需要更新"
        case .failed(let msg): return "异常: \(msg)"
        }
    }

    var isUsable: Bool {
        if case .running = self { return true }
        return false
    }
}

@MainActor
final class HelperManager: ObservableObject {
    @Published var state: HelperState = .unknown
    @Published var isBusy = false
    @Published var lastError: String?
    /// 本机风扇只读状态 (用于确认组件确实在工作)
    @Published var localFans: [FanInfo] = []

    private let connection = HelperConnection()
    /// 探测令牌: 收到回复后置 nil, 超时回调据此判断是否已回复
    private var probeToken: UUID?

    // MARK: - 探测

    func refresh() {
        let token = UUID()
        probeToken = token

        connection.snapshot(timeout: 3) { [weak self] fans in
            Task { @MainActor in
                guard let self, self.probeToken == token else { return }
                self.probeToken = nil
                self.localFans = fans
                self.state = fans.isEmpty ? .notInstalled : .running
            }
        }

        // 组件没装或没起来时不会回调, 超时后按文件存在性给结论
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, self.probeToken == token else { return }
            self.probeToken = nil
            if HelperConnection.isInstalled {
                self.state = .failed("组件未运行, 可重新安装")
            } else {
                self.state = .notInstalled
            }
        }
    }

    // MARK: - 安装 / 卸载

    func install() {
        guard let script = Bundle.main.path(forResource: "install-helper", ofType: "sh") else {
            state = .failed("找不到安装脚本")
            return
        }
        isBusy = true
        lastError = nil
        runPrivileged(script) { [weak self] ok, output in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                if ok {
                    self.state = .unknown
                    self.retryProbe(remaining: 4)
                } else {
                    self.state = .failed(Self.brief(output))
                    self.lastError = Self.brief(output)
                }
            }
        }
    }

    func uninstall() {
        guard let script = Bundle.main.path(forResource: "uninstall-helper", ofType: "sh") else {
            state = .failed("找不到卸载脚本")
            return
        }
        isBusy = true
        lastError = nil
        runPrivileged(script) { [weak self] ok, output in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.localFans = []
                if ok {
                    self.state = .notInstalled
                } else {
                    self.state = .failed(Self.brief(output))
                }
            }
        }
    }

    /// 安装后 daemon 注册需要一点时间, 失败则重试若干次
    private func retryProbe(remaining: Int) {
        refresh()
        guard remaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.state.isUsable else { return }
            self.retryProbe(remaining: remaining - 1)
        }
    }

    /// 用 osascript 请求管理员权限执行脚本
    private func runPrivileged(_ scriptPath: String, completion: @escaping (Bool, String) -> Void) {
        let escaped = scriptPath.replacingOccurrences(of: "\\", with: "\\\\")
                                .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\\\"\(escaped)\\\"\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            completion(false, error.localizedDescription)
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        // 用户点了"取消"时 osascript 返回 -128
        if process.terminationStatus == 0 {
            completion(true, output)
        } else if output.contains("-128") {
            completion(false, "已取消授权")
        } else {
            completion(false, output.isEmpty ? "退出码 \(process.terminationStatus)" : output)
        }
    }

    private static func brief(_ output: String) -> String {
        let line = output.split(separator: "\n").last.map(String.init) ?? output
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
