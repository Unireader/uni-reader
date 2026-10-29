// 连接服务器的同步线格式（`SyncWire`，`PROTOCOL.md §9`）跨端向量。运行（仓库根目录）：
//   cp spike/sync-wire-test.swift /tmp/main.swift && swiftc Sources/Store/MirrorFingerprint.swift \
//     Sources/Sync/SyncWire.swift /tmp/main.swift -o /tmp/swt && /tmp/swt [--write]
// （须命名为 main.swift）
//
// 不带参数：编出下面的 canonical 消息，与 spike/sync-wire-vectors.txt 逐字节比对，再把文件里的字节解回来、重编一遍比对。
// `--write`：重写向量文件（只在**末尾追加**了新消息时用；改动已有消息 = 改了线格式，三端一起改）。
// 安卓 `SyncWireTest` 照同一张表在 Kotlin 里编一遍、比同一份文件。
// 🔴 canonical 表**只许在末尾追加**（同 wire-codec-test 的纪律）。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }
func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func unhex(_ s: Substring) -> Data {
    var d = Data(); var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        d.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return d
}

typealias Row = [String: MirrorFp.Value]

/// 一行把四种值和 NULL 都带上；REAL 用 0.5 / -2.5 这类二进制精确的数（两端写字面量不会差一位）。
let noteRow: Row = [
    "id": .text("A1B2C3D4-0000-0000-0000-000000000001"),
    "document_id": .text("D0C00000-0000-0000-0000-000000000001"),
    "page": .int(3),
    "kind": .int(-1),
    "payload": .blob(Data([0x00, 0x01, 0xfe, 0xff])),
    "x": .real(0.5),
    "y": .real(-2.5),
    "title": .text("中文 · note"),
    "updated_at": .null,
]
let metaRow: Row = ["key": .text("workspace_name"), "value": .text("101学习区")]

let canonical: [(String, Data)] = [
    ("push_empty", SyncWire.encode(SyncWire.PushRequest(schemaVersion: 22, changes: []))),
    ("push_rows", SyncWire.encode(SyncWire.PushRequest(schemaVersion: 22, changes: [
        .init(table: "note", rowId: "A1B2C3D4-0000-0000-0000-000000000001", op: .upsert, baseFp: nil, row: noteRow),
        .init(table: "note", rowId: "A1B2C3D4-0000-0000-0000-000000000002", op: .delete, baseFp: "0123456789abcdef", row: nil),
        .init(table: "meta", rowId: "workspace_name", op: .upsert, baseFp: "fedcba9876543210", row: metaRow),
        .init(table: "ocr_page", rowId: "abc\u{1F}0\u{1F}paddle", op: .upsert, baseFp: nil,
              row: ["content_hash": .text("abc"), "page": .int(0), "provider": .text("paddle"),
                    "payload": .blob(Data([1, 2, 3])), "lang": .null, "created_at": .text("2026-10-29T00:00:00.000Z")]),
    ]))),
    ("push_resp", SyncWire.encode(SyncWire.PushResponse(
        head: 42,
        results: [
            .init(table: "note", rowId: "A1B2C3D4-0000-0000-0000-000000000001", outcome: .applied, rev: 41),
            .init(table: "note", rowId: "A1B2C3D4-0000-0000-0000-000000000002", outcome: .keptServer, rev: 7),
            .init(table: "image", rowId: "ffee", outcome: .missingFile, rev: 0),
            .init(table: "variant", rowId: "V1", outcome: .skippedClash, rev: 0),
            .init(table: "note", rowId: "N9", outcome: .skippedOrphan, rev: 0),
            .init(table: "meta", rowId: "workspace_name", outcome: .unchanged, rev: 3),
        ],
        conflicts: [
            .init(table: "note", rowId: "A1B2C3D4-0000-0000-0000-000000000002", kind: .bothModified, keptServer: true),
            .init(table: "document", rowId: "D1", kind: .deleteVsEdit, keptServer: false),
            .init(table: "bookmark", rowId: "B1", kind: .bothAdded, keptServer: true),
        ],
        serverRows: [
            .init(table: "note", rowId: "A1B2C3D4-0000-0000-0000-000000000002", rev: 7, deleted: false, row: noteRow),
            .init(table: "note", rowId: "N8", rev: 9, deleted: true, row: nil),
        ]))),
    ("pull_empty", SyncWire.encode(SyncWire.PullResponse(head: 0, more: false, rows: []))),
    ("pull_rows", SyncWire.encode(SyncWire.PullResponse(head: 0x1_0000_0001, more: true, rows: [
        .init(table: "meta", rowId: "workspace_name", rev: 1, deleted: false, row: metaRow),
        .init(table: "note", rowId: "A1B2C3D4-0000-0000-0000-000000000001", rev: 2, deleted: false, row: noteRow),
        .init(table: "bookmark", rowId: "B1", rev: 0x1_0000_0000, deleted: true, row: nil),
    ]))),
]

let path = "spike/sync-wire-vectors.txt"
if CommandLine.arguments.contains("--write") {
    var out = """
    # 连接服务器的同步线格式（`PROTOCOL.md §9`，`Sources/Sync/SyncWire.swift`）跨端向量。
    # 格式：每行 `名字|十六进制`。由 Mac `spike/sync-wire-test.swift --write` 生成；安卓 `SyncWireTest` 在 Kotlin 里编同一组消息逐字节比对。
    # 🔴 只许在末尾追加。

    """
    for (name, data) in canonical { out += "\(name)|\(hex(data))\n" }
    try! out.write(toFile: path, atomically: true, encoding: .utf8)
    print("已写 \(path)（\(canonical.count) 条）")
    exit(0)
}

print("① 编码与向量文件逐字节一致")
let file = try! String(contentsOfFile: path, encoding: .utf8)
var vectors: [String: Data] = [:]
for line in file.split(separator: "\n") where !line.hasPrefix("#") {
    let p = line.split(separator: "|")
    guard p.count == 2 else { continue }
    vectors[String(p[0])] = unhex(p[1])
}
check(vectors.count == canonical.count, "向量条数 \(vectors.count) = \(canonical.count)")
for (name, data) in canonical { check(vectors[name] == data, name) }

print("② 文件里的字节解回来再编，一字不差")
for (name, _) in canonical {
    guard let d = vectors[name] else { continue }
    let again: Data?
    switch name {
    case let n where n.hasPrefix("push_resp"): again = (try? SyncWire.decodePushResponse(d)).map { SyncWire.encode($0) }
    case let n where n.hasPrefix("push"): again = (try? SyncWire.decodePushRequest(d)).map { SyncWire.encode($0) }
    default: again = (try? SyncWire.decodePullResponse(d)).map { SyncWire.encode($0) }
    }
    check(again == d, name)
}

print("③ 坏数据解不出")
let good = vectors["pull_rows"]!
check((try? SyncWire.decodePullResponse(good.dropLast())) == nil, "截断")
check((try? SyncWire.decodePullResponse(good + Data([0]))) == nil, "尾部多字节")
var badVer = good; badVer[0] = 2
check((try? SyncWire.decodePullResponse(badVer)) == nil, "版本不对")

print("\n\(pass) 通过，\(fail) 失败")
exit(fail == 0 ? 0 : 1)
