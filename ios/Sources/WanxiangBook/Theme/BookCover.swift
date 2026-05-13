//
//  BookCover.swift
//  万象书屋 iOS · 通用封面视图
//
//  - 真 url 走 AsyncImage (含 Referer 头, 部分图床有防盗链)
//  - 失败 / 无 url → 占位
//

import SwiftUI
import UIKit

public struct BookCover: View {
    public let url: String?
    public let width: CGFloat
    public let height: CGFloat
    /// 万象书屋 (2026-05-11): 真 URL 加载失败 / 缺失时, 用 bookTitle 渲染彩色占位封面,
    /// 跟 Android `CoverImageView` 的"渐变 + 书名首字"占位行为对齐. 默认 nil = 用旧灰占位.
    public let bookTitle: String?
    @State private var image: UIImage?
    @State private var isLoading = false

    public init(url: String?, width: CGFloat, height: CGFloat, bookTitle: String? = nil) {
        self.url = url
        self.width = width
        self.height = height
        self.bookTitle = bookTitle
    }

    public var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if isLoading {
                placeholder.overlay(ProgressView().scaleEffect(0.6))
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: normalizedURLKey) {
            await load()
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let title = bookTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            // 彩色渐变 + 首字 (1-2 字), 跟 Android CoverImageView 同款.
            let palette = Self.colorPair(for: title)
            ZStack {
                LinearGradient(
                    colors: palette,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Text(String(title.prefix(2)))
                    .font(.system(size: max(12, min(width, height) * 0.32), weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 4)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(WanxiangColors.divider)
                .overlay(
                    Image(systemName: "book.closed.fill")
                        .foregroundStyle(WanxiangColors.textSecondary.opacity(0.5))
                )
        }
    }

    /// 万象书屋: 按书名哈希挑一组深浅相近的渐变色 (8 候选), 让占位看起来像真封面.
    private static func colorPair(for title: String) -> [Color] {
        let palettes: [(Color, Color)] = [
            (Color(red: 0.76, green: 0.42, blue: 0.34), Color(red: 0.52, green: 0.20, blue: 0.16)),
            (Color(red: 0.40, green: 0.52, blue: 0.72), Color(red: 0.18, green: 0.28, blue: 0.48)),
            (Color(red: 0.56, green: 0.42, blue: 0.68), Color(red: 0.32, green: 0.18, blue: 0.48)),
            (Color(red: 0.36, green: 0.60, blue: 0.50), Color(red: 0.16, green: 0.36, blue: 0.30)),
            (Color(red: 0.78, green: 0.58, blue: 0.34), Color(red: 0.52, green: 0.36, blue: 0.16)),
            (Color(red: 0.46, green: 0.46, blue: 0.55), Color(red: 0.24, green: 0.24, blue: 0.32)),
            (Color(red: 0.68, green: 0.36, blue: 0.50), Color(red: 0.44, green: 0.18, blue: 0.32)),
            (Color(red: 0.42, green: 0.62, blue: 0.68), Color(red: 0.20, green: 0.40, blue: 0.48)),
        ]
        var hasher = Hasher()
        hasher.combine(title)
        let idx = abs(hasher.finalize()) % palettes.count
        return [palettes[idx].0, palettes[idx].1]
    }

    private var normalizedURLKey: String {
        url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    @MainActor
    private func load() async {
        image = nil
        guard let request = Self.makeImageRequest(from: normalizedURLKey) else {
            isLoading = false
            return
        }
        let cacheKey = request.url?.absoluteString ?? normalizedURLKey
        // 1. 内存缓存
        if let cached = BookCoverImageCache.shared.image(for: cacheKey) {
            image = cached
            isLoading = false
            return
        }
        // 2. 磁盘缓存 (跟 Android Glide setDiskCache 1GB 行为对齐)
        if let disk = await BookCoverDiskCache.shared.load(key: cacheKey) {
            BookCoverImageCache.shared.set(disk, for: cacheKey)
            image = disk
            isLoading = false
            return
        }
        isLoading = true
        do {
            let (data, resp) = try await BookCoverImageSession.shared.data(for: request)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                isLoading = false
                return
            }
            // 3. 下采样到 cell 实际显示尺寸 (跟 Glide 自动 thumbnail 行为对齐)
            //    1MB 原图 → 50×70 缩略, 内存占用从几 MB → 几十 KB,
            //    decode 也快得多 (preparingThumbnail 用 ImageIO 单独 thumbnail pipeline).
            let target = CGSize(width: width * 2, height: height * 2)   // @2x retina
            let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
                guard let raw = UIImage(data: data) else { return nil }
                return await raw.byPreparingThumbnail(ofSize: target) ?? raw
            }.value
            guard let ui = decoded else {
                isLoading = false
                return
            }
            BookCoverImageCache.shared.set(ui, for: cacheKey)
            // 异步写磁盘 (不阻塞 UI)
            Task.detached(priority: .background) {
                await BookCoverDiskCache.shared.save(ui, key: cacheKey)
            }
            image = ui
        } catch {
            image = nil
        }
        isLoading = false
    }

    /// Legado 图片 URL 可写成 `https://img/x.jpg,{"headers":{"Referer":"..."}}`.
    /// AsyncImage 不能加 headers, 这里自定义 URLRequest:
    /// - 默认 UA: 避免部分站点拒空 UA / CF 拒绝
    /// - 默认 Referer: 同源首页
    /// - 合并 URL option.headers
    private static func makeImageRequest(from raw: String) -> URLRequest? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let (urlPart, optionHeaders) = splitImageOption(trimmed)
        guard let parsed = URL(string: urlPart) else { return nil }
        var req = URLRequest(url: parsed)
        // 万象书屋: 8s 比之前 20s 激进, 慢图床直接放弃, 让占位图保留 (跟 Glide DiskCacheStrategy + timeout 行为对齐)
        req.timeoutInterval = 8
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        req.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let scheme = parsed.scheme, let host = parsed.host {
            req.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        }
        for (k, v) in optionHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }
        return req
    }

    private static func splitImageOption(_ raw: String) -> (String, [String: String]) {
        guard let comma = raw.range(of: ",{") else { return (raw, [:]) }
        let urlPart = String(raw[..<comma.lowerBound])
        let opts = String(raw[raw.index(after: comma.lowerBound)...])
        guard let data = opts.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let headers = dict["headers"] as? [String: Any] else {
            return (urlPart, [:])
        }
        return (urlPart, headers.reduce(into: [String: String]()) { acc, pair in
            acc[pair.key] = String(describing: pair.value)
        })
    }
}

private final class BookCoverImageCache {
    static let shared = BookCoverImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        // 万象书屋 (M2.4 perf): 内存缓存提到 800 / 64MB.
        // 之前 300 / 24MB 在 32 源各 5+ 结果 = 150+ 封面时撑不住, 滚动列表频繁 evict + 重新 download.
        cache.countLimit = 800
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

/// 万象书屋 (M2.4 perf): 封面磁盘缓存 (跟 Android Glide `setDiskCache` 行为对齐).
/// 写在 Caches/ 目录, 系统在磁盘紧张时自动清, 不要用户手动管理.
/// 用 SHA256(url) 当文件名, 防止 url 含特殊字符 / 路径遍历.
private actor BookCoverDiskCache {
    static let shared = BookCoverDiskCache()
    private let dir: URL

    private init() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { fatalError("cachesDirectory unavailable") }
        let d = caches.appendingPathComponent("BookCover", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        self.dir = d
    }

    func load(key: String) async -> UIImage? {
        let url = dir.appendingPathComponent(filename(for: key))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func save(_ image: UIImage, key: String) async {
        let url = dir.appendingPathComponent(filename(for: key))
        // PNG 体积大但忠实度高; 跟 Glide 默认一致.
        // 已经 thumbnail 过, 单文件几十 KB, 写盘成本可接受.
        guard let data = image.pngData() else { return }
        try? data.write(to: url, options: .atomic)
    }

    private nonisolated func filename(for key: String) -> String {
        // 简单 hash: 用 hashValue 字符串 (不需要密码学强度, 只要避免冲突)
        var hasher = Hasher()
        hasher.combine(key)
        return "\(hasher.finalize()).img"
    }
}

/// 万象书屋 (M2.4 perf): 封面专用 URLSession.
/// - 跟搜索 / API 用的 URLSession 完全隔离, 避免封面下载抢搜索请求的 connection slot.
/// - max-per-host 16 (vs 默认 6), 同一图床 CDN 多并发拉.
/// - identity-encoding 默认 (有的图床给乱码 Content-Encoding 让 URLSession 解压报错).
private enum BookCoverImageSession {
    static let shared: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 16
        cfg.httpMaximumConnectionsPerHost = 16
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                diskCapacity: 256 * 1024 * 1024,
                                diskPath: "WanxiangCoverHTTPCache")
        return URLSession(configuration: cfg)
    }()
}
