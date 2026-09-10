import CoreGraphics
import Foundation

/// 粘贴的**摆放数学**（纯函数，不碰会话、不认识视图，spike 可测）。
///
/// 两条路径共用这一份：Mac 本机 ⌘V（`ReaderSurface+InkClip.pasteInk`）与平板发来的
/// `clip op=paste`（`AppModel.applyClip`）。当初把它抽出来的直接原因是后者——阅读区那版把
/// 「算落点」和「读视图几何」缠在一起，平板那条路径根本没有视图可读。
enum InkPaste {

    /// 剪贴板内容摆到目标页上。
    ///
    /// - `center`：落点（页内归一化）。内容的**包围盒中心**对齐到这一点；传 nil = 保持原位并
    ///   错开一点点（同页粘贴不完全压住源）。
    /// - `targetAspect`：目标页的页高/页宽。只在剪贴板来自**草稿纸**（画布点）时用得上——
    ///   先按它折回页内归一化（`InkClipboard.scaled`）。
    /// - `xRange`：可写的 x 区间（画板模式放宽到页边）。位移**先夹再整体平移** = 刚性，
    ///   撞上页边只是停住、不会被逐点摁扁（2026-08-30「框选移动把笔迹压缩了」那笔账）。
    /// - `layers`/`fallbackLayer`：目标文档已有的图层集合与当前作画图层——跨文档粘贴时源图层
    ///   多半不存在于这一篇，落到当前层，别造出无处可归的孤儿笔迹。`types` 同理（笔记类型属工作区）。
    static func place(strokes: [InkStroke], notes: [TextNote],
                      space: InkClipboard.Space, sourceAspect: Double,
                      page: Int, center: CGPoint?, targetAspect: Double,
                      xRange: ClosedRange<Double>,
                      layers: Set<UUID>, fallbackLayer: UUID,
                      types: Set<UUID>) -> (strokes: [InkStroke], notes: [TextNote]) {
        // 来自草稿纸的是画布点：先折成页内归一化（注解不会来自草稿纸——纸上没有注解）
        let src = space == .canvas
            ? InkClipboard.scaled(strokes, toCanvas: false, aspect: targetAspect)
            : strokes
        let inkBox = InkEdit.bounds(src)
        let noteBox = notes.reduce(CGRect.null) { $0.union($1.anchor) }
        let box = inkBox.union(noteBox)
        guard !box.isNull else { return ([], []) }

        var dx = 0.02, dy = 0.02
        if let center {
            dx = Double(center.x) - Double(box.midX)
            dy = Double(center.y) - Double(box.midY)
        }
        (dx, dy) = InkEdit.fitTranslation(dx: dx, dy: dy, inkBounds: inkBox,
                                          xRange: xRange, noteBounds: noteBox)

        var outStrokes: [InkStroke] = []
        for s0 in src {
            var st = InkEdit.translated(s0, dx: dx, dy: dy, xRange: xRange)
            st.page = page
            st.padId = nil
            if !layers.contains(st.layerId) { st.layerId = fallbackLayer }
            outStrokes.append(st)
        }
        var outNotes: [TextNote] = []
        for n0 in notes {
            var n = InkEdit.translated(n0, dx: dx, dy: dy)
            n.page = page
            if let t = n.typeId, !types.contains(t) { n.typeId = nil }
            n.createdAt = .now
            outNotes.append(n)
        }
        return (outStrokes, outNotes)
    }

    /// 摆到**草稿纸**上（画布坐标，无界不夹取）。页内来的先按源页纵横比折成画布点。
    /// `center` 为画布坐标落点（nil = 原位错开 24 点）。
    static func placeOnCanvas(strokes: [InkStroke], space: InkClipboard.Space, sourceAspect: Double,
                              pad: UUID, center: CGPoint?) -> [InkStroke] {
        let src = space == .page
            ? InkClipboard.scaled(strokes, toCanvas: true, aspect: sourceAspect)
            : strokes
        var box = CGRect.null
        for st in src {
            for p in st.points {
                let r = CGRect(x: CGFloat(p.x), y: CGFloat(p.y), width: 0, height: 0)
                box = box.isNull ? r : box.union(r)
            }
        }
        guard !box.isNull else { return [] }
        let dx = center.map { Double($0.x - box.midX) } ?? 24
        let dy = center.map { Double($0.y - box.midY) } ?? 24
        return src.map { st in
            var t = st
            t.points = st.points.map { InkPoint($0.dx + dx, $0.dy + dy, $0.dz) }
            t.padId = pad
            t.page = 0
            return t
        }
    }
}
