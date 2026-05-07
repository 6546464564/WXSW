// swift-tools-version: 5.9
//
// 万象书屋 · BookSource 引擎独立 SwiftPM 包
//
// 用途:
//  - 让 M1 书源引擎能在 macOS 上跑命令行测试 (不依赖 iOS 模拟器 runtime)
//  - 作为 M1-14 端到端 CLI 验证工具
//  - 长期: iOS App 也通过 SwiftPM 引这个包, 避免源文件双份同步
//
// 用法:
//   cd ios/BookSourceCLI
//   swift run BookSourceCLI search --source PATH/TO/source.json --key 关键字
//
import PackageDescription

let package = Package(
    name: "BookSourceCLI",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "BookSource", targets: ["BookSource"]),
        .executable(name: "BookSourceCLI", targets: ["BookSourceCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.7.5"),
    ],
    targets: [
        .target(
            name: "BookSource",
            dependencies: ["SwiftSoup"],
            path: "Sources/BookSource"   // 实际是 symlink → ../../Sources/WanxiangBook/BookSource
        ),
        .executableTarget(
            name: "BookSourceCLI",
            dependencies: ["BookSource"],
            path: "Sources/BookSourceCLI"
        ),
        .testTarget(
            name: "BookSourceTests",
            dependencies: ["BookSource", "SwiftSoup"],
            path: "Tests/BookSourceTests"
        ),
    ]
)
