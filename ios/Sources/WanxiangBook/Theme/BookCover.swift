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
    @State private var image: UIImage?
    @State private var isLoading = false

    public init(url: String?, width: CGFloat, height: CGFloat) {
        self.url = url
        self.width = width
        self.height = height
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

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(WanxiangColors.divider)
            .overlay(
                Image(systemName: "book.closed.fill")
                    .foregroundStyle(WanxiangColors.textSecondary.opacity(0.5))
            )
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
        if let cached = BookCoverImageCache.shared.image(for: request.url?.absoluteString ?? normalizedURLKey) {
            image = cached
            isLoading = false
            return
        }
        isLoading = true
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                isLoading = false
                return
            }
            guard let ui = UIImage(data: data) else {
                isLoading = false
                return
            }
            BookCoverImageCache.shared.set(ui, for: request.url?.absoluteString ?? normalizedURLKey)
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
        req.timeoutInterval = 20
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
        cache.countLimit = 300
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}
