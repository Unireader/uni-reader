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
check(MirrorFp.specs.map(\.table) == ["document", "variant", "note", "ink_layer", "scratch_pad", "md_doc",
                                     "board_note", "board_page", "board_item", "exercise", "exercise_attempt", "meta"],
      "参与同步的表恰好 12 张（location 不在其中 —— 它是设备本地事实；v16 加了画板两张、v17 加了页、v20 习题两张）")
check(MirrorFp.spec("exercise")?.columns.map(\.name) ==
      ["id", "document_id", "page", "seq", "kind", "number", "section", "payload", "starred", "wrong", "source",
       "created_at", "updated_at", "chapter", "note"] && MirrorFp.spec("exercise")?.lww == "updated_at",
      "exercise 列表（v20 章节、v22 笔记在表尾）+ 按 updated_at 取新")
check(MirrorFp.spec("exercise_attempt")?.columns.map(\.name) ==
      ["id", "exercise_id", "answer", "correct", "elapsed_ms", "created_at", "source", "ink", "judged_by", "feedback"]
      && MirrorFp.spec("exercise_attempt")?.lww == nil,
      "exercise_attempt 列表（v21：表尾多手写 / 谁判的 / 评语）+ 没有修改时间（冲突保留源盘）")
check(MirrorFp.spec("board_page")?.columns.map(\.name) ==
      ["id", "board_id", "sort_key", "width", "height", "template", "created_at", "updated_at"],
      "board_page 列表（v17）")
check(MirrorFp.spec("board_note")?.columns.map(\.name) ==
      ["id", "title", "bg", "pattern", "group_name", "created_at", "updated_at"],
      "board_note 列表（v16；**不含 last_opened_at**，同 document）")
check(MirrorFp.spec("board_item")?.columns.map(\.name) ==
      ["id", "board_id", "kind", "x", "y", "w", "h", "payload", "created_at", "updated_at"],
      "board_item 列表（v16）")
check(MirrorFp.spec("md_doc")?.columns.map(\.name) ==
      ["id", "title", "rel_path", "group_name", "sort_order", "created_at", "updated_at"],
      "md_doc 列表（v15；**不含 last_opened_at**，同 document）")
check(MirrorFp.syncedMetaKeys.contains("note_sources") == false,
      "🔴 note_sources 不同步：引用的外部目录是这台机器的事实（同 location 表）")
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

let boardRow: [String: Any] = [
    "id": "66666666-6666-4666-8666-666666666666", "title": "极限草稿",
    "bg": "rgba(252,247,235,1.0)", "pattern": "grid", "group_name": "",
    "created_at": "2026-09-24T09:00:00Z", "updated_at": "2026-09-24T09:30:00Z",
    "last_opened_at": "2026-09-24T10:00:00Z",
]
let boardItemRow: [String: Any] = [
    "id": "77777777-7777-4777-8777-777777777777",
    "board_id": "66666666-6666-4666-8666-666666666666",
    "kind": Int64(1), "x": -120.5, "y": 40.25, "w": 300.0, "h": 88.0,
    "payload": Data("{\"width\":2}".utf8),
    "created_at": "2026-09-24T09:10:00Z", "updated_at": "2026-09-24T09:10:00Z",
]

// 🔴 只许在末尾追加（向量序号就是这里的顺序）
let tableCases: [(String, [String: Any])] = [
    ("document", docRow), ("note", noteRow), ("ink_layer", layerRow),
    ("scratch_pad", padRow), ("variant", variantRow), ("meta", metaRow),
    ("board_note", boardRow), ("board_item", boardItemRow),
    ("board_page", [
        "id": "88888888-8888-4888-8888-888888888888",
        "board_id": "66666666-6666-4666-8666-666666666666",
        "sort_key": 1.5, "width": 595.0, "height": 842.0, "template": "cornell",
        "created_at": "2026-09-26T09:00:00Z", "updated_at": "2026-09-26T09:05:00Z",
    ] as [String: Any]),
    // v20 习题（2026-10-11）：page 有值 / correct 为 NULL（没答案时的作答）各覆盖一次
    // 🔴 v22 起这一行按 15 列编码（笔记缺 = NULL），#30 的编码 / fp 因列规格变了而变（2026-10-27，`EXERCISE-PLAN.md §12`）
    ("exercise", [
        "id": "99999999-9999-4999-8999-999999999999",
        "document_id": "11111111-1111-4111-8111-111111111111",
        "page": Int64(11), "seq": Int64(2), "kind": Int64(1), "number": "5", "section": "习题 2-3",
        "payload": Data("{\"answer\":[\"A\",\"C\"],\"options\":[],\"stem\":\"设 $f(x)=x^2$\"}".utf8),
        "starred": Int64(1), "wrong": Int64(0), "source": "kimi",
        "created_at": "2026-10-10T09:00:00.000Z", "updated_at": "2026-10-11T08:00:00.000Z",
        "chapter": "[\"第二章 导数\",\"2.3 求导法则\"]",
    ] as [String: Any]),
    // 🔴 v21 起这一行按 10 列编码（新三列缺 = NULL），#31 的编码 / fp 因列规格变了而变（2026-10-13，`EXERCISE-PLAN.md §11.5`）
    ("exercise_attempt", [
        "id": "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
        "exercise_id": "99999999-9999-4999-8999-999999999999",
        "answer": "AC", "correct": NSNull(), "elapsed_ms": Int64(4200),
        "created_at": "2026-10-11T08:00:00.000Z", "source": "",
    ] as [String: Any]),
    // v21 主观题作答：手写（blob）+ Agent 判了 + 评语
    ("exercise_attempt", [
        "id": "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB",
        "exercise_id": "99999999-9999-4999-8999-999999999999",
        "answer": "设 $\\sqrt2=p/q$", "correct": Int64(0), "elapsed_ms": Int64(91000),
        "created_at": "2026-10-13T08:00:00.000Z", "source": "",
        "ink": Data("{\"height\":280,\"strokes\":[],\"width\":600}".utf8), "judged_by": "agent", "feedback": "少了**互质**的假设",
    ] as [String: Any]),
    // v22 题目笔记（2026-10-27）：同一道题写了笔记、更新时间跟着变
    ("exercise", [
        "id": "99999999-9999-4999-8999-999999999999",
        "document_id": "11111111-1111-4111-8111-111111111111",
        "page": Int64(11), "seq": Int64(2), "kind": Int64(1), "number": "5", "section": "习题 2-3",
        "payload": Data("{\"answer\":[\"A\",\"C\"],\"options\":[],\"stem\":\"设 $f(x)=x^2$\"}".utf8),
        "starred": Int64(1), "wrong": Int64(1), "source": "kimi",
        "created_at": "2026-10-10T09:00:00.000Z", "updated_at": "2026-10-27T08:00:00.000Z",
        "chapter": "[\"第二章 导数\",\"2.3 求导法则\"]",
        "note": "别忘了 $f'(x)=2x$，**链式法则**",
    ] as [String: Any]),
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
