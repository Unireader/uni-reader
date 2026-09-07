// 三端笔迹绘制对比工具的 **macOS 出图端**。读 `vectors.json`，用**产品代码本身**
// （`Sources/Views/InkLayers.swift` 的 `inkDrawStroke`）把每条笔画渲成 PNG。
//
// 🔴 **绝不在这里复刻渲染算法**——对比工具比的是真源，复刻一份就等于自己跟自己比，
// 三端分叉照样藏着。这个文件只做三件事：解析向量、构造 `InkStroke`、驱动 `ImageRenderer`。
//
// 运行（`run.sh` 会自动跑，手动跑用这条）：
//   cp spike/ink-cross/mac.swift /tmp/main.swift && \
//   swiftc Sources/Views/InkLayers.swift Sources/App/InkModel.swift Sources/App/InkLayerModel.swift \
//          Sources/App/PenPreset.swift Sources/App/NoteTypeModel.swift Sources/App/TextNoteModel.swift \
//          Sources/Store/LibraryModels.swift Sources/Support/L.swift /tmp/main.swift -o /tmp/inkcross-mac && \
//   /tmp/inkcross-mac spike/ink-cross/vectors.json spike/ink-cross/out/mac
//
// 产物：`<outDir>/<name>.png`，尺寸 = canvas.w × canvas.h × canvas.scale。

import SwiftUI
import AppKit

/// `InkLayers.swift` 的探针挂钩在真机上来自 `UniReaderApp.swift`（带 `@main`、依赖整个 App 层，
/// 编不进 spike）——给个关闭态的桩即可，探针本就默认关。同 `spike/ink-fast-look.swift`。
enum ZoomProbe {
    static var enabled: Bool { false }
    static func inkDraw(page: Int, strokes: Int, fast: Bool, ms: Double) {}
}

// MARK: - 向量解析

struct VecColor: Decodable { let r: Double, g: Double, b: Double, a: Double }
struct VecCanvas: Decodable { let w: Double, h: Double, scale: Double }
struct VecStroke: Decodable {
    let name: String
    let type: String
    let color: VecColor
    let width: Double
    let points: [[Double]]
}
struct VecDoc: Decodable { let canvas: VecCanvas, strokes: [VecStroke] }

// MARK: - 出图

/// 一条笔画一张图：白底 + 该笔画铺满画布。
/// `inkScale = 1`：向量里的 `width` 就是最终笔宽，三端不许各自再乘一个自己的系数。
struct StrokeCard: View {
    let stroke: InkStroke
    let size: CGSize

    var body: some View {
        Canvas { ctx, sz in
            var c = ctx
            inkDrawStroke(stroke, in: &c, size: sz, inkScale: 1, margin: 0, fast: false)
        }
        .frame(width: size.width, height: size.height)
        .background(Color.white)
    }
}

@MainActor
func render(_ v: VecStroke, canvas: VecCanvas, to dir: URL) -> Bool {
    let type = PenBrushType(rawValue: v.type) ?? .ballpoint
    let st = InkStroke(page: 0,
                       color: InkColor(r: v.color.r, g: v.color.g, b: v.color.b, a: v.color.a),
                       width: v.width, type: type,
                       points: v.points.map { SIMD3($0[0], $0[1], $0.count > 2 ? $0[2] : 0.5) })
    let size = CGSize(width: canvas.w, height: canvas.h)
    let r = ImageRenderer(content: StrokeCard(stroke: st, size: size))
    r.scale = canvas.scale
    // 🔴 `isOpaque` 必须开：默认透明底下，白背景与 alpha 通道会一起写进 PNG，
    // 而另两端画的是不透明白底位图——比出来的差异全是底色的，不是笔迹的。
    r.isOpaque = true
    guard let img = r.nsImage, let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("✗ \(v.name) 渲染失败\n".utf8))
        return false
    }
    do {
        try png.write(to: dir.appendingPathComponent(v.name + ".png"))
        print("✓ mac/\(v.name).png")
        return true
    } catch {
        FileHandle.standardError.write(Data("✗ \(v.name) 写盘失败：\(error)\n".utf8))
        return false
    }
}

// MARK: - main

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("用法：inkcross-mac <vectors.json> <outDir>\n".utf8))
    exit(2)
}
let vecURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])

guard let data = try? Data(contentsOf: vecURL),
      let doc = try? JSONDecoder().decode(VecDoc.self, from: data) else {
    FileHandle.standardError.write(Data("✗ 读不出向量：\(vecURL.path)\n".utf8))
    exit(1)
}
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var ok = 0
MainActor.assumeIsolated {
    for s in doc.strokes where render(s, canvas: doc.canvas, to: outDir) { ok += 1 }
}
print("macOS 端出图 \(ok)/\(doc.strokes.count)")
exit(ok == doc.strokes.count ? 0 : 1)
