// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "macmon",
    platforms: [.macOS(.v13)],
    targets: [
        // 核心采集/推送库: CLI 与 GUI App 共用
        .target(
            name: "MacmonCore",
            path: "Sources/MacmonCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreWLAN"),
            ]
        ),
        // CLI 工具 (后台 Agent / 单次探针)
        .executableTarget(
            name: "macmon",
            dependencies: ["MacmonCore"],
            path: "Sources/macmon",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreWLAN"),
            ]
        ),
        // macOS 菜单栏 App
        .executableTarget(
            name: "macmonapp",
            dependencies: ["MacmonCore"],
            path: "Sources/macmonapp",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreWLAN"),
            ]
        ),
    ]
)
