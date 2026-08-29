// 快速描边（缩放期间用）与高质量描边的**样张对比**。运行：
//   cp spike/ink-fast-look.swift /tmp/main.swift && swiftc Sources/Views/InkLayers.swift Sources/App/InkModel.swift Sources/App/InkLayerModel.swift Sources/App/PenPreset.swift Sources/App/NoteTypeModel.swift Sources/App/TextNoteModel.swift Sources/Store/LibraryModels.swift Sources/Support/L.swift /tmp/main.swift -o /tmp/ifl && /tmp/ifl
// 产物：/tmp/ink-fast-look/*.png —— 直接看，别猜。
//
// 要看的就一件事：缩放**过程中**切到快速路径，画面会差多少。
// 快速路径省掉的是 `strokedPath()` 转轮廓 + 合并 fill，改回逐段直接 stroke：
// 几何/压感/锥度/线宽全都不变，唯一差别是相邻段共享端点的圆头各自半透明合成 → 接缝略深。
// 库里 2514 条笔迹 alpha<1（多为 0.95：叠一次 = 0.9975，肉眼几乎不可见），
// pencil 的 pass alpha 才 0.16~0.34，是最可能看出差别的笔型——所以样张里必须有它。
import SwiftUI
import AppKit

/// `InkLayers.swift` 里的探针挂钩在真机上来自 `UniReaderApp.swift`，那个文件带 `@main`
/// 且依赖整个 App 层，编不进 spike——给个关闭态的桩即可（探针本就默认关）。
enum ZoomProbe {
    static var enabled: Bool { false }
    static func inkDraw(page: Int, strokes: Int, fast: Bool, ms: Double) {}
}

let outDir = URL(fileURLWithPath: "/tmp/ink-fast-look")
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
    try? png.write(to: outDir.appendingPathComponent(name + ".png"))
    print("✓ \(name).png")
}

/// 一条手写风格的笔迹：正弦起伏 + 压感随位置变化
func stroke(_ type: PenBrushType, y: Double, width: Double, alpha: Double, color: (Double, Double, Double)) -> InkStroke {
    var pts: [SIMD3<Double>] = []
    let n = 120
    for i in 0..<n {
        let t = Double(i) / Double(n - 1)
        let x = 0.06 + t * 0.88
        let yy = y + sin(t * 8.5) * 0.035 + sin(t * 23) * 0.006
        let pressure = 0.35 + 0.65 * sin(t * .pi)            // 起收轻、中间重
        pts.append(SIMD3(x, yy, pressure))
    }
    return InkStroke(page: 0, color: InkColor(r: color.0, g: color.1, b: color.2, a: alpha),
                     width: width, type: type, points: pts)
}

struct Sheet: View {
    let title: String
    let strokes: [InkStroke]
    let fast: Bool
    /// true = 走缩放期真正用的整层分组绘制（`inkDrawStrokesFast`），而不是逐笔快速路径
    var grouped: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Canvas { ctx, sz in
                if grouped {
                    inkDrawStrokesFast(strokes, in: &ctx, size: sz, inkScale: 1, margin: 0)
                } else {
                    for st in strokes { inkDrawStroke(st, in: &ctx, size: sz, inkScale: 1, fast: fast) }
                }
            }
            .frame(width: 520, height: 300)
            .background(.white)
            .border(.gray.opacity(0.4))
        }
    }
}

@MainActor
func run() {
    let pens: [(String, PenBrushType, Double, Double, (Double, Double, Double))] = [
        ("ballpoint a=0.95（库里的主力，2234 条）", .ballpoint, 6, 0.95, (20, 20, 24)),
        ("ballpoint a=0.35（人为调很透明，放大差异）", .ballpoint, 10, 0.35, (20, 60, 200)),
        ("fountain a=0.95（242 条）", .fountain, 8, 0.95, (10, 10, 10)),
        ("pencil（34 条；三 pass、pass alpha 仅 0.16~0.34，最容易看出差别）", .pencil, 10, 0.9, (40, 40, 40)),
        ("marker（5 条；本来就是整条一次 stroke，两版应当一模一样）", .marker, 22, 0.5, (240, 200, 40)),
    ]
    for (i, p) in pens.enumerated() {
        let ss = [stroke(p.1, y: 0.28, width: p.2, alpha: p.3, color: p.4),
                  stroke(p.1, y: 0.68, width: p.2 * 1.6, alpha: p.3, color: p.4)]
        save(String(format: "%d-%@-A高质量", i + 1, "\(p.1)"), CGSize(width: 540, height: 330)) {
            Sheet(title: "高质量（静态显示 / settle 后）：" + p.0, strokes: ss, fast: false)
        }
        save(String(format: "%d-%@-B快速", i + 1, "\(p.1)"), CGSize(width: 540, height: 330)) {
            Sheet(title: "快速（缩放进行中）：" + p.0, strokes: ss, fast: true)
        }
    }
}

/// 混合一页：四种笔型 + 不同颜色/粗细同时在场，验证**整层分组**（缩放期真正走的那条路）
/// 有没有把颜色、线宽、混合模式串组——分组键写错的话，症状就是"某支笔的颜色/粗细跟别人串了"。
@MainActor
func runMixed() {
    var mixed: [InkStroke] = []
    let recipe: [(PenBrushType, Double, Double, (Double, Double, Double), Double)] = [
        (.ballpoint, 6, 0.95, (20, 20, 24), 0.18),
        (.ballpoint, 6, 0.95, (20, 20, 24), 0.30),      // 同笔同色：应当与上一条并进同一组
        (.ballpoint, 14, 0.95, (200, 40, 40), 0.42),    // 换色换粗
        (.fountain, 8, 0.95, (10, 60, 180), 0.54),
        (.pencil, 10, 0.9, (40, 40, 40), 0.66),
        (.marker, 22, 0.4, (240, 200, 40), 0.78),       // multiply，必须单独成组
    ]
    for (t, w, a, c, y) in recipe { mixed.append(stroke(t, y: y, width: w, alpha: a, color: c)) }
    save("6-混合-A高质量", CGSize(width: 540, height: 330)) {
        Sheet(title: "高质量（逐笔）：四种笔型 + 不同颜色粗细", strokes: mixed, fast: false)
    }
    save("6-混合-B整层分组快速", CGSize(width: 540, height: 330)) {
        Sheet(title: "缩放中（整层分组）：颜色/粗细/multiply 不得串组", strokes: mixed, fast: true, grouped: true)
    }
}

MainActor.assumeIsolated { run(); runMixed() }
