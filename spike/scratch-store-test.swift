// 草稿纸持久化 + 画布几何 round-trip 测试（schema v8：scratch_pad 表 + note kind=4）。运行：
//   cp spike/scratch-store-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift Sources/App/InkModel.swift Sources/App/InkLayerModel.swift Sources/App/InkEdit.swift Sources/App/ScratchPadModel.swift Sources/App/NoteTypeModel.swift Sources/App/TextNoteModel.swift Sources/App/PenPreset.swift Sources/Support/L.swift /tmp/main.swift -o /tmp/sst && /tmp/sst
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
//
// 覆盖三块：
//  ① scratch_pad 表 CRUD 与 ScratchPad ↔ LibScratchPad 映射；
//  ② 草稿纸笔迹走 note kind=4：**画布坐标（负数/大数）无损**、padId 保留、与页内 kind=2 互不串台；
//  ③ 无限画布几何：软边界 clamp、适应内容 fit、包围盒；以及局部擦除必须保住 padId（丢了就成孤儿）。
import Foundation
import CoreGraphics

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scratch_test_\(UInt64.random(in: 0..<1_000_000))")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let store = try LibraryStore(workspaceFolder: tmp)
let (doc, _) = try store.findOrCreate(hash: "h1", title: "Doc", pageCount: 20, path: "/tmp/a.pdf")

print("① scratch_pad 表")
check(store.meta("schema_version") == String(LibraryStore.schemaVersion),
      "schema_version = \(LibraryStore.schemaVersion)")

let padA = ScratchPad(title: "推导", anchorPage: 3, anchorX: 0.25, anchorY: 0.5)
let padB = ScratchPad(anchorPage: 0, anchorX: 0.5, anchorY: 0.125)
try store.upsertScratchPad(padA.toRow(documentId: doc.id))
try store.upsertScratchPad(padB.toRow(documentId: doc.id))
var pads = store.scratchPadsRT(doc.id)
check(pads.count == 2, "两张纸都落库了（读回 \(pads.count)）")
check(pads.contains { $0.id == padA.id && $0.title == "推导" && $0.anchorPage == 3
                      && abs($0.anchorX - 0.25) < 1e-9 && abs($0.anchorY - 0.5) < 1e-9 },
      "锚点/标题 round-trip 一致")
check(pads.contains { $0.id == padB.id && $0.title.isEmpty }, "空标题原样保留（显示名由 UI 兜底）")
check(pads.allSatisfy { $0.bg == InkColor.paper }, "默认底色 = 纯白 rgba(255,255,255,1)")
check(pads.allSatisfy { $0.pattern == .dots }, "默认底纹 = 点阵（v9）")
check(pads.allSatisfy { $0.showPage }, "新建的纸默认垫着它锚定的那一页（v10）")

// 页面底图开关（v10）round-trip：关掉也要真的存下来（默认值是 true，最容易被兜底写回成开）。
var hidPage = padA
hidPage.showPage = false
try store.upsertScratchPad(hidPage.toRow(documentId: doc.id))
check(store.scratchPadsRT(doc.id).first { $0.id == padA.id }?.showPage == false,
      "关掉页面底图 round-trip（不被 true 的默认值吃掉）")
hidPage.showPage = true
try store.upsertScratchPad(hidPage.toRow(documentId: doc.id))
check(store.scratchPadsRT(doc.id).first { $0.id == padA.id }?.showPage == true, "再开回来 round-trip")
// 页面底图的画布几何（三端契约）：宽恒 800，锚点落在画布原点。
let prect = padA.pageRect(aspect: 1.5)   // padA 锚点 (0.25, 0.5)
check(abs(prect.width - 800) < 1e-9 && abs(prect.height - 1200) < 1e-9, "页矩形 = 800 × 800·aspect")
check(abs(prect.minX - (-200)) < 1e-9 && abs(prect.minY - (-600)) < 1e-9,
      "锚点落在画布原点（rect 原点 = −nx·W, −ny·H）")

// 纸样（v9）：底色 + 底纹各自 round-trip。plain 单独试——它编码为 0，最容易被兜底逻辑吃掉。
var repapered = padB
repapered.bg = InkColor(r: 246, g: 236, b: 214, a: 1)   // 牛皮
repapered.pattern = .grid
try store.upsertScratchPad(repapered.toRow(documentId: doc.id))
var back = store.scratchPadsRT(doc.id).first { $0.id == padB.id }
check(back?.bg == repapered.bg && back?.pattern == .grid, "改纸样（牛皮 + 小格）round-trip")
repapered.pattern = .plain
try store.upsertScratchPad(repapered.toRow(documentId: doc.id))
back = store.scratchPadsRT(doc.id).first { $0.id == padB.id }
check(back?.pattern == .plain, "plain 底纹不会被默认值吃掉")
check(store.scratchPadsRT(doc.id).count == 2, "改纸样走 upsert，不新增行")
// 墨色由纸色明度推（浅纸配深纹）——底纹在深色纸上不能消失。
check(ScratchPad(anchorPage: 0, anchorX: 0, anchorY: 0, bg: .paper).inkIsDark, "白纸 → 深色底纹")
check(!ScratchPad(anchorPage: 0, anchorX: 0, anchorY: 0,
                  bg: InkColor(r: 30, g: 32, b: 36, a: 1)).inkIsDark, "深色纸 → 浅色底纹")

var renamed = padA; renamed.title = "改过的名字"; renamed.updatedAt = Date()
try store.upsertScratchPad(renamed.toRow(documentId: doc.id))
pads = store.scratchPadsRT(doc.id)
check(pads.count == 2 && pads.contains { $0.id == padA.id && $0.title == "改过的名字" }, "改名走 upsert，不新增行")

check(store.scratchPadsRT("别的文档").isEmpty, "按文档隔离（别的文档读不到）")

print("② 草稿纸笔迹（note kind=4，画布坐标）")
let ink = InkColor(r: 20, g: 20, b: 20, a: 1)
// 画布坐标的关键性质：**可负、可远超 1**。页内归一化那套 clamp 到 0~1 的假设在这里全不成立。
// 值都选二进制可精确表示的（Float 也无损），往返比对才能按「逐位相同」检
let canvasPts: [InkPoint] = [SIMD3(-120.5, 64.25, 0.5), SIMD3(512, -8.125, 1), SIMD3(2048.75, 900, 0.25)]
let s1 = InkStroke(page: 0, color: ink, width: 10, type: .pencil, points: canvasPts, padId: padA.id)
guard let n1 = s1.toNote(documentId: doc.id) else { fatalError("toNote nil") }
check(n1.kind == 4, "草稿纸笔迹落 kind=4（页内是 2）")
check(n1.page == 0, "page 列固定 0（画布不属于任何一页）")
try store.upsertNote(n1)

let backAll = try store.notes(documentId: doc.id)
let scratchBack = backAll.compactMap { $0.kind == InkStroke.scratchNoteKind ? InkStroke(note: $0) : nil }
check(scratchBack.count == 1, "读回 1 条草稿纸笔迹")
if let r = scratchBack.first {
    check(r.padId == padA.id, "padId 保留（否则这笔就成了无处可归的孤儿）")
    check(r.points.count == 3, "点数一致")
    check(zip(r.points, canvasPts).allSatisfy { abs($0.x - $1.x) < 1e-9 && abs($0.y - $1.y) < 1e-9 && abs($0.z - $1.z) < 1e-9 },
          "负数/大数画布坐标逐点无损")
    check(r.type == .pencil && abs(r.width - 10) < 1e-9, "笔型/线宽一致")
}

// 页内笔迹与草稿纸笔迹必须互不串台——两条读取路径各按 kind 一刀切干净。
let pageStroke = InkStroke(page: 5, color: ink, width: 8, points: [SIMD3(0.1, 0.2, 0.5), SIMD3(0.3, 0.4, 0.6)])
try store.upsertNote(pageStroke.toNote(documentId: doc.id)!)
let all2 = try store.notes(documentId: doc.id)
let pageOnly = all2.compactMap { $0.kind == InkStroke.noteKind ? InkStroke(note: $0) : nil }
let scratchOnly = all2.compactMap { $0.kind == InkStroke.scratchNoteKind ? InkStroke(note: $0) : nil }
check(pageOnly.count == 1 && pageOnly[0].padId == nil, "页内读取只拿到 kind=2，且 padId 为 nil")
check(scratchOnly.count == 1 && scratchOnly[0].padId != nil, "草稿纸读取只拿到 kind=4")
check(pageOnly[0].id != scratchOnly[0].id, "两者是不同的行")

// 老数据兼容：升级前的 payload 没有 padId 键，解出来必须是页内笔迹而不是坏数据。
let legacyPayload = Data(#"{"color":{"r":24,"g":90,"b":210,"a":0.95},"width":8,"points":[[0.1,0.2,0.5]]}"#.utf8)
let legacyNote = LibNote(id: UUID().uuidString, documentId: doc.id, kind: 2, page: 1,
                         anchor: .zero, payload: legacyPayload, createdAt: Date(), updatedAt: Date())
check(InkStroke(note: legacyNote)?.padId == nil, "老 payload（无 padId 键）解码为页内笔迹")

// kind=4 但 payload 里没有 padId = 坏数据（无处可归），必须丢弃而不是当页内笔迹混进去。
let orphan = LibNote(id: UUID().uuidString, documentId: doc.id, kind: 4, page: 0,
                     anchor: .zero, payload: legacyPayload, createdAt: Date(), updatedAt: Date())
check(InkStroke(note: orphan) == nil, "kind=4 缺 padId → 判为损坏并丢弃")

// 删纸：纸行删掉，纸上的笔迹由上层对账按 id 删（这里验证两步都做得到）。
try store.deleteScratchPad(id: padB.id.uuidString)
check(store.scratchPadsRT(doc.id).count == 1, "deleteScratchPad 删掉一行")
try store.deleteNote(id: s1.id.uuidString)
check((try store.notes(documentId: doc.id)).compactMap {
          $0.kind == InkStroke.scratchNoteKind ? $0 : nil }.isEmpty, "纸上笔迹按 id 删得掉")

// v8 → v9 迁移：老库（scratch_pad 没有 pattern 列）重开后应补上列、老纸兜底 dots、数据不丢。
try store.setMeta("schema_version", "8")
let store2 = try LibraryStore(workspaceFolder: tmp)
check(store2.meta("schema_version") == String(LibraryStore.schemaVersion), "退回 v8 重开 → 迁移拉回当前版本")
check(store2.scratchPadsRT(doc.id).count == 1, "迁移不丢已有草稿纸（此刻库里剩 padA 一张）")
check(store2.scratchPadsRT(doc.id).first?.pattern == .dots, "迁移后老纸兜底 dots（与 v8 观感一致）")

// v9 → v10 迁移：**真的没有 show_page 列**的老库（上面那条只能证明「重开不丢数据」，
// 因为列早就在了）。手搓一个 v9 形状的库，再让 LibraryStore 打开它补列。
let legacyDir = tmp.appendingPathComponent("legacy_v9")
try FileManager.default.createDirectory(at: legacyDir.appendingPathComponent("UniReader"),
                                        withIntermediateDirectories: true)
let legacyDB = try SQLiteDB(path: legacyDir.appendingPathComponent("UniReader/library.sqlite").path)
try legacyDB.exec("""
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
INSERT INTO meta(key,value) VALUES('schema_version','9');
CREATE TABLE scratch_pad (
  id TEXT PRIMARY KEY, document_id TEXT NOT NULL, title TEXT NOT NULL DEFAULT '',
  anchor_page INTEGER NOT NULL DEFAULT 0,
  anchor_x REAL NOT NULL DEFAULT 0, anchor_y REAL NOT NULL DEFAULT 0,
  bg TEXT NOT NULL DEFAULT 'rgba(255,255,255,1.0)', pattern TEXT NOT NULL DEFAULT 'dots',
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
INSERT INTO scratch_pad(id,document_id,title,anchor_page,anchor_x,anchor_y,bg,pattern,created_at,updated_at)
VALUES('11111111-1111-1111-1111-111111111111','D9','老纸',2,0.5,0.5,
       'rgba(246,236,214,1.0)','grid','2026-08-01T00:00:00Z','2026-08-01T00:00:00Z');
""")
legacyDB.close()
let store3 = try LibraryStore(workspaceFolder: legacyDir)
let oldPad = store3.scratchPadsRT("D9").first
check(store3.meta("schema_version") == String(LibraryStore.schemaVersion), "v9 老库打开即迁到当前版本")
check(oldPad != nil, "v9 → v10 补列不丢老纸")
check(oldPad?.showPage == false, "v9 老纸迁移后页面底图是关的（不惊扰既有白纸）")
check(oldPad?.pattern == .grid && oldPad?.title == "老纸", "老纸的纸样/标题原样保留")
store3.close()

print("③ 无限画布几何 + 擦除")
let box = ScratchBounds.contentBounds([s1])
check(box != nil, "非空笔迹算得出包围盒")
if let b = box {
    check(abs(b.minX - (-120.5)) < 1e-9 && abs(b.maxX - 2048.75) < 1e-9, "包围盒 x 覆盖负到正")
    check(abs(b.minY - (-8.125)) < 1e-9 && abs(b.maxY - 900) < 1e-9, "包围盒 y 覆盖负到正")
}
check(ScratchBounds.contentBounds([]) == nil, "空笔迹 → 无包围盒")

let viewSize = CGSize(width: 800, height: 600)
// 打开一张纸 = 画布原点落在视口正中。
let centered = ScratchViewport.centeredOnOrigin(viewport: viewSize)
check(abs(centered.toScreen(.zero).x - 400) < 1e-9 && abs(centered.toScreen(.zero).y - 300) < 1e-9,
      "回中后画布原点落在视口正中（= 用户要的「从该处显示」）")

// 软边界：空纸不允许滑到天边去（用户明确要求避免）。
var far = ScratchViewport(origin: CGPoint(x: 999_999, y: 999_999), zoom: 1)
far = ScratchBounds.clamp(far, content: nil, viewport: viewSize)
check(far.origin.x < 5000 && far.origin.y < 5000, "空纸滑到极远会被拉回（\(Int(far.origin.x)), \(Int(far.origin.y))）")
let near = ScratchBounds.clamp(ScratchViewport(origin: CGPoint(x: -400, y: -300), zoom: 1),
                               content: nil, viewport: viewSize)
check(abs(near.origin.x - (-400)) < 1e-9 && abs(near.origin.y - (-300)) < 1e-9, "边界内的位置不被动")

// 锚定缩放：捏合点下的画布内容不动。
let anchored = centered.zoomed(by: 2, anchorScreen: CGPoint(x: 200, y: 150))
let beforeCanvas = centered.toCanvas(CGPoint(x: 200, y: 150))
let afterCanvas = anchored.toCanvas(CGPoint(x: 200, y: 150))
check(abs(beforeCanvas.x - afterCanvas.x) < 1e-6 && abs(beforeCanvas.y - afterCanvas.y) < 1e-6,
      "以某点为锚缩放后，该点下的画布内容不动")
check(abs(anchored.zoom - 2) < 1e-9, "缩放倍率生效")

// 适应内容：包围盒装得进视口。
let fitted = ScratchBounds.fit(content: box, viewport: viewSize)
let vis = fitted.visibleRect(viewport: viewSize)
check(vis.contains(box!.insetBy(dx: 1, dy: 1)), "适应内容后全部笔迹落在可视区内")

// 局部擦除必须保住 padId：丢了的话这笔在界面上当场消失（按 padId 过滤取不到），
// 却以 kind=2 的身份留在库里污染页内笔迹。
let long = InkStroke(page: 0, color: ink, width: 6,
                     points: (0..<20).map { SIMD3(Double($0) * 10, 0, 0.5) }, padId: padA.id)
let cut = InkEdit.splitStroke(long, erasePts: [SIMD3(100, 0, 0)], r: 15)
check(cut.count >= 2, "局部擦除把一条切成多段（\(cut.count) 段）")
check(cut.allSatisfy { $0.padId == padA.id }, "每一段都继承 padId")
check(cut.allSatisfy { $0.id != long.id }, "切出的段是新 id（对账识别为「旧删新增」）")
let untouched = InkEdit.splitStroke(long, erasePts: [SIMD3(9999, 9999, 0)], r: 15)
check(untouched.count == 1 && untouched[0].id == long.id, "没擦到就原样返回（id 不变 = 对账零变化）")

print("—")
print("scratch-store: \(pass) 通过, \(fail) 失败")
if fail > 0 { exit(1) }

// MARK: - 小工具

extension LibraryStore {
    /// 读回运行时模型（测试便利；生产走 `WorkspaceManager.scratchPads`）。
    func scratchPadsRT(_ documentId: String) -> [ScratchPad] {
        ((try? scratchPads(documentId: documentId)) ?? []).map(ScratchPad.init(row:))
    }
}
