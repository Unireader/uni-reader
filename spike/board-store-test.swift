// 画板笔记持久化测试（schema v16：board_note + board_item，`BOARD-NOTE-PLAN.md §2`）。运行：
//   cp spike/board-store-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift Sources/App/InkModel.swift \
//     Sources/App/InkLayerModel.swift Sources/App/InkEdit.swift Sources/App/ScratchPadModel.swift Sources/App/BoardModel.swift \
//     Sources/App/NoteTypeModel.swift Sources/App/TextNoteModel.swift Sources/App/ImageNoteModel.swift \
//     Sources/App/PenPreset.swift Sources/App/TrashModel.swift Sources/Support/L.swift /tmp/main.swift -o /tmp/bst && /tmp/bst
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
//
// 覆盖：
//  ① board_note CRUD 与 BoardNote ↔ LibBoard 映射、打开不改 updated_at、按最近打开排序；
//  ② 笔迹 board_item kind=1：画布坐标（负数 / 大数）无损、payload 与草稿纸 kind=4 同形但**不写 padId**；
//  ③ 图片 board_item kind=2：矩形 / sha / 说明 round-trip；**图片引用计数把画板上的图一起数**；
//  ④ 删画板 = 条目跟着外键级联删掉；
//  ⑤ 回收站：归档 → 删除 → 恢复 行数一条不少，manifest 统计与图片护身符正确；
//  ⑥ 内容包围盒 = 笔迹 ∪ 图片；BoardNote.asPad 没有页面底图。
import Foundation
import CoreGraphics

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("board_test_\(UInt64.random(in: 0..<1_000_000))")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let store = try LibraryStore(workspaceFolder: tmp)

print("① board_note")
check(store.meta("schema_version") == String(LibraryStore.schemaVersion), "schema_version = \(LibraryStore.schemaVersion)")
let t0 = Date(timeIntervalSince1970: 1_790_000_000)
var a = BoardNote(title: "极限", bg: InkColor(r: 252, g: 247, b: 235, a: 1), pattern: .grid,
                  createdAt: t0, updatedAt: t0, lastOpenedAt: t0)
let b = BoardNote(title: "", createdAt: t0.addingTimeInterval(10), updatedAt: t0.addingTimeInterval(10),
                  lastOpenedAt: t0.addingTimeInterval(10))
try store.upsertBoard(a.row)
try store.upsertBoard(b.row)
var list = try store.boards().map(BoardNote.init(row:))
check(list.count == 2, "两篇都落库（读回 \(list.count)）")
check(list.first?.id == b.id, "按最近打开排序：后打开的在前")
check(list.contains { $0.id == a.id && $0.title == "极限" && $0.pattern == .grid && $0.bg == a.bg },
      "标题 / 纸样 round-trip")
check(list.first { $0.id == b.id }?.displayName == "Untitled Board", "空标题显示兜底名")
try store.touchBoardOpened(id: a.id.uuidString, at: t0.addingTimeInterval(100))
list = try store.boards().map(BoardNote.init(row:))
check(list.first?.id == a.id, "记一次打开后排到最前")
check(list.first { $0.id == a.id }?.updatedAt == t0, "🔴 打开不改 updated_at（否则镜像把没改过的画板当成改过）")
a.title = "极限 2"; a.updatedAt = t0.addingTimeInterval(200)
try store.upsertBoard(a.row)
check((try store.board(id: a.id.uuidString)).map(BoardNote.init(row:))?.title == "极限 2", "改名 upsert")
let pad = a.asPad
check(pad.id == a.id && !pad.showPage && pad.pattern == .grid, "asPad：id 同画板、不垫页面、纸样照搬")

print("② 笔迹 kind=1")
let st = InkStroke(page: 7, color: .defaultInk, width: 3, type: .fountain,
                   points: [InkPoint(-1203.5, 8000, 0.4), InkPoint(-10, 12.25, 0.9)], padId: a.id)
let item = st.toBoardItem(boardId: a.id.uuidString, createdAt: t0)!
check(item.kind == 1, "kind = 1")
let json = String(decoding: item.payload, as: UTF8.self)
check(!json.contains("padId"), "🔴 payload 不写 padId（归属在 board_id 列上）")
check(json.contains("\"points\"") && json.contains("\"color\""), "payload 与草稿纸同形（points / color）")
try store.upsertBoardItem(item)
let rows = try store.boardItems(boardId: a.id.uuidString)
let back = rows.compactMap { InkStroke(boardItem: $0, padId: a.id) }
check(back.count == 1 && back[0].id == st.id, "读回同一笔")
check(back.first.map { $0.points[0].x == -1203.5 && $0.points[0].y == 8000 && $0.points[1].y == 12.25 } == true,
      "画布坐标（负数 / 大数）无损")
check(back.first?.padId == a.id && back.first?.page == 0, "读回时 padId = 画板 id、page = 0")
check(back.first?.type == .fountain && back.first?.width == 3, "笔型 / 笔宽保留")
check(abs(rows[0].rect.minX - (-1203.5)) < 1e-6 && abs(rows[0].rect.maxY - 8000) < 1e-6, "包围盒列 = 画布坐标")

print("③ 图片 kind=2 + 引用计数")
let sha = String(repeating: "ab", count: 32)
try store.insertImageIfAbsent(LibImage(sha256: sha, ext: "png", width: 800, height: 600, bytes: 10,
                                       createdAt: t0, orphanedAt: nil))
let im = BoardImage(image: sha, rect: CGRect(x: -50, y: 20, width: 400, height: 300), caption: "图 1", sourceName: "a.png",
                    createdAt: t0, updatedAt: t0)
try store.upsertBoardItem(im.toItem(boardId: a.id.uuidString)!)
let imgBack = try store.boardItems(boardId: a.id.uuidString).compactMap { BoardImage(item: $0) }
check(imgBack.count == 1 && imgBack[0] == im, "图片条目 round-trip（矩形 / sha / 说明 / 文件名）")
check(try store.imageRefCount(sha256: sha) == 1, "🔴 引用计数数到画板上的图")
check(try store.imageRefCounts()[sha] == 1, "imageRefCounts 同样数到")
try store.reconcileImageOrphans()
check((try store.image(sha256: sha))?.orphanedAt == nil, "有画板引用 → 不进待删除")
let placed = BoardImage.placed(width: 1600, height: 800, center: CGPoint(x: 0, y: 0))
check(abs(placed.width - 400) < 1e-6 && abs(placed.height - 200) < 1e-6 && abs(placed.midX) < 1e-6,
      "默认摆放：最长边 400、居中")

print("⑥ 包围盒")
let cb = ScratchBounds.contentBounds(back, images: imgBack)!
check(cb.minX <= -1203.5 && cb.maxY >= 8000 && cb.maxX >= 350, "内容包围盒 = 笔迹 ∪ 图片")
check(ScratchBounds.contentBounds([], images: imgBack) == im.rect, "只有图时 = 图的矩形")

print("⑤ 回收站")
let counts = try store.boardItemCounts()
check(counts[a.id.uuidString] == 2, "画板 a 上 2 条（1 笔 + 1 图）")
let snap = tmp.appendingPathComponent("snap.sqlite").path
let arch = try store.archiveBoard(id: a.id.uuidString, to: snap)
check(arch.counts.boardInk == 1 && arch.counts.boardImage == 1 && arch.counts.total == 2, "归档统计：1 笔 1 图")
check(arch.images == [sha], "护身符里有这张图")
try store.deleteBoard(id: a.id.uuidString)
check(try store.board(id: a.id.uuidString) == nil, "删掉了")
check(try store.boardItems(boardId: a.id.uuidString).isEmpty, "条目随外键级联删掉")
check(try store.imageRefCount(sha256: sha) == 0, "删后图片没有引用了")
let n = try store.restoreTrash(snapshot: snap, remapDocumentId: nil)
check(n == 3, "恢复 3 行（1 画板 + 2 条目，读回 \(n)）")
check(try store.boardItems(boardId: a.id.uuidString).count == 2, "条目一条不少地回来了")
check((try store.board(id: a.id.uuidString))?.title == "极限 2", "画板那一行回来了")
check(try store.imageRefCount(sha256: sha) == 1, "图片引用回来了")
// 老 manifest（没有 boardInk / boardImage 键）照样读得出来
var oldM = Trash.Manifest()
oldM.counts.ink = 3
var obj = try JSONSerialization.jsonObject(with: try Trash.encode(oldM)) as! [String: Any]
var cObj = obj["counts"] as! [String: Any]
cObj.removeValue(forKey: "boardInk"); cObj.removeValue(forKey: "boardImage")
obj["counts"] = cObj
let oldData = try JSONSerialization.data(withJSONObject: obj)
check(!String(decoding: oldData, as: UTF8.self).contains("boardInk"), "（造出一份没有新键的老 manifest）")
let oldBack = try? Trash.decode(oldData)
check(oldBack?.counts.ink == 3 && oldBack?.counts.boardInk == 0, "老 manifest 缺新键也能解（缺的算 0）")

print("⑦ 分页（v17）：board_page + 页内坐标 + 布局契约 + 模板几何")
check(store.meta("schema_version") == "17", "schema_version = 17")
let pb = BoardNote(title: "分页", createdAt: t0, updatedAt: t0, lastOpenedAt: t0)
try store.upsertBoard(pb.row)
let pgA = BoardPage(sortKey: 1, width: 595, height: 842, template: .cornell, createdAt: t0, updatedAt: t0)
let pgB = BoardPage(sortKey: 2, width: 595, height: 842, template: .lined, createdAt: t0, updatedAt: t0)
let pgMid = BoardPage(sortKey: 1.5, width: 595, height: 842, template: .grid, createdAt: t0, updatedAt: t0)
for p in [pgB, pgA, pgMid] { try store.upsertBoardPage(p.toRow(boardId: pb.id.uuidString)) }
let pages = try store.boardPages(boardId: pb.id.uuidString).compactMap(BoardPage.init(row:))
check(pages.map(\.id) == [pgA.id, pgMid.id, pgB.id], "按 sort_key 排序：插在中间的那页（1.5）排第二")
check(pages[0].template == .cornell && pages[1].template == .grid, "模板 round-trip")
let lay = BoardLayout(pages: pages)
check(lay.rect(0) == CGRect(x: -297.5, y: 0, width: 595, height: 842), "第 0 页矩形 = (-W/2, 0, W, H)")
check(lay.rect(2).minY == 2 * (842 + 24), "第 2 页 y = 2 × (H + 24)")
check(lay.index(forY: 850) == 0 && lay.index(forY: 866) == 1 && lay.index(forY: -50) == 0 && lay.index(forY: 99_999) == 2,
      "页号：空隙归上面那页、首之上 / 末之下夹住")
check(lay.bounds == CGRect(x: -297.5, y: 0, width: 595, height: 3 * 866 - 24), "全部页的包围盒")
// 页内坐标：第 2 页上的一笔，存下去是页内坐标，读回来按布局还原
let o2 = lay.origin(2)
let pst = InkStroke(page: 0, color: .defaultInk, width: 2, points: [InkPoint(Double(o2.x) + 10, Double(o2.y) + 20, 0.5),
                                                                    InkPoint(Double(o2.x) + 30, Double(o2.y) + 40, 0.5)],
                    padId: pb.id)
let pitem = pst.toBoardItem(boardId: pb.id.uuidString, createdAt: t0, page: (pages[2].id, o2))!
let pjson = String(decoding: pitem.payload, as: UTF8.self)
check(pjson.contains(pages[2].id.uuidString), "payload 带 page = 页 id")
check(abs(pitem.rect.minX - 10) < 1e-4 && abs(pitem.rect.minY - 20) < 1e-4, "x/y/w/h 列是页内坐标")
try store.upsertBoardItem(pitem)
var origins: [String: CGPoint] = [:]
for (i, p) in pages.enumerated() { origins[p.id.uuidString] = lay.origin(i) }
let pback = try store.boardItems(boardId: pb.id.uuidString).compactMap { InkStroke(boardItem: $0, padId: pb.id, origin: { origins[$0] }) }
check(pback.count == 1 && abs(pback[0].points[0].dx - (Double(o2.x) + 10)) < 1e-3
      && abs(pback[0].points[1].dy - (Double(o2.y) + 40)) < 1e-3, "读回 = 画布坐标（按当前布局还原）")
// 页被删了（镜像合并里一边删页）→ 那条不显示
let orphan = try store.boardItems(boardId: pb.id.uuidString).compactMap { InkStroke(boardItem: $0, padId: pb.id, origin: { _ in nil }) }
check(orphan.isEmpty, "指向不存在的页 → 不显示（孤儿）")
// 插一页到最前：库里的条目一行不用改，还原出来整体下移一页
let lay4 = BoardLayout(width: 595, height: 842, count: 4)
var origins4: [String: CGPoint] = [:]
for (i, p) in pages.enumerated() { origins4[p.id.uuidString] = lay4.origin(i + 1) }
let shifted = try store.boardItems(boardId: pb.id.uuidString).compactMap { InkStroke(boardItem: $0, padId: pb.id, origin: { origins4[$0] }) }
check(shifted.first.map { abs($0.points[0].dy - (Double(o2.y) + 866 + 20)) < 1e-3 } == true,
      "前面插页后同一行还原到下一页的位置（库里页内坐标不变）")
// 图片同理
let pim = BoardImage(image: sha, rect: CGRect(x: Double(o2.x) + 5, y: Double(o2.y) + 6, width: 100, height: 50),
                     createdAt: t0, updatedAt: t0)
let pimItem = pim.toItem(boardId: pb.id.uuidString, page: (pages[2].id, o2))!
check(abs(pimItem.rect.minX - 5) < 1e-6 && abs(pimItem.rect.minY - 6) < 1e-6, "图片存页内坐标")
check(BoardImage(item: pimItem, origin: { origins[$0] })?.rect == pim.rect, "图片读回画布坐标")
// 模板几何（三端契约）
let lined = BoardTemplateGeometry.shape(.lined, width: 595, height: 842)
check(lined.thin.first.map { $0.0 == CGPoint(x: 36, y: 72) && $0.1 == CGPoint(x: 559, y: 72) } == true, "横线：首条 y=72、左右各留 36")
check(lined.thin.count == Int(((842 - 36) - 72) / 28) + 1, "横线：间距 28 到底 36 止（\(lined.thin.count) 条）")
let corn = BoardTemplateGeometry.shape(.cornell, width: 595, height: 842)
check(corn.bold.count == 3 && corn.bold[2].0.x == (595 * 0.3).rounded(), "康奈尔：三条粗线、提示栏宽 30%")
check(BoardTemplateGeometry.shape(.twoColumn, width: 595, height: 842).bold.first?.0.x == (595 / 2).rounded(), "两栏：中线")
check(BoardTemplateGeometry.shape(.blank, width: 595, height: 842).thin.isEmpty, "空白：什么都不画")
check(BoardTemplate(code: 4) == .cornell && BoardTemplate(code: 99) == .blank && BoardTemplate.twoColumn.code == 5,
      "模板编码：cornell=4、未知值按空白、twoColumn=5")
// 回收站也带上页
let snap2 = tmp.appendingPathComponent("snap2.sqlite").path
_ = try store.archiveBoard(id: pb.id.uuidString, to: snap2)
try store.deleteBoard(id: pb.id.uuidString)
check(try store.boardPages(boardId: pb.id.uuidString).isEmpty, "删画板：页随外键级联删掉")
_ = try store.restoreTrash(snapshot: snap2, remapDocumentId: nil)
check(try store.boardPages(boardId: pb.id.uuidString).count == 3, "从回收站恢复：三页都回来了")

print("④ 删画板 → 其它画板不受影响")
try store.deleteBoard(id: b.id.uuidString)
check(try store.boards().count == 2, "只剩两篇（无限画布 a + 分页那篇）")

print("\n通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
