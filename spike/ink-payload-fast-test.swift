// `InkPayloadFast.splitPoints` 的正确性 + 耗时对比（2026-09-10，开文档「笔迹」段 506ms 的修法）。
//   ① 逐位比对：快路解出的每个 Float（`InkPoint`）与「JSONDecoder 解 `[[Double]]` 再 `Float(d)`」bitPattern 相同；
//   ② 形态：JSONEncoder 原样 / 带空格与换行（别的端写的）/ 两元素点 / 空数组 / 负数与指数 /
//      points 排在最前或最后 / 整数写法；
//   ③ 坏形态一律 nil（调用方回落）；
//   ④ 计时：2616 笔 × 100 点，JSONDecoder 整段 vs 快路 + 小段 JSONDecoder。
// 运行（`InkPayloadFast` 住在 InkModel.swift 里，带上它的依赖，与 ink-store-test 同一套；
// 本文件用 `@main`，**别**改名成 main.swift）：
//   swiftc -O Sources/Store/*.swift Sources/App/InkModel.swift Sources/App/InkLayerModel.swift \
//     Sources/App/NoteTypeModel.swift Sources/App/PenPreset.swift Sources/Support/L.swift \
//     spike/ink-payload-fast-test.swift -o /tmp/ipf && /tmp/ipf

import Foundation

nonisolated(unsafe) var pass = 0
nonisolated(unsafe) var fail = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail += 1; print("  ✗ \(name) \(detail)") }
}

/// 与 `InkStrokePayload` 同形（本 spike 只编 InkPayloadFast.swift，不带整个 InkModel 的依赖）。
struct Payload: Codable {
    struct Color: Codable, Equatable { var r: Double, g: Double, b: Double, a: Double }
    var color: Color
    var width: Double
    var type: String
    var points: [[Double]]
    var layerId: UUID
    var padId: UUID?
}

func samePoints(_ a: [InkPoint], _ b: [[Double]]) -> Bool {
    guard a.count == b.count else { return false }
    for (p, q) in zip(a, b) {
        // 参照值走与回落路径同一种转换：Double 解出再 Float(d)
        let x = Float(q.count > 0 ? q[0] : 0), y = Float(q.count > 1 ? q[1] : 0), z = Float(q.count > 2 ? q[2] : 0.5)
        if p.x.bitPattern != x.bitPattern || p.y.bitPattern != y.bitPattern || p.z.bitPattern != z.bitPattern { return false }
    }
    return true
}

@main
struct InkPayloadFastTest {
static func main() {
    var rng = SystemRandomNumberGenerator()
    func randomStroke(points n: Int) -> Payload {
        var pts: [[Double]] = []
        for _ in 0..<n {
            pts.append([Double.random(in: -0.2...1.2, using: &rng),
                        Double.random(in: 0...1, using: &rng),
                        Double.random(in: 0...1, using: &rng)])
        }
        return Payload(color: .init(r: 24, g: 90, b: 210, a: 0.95), width: 2.5, type: "pencil",
                       points: pts, layerId: UUID(), padId: nil)
    }
    let enc = JSONEncoder(), dec = JSONDecoder()

    print("① 逐位比对（JSONEncoder 原样）")
    do {
        let p = randomStroke(points: 200)
        let data = try! enc.encode(p)
        let fast = InkPayloadFast.splitPoints(data)
        check("解得出", fast != nil)
        if let fast {
            let ref = try! dec.decode(Payload.self, from: data)
            check("200 点逐位相同", samePoints(fast.points, ref.points))
            let rest = try! dec.decode(Payload.self, from: fast.rest)
            check("其余字段不变", rest.color == p.color && rest.width == p.width && rest.type == p.type
                  && rest.layerId == p.layerId && rest.padId == nil && rest.points.isEmpty)
        }
    }

    print("② 各种形态")
    func tryForm(_ name: String, _ json: String, expect: [[Double]]?, restCheck: ((Payload) -> Bool)? = nil) {
        let data = json.data(using: .utf8)!
        let fast = InkPayloadFast.splitPoints(data)
        if let expect {
            guard let fast else { check(name, false, "快路返回 nil"); return }
            check(name, samePoints(fast.points, expect), "\(fast.points)")
            if let restCheck {
                let r = try? dec.decode(Payload.self, from: fast.rest)
                check("\(name)：其余字段", r.map(restCheck) ?? false, String(data: fast.rest, encoding: .utf8) ?? "")
            }
        } else {
            check(name, fast == nil, "本该 nil")
        }
    }
    let uuid = UUID().uuidString
    let head = "{\"color\":{\"r\":1,\"g\":2,\"b\":3,\"a\":0.5},\"width\":3,\"type\":\"ballpoint\",\"layerId\":\"\(uuid)\""
    tryForm("带空格与换行", "\(head), \"points\" : [ [0.1, 0.2, 0.3],\n [0.4 ,0.5 , 0.6] ] }",
            expect: [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]], restCheck: { $0.width == 3 && $0.points.isEmpty })
    tryForm("两元素点补压感 0.5", "\(head),\"points\":[[0.1,0.2],[0.3,0.4]]}", expect: [[0.1, 0.2], [0.3, 0.4]])
    tryForm("空数组", "\(head),\"points\":[]}", expect: [])
    tryForm("负数与指数", "\(head),\"points\":[[-0.25,1e-05,5E+2],[2,-3,1.5e0]]}",
            expect: [[-0.25, 1e-05, 5e2], [2, -3, 1.5]])
    tryForm("整数写法", "\(head),\"points\":[[0,1,1],[1,0,0]]}", expect: [[0, 1, 1], [1, 0, 0]])
    tryForm("points 在最前", "{\"points\":[[0.5,0.5,0.5]],\"color\":{\"r\":1,\"g\":2,\"b\":3,\"a\":0.5},\"width\":3,\"type\":\"ballpoint\",\"layerId\":\"\(uuid)\"}",
            expect: [[0.5, 0.5, 0.5]], restCheck: { $0.type == "ballpoint" })
    tryForm("草稿纸 padId", "\(head),\"padId\":\"\(uuid)\",\"points\":[[0.5,0.5,0.5]]}",
            expect: [[0.5, 0.5, 0.5]], restCheck: { $0.padId?.uuidString == uuid })
    tryForm("四元素点只取前三", "\(head),\"points\":[[0.1,0.2,0.3,0.9]]}", expect: [[0.1, 0.2, 0.3]])
    tryForm("空点 [] 按 0,0,0.5", "\(head),\"points\":[[]]}", expect: [[]])

    print("③ 坏形态回落")
    tryForm("没有 points 键", "\(head)}", expect: nil)
    tryForm("points 不是数组", "\(head),\"points\":3}", expect: nil)
    tryForm("内层不是数组", "\(head),\"points\":[0.1,0.2]}", expect: nil)
    tryForm("数组没闭合", "\(head),\"points\":[[0.1,0.2,0.3]", expect: nil)
    tryForm("数字里混字母", "\(head),\"points\":[[0.1,abc,0.3]]}", expect: nil)

    print("④ 计时（2616 笔 × 100 点）")
    let strokes = (0..<2616).map { _ in try! enc.encode(randomStroke(points: 100)) }
    let bytes = strokes.reduce(0) { $0 + $1.count }
    var t = CFAbsoluteTimeGetCurrent()
    var refPts = 0
    for d in strokes { refPts += (try! dec.decode(Payload.self, from: d)).points.count }
    let slow = (CFAbsoluteTimeGetCurrent() - t) * 1000
    t = CFAbsoluteTimeGetCurrent()
    var fastPts = 0
    for d in strokes {
        let f = InkPayloadFast.splitPoints(d)!
        _ = try! dec.decode(Payload.self, from: f.rest)
        fastPts += f.points.count
    }
    let quick = (CFAbsoluteTimeGetCurrent() - t) * 1000
    check("点数一致", refPts == fastPts)
    print(String(format: "  payload 共 %.1f MB：JSONDecoder 整段 %.0fms → 快路 %.0fms（%.1f×）",
                 Double(bytes) / 1048576, slow, quick, slow / max(quick, 0.001)))
    // 单线程只求明显更快；真正的收益在 ⑤ 的并行（strtod 版单线程更快但多线程不伸缩，见 InkPayloadFast 注释）。
    check("快路单线程至少快 2 倍", quick * 2 < slow, String(format: "%.0f vs %.0f", quick, slow))

    print("⑤ 并行解码（`InkStroke.decodeAll`）：结果与顺序解一致、顺序不乱")
    let notes: [LibInkRow] = strokes.enumerated().map { i, d in
        LibInkRow(id: UUID().uuidString, kind: InkStroke.noteKind, page: i / 10, payload: d)
    }
    t = CFAbsoluteTimeGetCurrent()
    let seq = notes.compactMap(InkStroke.init(row:))
    let seqMs = (CFAbsoluteTimeGetCurrent() - t) * 1000
    t = CFAbsoluteTimeGetCurrent()
    let par = InkStroke.decodeAll(notes)
    let parMs = (CFAbsoluteTimeGetCurrent() - t) * 1000
    check("条数一致", seq.count == par.count && par.count == notes.count)
    check("逐条相同且顺序一致", seq == par)
    print(String(format: "  顺序解 %.0fms → 并行 %.0fms（%d 核）", seqMs, parMs, ProcessInfo.processInfo.activeProcessorCount))
    if ProcessInfo.processInfo.activeProcessorCount >= 4 {
        check("并行比 JSONDecoder 整段至少快 5 倍", parMs * 5 < slow, String(format: "%.0f vs %.0f", parMs, slow))
    }

    print("\n\(pass) 通过 / \(fail) 失败")
    exit(fail == 0 ? 0 : 1)
}
}
