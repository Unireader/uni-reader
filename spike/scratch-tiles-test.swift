// 草稿纸 / 画板笔迹分块位图（`ScratchInkTilesLayer`）的离屏对照：同一批笔迹、同一个视口，
// 「分块位图」与原来的「整层直接画」（`ScratchInkCALayer`）渲染出来的像素要对得上。
// 覆盖：首次出图 / 平移（含非整数位移）/ 新增一笔（补画进已有块）/ 擦掉几笔（视口内当场重画）/
//       换缩放（停手 0.2s 后换一套块，旧块垫底直到新块出齐）/ 全删光。
// 运行（文件名必须叫 main.swift，swiftc 只许它带顶层代码）：
//   cp spike/scratch-tiles-test.swift /tmp/main.swift && swiftc -O \
//     Sources/Reader/Scratch/ScratchInkTiles.swift Sources/Reader/Scratch/ScratchCanvasNSLayers.swift \
//     Sources/Reader/InkRenderCG.swift Sources/App/InkModel.swift Sources/App/ScratchPadModel.swift \
//     Sources/App/BoardModel.swift Sources/App/PenPreset.swift Sources/Support/L.swift \
//     /tmp/main.swift -o /tmp/stt && /tmp/stt
// `ReaderLayers.swift` 会牵出整套阅读区，这里不编它：下面放一份与它逐行等价的 `QuietLayer`。
import AppKit
import QuartzCore

/// 与 `Sources/Reader/ReaderLayers.swift` 的 `QuietLayer` 等价（无隐式动画 + 统一 y 向下画）
class QuietLayer: CALayer {
    override func action(forKey event: String) -> CAAction? { nil }
    override init() {
        super.init()
        needsDisplayOnBoundsChange = false
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }
    func yDown(_ ctx: CGContext) {
        guard !contentsAreFlipped() else { return }
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
    }
}

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

// ---- 造笔迹：确定性的伪随机（每次跑都一样）----
var seed: UInt64 = 42
func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }

func makeStroke(cx: Double, cy: Double, type: PenBrushType = .ballpoint, width: Double = 3) -> InkStroke {
    var pts: [InkPoint] = []
    var x = cx, y = cy
    for _ in 0..<40 {
        x += (rnd() - 0.5) * 30; y += (rnd() - 0.5) * 30
        pts.append(InkPoint(Float(x), Float(y), Float(0.3 + rnd() * 0.5)))
    }
    return InkStroke(page: 0, color: InkColor(r: 30, g: 60, b: 200, a: 1), width: width, type: type, points: pts, padId: UUID())
}

var strokes: [InkStroke] = []
for _ in 0..<300 { strokes.append(makeStroke(cx: rnd() * 2400 - 600, cy: rnd() * 1800 - 400)) }
strokes.append(makeStroke(cx: 300, cy: 300, type: .marker, width: 12))   // 荧光笔（正片叠底）
strokes.append(makeStroke(cx: 500, cy: 200, type: .pencil, width: 4))

// ---- 离屏层树：根层 y 向下（同挂在 flipped 视图下），尺寸 800×600，倍率 2 ----
let size = CGSize(width: 800, height: 600), scale: CGFloat = 2

func renderTree(_ l: CALayer) -> [UInt8] {
    let w = Int(size.width * scale), h = Int(size.height * scale)
    let root = CALayer()
    root.isGeometryFlipped = true
    root.frame = CGRect(origin: .zero, size: size)
    root.addSublayer(l)
    l.frame = root.bounds
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { p in
        let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        root.render(in: ctx)
    }
    l.removeFromSuperlayer()
    return buf
}

func direct(_ list: [InkStroke], _ vp: ScratchViewport) -> [UInt8] {
    let l = ScratchInkCALayer()
    l.contentsScale = scale
    l.strokes = list
    l.viewport = vp
    l.frame = CGRect(origin: .zero, size: size)
    l.setNeedsDisplay()
    l.displayIfNeeded()
    return renderTree(l)
}

/// 两张图的差异：差值 > 阈值的像素占比 + 最大差值（只看 alpha 与颜色通道）
func diff(_ a: [UInt8], _ b: [UInt8], tol: Int = 48) -> (ratio: Double, inked: Int) {
    var bad = 0, inked = 0
    for i in stride(from: 0, to: a.count, by: 4) {
        if a[i + 3] > 0 || b[i + 3] > 0 { inked += 1 }
        var m = 0
        for c in 0..<4 { m = max(m, abs(Int(a[i + c]) - Int(b[i + c]))) }
        if m > tol { bad += 1 }
    }
    return (inked == 0 ? 0 : Double(bad) / Double(inked), inked)
}

func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

let tiles = ScratchInkTilesLayer()
tiles.frame = CGRect(origin: .zero, size: size)

/// 分块按屏幕整像素摆（不然会发虚），所以对照的直接画也把视口原点对齐到整像素（差不到半个物理像素，肉眼看不出）
func snapped(_ vp: ScratchViewport) -> ScratchViewport {
    var v = vp
    let f = vp.zoom * scale
    v.origin = CGPoint(x: -(-vp.origin.x * f).rounded() / f, y: -(-vp.origin.y * f).rounded() / f)
    return v
}

func compare(_ name: String, _ vp: ScratchViewport, _ list: [InkStroke], maxRatio: Double = 0.01) {
    let t = renderTree(tiles), d = direct(list, snapped(vp))
    let r = diff(t, d)
    check(r.inked > 1000 || list.isEmpty, "\(name)：画面里有笔迹（\(r.inked) 像素）")
    check(r.ratio <= maxRatio, "\(name)：与直接画的差异像素占 \(String(format: "%.3f%%", r.ratio * 100))（≤ \(maxRatio * 100)%）")
}

print("首次出图（视口里的块当场画）")
var vp = ScratchViewport(origin: CGPoint(x: -100, y: -50), zoom: 1)
tiles.setStrokes(strokes)
tiles.update(viewport: vp, size: size, scale: scale)
compare("首次", vp, strokes)

print("平移（整数 / 非整数位移，块只挪不重画）")
vp.origin = CGPoint(x: 37, y: 113); tiles.update(viewport: vp, size: size, scale: scale); compare("平移 1", vp, strokes)
vp.origin = CGPoint(x: 410.3, y: 777.7); tiles.update(viewport: vp, size: size, scale: scale); compare("平移 2（非整数）", vp, strokes)
pump(0.3)   // 让后台预取出完
vp.origin = CGPoint(x: 420, y: 640); tiles.update(viewport: vp, size: size, scale: scale); compare("平移 3（落在预取过的块上）", vp, strokes)

print("新增一笔（补画进已有块）")
strokes.append(makeStroke(cx: 700, cy: 900, width: 6))
tiles.setStrokes(strokes)
compare("新增", vp, strokes)

print("擦掉视口里的几笔（视口内的块当场重画，不留残影）")
let center = CGRect(x: vp.origin.x, y: vp.origin.y, width: size.width, height: size.height)
let gone = Set(strokes.filter { (ScratchInkCALayer.bounds($0) ?? .null).intersects(center) }.prefix(5).map(\.id))
check(gone.count == 5, "视口里挑出 5 笔来擦")
strokes.removeAll { gone.contains($0.id) }
tiles.setStrokes(strokes)
compare("擦除", vp, strokes)

print("挪动一笔（同 id 换点：旧位置当场清掉、新位置补画）")
if let i = strokes.indices.first(where: { (ScratchInkCALayer.bounds(strokes[$0]) ?? .null).intersects(center) }) {
    strokes[i].points = strokes[i].points.map { InkPoint($0.x + 40, $0.y + 25, $0.z) }
    tiles.setStrokes(strokes)
    compare("挪动", vp, strokes)
}

print("换缩放（缩放中拉伸旧块；停手 0.2s 换一套；新块出齐前旧块垫底）")
vp.zoom = 1.5
tiles.update(viewport: vp, size: size, scale: scale)
let stretched = diff(renderTree(tiles), direct(strokes, vp))
check(stretched.inked > 1000, "缩放中画面不空（拉伸的旧块顶着，\(stretched.inked) 像素）")
pump(0.5)   // 停手换块 + 后台出图
tiles.update(viewport: vp, size: size, scale: scale)
pump(0.3)
compare("换缩放后", vp, strokes)

print("计时：竖向连续滚 120 帧，每帧主线程花多少（新：分块只挪位置；旧：整层重画）")
do {
    // 笔迹多一些、分页画板那样竖着滚
    var many = strokes
    for _ in 0..<1500 { many.append(makeStroke(cx: rnd() * 1000, cy: rnd() * 6000)) }
    let t2 = ScratchInkTilesLayer()
    t2.frame = CGRect(origin: .zero, size: size)
    var v = ScratchViewport(origin: CGPoint(x: 0, y: 0), zoom: 1)
    t2.setStrokes(many)
    t2.update(viewport: v, size: size, scale: scale)
    pump(0.5)
    var tilesMs = 0.0, directMs = 0.0
    let old = ScratchInkCALayer()
    old.contentsScale = scale
    old.strokes = many
    old.frame = CGRect(origin: .zero, size: size)
    for _ in 0..<120 {
        v.origin.y += 6.5
        var t0 = CFAbsoluteTimeGetCurrent()
        t2.update(viewport: v, size: size, scale: scale)
        tilesMs += (CFAbsoluteTimeGetCurrent() - t0) * 1000
        pump(0.004)   // 让后台出好的块回到主线程（真实滚动里帧与帧之间也有这段空）
        t0 = CFAbsoluteTimeGetCurrent()
        old.viewport = v
        old.setNeedsDisplay()
        old.displayIfNeeded()
        directMs += (CFAbsoluteTimeGetCurrent() - t0) * 1000
    }
    print(String(format: "  笔迹 %d 条：分块 平均 %.2f ms/帧；整层重画 平均 %.2f ms/帧（后者还不含光栅化以外的上传）",
                 many.count, tilesMs / 120, directMs / 120))
    check(tilesMs < directMs, "分块每帧比整层重画省")
}

print("全删光")
strokes = []
tiles.setStrokes(strokes)
tiles.update(viewport: vp, size: size, scale: scale)
let empty = renderTree(tiles)
check(!stride(from: 3, to: empty.count, by: 4).contains { empty[$0] != 0 }, "整套块清掉，画面里一个笔迹像素都不剩")

print("\n\(pass) 通过, \(fail) 失败")
exit(fail == 0 ? 0 : 1)
