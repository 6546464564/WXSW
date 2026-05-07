//
//  JsLibCache.swift
//  万象书屋 iOS · jsLib / java.ajax 同步 fetch 缓存
//
//  对应 Android: io.legado.app.utils.ACache + okhttp 同步 newCall.
//
//  设计:
//   - 内存 + 磁盘 (Caches/wx_jslib/) 双层
//   - fetchSync(url) 用 URLSession + DispatchSemaphore 阻塞当前线程等结果
//     → 必须避免在 main thread / 主 actor 上调用!
//

import Foundation

public enum JsLibCache {

    private static let memCache = NSCache<NSString, NSString>()
    private static let cacheDir: URL = {
        let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let dir = urls[0].appendingPathComponent("wx_jslib", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    /// 万象书屋: jsLib 体积往往 < 100KB, 但谨防被恶意源塞 100MB 致内存爆
    private static let maxBodyBytes = 5 * 1024 * 1024

    public static func get(url: String) -> String? {
        if let mem = memCache.object(forKey: url as NSString) { return mem as String }
        let path = diskPath(for: url)
        if FileManager.default.fileExists(atPath: path.path) {
            if let s = try? String(contentsOf: path, encoding: .utf8) {
                memCache.setObject(s as NSString, forKey: url as NSString)
                return s
            }
        }
        return nil
    }

    /// 万象书屋: 同步 fetch (阻塞当前线程!). JSEngine 在 actor 内部调用,
    /// 多个源并行评估时各自的 actor instance 不互相阻塞.
    /// 注意: 不能在 main thread 上调用, 否则 UI 会卡死.
    public static func fetchSync(url: String) -> String? {
        if let cached = get(url: url) { return cached }
        guard let u = URL(string: url) else { return nil }

        let sema = DispatchSemaphore(value: 0)
        var body: String? = nil
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 12
        let session = URLSession(configuration: cfg)
        var req = URLRequest(url: u)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 万象书屋",
                     forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: req) { data, _, _ in
            defer { sema.signal() }
            guard let data = data, data.count <= maxBodyBytes else { return }
            body = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }
        task.resume()
        // 万象书屋: 给 12s 超时上限, 避免被恶意源吊死整条链
        let waitResult = sema.wait(timeout: .now() + 12)
        if waitResult == .timedOut {
            task.cancel()
            return nil
        }
        if let b = body, !b.isEmpty {
            memCache.setObject(b as NSString, forKey: url as NSString)
            try? b.write(to: diskPath(for: url), atomically: true, encoding: .utf8)
            return b
        }
        return nil
    }

    public static func clear() {
        memCache.removeAllObjects()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private static func diskPath(for url: String) -> URL {
        // md5 文件名
        let hash = md5Hex(url)
        return cacheDir.appendingPathComponent(hash + ".js")
    }
}
