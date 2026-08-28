// 气泡右上角「编辑」按钮的**图标候选样张**（用户 2026-08-27 报现版「有点丑」）。运行：
//   cp spike/note-bubble-icon-look.swift /tmp/main.swift && swiftc Sources/Views/NoteBubbleView.swift Sources/Support/L.swift /tmp/main.swift -o /tmp/nbi && /tmp/nbi
// 产物：/tmp/note-bubble-icon/candidates.png —— 一张图里把候选按**真实尺寸**并排放，直接看。
//
// 每行一个候选：左边是 760pt 页宽下的实际大小（字号 ≈16.7pt、按钮边长 ≈28pt），
// 右边把同一枚放大 3 倍看形状本身。裸符号 / 带圈符号 / 带方框符号三类都放进来比。
import AppKit
import SwiftUI

let outDir = URL(fileURLWithPath: "/tmp/note-bubble-icon")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

@MainActor
func save<V: View>(_ name: String, _ size: CGSize, @ViewBuilder _ view: () -> V) {
    let r = ImageRenderer(content: view().frame(width: size.width, height: size.height))
    r.scale = 3
    guard let img = r.nsImage, let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("✗ \(name) 渲染失败"); return
    }
    try? png.write(to: outDir.appendingPathComponent(name + ".png"))
    print("✓ \(outDir.appendingPathComponent(name + ".png").path)")
}

/// 候选：符号名 + 相对字号（÷ 正文字号）+ 字重。
let candidates: [(name: String, symbol: String, scale: CGFloat, weight: Font.Weight)] = [
    ("旧版 pencil（丑）", "pencil", 0.95, .medium),
    ("选定 square.and.pencil", "square.and.pencil", 0.95, .medium),
]

/// 一枚按钮的真实观感：正文字号 fs 下的气泡右上角（纸白底 + 一行正文压着看比例）。
@MainActor
func cell(_ c: (name: String, symbol: String, scale: CGFloat, weight: Font.Weight),
          fs: CGFloat, zoom: CGFloat) -> some View {
    let pad = fs * NoteBubble.padRatio
    let edit = fs * NoteBubble.editRatio
    let w = fs * 11
    return ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: fs * NoteBubble.radiusRatio)
            .fill(NoteBubble.fill)
            .overlay(RoundedRectangle(cornerRadius: fs * NoteBubble.radiusRatio)
                .stroke(NoteBubble.stroke, lineWidth: 1))
        Text("先看定义再看例题。")
            .font(.system(size: fs))
            .foregroundStyle(NoteBubble.ink)
            .padding(.leading, pad).padding(.top, pad)
        Image(systemName: c.symbol)
            .font(.system(size: fs * c.scale, weight: c.weight))
            .foregroundStyle(NoteBubble.editGlyph)
            .frame(width: edit, height: edit)
            .offset(x: w - edit - pad * 0.4, y: pad * 0.4)
    }
    .frame(width: w, height: fs * NoteBubble.lineHeightRatio + pad * 2, alignment: .topLeading)
    .scaleEffect(zoom, anchor: .topLeading)
    .frame(width: w * zoom, height: (fs * NoteBubble.lineHeightRatio + pad * 2) * zoom,
           alignment: .topLeading)
}

/// 网页/安卓画的那枚「编辑」图标（24 网格坐标与 `render.ts drawEditIcon`／`PadOverlays.drawEditIcon`
/// **逐个数字相同**）。放进样张是为了核对一件事：三端的图标是不是同一个形状。
struct WebEditIcon: View {
    let size: CGFloat
    var body: some View {
        Canvas { ctx, _ in
            let u = size / 24
            func P(_ a: CGFloat, _ b: CGFloat) -> CGPoint { CGPoint(x: a * u, y: b * u) }
            let r: CGFloat = 3
            var frame = Path()
            frame.move(to: P(14, 4.5))
            frame.addLine(to: P(4.5 + r, 4.5))
            frame.addQuadCurve(to: P(4.5, 4.5 + r), control: P(4.5, 4.5))
            frame.addLine(to: P(4.5, 19.5 - r))
            frame.addQuadCurve(to: P(4.5 + r, 19.5), control: P(4.5, 19.5))
            frame.addLine(to: P(19.5 - r, 19.5))
            frame.addQuadCurve(to: P(19.5, 19.5 - r), control: P(19.5, 19.5))
            frame.addLine(to: P(19.5, 10))
            ctx.stroke(frame, with: .color(NoteBubble.editGlyph),
                       style: StrokeStyle(lineWidth: max(1, 2 * u), lineCap: .round, lineJoin: .round))
            for poly in [[(19.08, 3.08), (20.92, 4.92), (14.92, 10.92), (13.08, 9.08)],
                         [(13.08, 9.08), (14.92, 10.92), (12.44, 11.56)]] as [[(CGFloat, CGFloat)]] {
                var q = Path()
                q.move(to: P(poly[0].0, poly[0].1))
                for t in poly.dropFirst() { q.addLine(to: P(t.0, t.1)) }
                q.closeSubpath()
                ctx.fill(q, with: .color(NoteBubble.editGlyph))
            }
        }
        .frame(width: size, height: size)
    }
}

/// 三端对照行：左＝Mac 的 SF Symbol，右＝网页/安卓画的那枚（真实大小 + ×2.5）。
@MainActor
func crossEndRow(fs: CGFloat) -> some View {
    let edit = fs * NoteBubble.editRatio
    func cell(_ zoom: CGFloat) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: fs * 0.95, weight: .medium))
                .foregroundStyle(NoteBubble.editGlyph)
                .frame(width: edit, height: edit)
            WebEditIcon(size: edit * 0.78).frame(width: edit, height: edit)
        }
        .padding(6)
        .background(NoteBubble.fill, in: RoundedRectangle(cornerRadius: 6))
        .scaleEffect(zoom, anchor: .topLeading)
        .frame(width: (edit * 2 + 22) * zoom, height: (edit + 12) * zoom, alignment: .topLeading)
    }
    return HStack(alignment: .top, spacing: 18) {
        Text("Mac 符号 ／ 网页·安卓画的")
            .font(.system(size: 11).monospaced()).foregroundStyle(.black.opacity(0.55))
            .frame(width: 150, alignment: .leading)
        cell(1)
        cell(2.5)
    }
}

@MainActor
func sheet() -> some View {
    // 760pt 页宽（常规阅读档）下的真实字号
    let fs = 760 * NoteBubble.fontRatio
    return VStack(alignment: .leading, spacing: 14) {
        Text("气泡编辑按钮候选 · 760pt 页宽（左＝真实大小，右＝×2.5 看形状）")
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.black.opacity(0.7))
        ForEach(candidates, id: \.name) { c in
            HStack(alignment: .top, spacing: 18) {
                Text(c.name)
                    .font(.system(size: 11).monospaced()).foregroundStyle(.black.opacity(0.55))
                    .frame(width: 150, alignment: .leading)
                cell(c, fs: fs, zoom: 1)
                cell(c, fs: fs, zoom: 2.5)
            }
        }
        Divider()
        crossEndRow(fs: fs)
    }
    .padding(20)
    .background(Color(white: 0.93))
}

MainActor.assumeIsolated {
    save("candidates", CGSize(width: 900, height: 320)) { sheet() }
    print("\n挑一个：要在真实大小下一眼认得出是「编辑」，且不像掉在气泡角上的一道斜杠。")
}
