import XCTest
@testable import WanxiangBook

/// 电池/耗电测试：CPU使用率、内存增长、长时间运行稳定性
final class EnergyTests: XCTestCase {

    // MARK: - E1: 分页引擎不应有过高 CPU 消耗

    func test_paginationCPU_baseline() {
        let content = String(repeating: "这是一段用于测试CPU消耗的文本。每个段落有大约三十个汉字。\n\n", count: 500)
        let metrics: [XCTMetric] = [XCTCPUMetric(), XCTMemoryMetric(), XCTClockMetric()]

        measure(metrics: metrics) {
            for i in 0..<5 {
                _ = PaginationEngine.paginate(
                    content: content,
                    chapterIndex: i,
                    chapterTitle: "CPU测试章节\(i)",
                    totalChapters: 100,
                    viewport: CGSize(width: 375, height: 812),
                    config: .testDefault
                )
            }
        }
    }

    // MARK: - E2: 封面缓存不应导致内存暴涨

    func test_coverCache_memoryGrowth() {
        let cache = BookCoverImageCache.shared
        let initialMemory = reportMemoryMB()

        for i in 0..<500 {
            let img = UIImage(systemName: "book.fill")!
            cache.set(img, for: "energy_test_\(i)")
        }

        let afterMemory = reportMemoryMB()
        let growth = afterMemory - initialMemory
        NSLog("[Energy] 封面缓存内存增长: %.1fMB (%.1fMB → %.1fMB)",
              growth, initialMemory, afterMemory)
        XCTAssertLessThan(growth, 128, "500张封面缓存内存增长不应超过128MB")
    }

    // MARK: - E3: 空闲时 CPU 应很低

    func test_idleCPU() {
        measure(metrics: [XCTCPUMetric()]) {
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private func reportMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            return Double(info.resident_size) / 1024.0 / 1024.0
        }
        return 0
    }
}
