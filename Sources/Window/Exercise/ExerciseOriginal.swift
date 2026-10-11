import AppKit
import PDFKit

/// 练习时的「看原题」：把题目在 PDF 页上的那一块（`payload.region`，没有就整页）现渲出来，不存图。
///
/// 🔴 PDF 实例只在自己的串行队列上用（`PageBitmap` 文件头的纪律：同一个 `PDFDocument` 只许一条队列渲染）——
/// 这里**另开一份**、只缓存最近那一本，绝不碰阅读区的 `session.pdf`。
@MainActor
enum ExerciseOriginal {
    private static let queue = DispatchQueue(label: "unireader.exercise.original", qos: .userInitiated)
    /// 只在 `queue` 上读写。
    nonisolated(unsafe) private static var openDoc: (path: String, pdf: PDFDocument)?
    private static let cache = NSCache<NSString, NSImage>()

    /// 渲出这道题的原图（宽 `pixelWidth` 像素左右）。拿不到（文件不在 / 没页码）→ nil。完成回调在主线程。
    static func image(for e: Exercise, workspace: WorkspaceManager, pixelWidth: Int,
                      completion: @escaping (NSImage?) -> Void) {
        guard let docId = e.documentId, let pageIndex = e.page,
              let target = workspace.openTarget(documentId: docId) else { completion(nil); return }
        let region = e.payload.region
        let key = "\(docId)#\(pageIndex)#\(region.map { $0.map { String(format: "%.4f", $0) }.joined(separator: ",") } ?? "page")#\(pixelWidth)"
        if let hit = cache.object(forKey: key as NSString) { completion(hit); return }
        let pageCount = workspace.document(id: docId)?.pageCount ?? 0
        let align = workspace.scanAlign(contentHash: target.hash, pageCount: pageCount)?.page(pageIndex)
        let path = target.path
        queue.async {
            let img = render(path: path, index: pageIndex, region: region, align: align, pixelWidth: pixelWidth)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let img { cache.setObject(img, forKey: key as NSString) }
                    completion(img)
                }
            }
        }
    }

    /// 一本书的目录（「设置章节…」/「按目录自动设置」用）。拿不到（文件不在 / 没有目录）→ 空。完成回调在主线程。
    static func chapters(documentId: String, workspace: WorkspaceManager,
                         completion: @escaping ([ExerciseChapterNode]) -> Void) {
        guard let target = workspace.openTarget(documentId: documentId) else { completion([]); return }
        let path = target.path
        queue.async {
            let toc = pdf(at: path).map(ExerciseChapterNode.toc(of:)) ?? []
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(toc) } }
        }
    }

    /// 只在 `queue` 上跑：最近那一本复用，换书才重开。
    nonisolated private static func pdf(at path: String) -> PDFDocument? {
        if let d = openDoc, d.path == path { return d.pdf }
        guard let d = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
        openDoc = (path, d)
        return d
    }

    /// 只在 `queue` 上跑。
    nonisolated private static func render(path: String, index: Int, region: [Double]?, align: PageAlign?,
                                           pixelWidth: Int) -> NSImage? {
        guard let page = pdf(at: path)?.page(at: index) else { return nil }
        let disp = PageBitmap.displaySize(page, align: align)
        guard disp.width > 0, disp.height > 0 else { return nil }
        var sub = CGRect(origin: .zero, size: disp)
        if let r = region, r.count == 4 {
            // 四周各留一点边：Agent 给的框常常贴着字，裁得太紧看着像被切掉了一截
            let pad = disp.width * 0.015
            sub = CGRect(x: r[0] * disp.width, y: r[1] * disp.height, width: r[2] * disp.width, height: r[3] * disp.height)
                .insetBy(dx: -pad, dy: -pad)
                .intersection(CGRect(origin: .zero, size: disp))
            guard sub.width > 1, sub.height > 1 else { return nil }
        }
        let scale = min(CGFloat(pixelWidth) / sub.width, 4)
        guard let cg = PageBitmap.renderTile(page: page, subRect: sub, scale: scale, align: align) else { return nil }
        // 点尺寸 = 像素的一半（Retina 上按 2x 显示，图不糊）
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
    }
}
