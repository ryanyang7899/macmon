//
//  Agent.swift
//  常驻 Agent 主循环: 定时采集 → 输出 JSON (stdout 或文件)
//  M2 将在这里加入 WebSocket 推送 (Transmitter)
//

import Foundation
import Darwin

public final class Agent {
    private let config: AgentConfig
    private let outFile: String?
    private let verbose: Bool
    private var running = true
    private let transmitter: Transmitter?
    private var fanPoller: FanCommandPoller?
    private var signalSources: [DispatchSourceSignal] = []

    public init(config: AgentConfig, outFile: String?, verbose: Bool) {
        self.config = config
        self.outFile = outFile
        self.verbose = verbose
        // M2: 配置了 serverURL 且非空时, 启用推送
        if let urlStr = config.serverURL, !urlStr.isEmpty,
           let url = URL(string: urlStr) {
            self.transmitter = Transmitter(serverURL: url, token: config.token ?? "", deviceID: config.deviceID)
        } else {
            self.transmitter = nil
        }
    }

    /// 开始常驻采集
    public func run() {
        installSignalHandlers()

        // 接收服务器下发的远程风扇指令 (需要本机已安装 helper)
        if let urlStr = config.serverURL, let url = URL(string: urlStr),
           let token = config.token, !token.isEmpty {
            let poller = FanCommandPoller(serverURL: url, token: token, deviceID: config.deviceID)
            poller.start()
            fanPoller = poller
        }

        if verbose {
            print("[macmon] agent 启动 device=\(config.deviceID) interval=\(config.interval)s")
            fflush(stdout)
        }

        // 首次立即采集一次
        collectAndEmit()

        while running {
            let start = Date()
            let wait = config.interval - Date().timeIntervalSince(start)
            if wait > 0 {
                Thread.sleep(forTimeInterval: wait)
            }
            collectAndEmit()
        }
    }

    private func collectAndEmit() {
        let result = collectOnce(sampleIntervalSeconds: min(1.0, config.interval / 2))

        // M2: 推送到远程服务器
        if let tx = transmitter, tx.isConfigured {
            tx.send(result)
        }

        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(result),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        // 始终输出到 stdout
        FileHandle.standardOutput.write(Data(line.utf8))
        if verbose { fflush(stdout) }

        // 可选: 追加到文件 (每行一个 JSON, 便于外部消费)
        if let outFile {
            if let handle = FileHandle(forWritingAtPath: outFile) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: outFile, contents: Data(line.utf8))
            }
        }
    }

    /// 用 DispatchSourceSignal 而不是 signal(): 信号处理器里不能安全调用 Foundation,
    /// 而退出前需要把被远程强制的风扇交还系统。
    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue(label: "macmon.signal"))
            source.setEventHandler { [weak self] in
                self?.fanPoller?.resetLocalFans()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
