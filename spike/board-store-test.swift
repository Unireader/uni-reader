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
check(store.meta("schema_version") == "16", "schema_version = 16")
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
let imgBack = try store.boardItems(boardId: a.id.uuidString).compactMap(BoardImage.init(item:))
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

print("④ 删画板 → 其它画板不受影响")
try store.deleteBoard(id: b.id.uuidString)
check(try store.boards().count == 1, "只剩一篇")

print("\n通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
