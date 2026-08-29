// 阅读区缩放的**真实层级**探针。运行：swift spike/reader-zoom-probe.swift
//
// 🔴 为什么必须复刻真实层级（2026-08-28 的教训，别再犯）：先前有个只挂了一个孤零零 Canvas 的
// 简化探针，量出「冻结绘制尺度 + scaleEffect」能让绘制闭包**全程只跑 1 次**、27→125 fps，
// 于是照着改了产品代码——真机上用户回「还是能感受到卡顿」。把外层结构（每帧变的内容尺寸 +
// 页 offset + 白纸/基图/墨迹三层 ZStack）补进探针后真相立刻出来：冻结在真实层级里几乎无效
// （绘制 45 次 vs 现状 49 次），因为外层每帧标脏会把 Canvas 一并重绘。
// **凡是验「SwiftUI 会不会复用/跳过」的探针，外层结构一起复刻，否则读数会骗人。**
//
// 现在的结论：慢的不是"重画"，是 strokedPath 转轮廓那套高质量描边（27ms/页 → 逐段 stroke 6.3ms/页）。
// 产品代码走的是 `.fast`（= 逐段 stroke）；`.frozen`（冻结+scaleEffect）与 `.snapshot`（位图上界）
// 留在这里当对照组，别再重新发明一遍。
import SwiftUI
import AppKit
import QuartzCore

var seed: UInt64 = 42
func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double((seed >> 33) % 100_000) / 100_000.0 }
// 178 笔 × 84 点 = 组成原理 p117 的量级
let strokes: [[CGPoint]] = (0..<178).map { _ in
    var x = 0.05 + rnd() * 0.9, y = 0.05 + rnd() * 0.9
    return (0..<84).map { _ in
        x += (rnd() - 0.5) * 0.008; y += (rnd() - 0.5) * 0.008
        return CGPoint(x: x, y: y)
    }
}
// 基图：与真实同量级（basePixelCap 2800）
let baseImg: CGImage = {
    let c = CGContext(data: nil, width: 2800, height: 3900, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(gray: 0.93, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 2800, height: 3900))
    for i in stride(from: 0, to: 3900, by: 26) {   // 假文字行
        c.setFillColor(CGColor(gray: 0.2, alpha: 1)); c.fill(CGRect(x: 200, y: i, width: 2400, height: 9))
    }
    return c.makeImage()!
}()

final class Stats { var draws = 0, frames = 0; var drawMs = 0.0
    func reset() { draws = 0; frames = 0; drawMs = 0 } }
let stats = Stats()

struct InkCanvas: View, Equatable {
    let inkScale: CGFloat
    static func == (l: Self, r: Self) -> Bool { l.inkScale == r.inkScale }
    var body: some View {
        Canvas { ctx, sz in
            let t0 = CACurrentMediaTime()
            var combined = Path()
            for pts in strokes {
                var lastPt = CGPoint(x: pts[0].x * sz.width, y: pts[0].y * sz.height)
                var lastMid = lastPt
                for i in 1..<pts.count {
                    let p = CGPoint(x: pts[i].x * sz.width, y: pts[i].y * sz.height)
                    let mid = CGPoint(x: (lastPt.x + p.x) / 2, y: (lastPt.y + p.y) / 2)
                    var seg = Path(); seg.move(to: lastMid); seg.addQuadCurve(to: mid, control: lastPt)
                    combined.addPath(seg.strokedPath(StrokeStyle(lineWidth: 3 * inkScale, lineCap: .round, lineJoin: .round)))
                    lastMid = mid; lastPt = p
                }
            }
            ctx.fill(combined, with: .color(.black))
            stats.draws += 1; stats.drawMs += (CACurrentMediaTime() - t0) * 1000
        }
        .allowsHitTesting(false)
    }
}

/// 快速渲染版：整条笔画一次 stroke（不逐段转轮廓再 fill）。接缝处会叠色（alpha<1 才看得出），
/// 缩放中短暂用它、settle 后换回高质量是可行的取舍——先量出它到底能省多少。
struct InkCanvasFast: View, Equatable {
    let inkScale: CGFloat
    static func == (l: Self, r: Self) -> Bool { l.inkScale == r.inkScale }
    var body: some View {
        Canvas { ctx, sz in
            let t0 = CACurrentMediaTime()
            for pts in strokes {
                var path = Path()
                var lastPt = CGPoint(x: pts[0].x * sz.width, y: pts[0].y * sz.height)
                path.move(to: lastPt)
                for i in 1..<pts.count {
                    let p = CGPoint(x: pts[i].x * sz.width, y: pts[i].y * sz.height)
                    let mid = CGPoint(x: (lastPt.x + p.x) / 2, y: (lastPt.y + p.y) / 2)
                    path.addQuadCurve(to: mid, control: lastPt)
                    lastPt = p
                }
                ctx.stroke(path, with: .color(.black),
                           style: StrokeStyle(lineWidth: 3 * inkScale, lineCap: .round, lineJoin: .round))
            }
            stats.draws += 1; stats.drawMs += (CACurrentMediaTime() - t0) * 1000
        }
        .allowsHitTesting(false)
    }
}

/// 逐段 stroke 版：**保留压感变宽**（每段各自线宽），但不转轮廓。相邻段共享端点的圆头会各自
/// 半透明合成 → alpha<1 的笔会在接缝处叠色（现实现正是为躲这个才改的 strokedPath+fill）。
/// 若它也够快，缩放期间就能既保压感又不掉帧，只在半透明笔上短暂地略深一点。
struct InkCanvasSeg: View, Equatable {
    let inkScale: CGFloat
    static func == (l: Self, r: Self) -> Bool { l.inkScale == r.inkScale }
    var body: some View {
        Canvas { ctx, sz in
            let t0 = CACurrentMediaTime()
            for pts in strokes {
                var lastPt = CGPoint(x: pts[0].x * sz.width, y: pts[0].y * sz.height)
                var lastMid = lastPt
                for i in 1..<pts.count {
                    let p = CGPoint(x: pts[i].x * sz.width, y: pts[i].y * sz.height)
                    let mid = CGPoint(x: (lastPt.x + p.x) / 2, y: (lastPt.y + p.y) / 2)
                    var seg = Path(); seg.move(to: lastMid); seg.addQuadCurve(to: mid, control: lastPt)
                    // 压感：拿点序号造一个 0.6~1.4 的变宽（真实里来自 st.points[i].z）
                    let w = 3 * (0.6 + 0.8 * abs(sin(Double(i) * 0.3)))
                    ctx.stroke(seg, with: .color(.black),
                               style: StrokeStyle(lineWidth: CGFloat(w) * inkScale, lineCap: .round, lineJoin: .round))
                    lastMid = mid; lastPt = p
                }
            }
            stats.draws += 1; stats.drawMs += (CACurrentMediaTime() - t0) * 1000
        }
        .allowsHitTesting(false)
    }
}

/// 墨迹的**位图快照**（缩放期间当纹理拉伸的上界参照）
@MainActor func makeInkSnapshot(_ size: CGSize) -> CGImage? {
    let r = ImageRenderer(content: InkCanvas(inkScale: 1).frame(width: size.width, height: size.height))
    r.scale = 2
    return r.cgImage
}
var inkSnap: CGImage?

/// PageCellView 的三层复刻（白纸 / 基图 / 墨迹）
enum InkKind { case live, frozen, snapshot, fast, seg }

struct PageCell: View {
    let size: CGSize, inkSize: CGSize, inkScale: CGFloat, stretch: CGFloat
    let kind: InkKind
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white.frame(width: size.width, height: size.height)
            Image(decorative: baseImg, scale: 1).resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
            ink
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder private var ink: some View {
        switch kind {
        case .live:
            InkCanvas(inkScale: inkScale).frame(width: size.width, height: size.height)
        case .fast:
            InkCanvasFast(inkScale: inkScale).frame(width: size.width, height: size.height)
        case .seg:
            InkCanvasSeg(inkScale: inkScale).frame(width: size.width, height: size.height)
        case .frozen:
            InkCanvas(inkScale: inkScale)
                .frame(width: inkSize.width, height: inkSize.height)
                .scaleEffect(stretch)
                .frame(width: size.width, height: size.height)
        case .snapshot:
            if let inkSnap {
                Image(decorative: inkSnap, scale: 2).resizable()
                    .interpolation(.medium)
                    .frame(width: size.width, height: size.height)
            }
        }
    }
}

final class Mode: ObservableObject { @Published var i = 0 }
let mode = Mode()
var phaseStart = Date().timeIntervalSince1970
let baseW: CGFloat = 620, baseH: CGFloat = 870, pages = 3

struct Root: View {
    @ObservedObject var m: Mode
    var body: some View {
        TimelineView(.animation) { tl in
            let s = 1 + 2 * CGFloat(min(1, max(0, (tl.date.timeIntervalSince1970 - phaseStart) / 2.2)))
            let pageW = baseW * s, pageH = baseH * s
            let kind = kinds[m.i]
            let frozen: CGFloat = kind == .frozen ? 1 : s
            let n = pages
            ZStack(alignment: .topLeading) {
                Color(white: 0.9)
                ForEach(0..<n, id: \.self) { i in
                    PageCell(size: CGSize(width: pageW, height: pageH),
                             inkSize: CGSize(width: baseW * frozen, height: baseH * frozen),
                             inkScale: frozen, stretch: s / frozen, kind: kind)
                        .offset(x: 40, y: CGFloat(i) * (pageH + 12))
                }
            }
            .frame(width: pageW + 80, height: CGFloat(pages) * (pageH + 12))   // 内容尺寸每帧变（同真实）
            .onChange(of: tl.date) { _, _ in stats.frames += 1 }
        }
        .frame(width: 900, height: 620, alignment: .topLeading)
        .clipped()
    }
}

let kinds: [InkKind] = [.live, .fast, .seg, .snapshot]
let names = ["A 现状：strokedPath 转轮廓 + 一次 fill（3 页）",
             "E 整条一次 stroke（恒宽，丢压感）（3 页）",
             "G 逐段 stroke（保压感，接缝可能叠色）（3 页）",
             "D 位图快照拉伸（上界参照，3 页）"]
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let win = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 620),
                   styleMask: [.titled], backing: .buffered, defer: false)
win.contentView = NSHostingView(rootView: Root(m: mode))
win.orderFrontRegardless()

func runPhase(_ i: Int) {
    mode.i = i; stats.reset(); phaseStart = Date().timeIntervalSince1970
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        print(String(format: "%@\n   帧数 %d (%.0f fps)  墨迹绘制 %d 次  总绘制 %.0f ms\n",
                     names[i], stats.frames, Double(stats.frames) / 2.5, stats.draws, stats.drawMs))
        if i < names.count - 1 { runPhase(i + 1) } else { exit(0) }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
    let t0 = CACurrentMediaTime()
    inkSnap = MainActor.assumeIsolated { makeInkSnapshot(CGSize(width: baseW, height: baseH)) }
    print(String(format: "（墨迹位图快照生成一次耗时 %.0f ms —— 这就是「捏合起手同步做一张」要付的顿挫）\n",
                 (CACurrentMediaTime() - t0) * 1000))
    runPhase(0)
}
app.run()
