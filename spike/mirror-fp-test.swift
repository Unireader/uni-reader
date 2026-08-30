// 离线镜像 行指纹（`MirrorFp`）测试 + **跨端向量导出**。方案见 OFFLINE-MIRROR-PLAN.md §3.3。
// 运行：
//   cp spike/mirror-fp-test.swift /tmp/main.swift \
//     && swiftc Sources/Store/MirrorFingerprint.swift /tmp/main.swift -o /tmp/mfp && /tmp/mfp
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
//
// 跑完会写出 spike/mirror-fp-vectors.txt（`序号|标签|编码hex|fp`），安卓 `MirrorFpTest` 逐条比对
// —— 两端算出的 fp 差一个 bit，合并时整张表就会被误判成「全都改过」。
// 🔴 canonical 表**只允许在末尾追加**：往中间插会静默错位掉整套跨端凭据（同 wire-codec-test 的纪律）。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

typealias V = MirrorFp.Value

func encAll(_ vs: [V]) -> Data {
    var buf = Data()
    for (i, v) in vs.enumerated() {
        if i > 0 { buf.append(MirrorFp.separator) }
        buf.append(MirrorFp.enc(v))
    }
    return buf
}

// —— canonical 向量表（只许在末尾追加）——
let canonical: [(String, [V])] = [
    ("null",                [.null]),
    ("int 0",               [.int(0)]),
    ("int -1",              [.int(-1)]),
    ("int max",             [.int(9223372036854775807)]),
    ("int min",             [.int(-9223372036854775808)]),
    ("real 0",              [.real(0)]),
    ("real -0",             [.real(-0.0)]),
    ("real 1",              [.real(1)]),
    ("real -1.5",           [.real(-1.5)]),
    ("real 0.1",            [.real(0.1)]),
    ("real pi",             [.real(3.141592653589793)]),
    ("text empty",          [.text("")]),
    ("text hello",          [.text("hello")]),
    ("text cjk",            [.text("中文 · 笔迹")]),
    ("text NUL",            [.text("\u{0}")]),
    ("blob empty",          [.blob(Data())]),
    ("blob 00 1f ff",       [.blob(Data([0x00, 0x1F, 0xFF]))]),
    ("two text a,b",        [.text("a"), .text("b")]),
    ("one text a US b",     [.text("a\u{1F}b")]),
    ("two blob a,b",        [.blob(Data("a".utf8)), .blob(Data("b".utf8))]),
    ("mixed row",           [.text("id-1"), .int(7), .real(0.25), .null, .blob(Data([0xDE, 0xAD]))]),
]

print("① 编码与指纹（canonical 向量）")
var lines: [String] = []
for (i, c) in canonical.enumerated() {
    let e = encAll(c.1)
    let fp = MirrorFp.fingerprint(c.1)
    lines.append("\(i)|\(c.0)|\(hex(e))|\(fp)")
    check(fp.count == 16, "#\(i) \(c.0) → fp 16 位十六进制（\(fp)）")
}

print("② 语义等价必须同 fp / 语义不同必须异 fp")
check(MirrorFp.fingerprint([.real(0)]) == MirrorFp.fingerprint([.real(-0.0)]),
      "-0.0 与 +0.0 同 fp（位模式不同但语义相同，不归一就是全表误判）")
check(MirrorFp.fingerprint([.real(Double.nan)]) == MirrorFp.fingerprint([.real(-Double.nan)]),
      "任意 NaN 同 fp")
check(MirrorFp.fingerprint([.null]) != MirrorFp.fingerprint([.text("")]),
      "NULL ≠ 空字符串（类型标签挡住）")
check(MirrorFp.fingerprint([.null]) != MirrorFp.fingerprint([.blob(Data([0x00]))]),
      "NULL ≠ 单字节 0x00 的 BLOB")
check(MirrorFp.fingerprint([.text("")]) != MirrorFp.fingerprint([.blob(Data())]),
      "空 TEXT ≠ 空 BLOB")
check(MirrorFp.fingerprint([.int(1)]) != MirrorFp.fingerprint([.text("1")]),
      "int 1 ≠ text \"1\"")
check(MirrorFp.fingerprint([.blob(Data("a".utf8)), .blob(Data("b".utf8))]) !=
      MirrorFp.fingerprint([.text("a"), .text("b")]),
      "(blob a, blob b) ≠ (text a, text b) —— 编码是单射的，不靠『同列类型固定』兜底")
check(MirrorFp.fingerprint([.text("a"), .text("b")]) != MirrorFp.fingerprint([.text("a\u{1F}b")]),
      "分隔符不产生歧义：('a','b') ≠ ('a\\x1Fb')")
check(MirrorFp.fingerprint([.int(1)]) != MirrorFp.fingerprint([.real(1)]),
      "INTEGER 1 ≠ REAL 1.0（所以取值必须按列的声明类型归一，见 ③）")

print("③ coerce：存储类漂移必须归一（同一个值两端存法不同 → fp 必须相同）")
// `read_zoom REAL`：一端绑 Double 存成 REAL、另一端绑 Int 存成 INTEGER
check(MirrorFp.coerce(Int64(1), as: .real) == V.real(1.0), "REAL 列里的 INTEGER 1 → real(1.0)")
check(MirrorFp.coerce(1.0, as: .real) == V.real(1.0), "REAL 列里的 REAL 1.0 → real(1.0)")
// `page INTEGER`：反向漂移
check(MirrorFp.coerce(3.0, as: .int) == V.int(3), "INTEGER 列里的 REAL 3.0 → int(3)")
// `payload BLOB`（BLOB 亲和不做转换，绑 String 就真的存成 TEXT）
check(MirrorFp.coerce("{}", as: .blob) == V.blob(Data("{}".utf8)), "BLOB 列里的 TEXT → 字节")
check(MirrorFp.coerce(NSNull(), as: .text) == V.null, "NSNull → null")
check(MirrorFp.coerce(nil, as: .text) == V.null, "缺列（nil）→ null，老库少一列不炸")

print("④ 表规格：列顺序 = 全新库 CREATE TABLE 的顺序")
check(MirrorFp.spec("document")?.columns.map(\.name) ==
      ["id", "title", "page_count", "added_at", "sort_order",
       "read_page", "read_frac", "read_zoom", "read_hfrac", "group_name", "canvas_mode"],
      "document 列表（**不含 last_opened_at**，见方案 §4）")
check(MirrorFp.spec("note")?.columns.map(\.name) ==
      ["id", "document_id", "kind", "page", "anchor_x", "anchor_y", "anchor_w", "anchor_h",
       "payload", "created_at", "updated_at"], "note 列表")
check(MirrorFp.specs.map(\.table) == ["document", "variant", "note", "ink_layer", "scratch_pad", "meta"],
      "参与同步的表恰好 6 张（location 不在其中 —— 它是设备本地事实）")
check(MirrorFp.spec("location") == nil, "🔴 location 没有 spec：同步它就是制造满屏假『路径失效』")

print("⑤ 真实表行（按 spec 取值算 fp）")
let docRow: [String: Any] = [
    "id": "11111111-1111-4111-8111-111111111111", "title": "高等数学", "page_count": Int64(412),
    "added_at": "2026-08-30T10:00:00Z", "last_opened_at": "2026-08-30T12:34:56Z",
    "sort_order": Int64(3), "read_page": Int64(86), "read_frac": 0.25, "read_zoom": 1.0,
    "read_hfrac": 0.0, "group_name": "考研", "canvas_mode": Int64(1),
]
let noteRow: [String: Any] = [
    "id": "22222222-2222-4222-8222-222222222222",
    "document_id": "11111111-1111-4111-8111-111111111111",
    "kind": Int64(2), "page": Int64(86),
    "anchor_x": 0.1, "anchor_y": 0.2, "anchor_w": 0.3, "anchor_h": 0.4,
    "payload": Data("{\"w\":8}".utf8),
    "created_at": "2026-08-30T11:00:00Z", "updated_at": "2026-08-30T11:00:01Z",
]
let layerRow: [String: Any] = [
    "id": "33333333-3333-4333-8333-333333333333",
    "document_id": "11111111-1111-4111-8111-111111111111",
    "name": "批注", "color_key": "blue", "sort_order": Int64(1), "visible": Int64(1),
    "created_at": "2026-08-30T09:00:00Z",
]
let padRow: [String: Any] = [
    "id": "44444444-4444-4444-8444-444444444444",
    "document_id": "11111111-1111-4111-8111-111111111111",
    "title": "推导", "anchor_page": Int64(86), "anchor_x": 0.5, "anchor_y": 0.5,
    "bg": "rgba(255,255,255,1.0)", "pattern": "dots", "show_page": Int64(0),
    "created_at": "2026-08-30T11:10:00Z", "updated_at": "2026-08-30T11:20:00Z",
]
let variantRow: [String: Any] = [
    "id": "55555555-5555-4555-8555-555555555555",
    "document_id": "11111111-1111-4111-8111-111111111111",
    "content_hash": "abc123", "page_count": Int64(412), "added_at": "2026-08-30T10:00:00Z",
]
let metaRow: [String: Any] = ["key": "workspace_name", "value": "考研"]

let tableCases: [(String, [String: Any])] = [
    ("document", docRow), ("note", noteRow), ("ink_layer", layerRow),
    ("scratch_pad", padRow), ("variant", variantRow), ("meta", metaRow),
]
for (t, row) in tableCases {
    guard let sp = MirrorFp.spec(t) else { check(false, "\(t) 有 spec"); continue }
    let vals = sp.columns.map { MirrorFp.coerce(row[$0.name], as: $0.type) }
    let fp = MirrorFp.fingerprint(vals)
    lines.append("\(lines.count)|row \(t)|\(hex(encAll(vals)))|\(fp)")
    check(fp.count == 16, "行 \(t) → \(fp)")
}

// document 的 last_opened_at 改了不该影响 fp
var docRow2 = docRow
docRow2["last_opened_at"] = "2099-01-01T00:00:00Z"
check(MirrorFp.fingerprint(row: docRow, spec: MirrorFp.spec("document")!) ==
      MirrorFp.fingerprint(row: docRow2, spec: MirrorFp.spec("document")!),
      "🔴 只改 last_opened_at → fp 不变（否则翻开一本书就在预览里刷一条）")
var docRow3 = docRow
docRow3["read_page"] = Int64(87)
check(MirrorFp.fingerprint(row: docRow, spec: MirrorFp.spec("document")!) !=
      MirrorFp.fingerprint(row: docRow3, spec: MirrorFp.spec("document")!),
      "改 read_page → fp 变（阅读进度要同步）")

print("⑥ 整表 fingerprints")
let rows = [docRow, docRow2]
let m = MirrorFp.fingerprints(rows: rows, spec: MirrorFp.spec("document")!)
check(m.count == 1, "同 id 的两行只留一条（row_id 作键）")
check(m["11111111-1111-4111-8111-111111111111"] != nil, "键是主键列的值")

// —— 导出向量 ——
let out = FileManager.default.currentDirectoryPath + "/spike/mirror-fp-vectors.txt"
let header = """
# MirrorFp 跨端向量（由 spike/mirror-fp-test.swift 生成，勿手改）
# 格式：序号|标签|编码hex|fp   —— fp = SHA256(编码)[0..8] 的小写 hex
# 安卓 `MirrorFpTest` 逐条比对；本表只许在末尾追加。

"""
try? (header + lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
print("\n向量已写出：\(out)（\(lines.count) 条）")

print("\n通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
