#!/usr/bin/env swift
//
//  overlay-screenshots.swift
//  万象书屋 · App Store 截图叠图脚本
//
//  原图 → 叠 万象棕金色块 + 大标题 + 副标题 → 输出
//
//  用法:
//    cd ios/scripts && swift overlay-screenshots.swift
//
//  输出: ../../screenshots/store/{bookshelf,bookstore,my}.png (1290x2796 iPhone 17 Pro Max)
//

import AppKit
import Foundation

// 万象棕金色
let primaryColor = NSColor(red: 0xB8/255.0, green: 0x95/255.0, blue: 0x6B/255.0, alpha: 1)
let parchment = NSColor(red: 0xF5/255.0, green: 0xEF/255.0, blue: 0xE6/255.0, alpha: 1)
let darkText = NSColor(red: 0x3C/255.0, green: 0x2E/255.0, blue: 0x1F/255.0, alpha: 1)

struct StoreShot {
    let source: String
    let title: String
    let subtitle: String
    let output: String
}

let shots: [StoreShot] = [
    .init(source: "bookshelf.png",
          title: "古韵新读\n万象书屋",
          subtitle: "TXT · EPUB · MOBI · UMD · PDF\n本地离线 · 自动切章 · 沉浸阅读",
          output: "01_bookshelf.png"),
    .init(source: "bookstore.png",
          title: "海量正版精选\n书城天天推荐",
          subtitle: "玄幻 · 都市 · 经典 · 排行 · 完结\n精排封面 · 一键加书架",
          output: "02_bookstore.png"),
    .init(source: "my.png",
          title: "深度护眼模式\n陪你读到天荒",
          subtitle: "暖色护眼 · 仿真翻页 · 听书有声\n云端同步 · 无障碍 · 完全免费",
          output: "03_my.png"),
]

let here = FileManager.default.currentDirectoryPath
let projectRoot = (here as NSString).deletingLastPathComponent.appending("/..")
let srcDir = projectRoot + "/screenshots"
let outDir = projectRoot + "/screenshots/store"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func loadImage(_ path: String) -> NSImage? {
    return NSImage(contentsOfFile: path)
}

func saveImage(_ image: NSImage, to path: String) -> Bool {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? data.write(to: URL(fileURLWithPath: path))) != nil
}

func overlay(_ shot: StoreShot) {
    let srcPath = "\(srcDir)/\(shot.source)"
    guard let src = loadImage(srcPath) else {
        print("跳过 (找不到): \(srcPath)")
        return
    }
    // App Store 标准: iPhone 6.9" → 1290 x 2796
    let canvasSize = NSSize(width: 1290, height: 2796)
    let canvas = NSImage(size: canvasSize)
    canvas.lockFocus()

    // 1. 米色羊皮纸背景
    parchment.setFill()
    NSRect(origin: .zero, size: canvasSize).fill()

    // 2. 顶部棕金渐变标题区 (高度 720)
    let titleArea = NSRect(x: 0, y: canvasSize.height - 760, width: canvasSize.width, height: 760)
    let gradient = NSGradient(colors: [
        primaryColor,
        primaryColor.blended(withFraction: 0.3, of: .white)!,
    ])!
    gradient.draw(in: titleArea, angle: -90)

    // 3. 主标题
    let titleFont = NSFont(name: "PingFangSC-Heavy", size: 110)
        ?? NSFont.systemFont(ofSize: 110, weight: .heavy)
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: titleFont,
        .foregroundColor: NSColor.white,
        .paragraphStyle: {
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            p.lineSpacing = 12
            return p
        }(),
        .shadow: {
            let s = NSShadow()
            s.shadowColor = NSColor(white: 0, alpha: 0.25)
            s.shadowOffset = NSSize(width: 0, height: -4)
            s.shadowBlurRadius = 8
            return s
        }(),
    ]
    let titleStr = shot.title as NSString
    let titleRect = NSRect(x: 60, y: canvasSize.height - 480, width: canvasSize.width - 120, height: 320)
    titleStr.draw(in: titleRect, withAttributes: titleAttrs)

    // 4. 副标题
    let subFont = NSFont(name: "PingFangSC-Medium", size: 44)
        ?? NSFont.systemFont(ofSize: 44, weight: .medium)
    let subAttrs: [NSAttributedString.Key: Any] = [
        .font: subFont,
        .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        .paragraphStyle: {
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            p.lineSpacing = 8
            return p
        }(),
    ]
    let subStr = shot.subtitle as NSString
    let subRect = NSRect(x: 60, y: canvasSize.height - 700, width: canvasSize.width - 120, height: 200)
    subStr.draw(in: subRect, withAttributes: subAttrs)

    // 5. 截图缩放居中放下方 (留 100 上 + 80 底)
    let screenshotMaxHeight = canvasSize.height - 760 - 100 - 80
    let originalSize = src.size
    let aspect = originalSize.width / originalSize.height
    let scaledHeight = screenshotMaxHeight
    let scaledWidth = scaledHeight * aspect
    let shotRect = NSRect(
        x: (canvasSize.width - scaledWidth) / 2,
        y: 80,
        width: scaledWidth,
        height: scaledHeight
    )
    // 加圆角阴影
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 30
    shadow.set()
    let path = NSBezierPath(roundedRect: shotRect, xRadius: 50, yRadius: 50)
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    // clip + 画图
    NSGraphicsContext.current?.saveGraphicsState()
    path.setClip()
    src.draw(in: shotRect)
    NSGraphicsContext.current?.restoreGraphicsState()

    canvas.unlockFocus()

    let outPath = "\(outDir)/\(shot.output)"
    if saveImage(canvas, to: outPath) {
        print("✓ \(outPath)")
    } else {
        print("✗ \(outPath) 写入失败")
    }
}

print("=== 万象书屋 App Store 截图合成 ===")
print("原图目录: \(srcDir)")
print("输出目录: \(outDir)")
print("")

for shot in shots {
    overlay(shot)
}

print("\n完成. 文件大小:")
let task = Process()
task.launchPath = "/bin/ls"
task.arguments = ["-lh", outDir]
try? task.run()
task.waitUntilExit()
