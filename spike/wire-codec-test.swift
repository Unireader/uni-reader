// 二进制线格式 Swift 端测试。
// 编译运行（项目根目录）：
//   swiftc spike/wire-codec-test.swift Sources/Server/WireCodec.swift -o /tmp/wct && /tmp/wct
// 做两件事：
//   1) 全消息 round-trip 的**字节稳定性**：E1=encode(x)，y=decode(E1)，E2=encode(y)，断言 E1==E2 且 y 非 nil。
//   2) 导出 canonical 消息的字节向量到 spike/wire-vectors-swift.txt，供 wire-cross-test.js 与 JS 端逐字节比对。
import Foundation

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

// —— canonical 消息集（顺序必须与 wire-cross-test.js 一致；数值取 f32 精确值）——
let canonical: [[String: Any]] = [
    ["type": "auth", "token": "abc123"],
    ["type": "authOK"],
    ["type": "authFail"],
    ["type": "ping", "t": 1700000000000],
    ["type": "pong", "t": 1700000000000],
    ["type": "latency", "ms": 42],
    ["type": "selectDoc", "id": "1A2B"],
    ["type": "pageTurn", "dir": "next"],
    ["type": "mode", "mode": "erase"],
    ["type": "pen", "index": 3],
    ["type": "page", "v": 5, "index": 2, "count": 100, "w": 612, "h": 792],
    ["type": "layout", "docId": "H", "v": "H", "count": 2, "pages": [[612.0, 792.0], [595.0, 842.0]]],
    ["type": "viewport", "page": 3, "frac": 0.5, "seq": 7],
    ["type": "viewport", "page": 3, "frac": 0.25, "force": true],
    ["type": "docs", "list": [["id": "a", "title": "T1"], ["id": "b", "title": "标题"]], "selected": "a", "following": false],
    ["type": "pens", "list": [["color": "rgba(24,90,210,0.5)", "w": 8, "t": "ballpoint"],
                              ["color": "rgba(255,214,40,0.25)", "w": 22, "t": "marker"]], "active": 1],
    ["type": "inkCancel"],
    ["type": "strokes", "list": [["page": 1, "pen": ["color": "rgba(20,20,20,1)", "w": 10, "t": "pencil"],
                                  "pts": [[0.5, 0.25, 0.5], [0.75, 0.125, 1.0]]]]],
    ["type": "scroll", "page": 2, "frac": 0.5, "t": 123456],
    ["type": "hover", "page": 1, "nx": 0.5, "ny": 0.25],
    ["type": "hover", "phase": "end"],
    ["type": "ink", "phase": "begin", "page": 0, "pen": ["color": "rgba(24,90,210,0.5)", "w": 8, "t": "ballpoint"],
     "pts": [[0.5, 0.5, 0.5]]],
    ["type": "ink", "phase": "move", "pts": [[0.25, 0.75, 0.5], [0.5, 0.5, 1.0]]],
    ["type": "ink", "phase": "end"],
    ["type": "erase", "phase": "move", "page": 1, "pts": [[0.5, 0.5], [0.25, 0.25]]],
    ["type": "erase", "phase": "end"],
    ["type": "probe", "phase": "begin", "page": 2, "pts": [[0.5, 0.5]]],
    ["type": "probe", "phase": "move", "pts": [[0.25, 0.25]]],
    ["type": "probe", "phase": "end"],
]

var pass = 0, fail = 0
var vectors: [String] = []

// —— 安全性：坏帧不崩、返回 nil ——
func expectNil(_ name: String, _ d: Data) {
    if WireCodec.decode(d) == nil { pass += 1 } else { print("✗ 安全[\(name)]: 期望 nil"); fail += 1 }
}

@main
struct WireCodecTest {
    static func main() {
        for (i, msg) in canonical.enumerated() {
            let type = msg["type"] as? String ?? "?"
            guard let e1 = WireCodec.encode(msg) else {
                print("✗ [\(i)] \(type): encode 返回 nil"); fail += 1; vectors.append(""); continue
            }
            vectors.append(hex(e1))
            guard let y = WireCodec.decode(e1) else {
                print("✗ [\(i)] \(type): decode 返回 nil"); fail += 1; continue
            }
            guard let e2 = WireCodec.encode(y) else {
                print("✗ [\(i)] \(type): 二次 encode 返回 nil"); fail += 1; continue
            }
            if e1 == e2 {
                pass += 1
            } else {
                print("✗ [\(i)] \(type): 字节不稳定\n   E1=\(hex(e1))\n   E2=\(hex(e2))"); fail += 1
            }
        }

        expectNil("空", Data())
        expectNil("未知opcode", Data([0xFF]))
        expectNil("ink截断(缺phase)", Data([0x42]))
        expectNil("scroll截断", Data([0x40, 0x01, 0x00]))
        expectNil("str越界", Data([0x01, 0xff, 0xff]))   // auth: len=0xffff 但无内容

        let out = vectors.joined(separator: "\n") + "\n"
        let path = "spike/wire-vectors-swift.txt"
        try? out.write(toFile: path, atomically: true, encoding: .utf8)

        print("—")
        print("round-trip + 安全: \(pass) 通过, \(fail) 失败；已写 \(canonical.count) 条向量 → \(path)")
        exit(fail == 0 ? 0 : 1)
    }
}
