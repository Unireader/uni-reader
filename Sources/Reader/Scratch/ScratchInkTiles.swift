import AppKit
import QuartzCore

/// 草稿纸 / 画板笔迹的**分块位图**（2026-10-07，用户报「macOS 端分页画板滚动很卡顿」）。
///
/// 采样实测：原来每滚一帧都把视口里的全部笔迹用 CoreGraphics 重新填一遍轮廓（`aa_render`），5 秒滚动里
/// 主线程有约 1.1 秒在干这个，笔迹越多越卡——那是系统代码，正式版一样慢。现在照安卓 `shared/ScratchTiles.kt`
/// 的做法（同一个问题 09-26 在安卓上就是这样解决的）：
///
/// - 笔迹按「块缩放 × 屏幕倍率」下的像素网格切成 `T`px 的方块，每块一张位图、一个子图层；
///   **平移只改子图层的位置，一笔都不重画**。块贴在整像素上，缩放没变时与直接画的一样清楚。
/// - 缩放变了：先把现有的块按比例拉伸顶着，停手 0.2s 后按新缩放换一套；新块出来之前旧那套垫在下面（只替换不清空）。
///   缩到一屏要上百块时立刻换。
/// - 笔迹变了，只动压到的块：纯新增（落笔、平板回推的新笔）当场补画进已有的块，收笔那一帧就在；
///   擦除 / 撤销 / 挪动牵涉的块，在视口里的当场重画（不留残影），视口外的过期、滚到附近再排后台。
/// - 视口外扩一圈（竖向两圈，分页画板主要上下滚）在后台先出图；滚到时还没出来、又没有旧块可垫的当场画。
/// - 块是透明底、只有笔迹（荧光笔的正片叠底只在笔迹之间生效，压在页面背景线上是普通叠加，白纸上看不出差别）。
///
/// 全部方法只在主线程调；后台只碰不可变快照（笔迹数组 + 包围盒）。
final class ScratchInkTilesLayer: QuietLayer {

    /// 块边长（像素）
    private static let T = 512
    /// 块数上限（512² × 4 字节 = 1MB 一块）：超了把预取圈外的扔掉
    private static let maxTiles = 128
    /// 视口里的块多于这个数（缩得很小）就不再拉伸旧块，立刻按新缩放换
    private static let maxVisible = 160
    /// 一次变这么多条以上（整篇重读、插页后整体挪位）整套块作废：旧图上的位置可能全不对了
    private static let bulk = 64
    /// 一次改动里视口内当场重画的块数上限，再多的排后台，免得一下卡太久
    private static let syncLimit = 12

    private final class Tile {
        let i: Int, j: Int
        let layer = QuietLayer()
        /// 内容版本：压到这块的笔迹变了就 +1
        var ver = 0
        /// 当前的图是按哪个版本画的；-1 = 还没有图（空块也算有图：`image == nil`、`doneVer >= 0`）
        var doneVer = -1
        /// 比这更早的后台结果不收：收了会把当场补画 / 重画进去的新内容盖掉
        var minAccept = 0
        var inFlight = false
        var image: CGImage?
        var shown: Bool { doneVer >= 0 }

        init(i: Int, j: Int) {
            self.i = i
            self.j = j
            layer.contentsGravity = .resize
            layer.magnificationFilter = .linear
            layer.minificationFilter = .linear
            layer.isHidden = true
        }
    }

    /// 某一刻的笔迹全集 + 各自的包围盒（后台只读）
    private struct Snap {
        let strokes: [InkStroke]
        let boxes: [CGRect]
    }

    private var all: [InkStroke] = []
    private var boxes: [UUID: CGRect] = [:]
    private var snap: Snap?

    /// 块像素 / 画布单位（= 块缩放 × 屏幕倍率）；0 = 还没出过块
    private var k: CGFloat = 0
    private var cur: [Int64: Tile] = [:]
    /// 换缩放时上一套块：新块出齐之前垫在下面
    private var oldK: CGFloat = 0
    private var old: [Int64: Tile] = [:]
    private let oldRoot = QuietLayer()
    private let curRoot = QuietLayer()

    private var vp = ScratchViewport()
    private var size: CGSize = .zero
    private var scale: CGFloat = 2
    private var settle: DispatchWorkItem?

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "tech.xvanturing.unireader.scratch-tiles"
        q.maxConcurrentOperationCount = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
        q.qualityOfService = .userInitiated
        return q
    }()

    override init() {
        super.init()
        addSublayer(oldRoot)
        addSublayer(curRoot)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    // MARK: - 对外

    /// 笔迹全集（已改好的那一份）：对账出删掉 / 新加 / 改过的，只动压到的块。
    func setStrokes(_ list: [InkStroke]) {
        let prev = all
        all = list
        snap = nil
        if list.isEmpty {
            // 全删光了：整套块清掉（不清的话旧图上的笔迹一直留着）
            dropAll()
            boxes = [:]
            return
        }
        guard k > 0 else { boxes = [:]; return }   // 还没出过块：下次 update 按全集出图

        // 对账（`==` 对没动过的笔迹几乎不花时间：点数组还是同一块存储）
        var before: [UUID: InkStroke] = [:]
        before.reserveCapacity(prev.count)
        for s in prev { before[s.id] = s }
        var removed: [CGRect] = []
        var added: [InkStroke] = []
        for s in list {
            if let o = before.removeValue(forKey: s.id) {
                if o != s {
                    removed.append(boxes[o.id] ?? Self.bounds(o))
                    boxes[s.id] = Self.bounds(s)
                    added.append(s)
                }
            } else {
                added.append(s)
            }
        }
        for o in before.values { removed.append(boxes.removeValue(forKey: o.id) ?? Self.bounds(o)) }
        if removed.isEmpty, added.isEmpty { return }

        dropOld()   // 旧缩放那套不跟进改动，直接不要了
        if removed.count + added.count > Self.bulk {
            for t in cur.values { t.layer.removeFromSuperlayer() }
            cur = [:]
            boxes = [:]
            update(viewport: vp, size: size, scale: scale)
            return
        }

        let vis = range(ringX: 0, ringY: 0)
        var budget = Self.syncLimit
        for t in cur.values {
            let r = rect(t, k: k)
            let hitRemoved = removed.contains { $0.intersects(r) }
            let newHere = added.filter { box($0).intersects(r) }
            guard hitRemoved || !newHere.isEmpty else { continue }
            t.ver += 1
            if !hitRemoved, t.shown, t.doneVer == t.ver - 1 {
                paintIn(newHere, into: t)   // 纯新增：补画进现有的图
            } else if vis.contains(t.i, t.j), budget > 0 {
                renderNow(t)                // 视口里的当场重画，不留残影
                budget -= 1
            }
            // 其余：过期，`scheduleWork` 排后台
        }
        scheduleWork()
    }

    /// 视口 / 尺寸 / 屏幕倍率变了（每帧都会调）：只挪子图层，必要时排出图。
    func update(viewport v: ScratchViewport, size s: CGSize, scale sc: CGFloat) {
        vp = v
        size = s
        scale = sc
        let full = CGRect(origin: .zero, size: s)
        if oldRoot.frame != full { oldRoot.frame = full; curRoot.frame = full }
        guard s.width > 1, s.height > 1, v.zoom > 0, !all.isEmpty else { return }

        let want = v.zoom * sc
        if k == 0 {
            k = want
        } else if abs(want - k) > want * 0.001 {
            if range(ringX: 0, ringY: 0).count > Self.maxVisible { switchScale(want) } else { scheduleSettle() }
        }

        // 视口里还没有图的块：没有旧缩放那套垫着（刚打开 / 整套作废后）就当场画，免得空一下
        let vis = range(ringX: 0, ringY: 0)
        if old.isEmpty {
            for i in vis.i0...vis.i1 {
                for j in vis.j0...vis.j1 {
                    let t = tile(i, j)
                    if !t.shown { renderNow(t) }
                }
            }
        }
        for t in old.values { place(t, k: oldK) }
        for t in cur.values { place(t, k: k) }
        scheduleWork()
        if !old.isEmpty, visibleShown() { dropOld() }
    }

    /// 离开窗口：还没开始画的作废（回来时按需重排）。
    func release() {
        queue.cancelAllOperations()
        for t in cur.values { t.inFlight = false }
        settle?.cancel()
        settle = nil
    }

    // MARK: - 块

    private struct Range {
        let i0: Int, i1: Int, j0: Int, j1: Int
        var count: Int { (i1 - i0 + 1) * (j1 - j0 + 1) }
        func contains(_ i: Int, _ j: Int) -> Bool { i >= i0 && i <= i1 && j >= j0 && j <= j1 }
    }

    /// 当前块缩放下视口覆盖的块号范围，外扩 [ringX] / [ringY] 圈
    private func range(ringX: Int, ringY: Int) -> Range {
        let T = CGFloat(Self.T)
        let x0 = vp.origin.x, y0 = vp.origin.y
        let x1 = x0 + size.width / vp.zoom, y1 = y0 + size.height / vp.zoom
        return Range(i0: Int(floor(x0 * k / T)) - ringX, i1: Int(floor((x1 * k - 0.01) / T)) + ringX,
                     j0: Int(floor(y0 * k / T)) - ringY, j1: Int(floor((y1 * k - 0.01) / T)) + ringY)
    }

    private static func key(_ i: Int, _ j: Int) -> Int64 { (Int64(i) << 32) | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: j))) }

    private func tile(_ i: Int, _ j: Int) -> Tile {
        let kk = Self.key(i, j)
        if let t = cur[kk] { return t }
        let t = Tile(i: i, j: j)
        cur[kk] = t
        curRoot.addSublayer(t.layer)
        return t
    }

    /// 块在画布上的矩形
    private func rect(_ t: Tile, k kk: CGFloat) -> CGRect {
        let s = CGFloat(Self.T) / kk
        return CGRect(x: CGFloat(t.i) * s, y: CGFloat(t.j) * s, width: s, height: s)
    }

    /// 摆到视口里：边按屏幕像素取整（相邻块共用同一条边，不露缝；缩放没变时一块正好 T 像素、不糊）
    private func place(_ t: Tile, k kk: CGFloat) {
        let r = rect(t, k: kk)
        let z = vp.zoom, sc = scale
        func px(_ v: CGFloat, _ o: CGFloat) -> CGFloat { ((v - o) * z * sc).rounded() / sc }
        let f = CGRect(x: px(r.minX, vp.origin.x), y: px(r.minY, vp.origin.y),
                       width: px(r.maxX, vp.origin.x) - px(r.minX, vp.origin.x),
                       height: px(r.maxY, vp.origin.y) - px(r.minY, vp.origin.y))
        let onScreen = t.image != nil && f.intersects(CGRect(origin: .zero, size: size))
        t.layer.isHidden = !onScreen
        if onScreen { t.layer.frame = f }
    }

    private func visibleShown() -> Bool {
        let vis = range(ringX: 0, ringY: 0)
        for i in vis.i0...vis.i1 {
            for j in vis.j0...vis.j1 where cur[Self.key(i, j)]?.shown != true { return false }
        }
        return true
    }

    /// 预取圈里缺图 / 过期的块排进后台（离视口中心近的先画）；块太多时淘汰圈外的
    private func scheduleWork() {
        guard k > 0, !all.isEmpty, size.width > 1 else { return }
        let pre = range(ringX: 1, ringY: 2)
        guard pre.count <= Self.maxTiles else { return }
        var need: [Tile] = []
        for i in pre.i0...pre.i1 {
            for j in pre.j0...pre.j1 {
                let t = tile(i, j)
                if t.doneVer != t.ver, !t.inFlight { need.append(t) }
            }
        }
        if !need.isEmpty {
            let ci = CGFloat(pre.i0 + pre.i1) / 2, cj = CGFloat(pre.j0 + pre.j1) / 2
            need.sort {
                hypot(CGFloat($0.i) - ci, CGFloat($0.j) - cj) < hypot(CGFloat($1.i) - ci, CGFloat($1.j) - cj)
            }
            let sn = snapshot()
            for t in need { enqueue(t, sn) }
        }
        if cur.count > Self.maxTiles {
            for (kk, t) in cur where !pre.contains(t.i, t.j) {
                t.layer.removeFromSuperlayer()
                cur[kk] = nil
            }
        }
    }

    private func enqueue(_ t: Tile, _ sn: Snap) {
        t.inFlight = true
        let ver = t.ver, r = rect(t, k: k), kk = k
        queue.addOperation { [weak self] in
            let img = Self.render(r, k: kk, sn)
            DispatchQueue.main.async { self?.finish(t, ver: ver, k: kk, image: img) }
        }
    }

    private func finish(_ t: Tile, ver: Int, k kk: CGFloat, image: CGImage?) {
        t.inFlight = false
        guard kk == k, cur[Self.key(t.i, t.j)] === t else { return }   // 换了缩放 / 已淘汰
        if ver >= t.minAccept, ver > t.doneVer {
            t.image = image
            t.doneVer = ver
            t.layer.contents = image
            place(t, k: k)
        }
        if t.doneVer != t.ver { scheduleWork() }   // 画的时候又变了：再排一次
        if !old.isEmpty, visibleShown() { dropOld() }
    }

    private func renderNow(_ t: Tile) {
        let img = Self.render(rect(t, k: k), k: k, snapshot())
        t.image = img
        t.doneVer = t.ver
        t.minAccept = t.ver
        t.layer.contents = img
        place(t, k: k)
    }

    /// 把新笔迹补画进这块现有的图（先把旧图原样铺回去，再画新的几笔）
    private func paintIn(_ strokes: [InkStroke], into t: Tile) {
        guard let ctx = Self.makeContext() else { renderNow(t); return }
        let T = CGFloat(Self.T)
        if let img = t.image { ctx.draw(img, in: CGRect(x: 0, y: 0, width: T, height: T)) }
        Self.flip(ctx)
        let r = rect(t, k: k)
        for s in strokes { Self.draw(s, in: ctx, origin: r.origin, k: k) }
        t.image = ctx.makeImage()
        t.doneVer = t.ver
        t.minAccept = t.ver
        t.layer.contents = t.image
        place(t, k: k)
    }

    private func switchScale(_ want: CGFloat) {
        settle?.cancel()
        settle = nil
        dropOld()
        if cur.values.contains(where: { $0.image != nil }) {
            old = cur
            oldK = k
            for t in old.values { oldRoot.addSublayer(t.layer) }
        } else {
            for t in cur.values { t.layer.removeFromSuperlayer() }
        }
        cur = [:]
        k = want
    }

    /// 缩放中：现有的块按比例拉伸，停手 0.2s 再按新缩放换一套
    private func scheduleSettle() {
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settle = nil
            let want = self.vp.zoom * self.scale
            guard abs(want - self.k) > want * 0.001 else { return }
            self.switchScale(want)
            self.update(viewport: self.vp, size: self.size, scale: self.scale)
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func dropOld() {
        for t in old.values { t.layer.removeFromSuperlayer() }
        old = [:]
        oldK = 0
    }

    private func dropAll() {
        queue.cancelAllOperations()
        dropOld()
        for t in cur.values { t.layer.removeFromSuperlayer() }
        cur = [:]
        k = 0
        snap = nil
    }

    // MARK: - 包围盒 / 快照

    private func box(_ s: InkStroke) -> CGRect {
        if let b = boxes[s.id] { return b }
        let b = Self.bounds(s)
        boxes[s.id] = b
        return b
    }

    private func snapshot() -> Snap {
        if let snap { return snap }
        let s = Snap(strokes: all, boxes: all.map { box($0) })
        snap = s
        return s
    }

    /// 画布坐标包围盒（含线宽余量）；没有点 = 空矩形（与谁都不相交）
    static func bounds(_ st: InkStroke) -> CGRect {
        ScratchInkCALayer.bounds(st) ?? .null
    }

    // MARK: - 出图（后台也调：只碰参数）

    private static func makeContext() -> CGContext? {
        CGContext(data: nil, width: T, height: T, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,   // 与窗口色彩空间一致，CA 不必转色（红线 5）
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// 块内坐标：左上原点、y 向下，1 单位 = 1 像素
    private static func flip(_ ctx: CGContext) {
        ctx.translateBy(x: 0, y: CGFloat(T))
        ctx.scaleBy(x: 1, y: -1)
    }

    private static func draw(_ st: InkStroke, in ctx: CGContext, origin o: CGPoint, k: CGFloat) {
        InkRenderCG.drawStroke(st, in: ctx, inkScale: k) {
            CGPoint(x: (CGFloat($0.x) - o.x) * k, y: (CGFloat($0.y) - o.y) * k)
        }
    }

    /// 压到 [r]（画布矩形）的笔迹画进一张新图；一条都没有 = nil（空块）
    private static func render(_ r: CGRect, k: CGFloat, _ sn: Snap) -> CGImage? {
        var ctx: CGContext?
        for (n, st) in sn.strokes.enumerated() where sn.boxes[n].intersects(r) {
            if ctx == nil {
                ctx = makeContext()
                if let c = ctx { flip(c) }
            }
            if let c = ctx { draw(st, in: c, origin: r.origin, k: k) }
        }
        return ctx?.makeImage()
    }
}
