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

import SwiftUI
import UIKit

/// SwiftUI 包装的仿真翻书容器
struct PageCurlContainer<Page: View>: UIViewControllerRepresentable {

    let pages: [(id: String, view: Page)]
    @Binding var currentId: String

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: nil
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        context.coordinator.parent = self
        context.coordinator.attach(pvc)
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncCurrent(pvc: pvc, animated: false)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageCurlContainer
        private var hostings: [String: UIHostingController<AnyView>] = [:]

        init(_ p: PageCurlContainer) { parent = p }

        func attach(_ pvc: UIPageViewController) {
            if let vc = controllerFor(id: parent.currentId) {
                pvc.setViewControllers([vc], direction: .forward, animated: false)
            }
        }

        func syncCurrent(pvc: UIPageViewController, animated: Bool) {
            guard let cur = pvc.viewControllers?.first,
                  let curId = hostings.first(where: { $0.value === cur })?.key,
                  curId != parent.currentId else { return }
            // SwiftUI 状态回写
            DispatchQueue.main.async {
                self.parent.currentId = curId
            }
        }

        private func controllerFor(id: String) -> UIViewController? {
            if let cached = hostings[id] { return cached }
            guard let pageEntry = parent.pages.first(where: { $0.id == id }) else { return nil }
            let vc = UIHostingController(rootView: AnyView(pageEntry.view))
            vc.view.backgroundColor = .clear
            hostings[id] = vc
            return vc
        }

        // MARK: - DataSource

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let curId = hostings.first(where: { $0.value === viewController })?.key,
                  let curIdx = parent.pages.firstIndex(where: { $0.id == curId }),
                  curIdx > 0 else { return nil }
            return controllerFor(id: parent.pages[curIdx - 1].id)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let curId = hostings.first(where: { $0.value === viewController })?.key,
                  let curIdx = parent.pages.firstIndex(where: { $0.id == curId }),
                  curIdx + 1 < parent.pages.count else { return nil }
            return controllerFor(id: parent.pages[curIdx + 1].id)
        }

        // MARK: - Delegate

        func pageViewController(_ pageViewController: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            guard finished, completed,
                  let cur = pageViewController.viewControllers?.first,
                  let curId = hostings.first(where: { $0.value === cur })?.key else { return }
            DispatchQueue.main.async {
                self.parent.currentId = curId
            }
        }
    }
}
