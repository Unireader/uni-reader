// 每帧逐页分桶（`PageBuckets` → `DocSession.visibleStrokesByPage`）的真实成本。运行：
//   cp spike/page-buckets-cost.swift /tmp/main.swift
//   swiftc Sources/App/InkModel.swift Sources/App/InkLayerModel.swift Sources/App/PenPreset.swift \
//     Sources/App/NoteTypeModel.swift Sources/App/TextNoteModel.swift Sources/Store/LibraryModels.swift \
//     Sources/Support/L.swift /tmp/main.swift -o /tmp/pbc && /tmp/pbc          # Debug 口径（-Onone）
//   ...同上加 -O -o /tmp/pbcO && /tmp/pbcO                                     # Release 口径
//
// 为什么要量它：用户报「缩放**没有笔迹的页**照样卡，换本没笔记的 PDF 就不卡」——卡顿与**文档笔迹
// 总量**成正比、与当前页有没有笔迹无关。渲染只画当前页，唯一按全文档量级每帧重做一遍的就是这里。
// 数据按「408学习区」实测建模：组成原理 1201 笔 / 约 89000 点（≈75 点/笔），340 页。
import Foundation

let strokeCount = 1200, ptsPerStroke = 75, pageCount = 340
let layerA = InkLayer.defaultID
var rng = SystemRandomNumberGenerator()

var strokes: [InkStroke] = (0..<strokeCount).map { i in
    var pts: [SIMD3<Double>] = []
    var x = 0.2, y = 0.3
    for _ in 0..<ptsPerStroke {
        x += Double.random(in: -0.004...0.004); y += Double.random(in: -0.004...0.004)
        pts.append(SIMD3(x, y, 0.6))
    }
    // 笔迹集中在少数页（同真实：p117 一页 178 笔），页号散布在 0..<pageCount
    return InkStroke(page: (i * 7) % pageCount, color: InkColor(r: 20, g: 20, b: 24, a: 0.95),
                     width: 6, type: .ballpoint, points: pts, layerId: layerA)
}
let visible: Set<UUID> = [layerA]
let layers: [InkLayer] = [InkLayer(id: layerA, name: "L", colorKey: "gray", sortOrder: 0, visible: true)]

/// `DocSession.visibleStrokesByPage` 的复刻（改那边要同步改这里）
func visibleStrokesByPage(in range: ClosedRange<Int>) -> [Int: [InkStroke]] {
    guard !strokes.isEmpty else { return [:] }
    let order = Dictionary(uniqueKeysWithValues: layers.enumerated().map { ($1.id, $0) })
    let vis = visible
    var out: [Int: [(seq: Int, stroke: InkStroke)]] = [:]
    for (seq, s) in strokes.enumerated() where range.contains(s.page) && vis.contains(s.layerId) {
        out[s.page, default: []].append((seq, s))
    }
    return out.mapValues { items in
        items.sorted { (order[$0.stroke.layerId] ?? 0, $0.seq) < (order[$1.stroke.layerId] ?? 0, $1.seq) }
             .map(\.stroke)
    }
}

func bench(_ label: String, iterations: Int = 200, _ body: () -> Void) {
    body()   // 预热
    let t0 = Date()
    for _ in 0..<iterations { body() }
    let ms = Date().timeIntervalSince(t0) * 1000 / Double(iterations)
    let fps = ms > 0 ? 1000 / ms : 999
    print(String(format: "  %-46@ %7.2f ms/次   (光这一项就把帧率封顶在 %.0f fps)", label as NSString, ms, min(fps, 999)))
}

print("文档笔迹 \(strokeCount) 条 / \(strokeCount * ptsPerStroke) 点，\(pageCount) 页")
print("\n每帧 body 重算时做的事：")
bench("PageBuckets：实化窗口内**有**笔迹（5 页）") { _ = visibleStrokesByPage(in: 115...119) }
bench("PageBuckets：实化窗口内**没有**笔迹（5 页）") { _ = visibleStrokesByPage(in: 300...304) }
bench("PageBuckets：缩小态实化窗口（30 页）") { _ = visibleStrokesByPage(in: 100...129) }

print("\n对照（同规模的其它全量操作）：")
let copy = strokes
bench("[InkStroke] 深比较（onChange(of:) 每次求值都做）") { _ = (copy == strokes) }
bench("filter { layerId == } （LayerRack 每图层一遍）") { _ = strokes.filter { $0.layerId == layerA }.count }
bench("只数 count（现 canvasMargin 的 onChange 用的）") { _ = strokes.count }
