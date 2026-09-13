// 文字笔记「展开气泡」的**样张自查**（交付前必跑；纪律：自绘图形不靠脑补，先出图看一眼）。运行：
//   cp spike/note-bubble-look.swift /tmp/main.swift && swiftc Sources/App/NoteMarkdown.swift Sources/Views/NoteBubbleView.swift Sources/Support/L.swift /tmp/main.swift -o /tmp/nblook && /tmp/nblook
// 产物：/tmp/note-bubble-look/*.png —— 直接看，别猜。
//
// 三档页宽（缩小 420 / 常规 760 / 放大 1400）各出一张，验证肉眼可判的四件事：
//  ① 两种口径各出一套：固定尺寸（默认，`fixed-*`）三档页宽下气泡应当**一样大**；跟页缩放（`zoom-*`）随页宽走；
//  ② 正文不溢出、不压到右上角铅笔，超 10 行截断；
//  ③ 图钉右侧放不下时翻到左侧、整体钳在页内（右下角那条就是贴边用例）；
//  ④ 纸白底 + 发丝描边在白页上分得出边界，且没有投影/渐变（红线：不拟物）。
import AppKit
import SwiftUI

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/note-bubble-look")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

@MainActor
func save<V: View>(_ name: String, _ size: CGSize, @ViewBuilder _ view: () -> V) {
    let r = ImageRenderer(content: view().frame(width: size.width, height: size.height))
    r.scale = 2
    guard let img = r.nsImage, let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("✗ \(name) 渲染失败"); return
    }
    let url = outDir.appendingPathComponent(name + ".png")
    try? png.write(to: url)
    print("✓ \(url.path)")
}

let short = "这一段是关键：先看定义再看例题。"
// 正文是 Markdown 源：这条带标题/列表/任务/强调/代码，看 `NoteMarkdown` 折算后气泡里长什么样、高度量得准不准
let long = """
## 洛必达法则
只对 **0/0** 与 **∞/∞** 两种未定式成立，别的形式要*先化过去*。
- 用之前先确认分母导数在去心邻域内不为零，否则结论无效
- 连续用两次以上时每一步都要重新验证条件——最常见的失分点
- [x] 极限存在不代表导数之比的极限存在，反向推不成立
> 两次之后还没化开，多半是方法选错了，试 `等价无穷小替换`
"""

/// 一页白纸 + 若干枚图钉与它们展开的气泡（图钉画法与 `PageCellView.notePin` 同款：扁平圆底 + 符号）。
@MainActor
func page(_ w: CGFloat, _ h: CGFloat, followsZoom: Bool) -> some View {
    let m = NoteBubble.metrics(pageWidth: w, followsZoom: followsZoom)
    let pins: [(x: CGFloat, y: CGFloat, text: String, edit: Bool)] = [
        (w * 0.16, h * 0.12, short, true),     // 常规：右侧展开 + 铅笔
        (w * 0.10, h * 0.40, long, true),      // 长文：折行 + 截断
        (w * 0.88, h * 0.62, short, false),    // 贴右边：翻到左侧，且是悬停预览（无铅笔）
        (w * 0.20, h * 0.94, short, true),     // 贴下边：整体钳回页内
    ]
    return ZStack(alignment: .topLeading) {
        Color.white
        ForEach(Array(pins.enumerated()), id: \.offset) { _, p in
            Image(systemName: "note.text")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black.opacity(0.75))
                .padding(3)
                .background(Color(red: 1, green: 0.80, blue: 0.15), in: Circle())
                .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5))
                .position(x: min(max(p.x, 12), w - 12), y: min(max(p.y, 10), h - 10))
            NoteBubbleView(text: p.text, metrics: m, pageSize: CGSize(width: w, height: h),
                           pin: CGPoint(x: min(max(p.x, 12), w - 12), y: min(max(p.y, 10), h - 10)),
                           pinRadius: 9,
                           onEdit: p.edit ? {} : nil)
        }
    }
    .frame(width: w, height: h)
    .border(.gray.opacity(0.4))
}

@MainActor
func run() {
    for (name, w) in [("small-420", CGFloat(420)), ("normal-760", 760), ("large-1400", 1400)] {
        let h = w * 1.3
        save("fixed-\(name)", CGSize(width: w, height: h)) { page(w, h, followsZoom: false) }
        save("zoom-\(name)", CGSize(width: w, height: h)) { page(w, h, followsZoom: true) }
    }
    print("\n逐张看：气泡是否跟页缩放、正文有无溢出/压铅笔、贴边是否翻侧并钳回页内。")
}

MainActor.assumeIsolated { run() }
