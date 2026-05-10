//
//  ChapterImageBlock.swift
//  万象书屋 iOS · 章节正文里的图片块 (M2.8 Gap 3)
//
//  对应 Android: ChapterProvider 在排版时遇到 ImageProvider 标识时的内联渲染
//
//  渲染流程:
//   1. 优先 ChapterImageCache.localFileURL — 已下载的就直接 disk
//   2. 没下载: AsyncImage 兜底从 URL 拉
//   3. 加载中显示 spinner + 占位框
//   4. 失败显示 [图片加载失败] 文本
//   5. 点击全屏弹大图 (ChapterImageFullscreen)
//

import SwiftUI

/// 章节正文里嵌入的图片块. 文本段落之间作为独立 block 显示.
struct ChapterImageBlock: View {
    let imageUrl: String
    let textColor: Color   // 跟正文颜色一致, 让占位/失败文字不突兀

    @State private var fullscreen: Bool = false
    @State private var loadedFromDisk: UIImage? = nil

    var body: some View {
        Button {
            fullscreen = true
        } label: {
            content
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .task { await tryLoadFromDisk() }
        .fullScreenCover(isPresented: $fullscreen) {
            ChapterImageFullscreen(imageUrl: imageUrl, preloaded: loadedFromDisk) {
                fullscreen = false
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let local = loadedFromDisk {
            Image(uiImage: local)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if let url = URL(string: imageUrl) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    placeholder(symbol: "photo", text: "加载中…")
                case .success(let img):
                    img.resizable().scaledToFit()
                        .frame(maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                case .failure:
                    placeholder(symbol: "photo.badge.exclamationmark", text: "图片加载失败")
                @unknown default:
                    placeholder(symbol: "photo", text: "")
                }
            }
        } else {
            placeholder(symbol: "photo.badge.exclamationmark", text: "无效图片地址")
        }
    }

    @ViewBuilder
    private func placeholder(symbol: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
            Text(text)
                .font(.caption)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .padding(.vertical, 16)
        .background(textColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(textColor.opacity(0.5))
    }

    private func tryLoadFromDisk() async {
        guard let local = await ChapterImageCache.shared.localFileURL(for: imageUrl) else { return }
        guard let data = try? Data(contentsOf: local) else { return }
        guard let img = UIImage(data: data) else { return }
        await MainActor.run { self.loadedFromDisk = img }
    }
}

/// 万象书屋: 点击章节内图片 → 全屏查看 + 双指捏合放大
struct ChapterImageFullscreen: View {
    let imageUrl: String
    let preloaded: UIImage?
    let onDismiss: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { v in scale = max(0.5, min(5, lastScale * v)) }
                        .onEnded { _ in lastScale = scale }
                )
                .onTapGesture(count: 2) {
                    withAnimation { scale = scale > 1.5 ? 1.0 : 2.5; lastScale = scale }
                }

            VStack {
                HStack {
                    Spacer()
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.85))
                            .background(Circle().fill(.black.opacity(0.4)))
                    }
                    .padding(.top, 50).padding(.trailing, 16)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let img = preloaded {
            Image(uiImage: img).resizable().scaledToFit()
        } else if let url = URL(string: imageUrl) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                case .failure:
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 48)).foregroundStyle(.white)
                        Text("图片加载失败").foregroundStyle(.white)
                    }
                default:
                    ProgressView().tint(.white).scaleEffect(1.5)
                }
            }
        }
    }
}

// MARK: - Text/Image 切片解析

/// 万象书屋 (M2.8 Gap 3): 把章节页文本按 `␎WX_IMG[url]␏` 标记切成 段.
/// .text 段直接 SwiftUI Text 渲染; .image 段用 ChapterImageBlock 渲染.
enum ChapterPageSegment: Identifiable {
    case text(String, id: String)
    case image(url: String, id: String)
    var id: String {
        switch self {
        case .text(_, let id), .image(_, let id): return id
        }
    }
}

func parseChapterPageSegments(_ pageText: String) -> [ChapterPageSegment] {
    let pattern = #"␎WX_IMG\[([^\]]+)\]␏"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return [.text(pageText, id: "all")]
    }
    let nsstr = pageText as NSString
    let matches = regex.matches(in: pageText, range: NSRange(0..<nsstr.length))
    if matches.isEmpty {
        return [.text(pageText, id: "all")]
    }
    var segs: [ChapterPageSegment] = []
    var cursor = 0
    var idx = 0
    for m in matches {
        if m.range.location > cursor {
            let chunk = nsstr.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segs.append(.text(chunk, id: "t\(idx)")); idx += 1
            }
        }
        if m.numberOfRanges > 1 {
            let url = nsstr.substring(with: m.range(at: 1))
            segs.append(.image(url: url, id: "i\(idx)")); idx += 1
        }
        cursor = m.range.location + m.range.length
    }
    if cursor < nsstr.length {
        let tail = nsstr.substring(with: NSRange(location: cursor, length: nsstr.length - cursor))
        if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segs.append(.text(tail, id: "t\(idx)"))
        }
    }
    return segs
}
