// 离线镜像「建镜像」测试（`MirrorBuilder` + `MirrorStore`）。方案 OFFLINE-MIRROR-PLAN.md §8.1。运行：
//   cp spike/mirror-build-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift /tmp/main.swift -o /tmp/mbt && /tmp/mbt
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
//
// 造一个有三本书的真工作区（① 工作区内副本 ② 外部文件 ③ 不带 PDF）+ 笔记/图层/草稿纸，
// 建镜像，然后逐条验：库全量 / PDF 选择性 / 外部内化 / 血缘 meta / sync_base 基线 / 源库借出记录。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

let fm = FileManager.default
let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("mirror_test_\(UInt64.random(in: 0..<1_000_000))")
try! fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

// —— 造源工作区 ——
let srcWS = root.appendingPathComponent("源.unrd")
try! fm.createDirectory(at: srcWS.appendingPathComponent("PDFs"), withIntermediateDirectories: true)
let store = try! LibraryStore(workspaceFolder: srcWS)
try! store.setWorkspaceName("源")

/// 造一个假 PDF（内容无所谓，只验搬运）
func writeFile(_ url: URL, _ bytes: Int) {
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(repeating: 0x41, count: bytes).write(to: url)
}

// ① 工作区内副本
let relA = "PDFs/aaaaaaaa-0000-4000-8000-000000000001.pdf"
writeFile(srcWS.appendingPathComponent(relA), 1024)
let (docA, varA) = try! store.findOrCreate(hash: "hA", title: "工作区内的书", pageCount: 10, path: relA)
_ = try! store.addLocation(variantId: varA.id, path: relA, inWorkspace: true)

// ② 外部文件（放工作区外边）
let extPath = root.appendingPathComponent("外部/外面的书.pdf")
writeFile(extPath, 2048)
let (docB, _) = try! store.findOrCreate(hash: "hB", title: "外部的书", pageCount: 20, path: extPath.path)

// ③ 不带 PDF 的书（有文件，但不进计划）
let relC = "PDFs/cccccccc-0000-4000-8000-000000000003.pdf"
writeFile(srcWS.appendingPathComponent(relC), 4096)
let (docC, varC) = try! store.findOrCreate(hash: "hC", title: "不带正文的书", pageCount: 30, path: relC)
_ = try! store.addLocation(variantId: varC.id, path: relC, inWorkspace: true)

// 笔记 / 图层 / 草稿纸 / 进度 / 分组：这些都必须整份进镜像
for (i, d) in [docA, docB, docC].enumerated() {
    for k in 0..<3 {
        try! store.upsertNote(LibNote(id: UUID().uuidString, documentId: d.id, kind: 2, page: k,
                                      anchor: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                                      payload: Data("{\"w\":\(k)}".utf8),
                                      createdAt: .now, updatedAt: .now))
    }
    try! store.updateProgress(documentId: d.id, page: i, frac: 0.5, zoom: 1.5, hfrac: 0.1)
    try! store.setGroup(documentId: d.id, group: "考研")
}
try! store.setMeta("note_types", "[{\"k\":\"v\"}]")
try! store.setOpenDocuments([docA.id, docB.id])

let srcNoteCount = store.noteCount()
check(srcNoteCount == 9, "源库 9 条笔记（3 本 × 3）")

// —— 解析器：与 WorkspaceManager.resolvedPath 同口径（工作区内/相对 → 拼工作区；否则绝对） ——
func resolve(_ ws: URL) -> (LibLocation) -> String? {
    { loc in
        (loc.inWorkspace || loc.isRelative) ? ws.appendingPathComponent(loc.path).path : loc.path
    }
}

// —— 估算 ——
print("① 估算（拷之前必须先算——内部存储写满会连累整个系统）")
let plan = MirrorBuilder.Plan(documentsWithPDF: [docA.id, docB.id], sourceHint: "移动硬盘 / 源.unrd")
let est = MirrorBuilder.estimate(source: srcWS, store: store, plan: plan, resolve: resolve(srcWS))
check(est.files == 2, "算出 2 个文件（③ 没勾）")
check(est.bytes > 1024 + 2048, "字节数含库本身 + 两个 PDF（\(est.bytes)）")
check(est.unresolved.isEmpty, "没有解析不到的文档")

let missPlan = MirrorBuilder.Plan(documentsWithPDF: [docA.id, "不存在的-doc-id"])
check(MirrorBuilder.estimate(source: srcWS, store: store, plan: missPlan, resolve: resolve(srcWS))
        .unresolved == ["不存在的-doc-id"],
      "🔴 解析不到的必须报出来（静默跳过 = 用户以为带上了，硬盘不在手上时才发现）")

// —— 建镜像 ——
print("② 建镜像")
let dstWS = root.appendingPathComponent("镜像/源.unrd")
var steps: [String] = []
let res = try! MirrorBuilder.create(source: srcWS, store: store, destination: dstWS,
                                    plan: plan, resolve: resolve(srcWS),
                                    progress: { s, _ in if steps.last != s { steps.append(s) } })
check(res.copiedFiles == 2, "拷了 2 个 PDF")
check(res.internalized == 1, "外部文件内化 1 条")
check(steps.count >= 3 && steps.last == "完成", "进度回调有分步（\(steps.joined(separator: " → "))）")

print("③ 文件布局")
check(fm.fileExists(atPath: dstWS.appendingPathComponent("UniReader/library.sqlite").path), "镜像有 library.sqlite")
check(fm.fileExists(atPath: dstWS.appendingPathComponent(relA).path),
      "🔴 工作区内副本**保持同一条相对路径**（镜像库那行 location 原样有效，一个字都不用改）")
check(!fm.fileExists(atPath: dstWS.appendingPathComponent(relC).path), "没勾的书不拷 PDF（库全量、PDF 选择性）")
let strays = (try? fm.contentsOfDirectory(atPath: dstWS.appendingPathComponent("PDFs").path))?
    .filter { $0.hasSuffix(".part") } ?? []
check(strays.isEmpty, "没有 .part 残留（原子 rename）")

// —— 镜像库 ——
let mdb = try! SQLiteDB(path: dstWS.appendingPathComponent("UniReader/library.sqlite").path)
func metaOf(_ db: SQLiteDB, _ k: String) -> String? {
    (try? db.query("SELECT value FROM meta WHERE key=?", [.text(k)]))?.first?["value"] as? String
}
func count(_ db: SQLiteDB, _ sql: String) -> Int {
    Int(((try? db.query(sql))?.first?.values.first as? Int64) ?? -1)
}

print("④ 库全量：所有书、所有笔记都在")
check(count(mdb, "SELECT COUNT(*) FROM document") == 3, "3 本书全在（含没带 PDF 的那本）")
check(count(mdb, "SELECT COUNT(*) FROM note") == 9, "9 条笔记全在")
check(count(mdb, "SELECT COUNT(*) FROM variant") == 3, "3 个 variant")
let readZoom = (try! mdb.query("SELECT read_zoom FROM document WHERE id=?", [.text(docA.id)]))
    .first?["read_zoom"] as? Double
check(readZoom == 1.5, "阅读进度跟着过来（read_zoom=1.5）")

print("⑤ 外部文件内化")
let locsB = try! mdb.query("SELECT * FROM location WHERE variant_id IN (SELECT id FROM variant WHERE document_id=?)",
                           [.text(docB.id)])
let inWS = locsB.filter { ($0["in_workspace"] as? Int64) == 1 }
check(inWS.count == 1, "镜像库里补了 1 条 in_workspace 的 location")
if let p = inWS.first?["path"] as? String {
    check(fm.fileExists(atPath: dstWS.appendingPathComponent(p).path), "那条相对路径在镜像里解析得到")
}
check(locsB.count == 2, "原来那条外部路径的行留着不动（location 本就不参与同步，删它没收益且是破坏性操作）")

print("⑥ 血缘 meta")
check(metaOf(mdb, MirrorStore.metaMirrorOf) == store.workspaceId, "mirror_of == 源库 workspace_id")
check(metaOf(mdb, MirrorStore.metaMirrorId) == res.mirrorId, "mirror_id 与返回值一致")
check(metaOf(mdb, MirrorStore.metaMirrorSourceHint) == "移动硬盘 / 源.unrd", "source_hint 记下了（只作人话提示，不作判据）")
check(metaOf(mdb, "workspace_id") != store.workspaceId,
      "🔴 镜像换了自己的 workspace_id（不换的话『扫盘按 id 找源』会把镜像自己也认成源）")
check(metaOf(mdb, "open_documents") == nil, "『本机开着哪几篇』已清（那是源设备的状态）")
check(metaOf(mdb, MirrorStore.metaCheckouts) == nil, "源库的借出记录没跟着复制到镜像里")
check(metaOf(mdb, "workspace_name") == "源", "工作区名照旧（它参与同步）")

print("⑦ sync_base 基线")
check(MirrorStore.hasSyncBase(mdb), "sync_base 表已建")
let base = try! MirrorStore.syncBase(mdb)
check(base["note"]?.count == 9, "note 基线 9 行")
check(base["document"]?.count == 3, "document 基线 3 行")
check(base["variant"]?.count == 3, "variant 基线 3 行")
check(base["location"] == nil, "🔴 location 不进基线（设备本地事实，同步它 = 满屏假『路径失效』）")
check(base["meta"]?.keys.sorted() == ["note_types", "workspace_name"],
      "meta 只收白名单两个键（\(base["meta"]?.keys.sorted().joined(separator: ",") ?? "-")）")
check(base["meta"]?["schema_version"] == nil && base["meta"]?[MirrorStore.metaMirrorOf] == nil,
      "库自身属性与血缘元数据不进基线（进了就会互相覆盖对方的身份）")
check(res.baseRows == base.values.reduce(0) { $0 + $1.count }, "返回的行数与读回的一致（\(res.baseRows)）")

// 基线必须等于"当下重算一遍"——刚建好的镜像，diff 应当为空
let now = try! MirrorStore.fingerprints(mdb, MirrorFp.spec("note")!)
check(now == base["note"], "🔴 刚建好的镜像重算 note 指纹 == 基线（diff 为空，这是整个合并方案的地基）")

print("⑧ 源库的借出记录（信息不是锁）")
let cos = MirrorStore.decodeCheckouts(store.meta(MirrorStore.metaCheckouts))
check(cos.count == 1, "源库记了 1 条借出")
check(cos.first?.mirrorId == res.mirrorId, "mirrorId 对得上")
check(cos.first?.noteCount == 9, "记下了借走时的笔记条数（纯展示）")
check(cos.first?.lastSyncedAt == nil, "从未同步过 → lastSyncedAt 为 nil")
check(!MirrorStore.deviceId.isEmpty && !MirrorStore.deviceName.isEmpty, "设备身份非空（存本机 UserDefaults，不进工作区）")

// 同 mirrorId 覆盖而不是越攒越多
let dup = MirrorStore.upsertCheckout(cos, MirrorStore.Checkout(
    mirrorId: res.mirrorId, deviceId: "d2", deviceName: "另一台", takenAt: "t", lastSyncedAt: "s", noteCount: 1))
check(dup.count == 1 && dup.first?.deviceName == "另一台", "upsertCheckout 同 mirrorId 覆盖")
check(MirrorStore.decodeCheckouts("这不是 JSON").isEmpty, "坏 JSON 按空处理（不让一条脏记录挡住开工作区）")
let rt = MirrorStore.decodeCheckouts(MirrorStore.encodeCheckouts(cos))
check(rt == cos, "借出记录编解码 round-trip（JSON 键名是跨端契约）")

print("⑨ 拦截")
do {
    _ = try MirrorBuilder.create(source: srcWS, store: store, destination: dstWS,
                                 plan: plan, resolve: resolve(srcWS))
    check(false, "目标已存在应当报错")
} catch MirrorBuilder.Failure.destinationExists(let name) {
    check(name == "源.unrd", "目标已存在 → 报错而不是覆盖")
    // UI 直接显示 localizedDescription，所以顺带验它是人话而不是 case 名
    check(MirrorBuilder.Failure.destinationExists(name).localizedDescription.contains("换个名字"),
          "错误文案是人话（\(MirrorBuilder.Failure.destinationExists(name).localizedDescription)）")
} catch { check(false, "错了别的：\(error)") }

let mirrorStore = try! LibraryStore(workspaceFolder: dstWS)
do {
    _ = try MirrorBuilder.create(source: dstWS, store: mirrorStore,
                                 destination: root.appendingPathComponent("镜像的镜像.unrd"),
                                 plan: plan, resolve: resolve(dstWS))
    check(false, "镜像的镜像应当被拦")
} catch MirrorBuilder.Failure.sourceIsMirror {
    check(true, "🔴 不许给镜像再做镜像")
} catch { check(false, "错了别的：\(error)") }
mirrorStore.close()

print("⑩ 中途失败要连整个骨架一起清掉")
// 造一次**建好目录之后**才失败的：把外部 PDF 设成不可读，拷到它那一步炸。
// （在建目录之前就失败的那种没意思——本来也没建出东西）
let halfDst = root.appendingPathComponent("半途而废.unrd")
try! fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: extPath.path)
do {
    _ = try MirrorBuilder.create(source: srcWS, store: store, destination: halfDst,
                                 plan: plan, resolve: resolve(srcWS))
    check(false, "源文件不可读时应当失败")
} catch {
    check(!fm.fileExists(atPath: halfDst.path),
          "失败后不留半个骨架（留着的话下次扫描列出来、点开又说没库，比没建成难查）")
}
try! fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: extPath.path)

print("⑪ 借出记录的跨端向量（同一个库两端都要读写，安卓 MirrorBuilderTest 逐字比对）")
// 🔴 canonical 表只许在末尾追加。两处最容易两端跑偏的点都覆盖了：
//    ① 键序（Swift 靠 .sortedKeys，Kotlin 靠手工按字典序放）
//    ② lastSyncedAt 为 nil 时**整个键省略**（Swift JSONEncoder 对 nil Optional 的默认行为），
//       而不是写成 "last_synced_at":null —— 写成 null 两端字节就对不上了
let canonical = [
    MirrorStore.Checkout(mirrorId: "m-1", deviceId: "d-1", deviceName: "小米 Pad 6",
                         takenAt: "2026-08-30T10:00:00.000Z", lastSyncedAt: nil, noteCount: 9),
    MirrorStore.Checkout(mirrorId: "m-2", deviceId: "d-2", deviceName: "MacBook",
                         takenAt: "2026-08-30T11:00:00.000Z",
                         lastSyncedAt: "2026-08-30T12:00:00.000Z", noteCount: 12),
]
let canonJSON = MirrorStore.encodeCheckouts(canonical)
check(!canonJSON.contains("last_synced_at\":null"), "🔴 nil 的 lastSyncedAt 省略整个键，不写 null")
check(canonJSON.contains("\"last_synced_at\":\"2026-08-30T12:00:00.000Z\""), "非 nil 的照常写出来")
check(MirrorStore.decodeCheckouts(canonJSON) == canonical, "canonical round-trip")
let vecPath = FileManager.default.currentDirectoryPath + "/spike/mirror-checkout-vector.json"
try? canonJSON.write(toFile: vecPath, atomically: true, encoding: .utf8)
print("  向量已写出：\(vecPath)")
print("  \(canonJSON)")

mdb.close()
store.close()
print("\n通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
