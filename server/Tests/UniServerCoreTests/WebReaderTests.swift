import Foundation
import XCTest
@testable import UniServerCore

/// 网页阅读器用的书目查询（`WEB-READER-PLAN.md §3`）。
final class WebReaderTests: XCTestCase {

    /// 顺序同 App 的书目；每本书挑**第一个服务器上有文件的版本**，一个都没有就不给哈希；分组与阅读进度原样给。
    func testDocumentsPickFirstVariantOnServer() throws {
        let f = try Fixture()
        let a = try f.makeDevice("A")
        try Seed.addDoc(a, "D1", title: "甲")
        try Seed.addDoc(a, "D2", title: "乙")
        let missing = String(repeating: "a", count: 64)
        try a.db { db in
            try db.run("UPDATE document SET sort_order=-1 WHERE id='D2'")
            try db.run("UPDATE document SET group_name='第一章', read_page=3, read_frac=0.25 WHERE id='D1'")
            // D1 先加的版本服务器上没有文件（也没有本机路径），后加的才有
            try db.run("INSERT INTO variant(id,document_id,content_hash,page_count,added_at) VALUES('V0','D1',?,7,'2026-10-29T09:00:00.000Z')",
                       [.text(missing)])
            try db.run("INSERT INTO variant(id,document_id,content_hash,page_count,added_at) VALUES('V9','D2',?,7,'2026-10-29T09:00:00.000Z')",
                       [.text(String(repeating: "b", count: 64))])
        }
        let hash = try Seed.addPDF(a, doc: "D1", bytes: "pdf")
        let ws = try f.upload(a)

        let docs = try ws.documents()
        XCTAssertEqual(docs.map(\.id), ["D2", "D1"], "顺序同 App 书目（sort_order）")
        XCTAssertNil(docs[0].contentHash, "服务器上一份 PDF 都没有")
        XCTAssertNil(docs[0].pdfBytes)
        XCTAssertEqual(docs[1].contentHash, hash, "跳过服务器上没有文件的版本")
        XCTAssertEqual(docs[1].pdfBytes, 3)
        XCTAssertEqual(docs[1].pageCount, 10, "页数用选中的那个版本的")
        XCTAssertEqual(docs[1].group, "第一章")
        XCTAssertEqual(docs[1].readPage, 3)
        XCTAssertEqual(docs[1].readFrac, 0.25)

        _ = try f.host.delete(ws.id, device: "A")
        XCTAssertThrowsError(try ws.documents(), "工作区删掉后老实例不再给数据")
    }
}

/// W2：页面上的标记、图层、笔记类型、扫描页对齐（`WEB-READER-PLAN.md §3 / §4`）。
final class WebReaderMarksTests: XCTestCase {

    private func blob(_ pts: [SIMD3<Float>]) -> Data { InkPointsBlob.encode(pts) }

    /// 只给文字笔记 / 笔迹 / 高亮、只给范围里的页；笔迹的点按 App 的规则挑（`BINARY-INK-PLAN.md §3`），一律给二进制、payload 里的点摘掉。
    func testPageMarksPickPointsLikeApp() throws {
        let f = try Fixture()
        let a = try f.makeDevice("A")
        try Seed.addDoc(a, "D1", title: "甲")
        let fresh: [SIMD3<Float>] = [[0.1, 0.2, 0.5], [0.3, 0.4, 0.6]]
        let stale: [SIMD3<Float>] = [[0.9, 0.9, 0.9]]
        let only: [SIMD3<Float>] = [[0.7, 0.1, 0.2]]
        try a.db { db in
            func note(_ id: String, kind: Int, page: Int, created: String, payload: String,
                      points: Data? = nil, pointsAt: String? = nil) throws {
                try db.run("""
                INSERT INTO note(id,document_id,kind,page,anchor_x,anchor_y,anchor_w,anchor_h,payload,created_at,updated_at,points,points_at)
                VALUES(?,'D1',?,?,0.1,0.2,0.3,0.4,?,?,'u1',?,?)
                """, [.text(id), .int(Int64(kind)), .int(Int64(page)), .blob(Data(payload.utf8)), .text(created),
                      points.map { .blob($0) } ?? .null, pointsAt.map { .text($0) } ?? .null])
            }
            let ink = #"{"color":{"r":1,"g":2,"b":3,"a":0.5},"width":8,"type":"fountain","points":%@,"layerId":"L1"}"#
            // 新格式：二进制有效，JSON 点是空的
            try note("N1", kind: 2, page: 0, created: "c1", payload: String(format: ink, "[]"), points: blob(fresh), pointsAt: "u1")
            // 旧版 App 改过：二进制过期，以 JSON 为准
            try note("N2", kind: 2, page: 1, created: "c2", payload: String(format: ink, "[[0.5,0.5,0.7]]"), points: blob(stale), pointsAt: "u0")
            // 只有二进制（过期也用它：JSON 里没有点）
            try note("N3", kind: 2, page: 1, created: "c3", payload: String(format: ink, "[]"), points: blob(only), pointsAt: "u0")
            try note("N4", kind: 0, page: 1, created: "c1", payload: #"{"quote":"","text":"看这里","rects":[]}"#)
            try note("N5", kind: 3, page: 2, created: "c1", payload: #"{"quote":"字","rects":[[0.1,0.2,0.3,0.04]],"color":{"r":255,"g":214,"b":40,"a":1}}"#)
            try note("N6", kind: 4, page: 0, created: "c1", payload: String(format: ink, "[]"), points: blob(fresh), pointsAt: "u1")
            try note("N7", kind: 2, page: 5, created: "c1", payload: String(format: ink, "[]"), points: blob(fresh), pointsAt: "u1")
            try note("N8", kind: 2, page: 0, created: "c9", payload: "坏了")
        }
        let ws = try f.upload(a)

        let marks = try ws.pageMarks(documentId: "D1", from: 0, to: 2)
        XCTAssertEqual(marks.map(\.id), ["N1", "N4", "N2", "N3", "N5"], "按页、创建时刻排；草稿纸笔迹、范围外、坏行都不给")
        let byId = Dictionary(uniqueKeysWithValues: marks.map { ($0.id, $0) })
        XCTAssertEqual(byId["N1"]?.points.flatMap(InkPointsBlob.decode), fresh)
        XCTAssertEqual(byId["N2"]?.points.flatMap(InkPointsBlob.decode), [[0.5, 0.5, 0.7]], "二进制过期 → JSON")
        XCTAssertEqual(byId["N3"]?.points.flatMap(InkPointsBlob.decode), only)
        for id in ["N1", "N2", "N3"] {
            XCTAssertTrue(byId[id]!.payload.contains(#""points":[]"#), id)
            XCTAssertTrue(byId[id]!.payload.contains(#""type":"fountain""#), id)
        }
        XCTAssertNil(byId["N4"]?.points)
        XCTAssertEqual(byId["N4"]?.payload, #"{"quote":"","text":"看这里","rects":[]}"#, "非笔迹 payload 原样")
        XCTAssertEqual(byId["N4"]?.anchor, [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(try ws.pageMarks(documentId: "D1", from: 3, to: 9).map(\.id), ["N7"])
        XCTAssertThrowsError(try ws.pageMarks(documentId: "nope", from: 0, to: 1)) {
            XCTAssertEqual($0 as? ServerError, .unknownDocument("nope"))
        }
    }

    /// 图层按 sort_order；笔记类型、对齐参数原样给；对齐只给打开的那份 PDF、且开着的。
    func testDocumentView() throws {
        let f = try Fixture()
        let a = try f.makeDevice("A")
        try Seed.addDoc(a, "D1", title: "甲")
        let h1 = String(repeating: "1", count: 64), h2 = String(repeating: "2", count: 64)
        let align = #"{"v":1,"w":500,"pages":[[0.01,2,0,498,700]]}"#
        try a.db { db in
            try db.run("INSERT INTO ink_layer(id,document_id,name,color_key,sort_order,visible,created_at) VALUES('L2','D1','二','blue',1,0,'t')")
            try db.run("INSERT INTO ink_layer(id,document_id,name,color_key,sort_order,visible,created_at) VALUES('L1','D1','一','red',0,1,'t')")
            try db.run("INSERT OR REPLACE INTO meta(key,value) VALUES('note_types','[{\"id\":\"T\",\"name\":\"疑问\",\"color_key\":\"red\",\"icon_name\":\"flag\"}]')")
            try db.run("INSERT INTO page_align(content_hash,enabled,page_count,payload,created_at,updated_at) VALUES(?,1,1,?,'t','t')",
                       [.text(h1), .blob(Data(align.utf8))])
            try db.run("INSERT INTO page_align(content_hash,enabled,page_count,payload,created_at,updated_at) VALUES(?,0,1,?,'t','t')",
                       [.text(h2), .blob(Data(align.utf8))])
        }
        let ws = try f.upload(a)

        let v = try ws.documentView(documentId: "D1", contentHash: h1)
        XCTAssertEqual(v.layers.map(\.id), ["L1", "L2"])
        XCTAssertEqual(v.layers.map(\.visible), [true, false])
        XCTAssertEqual(v.layers.first?.colorKey, "red")
        XCTAssertTrue(v.noteTypes?.contains("疑问") == true)
        XCTAssertEqual(v.align, align)
        XCTAssertNil(try ws.documentView(documentId: "D1", contentHash: h2).align, "关着的不给")
        XCTAssertNil(try ws.documentView(documentId: "D1", contentHash: nil).align)
        XCTAssertThrowsError(try ws.documentView(documentId: "nope", contentHash: nil))
    }
}
