import Foundation

// 仅供 BookSourceCLI 包在 macOS 上编译链接；App target 里这些类型都是真实定义，重复声明会编译失败
#if os(macOS)

extension Notification.Name {
    static let wanxiangMemoryWarning = Notification.Name("wanxiang.memoryWarning")
}

final class DebugActivityTracker: @unchecked Sendable {
    static let shared = DebugActivityTracker()
    func begin(_ tag: String) {}
    func end(_ tag: String) {}
    var snapshot: [String: Int] { [:] }
}

public struct ShelfBook {
    public var bookUrl: String
    public var name: String
    public var author: String
    public var origin: String
    public var originName: String
    public var coverUrl: String?
    public var lastChapter: String?
    public var intro: String?
    public var kind: String?
    public var tocUrl: String?
}

@MainActor
public final class BookSourceRegistry {
    public static let shared = BookSourceRegistry()
    public var sources: [BookSource] = []
}

public final class BookshelfRepository {
    public static let shared = BookshelfRepository()
    public func add(_ book: ShelfBook) async throws {}
    public func remove(bookUrl: String) async throws {}
}

#endif
