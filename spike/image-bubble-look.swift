// 图片笔记「展开气泡」的**样张自查**（同 note-bubble-look 的纪律：自绘图形先出图看一眼）。运行：
//   cp spike/image-bubble-look.swift /tmp/main.swift && swiftc Sources/Support/L.swift Sources/Store/LibraryModels.swift Sources/Store/ImageAssets.swift Sources/App/PenPreset.swift Sources/App/InkModel.swift Sources/App/InkLayerModel.swift Sources/App/NoteTypeModel.swift Sources/App/TextNoteModel.swift Sources/App/ImageNoteModel.swift Sources/App/ImageThumbCache.swift Sources/Views/NoteBubbleView.swift Sources/Views/ImageNoteViews.swift /tmp/main.swift -o /tmp/iblook && /tmp/iblook
// 产物：/tmp/image-bubble-look/*.png（可传一个目录当第 1 个参数）。
//
// 一张常规页宽（760）出固定尺寸 / 跟页缩放两张，各摆四条：横图无说明 / 竖图（高到上限被缩）带说明 /
// 贴右边翻左 / 图不在（占位 + 感叹号）。验：缩略图不撑破气泡、说明不溢出、没有铅笔压在图上、内边距很窄。
import AppKit
import SwiftUI

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/image-bubble-look")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// 造一张带纹理的图（纯色一眼看不出缩放对不对）。
func sample(_ w: Int, _ h: Int) -> URL {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1))
    for i in stride(from: 0, to: w, by: 40) { ctx.fill(CGRect(x: i, y: 0, width: 20, height: h)) }
    ctx.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.3, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
    let p = ImageAssets.prepare(ctx.makeImage()!)!
    let url = outDir.appendingPathComponent("src-\(w)x\(h).png")
    try! p.data.write(to: url)
    return url
}

@MainActor
func save<V: View>(_ name: String, _ size: CGSize, @ViewBuilder _ view: () -> V) {
    let r = ImageRenderer(content: view().frame(width: size.width, height: size.height))
    r.scale = 2
    guard let img = r.nsImage, let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { print("✗ \(name)"); return }
    let url = outDir.appendingPathComponent(name + ".png")
    try? png.write(to: url)
    print("✓ \(url.path)")
}

let wide = sample(800, 300)
let tall = sample(300, 900)

@MainActor
func page(_ w: CGFloat, _ h: CGFloat, followsZoom: Bool) -> some View {
    let m = NoteBubble.metrics(pageWidth: w, followsZoom: followsZoom)
    let items: [(x: CGFloat, y: CGFloat, info: (url: URL, size: CGSize)?, caption: String, sticky: Bool)] = [
        (w * 0.12, h * 0.08, (wide, CGSize(width: 800, height: 300)), "", true),
        (w * 0.12, h * 0.34, (tall, CGSize(width: 300, height: 900)), "图 3-2：洛必达法则适用条件的示意，注意分母导数不为零那一条，后面例题要用到。", true),
        (w * 0.90, h * 0.80, (wide, CGSize(width: 800, height: 300)), "贴右边翻到左侧", false),
        (w * 0.55, h * 0.10, nil, "图不在这份副本里", true),
    ]
    return ZStack(alignment: .topLeading) {
        Color.white
        ForEach(Array(items.enumerated()), id: \.offset) { _, it in
            let pin = CGPoint(x: min(max(it.x, 12), w - 12), y: min(max(it.y, 10), h - 10))
            Image(systemName: "photo")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black.opacity(0.75))
                .padding(3)
                .background(Color(red: 0.64, green: 0.88, blue: 0.80), in: Circle())
                .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5))
                .position(pin)
            ImageBubbleView(note: ImageNote(page: 0, anchor: .zero, image: "x", caption: it.caption,
                                            source: .file(name: "a.png")),
                            info: it.info, metrics: m, pageSize: CGSize(width: w, height: h),
                            pin: pin, pinRadius: 9,
                            onEdit: it.sticky ? {} : nil, onView: it.sticky ? {} : nil, onDelete: it.sticky ? {} : nil)
        }
    }
    .frame(width: w, height: h)
    .border(.gray.opacity(0.4))
}

@MainActor
func run() {
    // 先把缩略图解好（缓存是异步的，直接渲会得到占位方块）
    let cache = ImageThumbCache.shared
    for px in [128, 256, 512, 1024] { _ = cache.image(url: wide, maxPixel: px); _ = cache.image(url: tall, maxPixel: px) }
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    let w: CGFloat = 760, h: CGFloat = 988
    save("image-fixed-760", CGSize(width: w, height: h)) { page(w, h, followsZoom: false) }
    save("image-zoom-760", CGSize(width: w, height: h)) { page(w, h, followsZoom: true) }
    print("\n逐张看：缩略图有没有撑破气泡、说明有没有溢出、图上有没有多余的按钮、边够不够窄。")
}

MainActor.assumeIsolated { run() }
