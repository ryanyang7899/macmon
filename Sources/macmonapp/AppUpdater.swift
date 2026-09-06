//
//  AppUpdater.swift
//  自动更新: 锚定 GitHub 仓库的 release, 对比版本, 提供下载
//

import Foundation

struct UpdateInfo {
    let version: String      // 如 v0.0.1
    let downloadURL: URL
    let isPrerelease: Bool
    let notes: String?
}

enum AppUpdater {
    static let repoOwner = "ryanyang7899"
    static let repoName = "macmon"

    /// 当前 App 版本 (Info.plist CFBundleShortVersionString)
    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// 检查 GitHub 最新 release (含 pre-release), 比当前版本新则返回更新信息
    static func checkLatest() async throws -> UpdateInfo? {
        let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases?per_page=1")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("macmon-updater/1.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await fetchWithFallback(req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        struct Release: Decodable {
            let tag_name: String
            let prerelease: Bool
            let body: String?
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
            }
            let assets: [Asset]
        }

        let releases = try JSONDecoder().decode([Release].self, from: data)
        guard let latest = releases.first else { return nil }

        let tag = latest.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard compare(tag, currentVersion) > 0 else { return nil }

        guard let dmg = latest.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
              let dl = URL(string: dmg.browser_download_url) else { return nil }

        return UpdateInfo(version: latest.tag_name, downloadURL: dl,
                          isPrerelease: latest.prerelease, notes: latest.body)
    }

    /// 请求 GitHub API: 先直连, 失败 (网络不通/被墙) 时经本地代理 127.0.0.1:7890 重试
    private static func fetchWithFallback(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: req)
        } catch {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 10
            cfg.connectionProxyDictionary = [
                "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890,
                "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890,
            ]
            let proxied = URLSession(configuration: cfg)
            defer { proxied.finishTasksAndInvalidate() }
            return try await proxied.data(for: req)
        }
    }

    /// 简单版本号比较: a > b 返回 1, 相等 0, a < b 返回 -1
    static func compare(_ a: String, _ b: String) -> Int {
        let av = a.split(separator: ".").compactMap { Int($0) }
        let bv = b.split(separator: ".").compactMap { Int($0) }
        let n = max(av.count, bv.count)
        for i in 0..<n {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }
}
