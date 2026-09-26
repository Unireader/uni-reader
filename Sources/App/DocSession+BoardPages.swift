import Foundation
import CoreGraphics

/// 分页画板的页操作（`BOARD-NOTE-PLAN.md §9`）：Mac 本机（页面弹层 / 右键）与平板上行（`boardPageAdd` /
/// `boardPageTemplate`）共用这一份。
///
/// 会话里的条目一律是**画布坐标**（草稿纸整条链路不认识「页」）。页的结构一变（插页 / 删页 / 改尺寸），
/// 后面那些页在画布上的位置就变了，这里把受影响的条目整体平移过去——**对账快照（persisted*）同样平移**，
/// 于是落库时它们「没变」，一行都不重写（库里存的是页内坐标，本来就没变；离线镜像也不会满屏「改过」）。
extension DocSession {

    /// 一条笔迹归哪一页：按第一个点（`§9.1`）。
    func boardPageIndex(of st: InkStroke) -> Int {
        boardLayout.index(forY: st.points.first.map { $0.dy } ?? 0)
    }
    func boardPageIndex(of im: BoardImage) -> Int {
        boardLayout.index(forY: Double(im.rect.minY))
    }
    /// 落库用：某条目所在页的 id 与画布左上角（不是分页画板 → nil）。
    func boardPageRef(index i: Int) -> (id: UUID, origin: CGPoint)? {
        guard isPagedBoard, boardPages.indices.contains(i) else { return nil }
        return (boardPages[i].id, boardLayout.origin(i))
    }

    /// 视口中心所在的页（平板「改当前页背景」与工具条的页码用）。
    func boardPageIndex(forCanvasY y: Double) -> Int { boardLayout.index(forY: y) }

    // MARK: - 操作

    /// 在末尾加 `count` 页（沿用末页的尺寸与背景）。不影响已有内容的位置，撤销栈照旧。
    func appendBoardPages(_ count: Int = 1) {
        guard isPagedBoard, let last = boardPages.last else { return }
        var arr = boardPages
        for i in 0..<max(1, min(count, 100)) {
            arr.append(BoardPage(sortKey: last.sortKey + Double(i + 1), width: last.width, height: last.height,
                                 template: last.template))
        }
        boardPages = arr
    }

    /// 在第 `k` 页前面插一页（`k == 页数` = 末尾）。后面那些页的内容整体下移一页。
    func insertBoardPage(at k: Int) {
        guard isPagedBoard else { return }
        let n = boardPages.count, k = min(max(0, k), n)
        if k == n { appendBoardPages(1); return }
        let ref = boardPages[k]
        let prev = k > 0 ? boardPages[k - 1].sortKey : ref.sortKey - 1
        let page = BoardPage(sortKey: (prev + ref.sortKey) / 2, width: ref.width, height: ref.height,
                             template: (k > 0 ? boardPages[k - 1] : ref).template)
        let stride = boardLayout.stride
        shiftBoardItems { i in i >= k ? CGVector(dx: 0, dy: stride) : .zero }
        var arr = boardPages
        arr.insert(page, at: k)
        boardPages = arr
        scratchUndo.reset()   // 撤销栈里记的是旧位置，套到新布局上就错位
    }

    /// 删掉几页连同上面的内容；后面的页上移补位。至少留一页（分页画板不会变成无限画布）。
    func deleteBoardPages(_ indices: Set<Int>) {
        guard isPagedBoard else { return }
        let del = indices.filter { boardPages.indices.contains($0) }
        guard !del.isEmpty, del.count < boardPages.count else { return }
        let stride = boardLayout.stride
        shiftBoardItems { i in
            if del.contains(i) { return nil }
            return CGVector(dx: 0, dy: -stride * Double(del.filter { $0 < i }.count))
        }
        boardPages = boardPages.enumerated().filter { !del.contains($0.offset) }.map(\.element)
        scratchUndo.reset()
    }

    /// 改几页的背景（批量）。只改页，不动内容。
    func setBoardTemplate(_ t: BoardTemplate, pages indices: Set<Int>) {
        var arr = boardPages
        var changed = false
        for i in indices where arr.indices.contains(i) && arr[i].template != t {
            arr[i].template = t
            arr[i].updatedAt = .now
            changed = true
        }
        if changed { boardPages = arr }
    }

    /// 改整本的页面尺寸：每页一起改，内容跟着各自那页的左上角走（页内位置不变）。
    func setBoardPageSize(width w: Double, height h: Double) {
        guard isPagedBoard, w > 1, h > 1 else { return }
        let old = boardLayout
        guard abs(old.width - w) > 0.01 || abs(old.height - h) > 0.01 else { return }
        let new = BoardLayout(width: w, height: h, count: old.count)
        shiftBoardItems { i in
            let a = old.origin(i), b = new.origin(i)
            return CGVector(dx: b.x - a.x, dy: b.y - a.y)
        }
        boardPages = boardPages.map { var p = $0; p.width = w; p.height = h; p.updatedAt = .now; return p }
        scratchUndo.reset()
    }

    // MARK: - 平移

    /// 按「所在页 → 位移」平移全部条目；返回 nil = 删掉（只从当前数组删，对账快照里留着，落库时据此删行）。
    /// 页号按**平移前**的布局算。对账快照用它自己那份的页号算（通常与当前一致）。
    private func shiftBoardItems(_ f: (Int) -> CGVector?) {
        func moved(_ st: InkStroke, _ v: CGVector) -> InkStroke {
            guard v != .zero else { return st }
            var t = st
            t.points = st.points.map { InkPoint($0.dx + Double(v.dx), $0.dy + Double(v.dy), $0.dz) }
            return t
        }
        func moved(_ im: BoardImage, _ v: CGVector) -> BoardImage {
            guard v != .zero else { return im }
            var t = im
            t.rect = im.rect.offsetBy(dx: v.dx, dy: v.dy)
            return t
        }
        var strokes: [InkStroke] = []
        for st in scratchStrokes {
            if let v = f(boardPageIndex(of: st)) { strokes.append(moved(st, v)) }
        }
        var images: [BoardImage] = []
        for im in boardImages {
            if let v = f(boardPageIndex(of: im)) { images.append(moved(im, v)) }
        }
        for (id, st) in persistedScratchStrokes {
            if let v = f(boardPageIndex(of: st)) { persistedScratchStrokes[id] = moved(st, v) }
        }
        for (id, im) in persistedBoardImages {
            if let v = f(boardPageIndex(of: im)) { persistedBoardImages[id] = moved(im, v) }
        }
        scratchStrokes = strokes
        boardImages = images
    }
}
