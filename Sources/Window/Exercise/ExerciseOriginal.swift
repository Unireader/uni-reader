import AppKit
import PDFKit

/// 练习时的「看原题」：把题目在 PDF 页上的那一块（`payload.region`，没有就整页）现渲出来，不存图。
/// 跨页的题（`payload.next_regions`，`EXERCISE-PLAN.md §26`）后面几页各渲一块，从上到下拼成一张。
///
/// 🔴 PDF 实例只在自己的串行队列上用（`PageBitmap` 文件头的纪律：同一个 `PDFDocument` 只许一条队列渲染）——
/// 这里**另开一份**、只缓存最近那一本，绝不碰阅读区的 `session.pdf`。
@MainActor
enum ExerciseOriginal {
    nonisolated private static let queue = DispatchQueue(label: "unireader.exercise.original", qos: .userInitiated)
    /// 只在 `queue` 上读写。
    nonisolated(unsafe) private static var openDoc: (path: String, pdf: PDFDocument)?
    private static let cache = NSCache<NSString, NSImage>()

    /// 渲出这道题的原图（宽 `pixelWidth` 像素左右）。拿不到（文件不在 / 没页码）→ nil。完成回调在主线程。
    static func image(for e: Exercise, workspace: WorkspaceManager, pixelWidth: Int,
                      completion: @escaping (NSImage?) -> Void) {
        guard let src = source(for: e, workspace: workspace) else { completion(nil); return }
        image(src, pixelWidth: pixelWidth, completion: completion)
    }

    /// 某一页整页（设置原题区域时在整页上框，`ExerciseRegionPicker`）。同一份渲染、同一个扫描页对齐口径。
    static func pageImage(documentId: String, page: Int, workspace: WorkspaceManager, pixelWidth: Int,
                          completion: @escaping (NSImage?) -> Void) {
        guard let target = workspace.openTarget(documentId: documentId) else { completion(nil); return }
        let pageCount = workspace.document(id: documentId)?.pageCount ?? 0
        let align = workspace.scanAlign(contentHash: target.hash, pageCount: pageCount)?.page(page)
        image(ExerciseImageSource(path: target.path, slices: [ExerciseSlice(page: page, region: nil, align: align)]),
              pixelWidth: pixelWidth, completion: completion)
    }

    /// 这道题看原题要渲的那几段（文件在哪、每段哪一页哪一块、各页的扫描页对齐）。拿不到 → nil。
    /// 平板模式2 的 `/exercise.png` 在 `AppModel.pushExerciseDeck` 里按同一条 `Exercise.originalSlices` 拼（同一本书只查一次文件）。
    static func source(for e: Exercise, workspace: WorkspaceManager) -> ExerciseImageSource? {
        guard let docId = e.documentId, e.page != nil,
              let target = workspace.openTarget(documentId: docId) else { return nil }
        let pageCount = workspace.document(id: docId)?.pageCount ?? 0
        let table = workspace.scanAlign(contentHash: target.hash, pageCount: pageCount)
        let slices = e.originalSlices(pageCount: pageCount > 0 ? pageCount : nil)
            .map { ExerciseSlice(page: $0.page, region: $0.region, align: table?.page($0.page)) }
        return slices.isEmpty ? nil : ExerciseImageSource(path: target.path, slices: slices)
    }

    private static func image(_ src: ExerciseImageSource, pixelWidth: Int, completion: @escaping (NSImage?) -> Void) {
        let key = "\(src.path)#\(src.cacheKey)#\(pixelWidth)"
        if let hit = cache.object(forKey: key as NSString) { completion(hit); return }
        queue.async {
            let img = render(src, pixelWidth: pixelWidth)
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

    /// 平板模式2 的「看原题」（`/exercise.png`，`EXERCISE-PLAN.md §10.4`）：同一块、同一份 PDF 实例，出 JPEG 字节。
    /// 在调用方线程（`LANServer` 的服务 queue）上**同步**等本队列渲完——PDF 实例只许本队列碰，纪律不变。
    nonisolated static func jpeg(_ src: ExerciseImageSource, pixelWidth: Int) -> Data? {
        let cg = queue.sync { renderCG(src, pixelWidth: pixelWidth) }
        guard let cg else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    /// 只在 `queue` 上跑。
    nonisolated private static func render(_ src: ExerciseImageSource, pixelWidth: Int) -> NSImage? {
        guard let cg = renderCG(src, pixelWidth: pixelWidth) else { return nil }
        // 点尺寸 = 像素的一半（Retina 上按 2x 显示，图不糊）
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
    }

    /// 段与段之间那条浅灰分隔有几像素高（不留的话接缝处会被看成一段连续正文，同 `PageSnip` 跨页截图）。
    nonisolated private static let gap = 8

    /// 只在 `queue` 上跑：每段是那一页上的一块（四周放 1.5% 页宽；没有框 = 整页）。
    /// 几段按**同一个倍率**渲（字一样大，倍率按最宽那段定），从上到下左对齐拼起来；起始页渲不出来 → nil，后面某页没了就少那段。
    nonisolated private static func renderCG(_ src: ExerciseImageSource, pixelWidth: Int) -> CGImage? {
        guard let pdf = pdf(at: src.path) else { return nil }
        var parts: [(page: PDFPage, sub: CGRect, align: PageAlign?)] = []
        for (k, s) in src.slices.enumerated() {
            guard let page = pdf.page(at: s.page) else { if k == 0 { return nil } else { break } }
            let disp = PageBitmap.displaySize(page, align: s.align)
            guard disp.width > 0, disp.height > 0 else { if k == 0 { return nil } else { break } }
            var sub = CGRect(origin: .zero, size: disp)
            if let r = s.region, r.count == 4 {
                // 四周各留一点边：Agent 给的框常常贴着字，裁得太紧看着像被切掉了一截
                let pad = disp.width * 0.015
                sub = CGRect(x: r[0] * disp.width, y: r[1] * disp.height, width: r[2] * disp.width, height: r[3] * disp.height)
                    .insetBy(dx: -pad, dy: -pad)
                    .intersection(CGRect(origin: .zero, size: disp))
                guard sub.width > 1, sub.height > 1 else { if k == 0 { return nil } else { break } }
            }
            parts.append((page, sub, s.align))
        }
        guard let widest = parts.map(\.sub.width).max(), widest > 0 else { return nil }
        let scale = min(CGFloat(pixelWidth) / widest, 4)
        var tiles: [CGImage] = []
        for p in parts {
            guard let t = PageBitmap.renderTile(page: p.page, subRect: p.sub, scale: scale, align: p.align) else {
                if tiles.isEmpty { return nil } else { break }
            }
            tiles.append(t)
        }
        return tiles.count == 1 ? tiles.first : stack(tiles)
    }

    /// 几段从上到下拼成一张（白底、左对齐，段间一条浅灰分隔）。
    nonisolated private static func stack(_ tiles: [CGImage]) -> CGImage? {
        let w = tiles.map(\.width).max() ?? 0
        let h = tiles.reduce(0) { $0 + $1.height } + gap * (tiles.count - 1)
        guard w > 0, h > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
        var y = h                       // CG 原点在左下，从上往下摆要倒着走
        for (i, t) in tiles.enumerated() {
            y -= t.height
            ctx.draw(t, in: CGRect(x: 0, y: y, width: t.width, height: t.height))
            if i < tiles.count - 1 {
                y -= gap
                ctx.fill(CGRect(x: 0, y: y, width: w, height: gap))
            }
        }
        return ctx.makeImage()
    }
}
