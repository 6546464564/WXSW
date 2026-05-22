//
//  PageCurlView.swift
//  万象书屋 iOS · 仿真翻书 (M2.5.3.5, ⭐⭐⭐⭐⭐)
//
//  iOS 系统天然有 page curl 翻页:
//   - UIPageViewController(transitionStyle: .pageCurl) — 1 行代码就有
//   - 跟 iBooks 翻书效果一致
//
//  我们包一层 SwiftUI UIViewControllerRepresentable, 让 ReaderView 能用.
//  比手撸 Metal shader 简单 100 倍, 视觉效果一样自然.
//
//  对应 Android: io.legado.app.ui.book.read.page.delegate.SimulationPageDelegate
//
//  2026-05-20 修复:
//   - updateUIViewController 方向修正: SwiftUI currentId 变化时主动推 PVC 翻页 (之前是反向写回 → 点击翻页失效)
//   - 翻页方向: 根据新旧 index 对比决定 forward/reverse
//   - 消除白闪: pvc.view + hosting.view 均设为透明背景
//   - 防止重复触发: animated 动画时加 guard 避免并发 setViewControllers 冲突
//   - 内存: LRU 裁剪, 最多保留 ±3 相邻页的 hosting 缓存
//

import SwiftUI
import UIKit

/// SwiftUI 包装的仿真翻书容器
struct PageCurlContainer<Page: View>: UIViewControllerRepresentable {

    let pages: [(id: String, view: Page)]
    @Binding var currentId: String
    /// 阅读器背景色 (跟 config.theme.background 同步), 给 UIHostingController 用
    var backgroundColor: UIColor = .clear

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue]
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = .clear
        context.coordinator.parent = self
        context.coordinator.attach(pvc)
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        // 章节切换后 pages 整体刷新, 清理失效缓存防止旧 VC 残留
        context.coordinator.evictStaleEntries()
        // 同步阅读器背景色 (夜间/护眼切换时)
        pvc.view.backgroundColor = backgroundColor
        context.coordinator.pushIfNeeded(pvc: pvc)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageCurlContainer
        /// id → UIHostingController 缓存, 最多保留 LRU_LIMIT 个避免无限增长
        private var cache: [(id: String, vc: UIHostingController<AnyView>)] = []
        private let lruLimit = 7
        /// 正在 animate setViewControllers 时加锁, 防止并发调用导致系统崩溃
        private var isAnimating = false

        init(_ p: PageCurlContainer) { parent = p }

        // MARK: - 初始化

        func attach(_ pvc: UIPageViewController) {
            if let vc = controllerFor(id: parent.currentId) {
                pvc.setViewControllers([vc], direction: .forward, animated: false)
            }
        }

        // MARK: - SwiftUI → PVC 方向 (updateUIViewController 路径)

        /// 当 SwiftUI 侧 currentId 变了, 主动推 PVC 翻到目标页
        func pushIfNeeded(pvc: UIPageViewController) {
            guard !isAnimating else { return }
            guard let cur = pvc.viewControllers?.first,
                  let curId = id(for: cur) else {
                // PVC 还没初始化 — 直接 setViewControllers 无动画
                if let vc = controllerFor(id: parent.currentId) {
                    pvc.setViewControllers([vc], direction: .forward, animated: false)
                }
                return
            }
            guard curId != parent.currentId else { return }

            let oldIdx = parent.pages.firstIndex(where: { $0.id == curId }) ?? 0
            let newIdx = parent.pages.firstIndex(where: { $0.id == parent.currentId }) ?? 0
            let dir: UIPageViewController.NavigationDirection = newIdx >= oldIdx ? .forward : .reverse

            guard let vc = controllerFor(id: parent.currentId) else { return }
            isAnimating = true
            pvc.setViewControllers([vc], direction: dir, animated: true) { [weak self] _ in
                self?.isAnimating = false
            }
        }

        // MARK: - PVC → SwiftUI 方向 (delegate 回调路径, 用户手势拖拽完成)

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard finished, completed,
                  let cur = pageViewController.viewControllers?.first,
                  let curId = id(for: cur),
                  curId != parent.currentId else { return }
            DispatchQueue.main.async {
                self.parent.currentId = curId
            }
        }

        // MARK: - DataSource

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let curId = id(for: viewController),
                  let curIdx = parent.pages.firstIndex(where: { $0.id == curId }),
                  curIdx > 0 else { return nil }
            return controllerFor(id: parent.pages[curIdx - 1].id)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let curId = id(for: viewController),
                  let curIdx = parent.pages.firstIndex(where: { $0.id == curId }),
                  curIdx + 1 < parent.pages.count else { return nil }
            return controllerFor(id: parent.pages[curIdx + 1].id)
        }

        // MARK: - 缓存工具

        /// 根据 VC 实例反查 id
        func id(for vc: UIViewController) -> String? {
            cache.first(where: { $0.vc === vc })?.id
        }

        /// 获取或创建指定 id 的 HostingController, 并维护 LRU 顺序
        func controllerFor(id: String) -> UIHostingController<AnyView>? {
            guard let pageEntry = parent.pages.first(where: { $0.id == id }) else { return nil }
            // 命中缓存: 同步最新 rootView (pages 刷新后 chapter title / progress 等可能变化), 移到末尾
            if let idx = cache.firstIndex(where: { $0.id == id }) {
                let entry = cache.remove(at: idx)
                entry.vc.rootView = AnyView(pageEntry.view)
                entry.vc.view.backgroundColor = parent.backgroundColor
                cache.append(entry)
                return entry.vc
            }
            // 未命中: 构造新 VC
            let vc = UIHostingController(rootView: AnyView(pageEntry.view))
            vc.view.backgroundColor = parent.backgroundColor
            cache.append((id: id, vc: vc))
            // 裁剪 LRU 头部
            if cache.count > lruLimit {
                cache.removeFirst()
            }
            return vc
        }

        /// 当 pages 数组刷新时, 失效的缓存条目需要重建 (新章节加载后旧 view 已过期).
        /// 保留 PVC 正在显示的 VC 以避免 UIPageViewController 持有被释放的 VC 导致崩溃.
        func evictStaleEntries() {
            let validIds = Set(parent.pages.map(\.id))
            let currentlyDisplayedId = parent.currentId
            cache.removeAll(where: {
                !validIds.contains($0.id) && $0.id != currentlyDisplayedId
            })
        }
    }
}
