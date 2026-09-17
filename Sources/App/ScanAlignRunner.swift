import Foundation
import CoreGraphics
import PDFKit

/// 跨线程的「别测了」标志（主线程置位，工作线程每页查一次）。
final class ScanAlignCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// 扫描页对齐的「整篇测一遍」（方案 §6）：按原始显示空间出灰度图 → `ScanAlignDetector` → `ScanAlignSolver`。
///
/// 🔴 **每个工作线程各开一份 `PDFDocument`**：PDFKit 的文档 / 页对象不能跨线程共用（`PageBitmap` 头注释那条红线），
/// 这里既不碰 `session.pdf`，也不跟阅读区渲染队列抢同一份实例。
enum ScanAlignRunner {
    /// 在**调用线程**上同步跑完（调用方负责放到后台）。取消了返回 nil。
    /// - Parameters:
    ///   - progress: 每测完一页回调一次（已完成页数），**在工作线程上**调用。
    static func measure(url: URL, pageCount: Int,
                        isCancelled: @escaping () -> Bool,
                        progress: @escaping (Int) -> Void) -> [ScanAlignDetector.Measure]? {
        guard pageCount > 0 else { return [] }
        let workers = max(1, min(6, ProcessInfo.processInfo.activeProcessorCount / 2, pageCount))
        let lock = NSLock()
        var results = [ScanAlignDetector.Measure?](repeating: nil, count: pageCount)
        var done = 0
        DispatchQueue.concurrentPerform(iterations: workers) { k in
            guard let doc = PDFDocument(url: url) else { return }
            var i = k
            while i < pageCount {
                if isCancelled() { return }
                let m = autoreleasepool { measurePage(doc.page(at: i)) }
                lock.lock()
                results[i] = m
                done += 1
                let d = done
                lock.unlock()
                progress(d)
                i += workers
            }
        }
        guard !isCancelled() else { return nil }
        // 某个工作线程开不了文档（极少见）→ 那几页按空白页处理，定中心时用邻页值兜底
        return results.map { $0 ?? .blank(sw: 1, sh: 1) }
    }

    /// 一页：原始显示空间按 `ScanAlignDetector.pxPerPt` 画灰度图再测（超大页降分辨率，单页缓冲封顶 ~8MB）。
    static func measurePage(_ page: PDFPage?) -> ScanAlignDetector.Measure {
        guard let page else { return .blank(sw: 1, sh: 1) }
        let size = PageBitmap.displaySize(page, align: nil)
        guard size.width > 1, size.height > 1 else {
            return .blank(sw: Double(size.width), sh: Double(size.height))
        }
        let area = Double(size.width * size.height)
        let S = min(ScanAlignDetector.pxPerPt, (8_000_000 / area).squareRoot())
        let pw = Int((Double(size.width) * S).rounded()), ph = Int((Double(size.height) * S).rounded())
        guard pw > 8, ph > 8 else { return .blank(sw: Double(size.width), sh: Double(size.height)) }
        var buf = [UInt8](repeating: 255, count: pw * ph)
        let drawn = buf.withUnsafeMutableBytes { raw -> Bool in
            // 灰度位图的内存第 0 行 = 图像顶部（CG 坐标原点在左下，但缓冲按行自上而下排）
            guard let ctx = CGContext(data: raw.baseAddress, width: pw, height: ph, bitsPerComponent: 8,
                                      bytesPerRow: pw, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
            ctx.interpolationQuality = .medium
            ctx.scaleBy(x: CGFloat(pw) / size.width, y: CGFloat(ph) / size.height)
            page.draw(with: PageBitmap.effectiveBox(page), to: ctx)
            return true
        }
        guard drawn else { return .blank(sw: Double(size.width), sh: Double(size.height)) }
        return buf.withUnsafeBufferPointer {
            ScanAlignDetector.measure(gray: $0, width: pw, height: ph,
                                      pxPerPt: Double(pw) / Double(size.width), pageSize: size)
        }
    }
}
