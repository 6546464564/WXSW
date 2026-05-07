//
//  RarImporter.swift
//  万象书屋 iOS · RAR 文件导入 (M2.8.1.6)
//
//  RAR 决策:
//   - 标准 RAR 5 是闭源算法 + RarLab 商业许可, Swift 生态没成熟纯 Swift 库.
//   - C 库 UnRAR 是 LGPL 风格半开源, 集成会引入二进制风险, App Store 审核也敏感.
//   - 实际使用场景: 99% 用户是 zip/epub, RAR 是边缘需求.
//
//  万象书屋方案 (跟 Android 端对齐, 安卓也是 ALERT 让用户用文件 App 解压):
//   1. 检测 .rar / .cbr 后缀 → 弹引导
//   2. 提示: "RAR 暂不支持. 请用 iOS 文件 App 长按 → 解压, 再导入解压后的文件."
//   3. 提供"打开文件 App"的快捷入口
//
//  v1.x 后续: 评估接 UnRARKit (CocoaPods) 或自写 RAR4 inflate.
//

import Foundation
import UIKit

enum RarImporter {

    enum ImportResult {
        case unsupported(reason: String)
    }

    static func handle(url: URL) -> ImportResult {
        // 万象书屋: 给一个统一的不支持说明
        return .unsupported(
            reason: """
            RAR / CBR 暂不支持.

            iOS 系统不内置 RAR 解码, 且 RAR 算法是闭源商业格式.
            
            请按以下任一方式处理:
            
            1. 用 iOS 自带的「文件」App, 长按文件 → 选择「解压缩」
            2. 用「The Unarchiver」或「iZip」等第三方解压工具
            3. 解压后用 ZIP / EPUB / TXT 格式导入万象书屋
            """
        )
    }

    /// 打开 iOS 系统文件 App
    @MainActor
    static func openFilesApp() {
        if let url = URL(string: "shareddocuments://"),
           UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
}
