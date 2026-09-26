import Foundation
import CoreGraphics

/// 一个工作区的持久层：`<工作区>/UniReader/library.sqlite`（自有 schema，跨平台可读）。
/// 单一真相源；所有读写走这里。非线程安全，请在主线程使用。
final class LibraryStore {
    private let db: SQLiteDB
    let fileURL: URL
    static let schemaVersion = 18

    /// 打开/创建工作区库（文件夹须已存在）。会建表并跑迁移。
    init(workspaceFolder: URL) throws {
        let dir = workspaceFolder.appendingPathComponent("UniReader", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("library.sqlite")
        db = try SQLiteDB(path: fileURL.path)
        try migrate()
    }

    /// **显式**关闭底层连接（幂等）；之后所有读写自动退化成 no-op。
    /// 为什么不能只靠 ARC/`deinit`：见 `SQLiteDB.close()`（可移动硬盘弹不出去）。
    func close() { db.close() }

    // MARK: - 整库操作（离线镜像用，`MirrorBuilder`）

    /// 把 `-wal` 合并回主库。搬运/复制工作区前必做——只拷 `.sqlite` 会静默丢掉最近的写入
    /// （安卓端为此踩过坑，`ANDROID-STANDALONE-PLAN.md §9.2`）。
    /// FAT32/exFAT 上 WAL 建不起来时这是空操作，不报错。
    func checkpointTruncate() { try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)") }

    /// 把整库一致地拷到 [path]（`VACUUM INTO`）。
    ///
    /// **为什么不是 `cp` 那三个文件**：`.sqlite`/`-wal`/`-shm` 分三次拷不是原子的，中间还有写入
    /// 就拿到一份撕裂的库；而 `VACUUM INTO` 在一个读事务里生成，天生一致，还顺带压缩、不需要停写。
    /// 目标文件**已存在会失败**（SQLite 的行为），正好挡住误覆盖。
    func vacuumInto(_ path: String) throws {
        try db.run("VACUUM INTO ?", [.text(path)])
    }

    /// 本库里**参与同步的全部行**（离线镜像三方合并的一个输入，见 `MirrorStore.snapshot`）。
    /// 走这里而不是把 `db` 开放出去：这个类的约定是「所有读写走 DAO」，
    /// 为一个功能破例交出连接，下一个功能就会照着做。
    func mirrorSnapshot() throws -> MirrorDiff.Snapshot { try MirrorStore.snapshot(db) }

    /// 本库 `ocr_page` 的全部键（纯 additive 表，不进基线，见 `MirrorStore.ocrKeys`）。
    func mirrorOCRKeys() throws -> Set<MirrorDiff.OCRKey> { try MirrorStore.ocrKeys(db) }

    /// 本工作区拿得出来的图片（有行且文件在，见 `MirrorStore.imageKeys`）。同 OCR 那条 additive 通道。
    func mirrorImageKeys() throws -> Set<String> { try MirrorStore.imageKeys(db, folder: workspaceFolder) }

    /// 本库 `page_align` 的「内容 hash → updated_at」（扫描页对齐那条通道，见 `MirrorStore.alignStamps`）。
    func mirrorAlignStamps() throws -> [String: String] { try MirrorStore.alignStamps(db) }

    /// 工作区包的根（`fileURL` 是 `<根>/UniReader/library.sqlite`）。
    var workspaceFolder: URL { fileURL.deletingLastPathComponent().deletingLastPathComponent() }

    /// 镜像基线（`sync_base`）。不是镜像时返回空 —— 那张表只在镜像库里存在。
    func syncBase() throws -> [String: [String: String]] { try MirrorStore.syncBase(db) }

    /// 重算基线（合并完成后要重置成「此刻两端一致」的样子）。
    @discardableResult
    func rebuildSyncBase() throws -> Int { try MirrorStore.rebuildSyncBase(db) }

    /// 把底层连接**限时**交给离线镜像的合并逻辑（`MirrorApply`）。
    ///
    /// 这是本类「所有读写走 DAO」这条约定的**唯一例外**，理由在于合并要对**任意表**做通用的
    /// upsert/delete（列由 `PRAGMA table_info` 现取），给它写一套 DAO 等于把 `MirrorApply`
    /// 抄进这个文件。作用域式交出、只此一处、名字里带 `mirror` 便于 grep ——
    /// **别拿它当"拿连接的口子"用**，下一个功能照着做，这个类就名存实亡了。
    func withMirrorDB<T>(_ body: (SQLiteDB) throws -> T) rethrows -> T { try body(db) }

    // MARK: - 回收站（`BACKUP-PLAN.md §2`，实现在 `TrashStore`）
    //
    // 同 `mirrorSnapshot` 那几条的口径：连接不出这个类，只把四个具体动作开出去。
    // 搬运要按列通用地复制整张表（列由 `PRAGMA table_info` 现取），故实现另起一个文件。

    /// 把一篇文档的全部行归档进 [path] 的新快照库。🔴 **归档成功之后才允许调 `deleteDocument`**。
    func archiveDocument(id: String, to path: String) throws -> TrashStore.Archived {
        try TrashStore.archiveDocument(db, documentId: id, to: path)
    }
    func archiveBoard(id: String, to path: String) throws -> TrashStore.Archived {
        try TrashStore.archiveBoard(db, boardId: id, to: path)
    }

    /// 把一个笔迹图层连同它那些笔画归档。判定与 `deleteInkStrokes` 同一套（默认层含无 `layerId` 的老行）。
    func archiveInkLayer(documentId: String, layerId: String, isDefaultLayer: Bool,
                         to path: String) throws -> TrashStore.Archived {
        try TrashStore.archiveInkLayer(db, documentId: documentId, layerId: layerId,
                                       isDefaultLayer: isDefaultLayer, to: path)
    }

    /// 恢复前探路：这份快照的 PDF 已经被重新导入过吗（返回要并入的那篇文档 id）。
    func trashMergeTarget(snapshot path: String) throws -> String? {
        try TrashStore.mergeTarget(db, snapshot: path)
    }

    /// 把快照写回主库（`remapDocumentId` 非 nil = 并入现有那篇，见 `TrashStore.restore`）。
    @discardableResult
    func restoreTrash(snapshot path: String, remapDocumentId: String?) throws -> Int {
        try TrashStore.restore(db, snapshot: path, remapDocumentId: remapDocumentId)
    }

    /// 重新数一份快照里有什么（manifest 丢了 / 版本对不上时用）。
    func trashSummary(snapshot path: String) throws -> TrashStore.Archived {
        try TrashStore.summary(db, snapshot: path)
    }

    // MARK: - Schema / 迁移

    private func migrate() throws {
        let fresh = metaInt("schema_version") == nil
        // 建表（含最新列；已存在则不动）。
        try db.exec("""
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS document (
          id TEXT PRIMARY KEY, title TEXT NOT NULL, page_count INTEGER NOT NULL,
          added_at TEXT NOT NULL, last_opened_at TEXT NOT NULL, sort_order INTEGER NOT NULL DEFAULT 0,
          read_page INTEGER NOT NULL DEFAULT 0, read_frac REAL NOT NULL DEFAULT 0,
          read_zoom REAL NOT NULL DEFAULT 1, read_hfrac REAL NOT NULL DEFAULT 0,
          group_name TEXT NOT NULL DEFAULT '', canvas_mode INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS variant (
          id TEXT PRIMARY KEY,
          document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
          content_hash TEXT NOT NULL UNIQUE, page_count INTEGER NOT NULL, added_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_variant_document ON variant(document_id);
        CREATE TABLE IF NOT EXISTS location (
          id TEXT PRIMARY KEY,
          variant_id TEXT NOT NULL REFERENCES variant(id) ON DELETE CASCADE,
          path TEXT NOT NULL, is_valid INTEGER NOT NULL DEFAULT 1, last_validated_at TEXT,
          in_workspace INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_location_variant ON location(variant_id);
        CREATE TABLE IF NOT EXISTS note (
          id TEXT PRIMARY KEY,
          document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
          kind INTEGER NOT NULL, page INTEGER NOT NULL,
          anchor_x REAL NOT NULL, anchor_y REAL NOT NULL, anchor_w REAL NOT NULL, anchor_h REAL NOT NULL,
          payload BLOB NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
          points BLOB, points_at TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_note_document_page ON note(document_id, page);
        -- 2026-09-10：按类读（`notes(documentId:kind:)` / 笔迹按页窗口 `inkRows(pages:)`）走这条。
        -- 只有上面那条索引时，`document_id=? AND kind=?` 要把这篇文档**每一行**的表页都翻一遍再筛 kind——
        -- 一篇 2616 笔的文档就是三百多个表页；库在外置盘、页缓存冷的时候，开文档第一条碰 note 表的查询
        -- 要为此等上百毫秒（账本上先是「笔迹读库 158ms」，笔迹挪到后台后变成「注解 154ms」，同一笔账换了个名字）。
        -- 索引不是数据契约（安卓 `Schema.kt` 只管建新库，老库由这里补），故不升 schema_version。
        CREATE INDEX IF NOT EXISTS idx_note_document_kind_page ON note(document_id, kind, page);
        -- v3：扫描页 OCR 结果缓存（跨平台契约）。按内容 hash（= variant 物理内容）+ 页 + 引擎 缓存，
        -- 随文件移动/换机复用；payload = JSON {w,h,runs:[{text,x,y,w,h}]}（归一化 0~1，左上原点）。
        CREATE TABLE IF NOT EXISTS ocr_page (
          content_hash TEXT NOT NULL, page INTEGER NOT NULL, provider TEXT NOT NULL,
          payload BLOB NOT NULL, lang TEXT, created_at TEXT NOT NULL,
          PRIMARY KEY (content_hash, page, provider)
        );
        -- v7：多层笔迹的图层注册表（挂逻辑文档，全版本共用，同 note）。笔画本身仍在 note(kind=2)，
        -- 靠 payload 里的 layer_id 关联到这里的一行；这张表只存图层的名字/颜色/顺序/可见性。
        CREATE TABLE IF NOT EXISTS ink_layer (
          id TEXT PRIMARY KEY,
          document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
          name TEXT NOT NULL, color_key TEXT NOT NULL DEFAULT '',
          sort_order INTEGER NOT NULL DEFAULT 0, visible INTEGER NOT NULL DEFAULT 1,
          created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_ink_layer_document ON ink_layer(document_id);
        -- v8：草稿纸（盖在 PDF 之上的无限白板，不改 PDF 原文）。挂逻辑文档，全版本共用，同 note。
        -- 锚点 = 创建时所在页 + 页内归一化点（页面上那枚图钉）；草稿纸上的笔迹仍在 note，但 kind=4、
        -- payload 里带 pad_id 指回这里，且点集是**画布坐标（逻辑点，可负无界）**而非页内 0~1 归一化。
        -- 视口（滚动/缩放）刻意不落库：三端各自独立，打开一律回画布原点。
        CREATE TABLE IF NOT EXISTS scratch_pad (
          id TEXT PRIMARY KEY,
          document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
          title TEXT NOT NULL DEFAULT '',
          anchor_page INTEGER NOT NULL DEFAULT 0,
          anchor_x REAL NOT NULL DEFAULT 0, anchor_y REAL NOT NULL DEFAULT 0,
          bg TEXT NOT NULL DEFAULT 'rgba(255,255,255,1.0)',
          pattern TEXT NOT NULL DEFAULT 'dots',
          show_page INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL, updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_scratch_pad_document ON scratch_pad(document_id);
        -- 2026-09-10：页面几何缓存（本端私有的纯 additive 缓存表，同 ocr_page 的性质：按内容 hash、
        -- 不进镜像基线、不升 schema_version、别的端不必认识）。`PageLayout` 只要每页「高/宽 × 参考宽」
        -- 一个数，开文档遍历 340 页 `page.bounds` 在冷的外置盘上要 ~100ms（账本 `布局计算 96(316页)`），
        -- 有这张表就一行 5KB 读完开画。heights = JSON 数组（文档单位，见 PageLayout.refWidth）。
        CREATE TABLE IF NOT EXISTS page_geom (
          content_hash TEXT PRIMARY KEY, page_count INTEGER NOT NULL,
          heights BLOB NOT NULL, created_at TEXT NOT NULL
        );
        -- v13：图片本体注册表（`IMAGE-NOTE-PLAN.md §2`，跨端契约）。文件在 `<工作区>/Images/<sha256>.<ext>`，
        -- **主键就是内容 SHA-256**（同图只存一份；两端各自导入同一张图在镜像合并时天然合一）。
        -- 引用 = note 表 kind=6 的 payload `image` 键指向这里，**不存计数列**——数出来的永远对
        -- （`imageRefCounts`）。orphaned_at 非 NULL = 从那一刻起没有引用（待删除），30 天后 `purgeImages` 真删。
        -- 离线镜像走 OCR 那条纯 additive 通道（不进 sync_base，`MirrorApply.fillImages`）。
        CREATE TABLE IF NOT EXISTS image (
          sha256 TEXT PRIMARY KEY,
          ext TEXT NOT NULL,
          width INTEGER NOT NULL, height INTEGER NOT NULL, bytes INTEGER NOT NULL,
          created_at TEXT NOT NULL,
          orphaned_at TEXT
        );
        -- v14：扫描页对齐（`SCAN-ALIGN-PLAN.md §3`，跨端契约）。按内容 hash（同 ocr_page）：每页旋转 + 平移参数 +
        -- 开关。payload = JSON {"v":1,"w":目标页宽,"pages":[[rot,dx,dy,sw,sh],…]}。**只有 Mac 写**（测量要跑像素统计），
        -- 安卓只读。关开关不删行（enabled=0，再开不用重测）。离线镜像按 updated_at 取新（方案 §5），不进 sync_base。
        CREATE TABLE IF NOT EXISTS page_align (
          content_hash TEXT PRIMARY KEY,
          enabled INTEGER NOT NULL DEFAULT 0,
          page_count INTEGER NOT NULL,
          payload BLOB NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        -- v15：工作区里的 Markdown 笔记（`MARKDOWN-NOTES-PLAN.md §2`）。**与 PDF 分表**，理由见方案 §2.1
        -- （`document` 一半的列对 md 是垃圾；`variant/content_hash` 是给不可变文件设计的，md 每存一次就换 hash；
        --  混表还要在 8 处消费方各加一道 kind 过滤，漏一处就是一个 bug）。
        -- 🔴 **正文不进库**：就是 `<工作区>/Notes/…` 下的 md 文件本身（那个目录用 Obsidian 打开仍是正常 vault）。
        -- 这张表只存元数据；库与文件对不上时**以文件系统为真源**。
        -- `id` 就是 `[[名字|<id>]]` 里的那个 id，**一旦写进文件就不许换**（换了所有指向它的链接同时断）。
        CREATE TABLE IF NOT EXISTS md_doc (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          rel_path TEXT NOT NULL,
          group_name TEXT NOT NULL DEFAULT '',
          sort_order INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          last_opened_at TEXT NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_md_doc_path ON md_doc(rel_path);
        -- v16：画板笔记（`BOARD-NOTE-PLAN.md §2`，跨端契约）。工作区里一篇独立的无限白板，**不挂 document**。
        -- 纸样两列与 scratch_pad 同语义；group_name 预留一级分组（同 document.group_name）。
        -- 🔴 安卓模式1 在没有这两张表的库上会用**逐字相同**的语句补建（方案 §2.4），改这里必须同步 `Schema.kt`。
        CREATE TABLE IF NOT EXISTS board_note (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL DEFAULT '',
          bg TEXT NOT NULL DEFAULT 'rgba(255,255,255,1.0)',
          pattern TEXT NOT NULL DEFAULT 'dots',
          group_name TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          last_opened_at TEXT
        );
        -- 画板上的东西，一条一行（离线镜像按行合并）：kind 1 = 笔迹（payload 同草稿纸 kind=4，不带 padId）、
        -- 2 = 图片（payload {image,caption,source}）。x/y/w/h = 画布坐标包围盒（左上原点，逻辑点）。
        CREATE TABLE IF NOT EXISTS board_item (
          id TEXT PRIMARY KEY,
          board_id TEXT NOT NULL REFERENCES board_note(id) ON DELETE CASCADE,
          kind INTEGER NOT NULL,
          x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL,
          payload BLOB NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          points BLOB, points_at TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_board_item_board ON board_item(board_id);
        -- v17：分页画板的页（`BOARD-NOTE-PLAN.md §9`）。一个画板有页 = 分页模式，没有页 = 无限画布。
        -- 分页画板上的条目在 payload 里带 "page"（这里的 id），点与 x/y/w/h 是**页内坐标**。
        -- sort_key = 小数排序键（插页取前后两页中点）；width/height 整本统一（每页存同一个值、一起改）；
        -- template = 背景模板（blank / lined / grid / dots / cornell / twoColumn）。
        CREATE TABLE IF NOT EXISTS board_page (
          id TEXT PRIMARY KEY,
          board_id TEXT NOT NULL REFERENCES board_note(id) ON DELETE CASCADE,
          sort_key REAL NOT NULL,
          width REAL NOT NULL, height REAL NOT NULL,
          template TEXT NOT NULL DEFAULT 'blank',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_board_page_board ON board_page(board_id, sort_key);
        """)
        // 已有库补列（幂等：列已存在则跳过）。v1 → v2 加入 阅读进度 + in_workspace。
        // v2 → v3 只新增 ocr_page 表（上面 CREATE TABLE IF NOT EXISTS 已覆盖，无需 ALTER）。
        try addColumnIfMissing("document", "read_page", "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing("document", "read_frac", "REAL NOT NULL DEFAULT 0")
        try addColumnIfMissing("location", "in_workspace", "INTEGER NOT NULL DEFAULT 0")
        // v3 → v4：记住上次缩放（相对 fit-width 的倍率，1=贴合宽度）。
        try addColumnIfMissing("document", "read_zoom", "REAL NOT NULL DEFAULT 1")
        // v4 → v5：记住上次横向滚动比例（offsetX / pageW，缩放态才非 0）。
        try addColumnIfMissing("document", "read_hfrac", "REAL NOT NULL DEFAULT 0")
        // v5 → v6：外部文件与工作区同盘（移动硬盘等）时，path 存工作区相对路径而非绝对路径。
        try addColumnIfMissing("location", "is_relative", "INTEGER NOT NULL DEFAULT 0")
        // v7 → v8 只新增 scratch_pad 表（上面 CREATE TABLE IF NOT EXISTS 已覆盖，无需 ALTER）。
        // 草稿纸笔迹复用 note 表（kind=4），故 note 也不用改结构。
        // v8 → v9：草稿纸加底纹（无/点阵/小格）。已有的纸补列即得默认 dots，与 v8 的观感一致。
        try addColumnIfMissing("scratch_pad", "pattern", "TEXT NOT NULL DEFAULT 'dots'")
        // v9 → v10：草稿纸可以把它锚定的那一页垫在纸下面当参照。**已有的纸补列即 0（关）**——
        // 老纸的观感一点不变；只有新建的纸默认开（见 `ScratchPad.showPage`）。
        try addColumnIfMissing("scratch_pad", "show_page", "INTEGER NOT NULL DEFAULT 0")
        // v10 → v11：文档一级分组（工作区内再分组，快速筛选用）。空串 = 未分组；不建分组表——
        // 分组没有独立元数据（顺序按名字排），一个字符串列最省，跨端读取也零成本兼容。
        try addColumnIfMissing("document", "group_name", "TEXT NOT NULL DEFAULT ''")
        // v11 → v12：画板模式（页面两侧空白也能写字）。逐文档记；已有文档补列即 0（关），观感不变。
        // 页边笔迹仍是页内笔迹（note kind=2），只是归一化 x 越出 0~1，故 note 表不用动。
        try addColumnIfMissing("document", "canvas_mode", "INTEGER NOT NULL DEFAULT 0")
        // v12 → v13 只新增 image 表（上面 CREATE TABLE IF NOT EXISTS 已覆盖，无需 ALTER）。
        // 图片笔记复用 note 表（kind=6），故 note 也不用改结构。
        // v13 → v14 只新增 page_align 表（同上，无需 ALTER）。
        // v14 → v15 只新增 md_doc 表（同上，无需 ALTER）。Markdown 笔记正文在文件里，不动其它表。
        // v15 → v16 只新增 board_note / board_item 两张表（同上，无需 ALTER）。
        // v16 → v17 只新增 board_page 表（同上，无需 ALTER）；页内坐标的 "page" 键在 payload 里，不动 board_item 结构。
        // v17 → v18：笔迹点集改存二进制（`BINARY-INK-PLAN.md`）。points = `InkPointsBlob`，points_at = 写它那一刻
        // 这一行的 updated_at（不相等 = 旧版 App 之后改过这一行，二进制已过期，读 JSON）。payload 一个键不删。
        // 🔴 顺序与安卓 `Schema.ADD_COLUMNS` 一致。
        try addColumnIfMissing("note", "points", "BLOB")
        try addColumnIfMissing("note", "points_at", "TEXT")
        try addColumnIfMissing("board_item", "points", "BLOB")
        try addColumnIfMissing("board_item", "points_at", "TEXT")
        if fresh { try setMeta("created_at", ISO.string(.now)) }
        try setMeta("schema_version", String(Self.schemaVersion))
    }

    private func tableColumns(_ table: String) -> Set<String> {
        let rows = (try? db.query("PRAGMA table_info(\(table))")) ?? []
        return Set(rows.compactMap { $0["name"] as? String })
    }
    private func addColumnIfMissing(_ table: String, _ column: String, _ decl: String) throws {
        if !tableColumns(table).contains(column) {
            try db.exec("ALTER TABLE \(table) ADD COLUMN \(column) \(decl)")
        }
    }

    /// 只读偷看工作区名字（迁移命名用）：独立短连接打开库取 `workspace_name`，用完即关。
    /// 库不存在/损坏/无此 meta → nil。须在主 store 打开**之前**调用（避免双连接）。
    static func peekWorkspaceName(folder: URL) -> String? {
        let file = folder.appendingPathComponent("UniReader/library.sqlite")
        guard FileManager.default.fileExists(atPath: file.path),
              let db = try? SQLiteDB(path: file.path) else { return nil }
        return (try? db.query("SELECT value FROM meta WHERE key=?", [.text("workspace_name")]))?
            .first?["value"] as? String
    }

    /// 一个工作区的**身份**：它是谁、是不是离线副本、源在哪。
    struct Identity {
        var id: String?          // workspace_id
        var name: String?
        /// 非 nil = 这是一份离线副本，值是它源工作区的 `workspace_id`
        var mirrorOf: String?
        /// 这份副本自己的 id（源库那边的借出记录按它记账）
        var mirrorId: String?
        /// 副本记下的「上次见到源盘在哪」。只用来给一句人话/迁移兜底，**不作判据**
        var sourceHint: String?
    }

    /// 瞄一眼这个工作区的身份。
    ///
    /// 给「最近工作区」这类只想看一眼、不打算持有连接的地方用：不建 `LibraryStore` 实例，
    /// 用完当场 `close()`（不靠 deinit —— 理由见 `SQLiteDB.close()`：可移动硬盘会弹不出去）。
    /// 目录不在（盘没插）就是 nil，调用方不必先自己判断存在性。
    static func peekIdentity(folder: URL) -> Identity? {
        let file = folder.appendingPathComponent("UniReader/library.sqlite")
        guard FileManager.default.fileExists(atPath: file.path),
              let db = try? SQLiteDB(path: file.path) else { return nil }
        defer { db.close() }
        func v(_ key: String) -> String? {
            let s = (try? db.query("SELECT value FROM meta WHERE key=?", [.text(key)]))?
                .first?["value"] as? String
            return (s?.isEmpty ?? true) ? nil : s
        }
        return Identity(id: v("workspace_id"), name: v("workspace_name"),
                        mirrorOf: v(MirrorStore.metaMirrorOf),
                        mirrorId: v(MirrorStore.metaMirrorId),
                        sourceHint: v(MirrorStore.metaMirrorSourceHint))
    }

    // MARK: - meta

    func meta(_ key: String) -> String? {
        (try? db.query("SELECT value FROM meta WHERE key=?", [.text(key)]))?.first?["value"] as? String
    }
    private func metaInt(_ key: String) -> Int? { meta(key).flatMap { Int($0) } }
    func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                   [.text(key), .text(value)])
    }
    var workspaceName: String {
        get { meta("workspace_name") ?? "" }
    }
    func setWorkspaceName(_ name: String) throws { try setMeta("workspace_name", name) }

    /// 工作区的**稳定身份**（离线镜像用，见 `OFFLINE-MIRROR-PLAN.md` §5.1）。只读，不存在返回 nil。
    ///
    /// 为什么不能拿 `workspace_name` 或路径当身份：名字会被改、路径换台机器/换挂载点必变，
    /// 而镜像要靠它认出「我的源盘是哪一个」——插上任意一块盘都能自动匹配，靠路径就得让用户手指。
    var workspaceId: String? { meta("workspace_id").flatMap { $0.isEmpty ? nil : $0 } }

    /// 取工作区 id，没有就地补一个。**只在真的要用到时调**（建镜像/同步），
    /// 不塞进 `migrate()`：那样每个老库一打开就被写一次，而绝大多数工作区永远不会做镜像。
    /// 库只读（镜像挂在只读卷上等）时写入会失败 → 抛错，调用方据此提示，不静默当成功。
    @discardableResult
    func ensureWorkspaceId() throws -> String {
        if let id = workspaceId { return id }
        let id = UUID().uuidString
        try setMeta("workspace_id", id)
        return id
    }

    /// 工作区当前打开的文档集合（多窗口会话，存 meta·JSON，随文件夹移动而保留）。
    func openDocuments() -> [String] {
        guard let s = meta("open_documents"), let data = s.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return arr
    }
    func setOpenDocuments(_ ids: [String]) throws {
        let data = (try? JSONSerialization.data(withJSONObject: ids)) ?? Data("[]".utf8)
        try setMeta("open_documents", String(data: data, encoding: .utf8) ?? "[]")
    }

    // MARK: - Document

    func allDocuments() throws -> [LibDocument] {
        try db.query("SELECT * FROM document ORDER BY sort_order ASC, last_opened_at DESC").map(Self.doc)
    }
    func document(id: String) throws -> LibDocument? {
        try db.query("SELECT * FROM document WHERE id=?", [.text(id)]).first.map(Self.doc)
    }
    func updateLastOpened(documentId: String, at date: Date = .now) throws {
        try db.run("UPDATE document SET last_opened_at=? WHERE id=?", [.text(ISO.string(date)), .text(documentId)])
    }
    /// 记录阅读进度（视口顶部所在页 + 页内比例 + 缩放倍率 + 横向滚动比例）。
    /// `hfrac` = offsetX / 页宽：画板模式（v12）下页两侧还有页边，它可以大于 1，
    /// 故上限按 `CanvasMargin.limit` 那一侧的最大可能值放宽（原来硬 clamp 到 1 会把横向位置截断）。
    func updateProgress(documentId: String, page: Int, frac: Double, zoom: Double, hfrac: Double) throws {
        try db.run("UPDATE document SET read_page=?, read_frac=?, read_zoom=?, read_hfrac=? WHERE id=?",
                   [.int(Int64(page)), .double(min(max(0, frac), 1)), .double(zoom),
                    .double(min(max(0, hfrac), 20)), .text(documentId)])
    }
    /// 画板模式开关（v12，逐文档）。
    func setCanvasMode(documentId: String, on: Bool) throws {
        try db.run("UPDATE document SET canvas_mode=? WHERE id=?", [.int(on ? 1 : 0), .text(documentId)])
    }
    func rename(documentId: String, title: String) throws {
        try db.run("UPDATE document SET title=? WHERE id=?", [.text(title), .text(documentId)])
    }
    /// 设置文档分组（v11；空串 = 未分组）。调用方负责 trim。
    func setGroup(documentId: String, group: String) throws {
        try db.run("UPDATE document SET group_name=? WHERE id=?", [.text(group), .text(documentId)])
    }
    /// 设置文档在侧栏里的手动位次（侧栏拖拽排序，2026-09-03）。
    /// ⚠️ 与 `allDocuments` 的 `ORDER BY sort_order ASC, last_opened_at DESC` 配套：
    /// 手动排过的一律 ≥1，**没排过的仍是 0 → 排在最前**（新加的书还是出现在顶上，与拖拽之前的观感一致）。
    func setSortOrder(documentId: String, order: Int) throws {
        try db.run("UPDATE document SET sort_order=? WHERE id=?", [.int(Int64(order)), .text(documentId)])
    }
    /// 整组改名（to 为空串 = 解散该组，文档回未分组）。
    func renameGroup(from: String, to: String) throws {
        try db.run("UPDATE document SET group_name=? WHERE group_name=?", [.text(to), .text(from)])
    }
    func deleteDocument(id: String) throws {
        try db.run("DELETE FROM document WHERE id=?", [.text(id)])   // variant/location/note 级联删
    }

    // MARK: - Markdown 笔记（v15，`MARKDOWN-NOTES-PLAN.md §2`）

    /// 全部 md 笔记。排序口径与 `allDocuments` 一致（手动排过的 ≥1 在后，没排过的 0 在前、按最近打开）。
    func allMarkdownDocs() throws -> [LibMarkdownDoc] {
        try db.query("SELECT * FROM md_doc ORDER BY sort_order ASC, last_opened_at DESC").map(Self.mdDoc)
    }
    func markdownDoc(id: String) throws -> LibMarkdownDoc? {
        try db.query("SELECT * FROM md_doc WHERE id=?", [.text(id)]).first.map(Self.mdDoc)
    }
    func markdownDoc(relPath: String) throws -> LibMarkdownDoc? {
        try db.query("SELECT * FROM md_doc WHERE rel_path=?", [.text(relPath)]).first.map(Self.mdDoc)
    }
    /// 插入一行。`id` 由调用方给——导入时要**先分配 id 建好索引、再重写链接**（方案 §4.2），
    /// 所以这里不自己生成。`rel_path` 唯一，撞了就抛（调用方负责先避让，见 `MarkdownImport`）。
    @discardableResult
    func addMarkdownDoc(id: String, title: String, relPath: String, group: String = "",
                        at date: Date = .now) throws -> LibMarkdownDoc {
        let ts = ISO.string(date)
        try db.run("""
        INSERT INTO md_doc(id,title,rel_path,group_name,sort_order,created_at,updated_at,last_opened_at)
        VALUES(?,?,?,?,0,?,?,?)
        """, [.text(id), .text(title), .text(relPath), .text(group), .text(ts), .text(ts), .text(ts)])
        return LibMarkdownDoc(id: id, title: title, relPath: relPath, group: group,
                              createdAt: date, updatedAt: date, lastOpenedAt: date)
    }
    /// 改标题。**只改这一行**——指向它的 `[[名字|<id>]]` 一个字都不用动（显示名由 `name(forID:)` 现查）。
    func renameMarkdownDoc(id: String, title: String, at date: Date = .now) throws {
        try db.run("UPDATE md_doc SET title=?, updated_at=? WHERE id=?",
                   [.text(title), .text(ISO.string(date)), .text(id)])
    }
    /// 换文件路径（笔记在工作区内挪目录）。同样不碰任何链接。
    func setMarkdownPath(id: String, relPath: String, at date: Date = .now) throws {
        try db.run("UPDATE md_doc SET rel_path=?, updated_at=? WHERE id=?",
                   [.text(relPath), .text(ISO.string(date)), .text(id)])
    }
    /// 正文存盘后打时间戳（离线镜像按它取新）。
    func touchMarkdownDoc(id: String, at date: Date = .now) throws {
        try db.run("UPDATE md_doc SET updated_at=? WHERE id=?", [.text(ISO.string(date)), .text(id)])
    }
    func updateMarkdownLastOpened(id: String, at date: Date = .now) throws {
        try db.run("UPDATE md_doc SET last_opened_at=? WHERE id=?", [.text(ISO.string(date)), .text(id)])
    }
    func setMarkdownGroup(id: String, group: String) throws {
        try db.run("UPDATE md_doc SET group_name=? WHERE id=?", [.text(group), .text(id)])
    }
    func setMarkdownSortOrder(id: String, order: Int) throws {
        try db.run("UPDATE md_doc SET sort_order=? WHERE id=?", [.int(Int64(order)), .text(id)])
    }
    /// 删行。**不删文件**——文件的去留由 `WorkspaceManager` 决定（同 `deleteLocation` 的分工）。
    func deleteMarkdownDoc(id: String) throws {
        try db.run("DELETE FROM md_doc WHERE id=?", [.text(id)])
    }

    // MARK: - Variant / Location

    func variant(hash: String) throws -> LibVariant? {
        try db.query("SELECT * FROM variant WHERE content_hash=?", [.text(hash)]).first.map(Self.variant)
    }
    func variant(id: String) throws -> LibVariant? {
        try db.query("SELECT * FROM variant WHERE id=?", [.text(id)]).first.map(Self.variant)
    }
    /// 给已有文档添加一个新版本（重定位到内容不同但用户认定为同一文档的文件时用）。
    @discardableResult
    func addVariant(documentId: String, hash: String, pageCount: Int, path: String, inWorkspace: Bool = false, isRelative: Bool = false) throws -> LibVariant {
        let now = Date.now, varId = UUID().uuidString
        try db.transaction {
            try db.run("INSERT INTO variant(id,document_id,content_hash,page_count,added_at) VALUES(?,?,?,?,?)",
                       [.text(varId), .text(documentId), .text(hash), .int(Int64(pageCount)), .text(ISO.string(now))])
            try db.run("INSERT INTO location(id,variant_id,path,is_valid,last_validated_at,in_workspace,is_relative) VALUES(?,?,?,1,?,?,?)",
                       [.text(UUID().uuidString), .text(varId), .text(path), .text(ISO.string(now)), .int(inWorkspace ? 1 : 0), .int(isRelative ? 1 : 0)])
        }
        return LibVariant(id: varId, documentId: documentId, contentHash: hash, pageCount: pageCount, addedAt: now)
    }
    func variants(documentId: String) throws -> [LibVariant] {
        try db.query("SELECT * FROM variant WHERE document_id=? ORDER BY added_at ASC", [.text(documentId)]).map(Self.variant)
    }
    func locations(variantId: String) throws -> [LibLocation] {
        try db.query("SELECT * FROM location WHERE variant_id=? ORDER BY is_valid DESC", [.text(variantId)]).map(Self.location)
    }
    /// 逻辑文档的全部路径（跨版本），有效优先。用于打开时探测可用路径。
    func locations(documentId: String) throws -> [LibLocation] {
        try db.query("""
        SELECT location.* FROM location
        JOIN variant ON location.variant_id = variant.id
        WHERE variant.document_id=? ORDER BY location.is_valid DESC
        """, [.text(documentId)]).map(Self.location)
    }
    func setLocationValidity(id: String, isValid: Bool, at date: Date = .now) throws {
        try db.run("UPDATE location SET is_valid=?, last_validated_at=? WHERE id=?",
                   [.int(isValid ? 1 : 0), .text(ISO.string(date)), .text(id)])
    }
    /// 逻辑文档下所有「已复制进工作区」的 location（path 为工作区相对路径）。
    func inWorkspaceLocations(documentId: String) throws -> [LibLocation] {
        try db.query("""
        SELECT location.* FROM location JOIN variant ON location.variant_id = variant.id
        WHERE variant.document_id=? AND location.in_workspace=1
        """, [.text(documentId)]).map(Self.location)
    }
    @discardableResult
    func addLocation(variantId: String, path: String, inWorkspace: Bool, isRelative: Bool = false) throws -> LibLocation {
        let id = UUID().uuidString, now = Date.now
        try db.run("INSERT INTO location(id,variant_id,path,is_valid,last_validated_at,in_workspace,is_relative) VALUES(?,?,?,1,?,?,?)",
                   [.text(id), .text(variantId), .text(path), .text(ISO.string(now)), .int(inWorkspace ? 1 : 0), .int(isRelative ? 1 : 0)])
        return LibLocation(id: id, variantId: variantId, path: path, isValid: true, lastValidatedAt: now, inWorkspace: inWorkspace, isRelative: isRelative)
    }
    func removeLocation(id: String) throws { try db.run("DELETE FROM location WHERE id=?", [.text(id)]) }

    // MARK: - 导入：按 hash + 路径「找到或创建」

    /// 打开一个 PDF 时调用（已算出 hash）。返回其逻辑文档与该版本。
    /// - hash 已知 → 复用其 document/variant，并确保 path 作为 location 存在。
    /// - hash 未知 → 新建 document + variant + location。
    @discardableResult
    func findOrCreate(hash: String, title: String, pageCount: Int, path: String, isRelative: Bool = false) throws -> (document: LibDocument, variant: LibVariant) {
        if let v = try variant(hash: hash) {
            try ensureLocation(variantId: v.id, path: path, isRelative: isRelative)
            try updateLastOpened(documentId: v.documentId)
            let doc = try document(id: v.documentId) ?? { throw SQLiteError.step("variant 指向的 document 缺失") }()
            return (doc, v)
        }
        let now = Date.now
        let docId = UUID().uuidString, varId = UUID().uuidString
        try db.transaction {
            try db.run("INSERT INTO document(id,title,page_count,added_at,last_opened_at,sort_order) VALUES(?,?,?,?,?,0)",
                       [.text(docId), .text(title), .int(Int64(pageCount)), .text(ISO.string(now)), .text(ISO.string(now))])
            try db.run("INSERT INTO variant(id,document_id,content_hash,page_count,added_at) VALUES(?,?,?,?,?)",
                       [.text(varId), .text(docId), .text(hash), .int(Int64(pageCount)), .text(ISO.string(now))])
            try db.run("INSERT INTO location(id,variant_id,path,is_valid,last_validated_at,is_relative) VALUES(?,?,?,1,?,?)",
                       [.text(UUID().uuidString), .text(varId), .text(path), .text(ISO.string(now)), .int(isRelative ? 1 : 0)])
        }
        let doc = LibDocument(id: docId, title: title, pageCount: pageCount, addedAt: now, lastOpenedAt: now, sortOrder: 0)
        let v = LibVariant(id: varId, documentId: docId, contentHash: hash, pageCount: pageCount, addedAt: now)
        return (doc, v)
    }

    /// 确保某 variant 下存在该路径的 location（去重）。
    private func ensureLocation(variantId: String, path: String, isRelative: Bool = false) throws {
        let exists = try db.query("SELECT id FROM location WHERE variant_id=? AND path=?",
                                  [.text(variantId), .text(path)]).first != nil
        if exists {
            try db.run("UPDATE location SET is_valid=1, last_validated_at=? WHERE variant_id=? AND path=?",
                       [.text(ISO.string(.now)), .text(variantId), .text(path)])
        } else {
            try db.run("INSERT INTO location(id,variant_id,path,is_valid,last_validated_at,is_relative) VALUES(?,?,?,1,?,?)",
                       [.text(UUID().uuidString), .text(variantId), .text(path), .text(ISO.string(.now)), .int(isRelative ? 1 : 0)])
        }
    }

    /// 「关联为同一文档」：把源 document 的**全部** variant 与 note 并入目标 document，再删源 document。
    /// 用于侧栏「关联到…」把 B 认定为 A 的另一版本。返回是否成功。
    @discardableResult
    func mergeDocument(sourceId: String, intoTargetId targetId: String) throws -> Bool {
        guard sourceId != targetId,
              try document(id: sourceId) != nil, try document(id: targetId) != nil else { return false }
        try db.transaction {
            try db.run("UPDATE variant SET document_id=? WHERE document_id=?", [.text(targetId), .text(sourceId)])
            try db.run("UPDATE note SET document_id=? WHERE document_id=?", [.text(targetId), .text(sourceId)])
            try db.run("UPDATE ink_layer SET document_id=? WHERE document_id=?", [.text(targetId), .text(sourceId)])
            try db.run("UPDATE scratch_pad SET document_id=? WHERE document_id=?", [.text(targetId), .text(sourceId)])
            try db.run("DELETE FROM document WHERE id=?", [.text(sourceId)])
        }
        return true
    }

    /// 「关联为同一文档」：把某 variant 挪到目标 document 名下（多 hash 合并，笔记随目标 document 共用）。
    /// 若源 document 变空则删除。返回是否成功。
    @discardableResult
    func linkVariant(variantId: String, toDocumentId targetDocId: String) throws -> Bool {
        guard let v = try db.query("SELECT * FROM variant WHERE id=?", [.text(variantId)]).first.map(Self.variant),
              try document(id: targetDocId) != nil else { return false }
        let sourceDocId = v.documentId
        if sourceDocId == targetDocId { return true }
        try db.transaction {
            try db.run("UPDATE variant SET document_id=? WHERE id=?", [.text(targetDocId), .text(variantId)])
            let remaining = try db.query("SELECT COUNT(*) AS n FROM variant WHERE document_id=?", [.text(sourceDocId)]).first?["n"] as? Int64 ?? 0
            if remaining == 0 { try db.run("DELETE FROM document WHERE id=?", [.text(sourceDocId)]) }
        }
        return true
    }

    // MARK: - Note

    /// 整个工作区的笔记条数（笔迹一笔也算一条）。借出记录里存一份纯展示用，
    /// 让用户在源盘那端一眼看出「借走时是 3800 条」。
    func noteCount() -> Int {
        let r = (try? db.query("SELECT COUNT(*) AS n FROM note")) ?? []
        return Int((r.first?["n"] as? Int64) ?? 0)
    }

    func notes(documentId: String) throws -> [LibNote] {
        try db.query("SELECT * FROM note WHERE document_id=? ORDER BY page ASC, created_at ASC", [.text(documentId)]).map(Self.note)
    }
    /// 只取某一类。**开文档必须用它**：`note` 表混着五类（文字注解 0 / AI 会话 1 / 页内笔迹 2 /
    /// 高亮 3 / 草稿纸笔迹 4），而 `load()` 里五个 loader 各要一类——都用上面那个不带 kind 的版本，
    /// 就是把整张表连同全部 payload **读五遍**再在 Swift 里筛。
    /// 2026-09-02 实测（3506 行 / 13.9MB 的文档）：五次全表读 1090ms，换成五次窄查约 220ms。
    func notes(documentId: String, kind: Int) throws -> [LibNote] {
        try db.query("SELECT * FROM note WHERE document_id=? AND kind=? ORDER BY page ASC, created_at ASC",
                     [.text(documentId), .int(Int64(kind))]).map(Self.note)
    }
    func notes(documentId: String, page: Int) throws -> [LibNote] {
        try db.query("SELECT * FROM note WHERE document_id=? AND page=? ORDER BY created_at ASC",
                     [.text(documentId), .int(Int64(page))]).map(Self.note)
    }
    /// 笔迹专用窄查询（kind=2 页内 / kind=4 草稿纸）：只取四列、按位置读、不走 `[String: Any]`。
    /// 排序与 `notes(documentId:kind:)` 一致（页 → 落库时间 = 绘制叠放序）。
    /// 开文档最热的一条读（`DocTabModel.loadInk`），在后台线程调；一条语句一把锁，与主线程互不干扰。
    func inkRows(documentId: String, kind: Int) throws -> [LibInkRow] {
        try db.query("SELECT id, kind, page, payload, points, points_at IS updated_at FROM note WHERE document_id=? AND kind=? ORDER BY page ASC, created_at ASC",
                     [.text(documentId), .int(Int64(kind))]) { r in
            Self.inkRow(r)
        }
    }

    /// `SELECT id, kind, page, payload, points, points_at IS updated_at` 的一行（v18：第 5 列二进制点集，
    /// 第 6 列「二进制是否最新」——`IS` 让两边都是 NULL 时也为真，但那时 points 为空、不会被用）。
    private static func inkRow(_ r: SQLiteDB.Row) -> LibInkRow {
        let pts = r.blob(4)
        return LibInkRow(id: r.text(0), kind: Int(r.int64(1)), page: Int(r.int64(2)), payload: r.blob(3),
                         points: pts.isEmpty ? nil : pts, pointsValid: r.int64(5) != 0)
    }

    // MARK: 页内笔迹按页窗口装载（`INK-PAGING-PLAN.md §4`）——下面这几条都不读 payload 里的点

    /// 某页区间的页内笔迹行（kind=2），排序同上。走 `idx_note_document_page`；`kind` 在几十行里过滤。
    func inkRows(documentId: String, kind: Int, pages: ClosedRange<Int>) throws -> [LibInkRow] {
        try db.query("""
        SELECT id, kind, page, payload, points, points_at IS updated_at FROM note
        WHERE document_id=? AND kind=? AND page BETWEEN ? AND ? ORDER BY page ASC, created_at ASC
        """, [.text(documentId), .int(Int64(kind)), .int(Int64(pages.lowerBound)), .int(Int64(pages.upperBound))]) { r in
            Self.inkRow(r)
        }
    }

    /// 全篇按页汇总（笔数 / 最小 y / 出现过的笔色），给检查器的按页列表。一条 GROUP BY；
    /// `json_extract` 要解每行 payload 的 JSON（几千行几十毫秒），调用方放后台。
    func inkPageSummaries(documentId: String) throws -> [LibInkPageSummary] {
        try db.query("""
        SELECT page, COUNT(*), MIN(anchor_y), json_group_array(DISTINCT json_extract(payload, '$.color'))
        FROM note WHERE document_id=? AND kind=? GROUP BY page ORDER BY page ASC
        """, [.text(documentId), .int(Int64(2))]) { r in
            LibInkPageSummary(page: Int(r.int64(0)), count: Int(r.int64(1)), minY: r.double(2), colorsJSON: r.text(3))
        }
    }

    /// 各图层的笔数（图层面板的「删除会连带 N 笔」）。键是 payload 里的 `layerId`，统一成**大写**
    /// （Swift 写的本来就是大写 UUID，别的端写小写也归到一起）；老数据没这个键 → 空串，调用方按默认图层算。
    func inkLayerCounts(documentId: String) throws -> [String: Int] {
        let rows = try db.query("""
        SELECT UPPER(COALESCE(json_extract(payload, '$.layerId'), '')), COUNT(*)
        FROM note WHERE document_id=? AND kind=? GROUP BY 1
        """, [.text(documentId), .int(Int64(2))]) { r in (r.text(0), Int(r.int64(1))) }
        return Dictionary(rows, uniquingKeysWith: +)
    }

    /// 删整层的笔迹（窗口外那些内存里没有、对账删不到的行）。`layerId` 传 UUID 字符串（大小写不论）；
    /// 传默认图层 id 时把没有 `layerId` 键的老行一并算进去。返回删掉的行数。
    @discardableResult
    func deleteInkStrokes(documentId: String, layerId: String, isDefaultLayer: Bool) throws -> Int {
        let cond = isDefaultLayer
            ? "(json_extract(payload, '$.layerId') = ? COLLATE NOCASE OR json_extract(payload, '$.layerId') IS NULL)"
            : "json_extract(payload, '$.layerId') = ? COLLATE NOCASE"
        let before = try inkCount(documentId: documentId)
        try db.run("DELETE FROM note WHERE document_id=? AND kind=? AND \(cond)",
                   [.text(documentId), .int(Int64(2)), .text(layerId)])
        return before - (try inkCount(documentId: documentId))
    }

    /// 页内笔迹总数。
    func inkCount(documentId: String) throws -> Int {
        let r = try db.query("SELECT COUNT(*) FROM note WHERE document_id=? AND kind=?",
                             [.text(documentId), .int(Int64(2))]) { Int($0.int64(0)) }
        return r.first ?? 0
    }

    /// 挂在**页面坐标**上的批注条数：文字笔记 0 / 页内笔迹 2 / 高亮 3 / 书签 5 / 图片笔记 6 + 草稿纸（锚点在页上）。
    /// 不含 AI 会话（1）与草稿纸上的笔迹（4，画布坐标）。扫描页对齐切换前提示「多少条会偏」用。
    func pageAnchoredNoteCount(documentId: String) throws -> Int {
        let notes = try db.query("SELECT COUNT(*) FROM note WHERE document_id=? AND kind IN (0,2,3,5,6)",
                                 [.text(documentId)]) { Int($0.int64(0)) }
        let pads = try db.query("SELECT COUNT(*) FROM scratch_pad WHERE document_id=?",
                                [.text(documentId)]) { Int($0.int64(0)) }
        return (notes.first ?? 0) + (pads.first ?? 0)
    }

    /// 按 kind 数一篇文档的 note 行（删除确认框那句「2616 笔笔迹、12 条笔记…」用）。
    /// 一条 GROUP BY，不读 payload。
    func noteKindCounts(documentId: String) throws -> [Int: Int] {
        let rows = try db.query("SELECT kind, COUNT(*) FROM note WHERE document_id=? GROUP BY kind",
                                [.text(documentId)]) { r in (Int(r.int64(0)), Int(r.int64(1))) }
        return Dictionary(rows, uniquingKeysWith: +)
    }

    /// 全篇页内笔迹的横向范围（归一化，anchor 列 = 包围盒）：画板模式页边宽度的首值
    /// （`CanvasMargin`），不必把整篇点装进内存扫一遍。没有笔迹 → nil。
    func inkXExtent(documentId: String) throws -> (minX: Double, maxX: Double)? {
        let r = try db.query("""
        SELECT COUNT(*), MIN(anchor_x), MAX(anchor_x + anchor_w) FROM note WHERE document_id=? AND kind=?
        """, [.text(documentId), .int(Int64(2))]) { r in (Int(r.int64(0)), r.double(1), r.double(2)) }
        guard let row = r.first, row.0 > 0 else { return nil }
        return (row.1, row.2)
    }
    func upsertNote(_ n: LibNote) throws {
        let up = ISO.string(n.updatedAt)
        try db.run("""
        INSERT INTO note(id,document_id,kind,page,anchor_x,anchor_y,anchor_w,anchor_h,payload,created_at,updated_at,points,points_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, page=excluded.page,
          anchor_x=excluded.anchor_x, anchor_y=excluded.anchor_y, anchor_w=excluded.anchor_w, anchor_h=excluded.anchor_h,
          payload=excluded.payload, updated_at=excluded.updated_at, points=excluded.points, points_at=excluded.points_at
        """, [.text(n.id), .text(n.documentId), .int(Int64(n.kind)), .int(Int64(n.page)),
              .double(n.anchor.origin.x), .double(n.anchor.origin.y), .double(n.anchor.size.width), .double(n.anchor.size.height),
              .blob(inkPayloadForWrite(n.payload, points: n.points)), .text(ISO.string(n.createdAt)), .text(up),
              n.points.map { .blob($0) } ?? .null, n.points == nil ? .null : .text(up)])
    }

    /// 写库前的笔迹 payload（`BINARY-INK-PLAN.md §4`）：这一行带二进制 → 把 JSON 点摘成 `[]`（点只存二进制）。
    /// 所有写口（页内 / 草稿纸 / 画板）都经这里；上层照旧产出带点的完整 JSON（剪贴板等别处要用）。
    private func inkPayloadForWrite(_ payload: Data, points: Data?) -> Data {
        guard points != nil else { return payload }
        return InkPayloadFast.stripPoints(payload)?.rest ?? payload
    }
    func deleteNote(id: String) throws { try db.run("DELETE FROM note WHERE id=?", [.text(id)]) }

    // MARK: - 笔迹图层（ink_layer，v7）

    func inkLayers(documentId: String) throws -> [LibInkLayer] {
        try db.query("SELECT * FROM ink_layer WHERE document_id=? ORDER BY sort_order ASC", [.text(documentId)]).map(Self.inkLayer)
    }
    func upsertInkLayer(_ l: LibInkLayer) throws {
        try db.run("""
        INSERT INTO ink_layer(id,document_id,name,color_key,sort_order,visible,created_at)
        VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET name=excluded.name, color_key=excluded.color_key,
          sort_order=excluded.sort_order, visible=excluded.visible
        """, [.text(l.id), .text(l.documentId), .text(l.name), .text(l.colorKey),
              .int(Int64(l.sortOrder)), .int(l.visible ? 1 : 0), .text(ISO.string(l.createdAt))])
    }
    func deleteInkLayer(id: String) throws { try db.run("DELETE FROM ink_layer WHERE id=?", [.text(id)]) }

    // MARK: - 草稿纸（scratch_pad，v8）

    func scratchPads(documentId: String) throws -> [LibScratchPad] {
        try db.query("SELECT * FROM scratch_pad WHERE document_id=? ORDER BY created_at ASC",
                     [.text(documentId)]).map(Self.scratchPad)
    }
    func upsertScratchPad(_ p: LibScratchPad) throws {
        try db.run("""
        INSERT INTO scratch_pad(id,document_id,title,anchor_page,anchor_x,anchor_y,bg,pattern,show_page,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET title=excluded.title, anchor_page=excluded.anchor_page,
          anchor_x=excluded.anchor_x, anchor_y=excluded.anchor_y, bg=excluded.bg,
          pattern=excluded.pattern, show_page=excluded.show_page, updated_at=excluded.updated_at
        """, [.text(p.id), .text(p.documentId), .text(p.title), .int(Int64(p.anchorPage)),
              .double(p.anchorX), .double(p.anchorY), .text(p.bg), .text(p.pattern),
              .int(p.showPage ? 1 : 0),
              .text(ISO.string(p.createdAt)), .text(ISO.string(p.updatedAt))])
    }
    /// 删除一张草稿纸。**纸上的笔迹（note kind=4）不在这里删**——它们由上层的 `session.scratchStrokes`
    /// 对账机制按 id 删除（与擦除同一条路径）。这里多删一次只会和对账重复。
    func deleteScratchPad(id: String) throws {
        try db.run("DELETE FROM scratch_pad WHERE id=?", [.text(id)])
    }

    // MARK: - 画板笔记（board_note / board_item，v16；`BOARD-NOTE-PLAN.md §2`）

    /// 画板笔记里的图片条目 kind（同 `imageNoteKind`：引用计数的 SQL 要用）。
    static let boardImageKind = 2

    func boards() throws -> [LibBoard] {
        try db.query("SELECT * FROM board_note ORDER BY COALESCE(last_opened_at, created_at) DESC").map(Self.board)
    }
    func board(id: String) throws -> LibBoard? {
        try db.query("SELECT * FROM board_note WHERE id=?", [.text(id)]).map(Self.board).first
    }
    func upsertBoard(_ b: LibBoard) throws {
        try db.run("""
        INSERT INTO board_note(id,title,bg,pattern,group_name,created_at,updated_at,last_opened_at)
        VALUES(?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET title=excluded.title, bg=excluded.bg, pattern=excluded.pattern,
          group_name=excluded.group_name, updated_at=excluded.updated_at, last_opened_at=excluded.last_opened_at
        """, [.text(b.id), .text(b.title), .text(b.bg), .text(b.pattern), .text(b.groupName),
              .text(ISO.string(b.createdAt)), .text(ISO.string(b.updatedAt)),
              b.lastOpenedAt.map { .text(ISO.string($0)) } ?? .null])
    }
    /// 只记「最近打开」（不动 `updated_at`——打开不算改动，否则离线镜像会把没改过的画板当成改过）。
    func touchBoardOpened(id: String, at: Date = .now) throws {
        try db.run("UPDATE board_note SET last_opened_at=? WHERE id=?", [.text(ISO.string(at)), .text(id)])
    }
    /// 删一篇画板笔记，连同上面的全部条目（外键 CASCADE）。归档进回收站由上层先做。
    func deleteBoard(id: String) throws {
        try db.run("DELETE FROM board_note WHERE id=?", [.text(id)])
    }
    func boardItems(boardId: String) throws -> [LibBoardItem] {
        try db.query("SELECT * FROM board_item WHERE board_id=? ORDER BY created_at ASC",
                     [.text(boardId)]).map(Self.boardItem)
    }
    func boardItemCounts() throws -> [String: Int] {
        let rows = try db.query("SELECT board_id, COUNT(*) FROM board_item GROUP BY board_id") { r in
            (r.text(0), Int(r.int64(1)))
        }
        return Dictionary(rows, uniquingKeysWith: +)
    }
    func upsertBoardItem(_ i: LibBoardItem) throws {
        let up = ISO.string(i.updatedAt)
        try db.run("""
        INSERT INTO board_item(id,board_id,kind,x,y,w,h,payload,created_at,updated_at,points,points_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, x=excluded.x, y=excluded.y, w=excluded.w, h=excluded.h,
          payload=excluded.payload, updated_at=excluded.updated_at, points=excluded.points, points_at=excluded.points_at
        """, [.text(i.id), .text(i.boardId), .int(Int64(i.kind)),
              .double(i.rect.origin.x), .double(i.rect.origin.y), .double(i.rect.width), .double(i.rect.height),
              .blob(inkPayloadForWrite(i.payload, points: i.points)), .text(ISO.string(i.createdAt)), .text(up),
              i.points.map { .blob($0) } ?? .null, i.points == nil ? .null : .text(up)])
    }
    func deleteBoardItem(id: String) throws { try db.run("DELETE FROM board_item WHERE id=?", [.text(id)]) }

    // MARK: - 笔迹点集二进制（v18，`BINARY-INK-PLAN.md`）

    /// 装笔迹的两张表与各自的笔迹 kind
    private static let inkTables: [(table: String, kinds: String)] = [("note", "2,4"), ("board_item", "1")]

    /// 打开工作区时的整理（§5，用户 2026-09-26 定：**默认就清掉 JSON 点，不要兼容模式、不要备份**）：
    /// 找出「二进制缺失 / 过期，或 payload 里还带 JSON 点」的笔迹行，一行一次写好——
    ///  · 二进制有效（`points_at == updated_at`）→ 以二进制为准，只摘 JSON 点；
    ///  · 否则以 JSON 点为准（旧版 App 写的 / 改过的 / v17 的老行）→ 编成二进制，同时摘 JSON 点。
    /// `updated_at` 不动（`points_at` 仍等于它）；payload 变了，离线镜像两边各自整理完字节相同。
    /// 按 id 翻页（解不出点的行不会让它原地打转），每批一个事务；写时再核一次 `updated_at`
    /// （批与批之间主线程改过这一行就跳过，下次打开再整理）。后台线程调，返回整理了几行。
    /// `jsonPoints` = 从 payload 读 JSON 点（App 层传带 `JSONDecoder` 兜底的那版，默认只用字节快读——存储层不依赖 App 层）。
    @discardableResult
    func compactInkPoints(batch: Int = 400,
                          jsonPoints: (Data) -> [SIMD3<Float>]? = { InkPayloadFast.splitPoints($0)?.points }) -> Int {
        var total = 0
        for (table, kinds) in Self.inkTables {
            var after = ""
            while true {
                // LIKE 在 BLOB 上按文本比；`[` 不是 LIKE 的通配符。两端写 JSON 都是紧凑形态（`"points":[[`）
                let rows = (try? db.query("""
                SELECT id, payload, updated_at, points, points_at IS updated_at FROM \(table)
                WHERE kind IN (\(kinds)) AND id > ?
                  AND (points IS NULL OR points_at IS NOT updated_at OR payload LIKE '%"points":[[%')
                ORDER BY id LIMIT ?
                """, [.text(after), .int(Int64(batch))]) { r -> (String, Data, String, Data, Bool) in
                    (r.text(0), r.blob(1), r.text(2), r.blob(3), r.int64(4) != 0)
                }) ?? []
                guard let last = rows.last else { break }
                after = last.0
                let fills = rows.compactMap { row -> (id: String, blob: Data, payload: Data, up: String)? in
                    let (id, payload, up, blob, valid) = row
                    if valid, !blob.isEmpty, InkPointsBlob.decode(blob) != nil {
                        guard let s = InkPayloadFast.stripPoints(payload), s.hadPoints else { return nil }
                        return (id, blob, s.rest, up)
                    }
                    guard let pts = jsonPoints(payload), !pts.isEmpty else { return nil }
                    return (id, InkPointsBlob.encode(pts), InkPayloadFast.stripPoints(payload)?.rest ?? payload, up)
                }
                guard !fills.isEmpty else { continue }
                do {
                    try db.transaction {
                        for f in fills {
                            try db.run("""
                            UPDATE \(table) SET points=?, points_at=updated_at, payload=? WHERE id=? AND updated_at=?
                            """, [.blob(f.blob), .blob(f.payload), .text(f.id), .text(f.up)])
                        }
                    }
                    total += fills.count
                } catch {
                    NSLog("[InkBlob] 整理 \(table) 一批失败：\(error)")
                    break
                }
            }
        }
        return total
    }

    // 分页画板的页（board_page，v17；`BOARD-NOTE-PLAN.md §9`）
    func boardPages(boardId: String) throws -> [LibBoardPage] {
        try db.query("SELECT * FROM board_page WHERE board_id=? ORDER BY sort_key ASC, created_at ASC",
                     [.text(boardId)]).map(Self.boardPage)
    }
    func upsertBoardPage(_ p: LibBoardPage) throws {
        try db.run("""
        INSERT INTO board_page(id,board_id,sort_key,width,height,template,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET sort_key=excluded.sort_key, width=excluded.width, height=excluded.height,
          template=excluded.template, updated_at=excluded.updated_at
        """, [.text(p.id), .text(p.boardId), .double(p.sortKey), .double(p.width), .double(p.height),
              .text(p.template), .text(ISO.string(p.createdAt)), .text(ISO.string(p.updatedAt))])
    }
    func deleteBoardPage(id: String) throws { try db.run("DELETE FROM board_page WHERE id=?", [.text(id)]) }

    // MARK: - 图片本体（image，v13；`IMAGE-NOTE-PLAN.md §2~3`）

    /// 图片笔记的 note kind。定义在 Store 层而不是 App 层：引用计数是 SQL 算的，这个数字 DAO 自己要用。
    static let imageNoteKind = 6
    /// 待删除多久后真删（秒）：30 天。
    static let imagePurgeAfter: TimeInterval = 30 * 86_400

    func images() throws -> [LibImage] {
        try db.query("SELECT * FROM image ORDER BY created_at ASC").map(Self.image)
    }
    func image(sha256: String) throws -> LibImage? {
        try db.query("SELECT * FROM image WHERE sha256=?", [.text(sha256)]).map(Self.image).first
    }
    /// 登记一张图（已存在则不动——同图只有一行，`orphaned_at` 由对账管）。
    func insertImageIfAbsent(_ im: LibImage) throws {
        try db.run("""
        INSERT OR IGNORE INTO image(sha256,ext,width,height,bytes,created_at,orphaned_at) VALUES(?,?,?,?,?,?,?)
        """, [.text(im.sha256), .text(im.ext), .int(Int64(im.width)), .int(Int64(im.height)),
              .int(Int64(im.bytes)), .text(ISO.string(im.createdAt)),
              im.orphanedAt.map { .text(ISO.string($0)) } ?? .null])
    }
    /// 只删行。**文件由调用方删**（`ImageAssets.remove`）——DAO 不碰文件系统，spike 才能只测库。
    func deleteImage(sha256: String) throws {
        try db.run("DELETE FROM image WHERE sha256=?", [.text(sha256)])
    }

    /// 每张图当前被引用几次（**数出来的**：`note` kind=6 + `board_item` kind=2 的 payload `image` 键）。
    /// 没被引用的图不在结果里。图片条目几十条顶天，`json_extract` 这点开销可忽略。
    /// 🔴 画板上的图（v16）必须一起数，否则会被当成没人用、30 天后删掉（`BOARD-NOTE-PLAN.md §2.3`）。
    func imageRefCounts() throws -> [String: Int] {
        var out: [String: Int] = [:]
        for (sha, n) in try db.query("""
        SELECT img, COUNT(*) FROM (
          SELECT json_extract(payload, '$.image') AS img FROM note WHERE kind=?
          UNION ALL
          SELECT json_extract(payload, '$.image') AS img FROM board_item WHERE kind=?
        ) GROUP BY img
        """, [.int(Int64(Self.imageNoteKind)), .int(Int64(Self.boardImageKind))],
             row: { r in (r.text(0), Int(r.int64(1))) }) where !sha.isEmpty {
            out[sha] = n
        }
        return out
    }
    func imageRefCount(sha256: String) throws -> Int {
        let r = try db.query("""
        SELECT (SELECT COUNT(*) FROM note WHERE kind=? AND json_extract(payload, '$.image')=?)
             + (SELECT COUNT(*) FROM board_item WHERE kind=? AND json_extract(payload, '$.image')=?)
        """, [.int(Int64(Self.imageNoteKind)), .text(sha256),
              .int(Int64(Self.boardImageKind)), .text(sha256)]) { r in Int(r.int64(0)) }
        return r.first ?? 0
    }

    /// 对账 `orphaned_at`（方案 §3 规则 1）：有引用 → 清空；无引用且此前为空 → 记下 `now`。
    /// **已经非空的不重置**——否则「删了又恢复又删」把 30 天越拖越长。返回状态**变了**的 sha 列表。
    /// `only` 非 nil 时只对账那几张（删一条笔记后只需要看它指向的那一张）。
    @discardableResult
    func reconcileImageOrphans(now: Date = .now, only: Set<String>? = nil) throws -> [String] {
        let refs = try imageRefCounts()
        var changed: [String] = []
        for im in try images() {
            if let only, !only.contains(im.sha256) { continue }
            let referenced = (refs[im.sha256] ?? 0) > 0
            if referenced, im.orphanedAt != nil {
                try db.run("UPDATE image SET orphaned_at=NULL WHERE sha256=?", [.text(im.sha256)])
                changed.append(im.sha256)
            } else if !referenced, im.orphanedAt == nil {
                try db.run("UPDATE image SET orphaned_at=? WHERE sha256=?", [.text(ISO.string(now)), .text(im.sha256)])
                changed.append(im.sha256)
            }
        }
        return changed
    }

    /// 待删除且已到期的图（`orphaned_at < before`）。调用方删文件 + `deleteImage`。
    /// `before` 传「现在」= 立即清理全部待删除；传「现在 − 30 天」= 常规到期清理。
    func purgeableImages(before: Date) throws -> [LibImage] {
        try db.query("SELECT * FROM image WHERE orphaned_at IS NOT NULL AND orphaned_at < ?",
                     [.text(ISO.string(before))]).map(Self.image)
    }

    /// 设置页那一行要的数：总数 / 待删除数 / 总字节。
    func imageStats() -> (total: Int, orphaned: Int, bytes: Int64) {
        let r = (try? db.query("""
        SELECT COUNT(*), SUM(orphaned_at IS NOT NULL), COALESCE(SUM(bytes), 0) FROM image
        """) { r in (Int(r.int64(0)), Int(r.int64(1)), r.int64(2)) }) ?? []
        return r.first ?? (0, 0, 0)
    }

    // MARK: - 页面几何缓存（page_geom）

    /// 某内容的每页高度（文档单位）；没缓存或页数对不上 → nil（上层按 PDF 现算并回填）。
    func pageHeights(contentHash: String, pageCount: Int) throws -> [Double]? {
        let rows = try db.query("SELECT page_count, heights FROM page_geom WHERE content_hash=?",
                                [.text(contentHash)]) { r in (Int(r.int64(0)), r.blob(1)) }
        guard let row = rows.first, row.0 == pageCount,
              let hs = try? JSONDecoder().decode([Double].self, from: row.1), hs.count == pageCount else { return nil }
        return hs
    }
    func savePageHeights(contentHash: String, heights: [Double]) throws {
        let data = try JSONEncoder().encode(heights)
        try db.run("""
        INSERT INTO page_geom(content_hash,page_count,heights,created_at) VALUES(?,?,?,?)
        ON CONFLICT(content_hash) DO UPDATE SET page_count=excluded.page_count, heights=excluded.heights, created_at=excluded.created_at
        """, [.text(contentHash), .int(Int64(heights.count)), .blob(data), .text(ISO.string(.now))])
    }

    // MARK: - 扫描页对齐（page_align，v14，`SCAN-ALIGN-PLAN.md §3`）

    /// 某内容的对齐参数行（没测过 → nil）。开关开没开都返回，调用方看 `enabled`。
    func pageAlign(contentHash: String) throws -> PageAlignRow? {
        try db.query("SELECT * FROM page_align WHERE content_hash=?", [.text(contentHash)]).first.map(Self.pageAlign)
    }
    /// 全部开着的对齐参数行（参考窗索引一次取齐，别逐篇查）。
    func enabledPageAligns() throws -> [PageAlignRow] {
        try db.query("SELECT * FROM page_align WHERE enabled=1").map(Self.pageAlign)
    }
    /// 写一整行（测量完 / 离线镜像合并按 `updated_at` 取新时用）。
    func upsertPageAlign(_ r: PageAlignRow) throws {
        try db.run("""
        INSERT INTO page_align(content_hash,enabled,page_count,payload,created_at,updated_at) VALUES(?,?,?,?,?,?)
        ON CONFLICT(content_hash) DO UPDATE SET enabled=excluded.enabled, page_count=excluded.page_count,
          payload=excluded.payload, created_at=excluded.created_at, updated_at=excluded.updated_at
        """, [.text(r.contentHash), .int(r.enabled ? 1 : 0), .int(Int64(r.pageCount)), .blob(r.payload),
              .text(ISO.string(r.createdAt)), .text(ISO.string(r.updatedAt))])
    }
    /// 只切开关（参数不动、不重测）。
    func setPageAlignEnabled(contentHash: String, on: Bool, at date: Date = .now) throws {
        try db.run("UPDATE page_align SET enabled=?, updated_at=? WHERE content_hash=?",
                   [.int(on ? 1 : 0), .text(ISO.string(date)), .text(contentHash)])
    }
    /// 离线镜像合并：把这一行**原样**（时间戳字符串逐字，不经 Date 往返）写到另一个库，覆盖对面同键那一行。
    /// 逐字搬是为了下一轮干跑两侧 `updated_at` 相等、不再判出差异。没有这一行 → false。
    @discardableResult
    func copyPageAlign(contentHash: String, to other: LibraryStore) throws -> Bool {
        guard let r = try db.query("SELECT * FROM page_align WHERE content_hash=?", [.text(contentHash)]).first
        else { return false }
        try other.db.run("""
        INSERT INTO page_align(content_hash,enabled,page_count,payload,created_at,updated_at) VALUES(?,?,?,?,?,?)
        ON CONFLICT(content_hash) DO UPDATE SET enabled=excluded.enabled, page_count=excluded.page_count,
          payload=excluded.payload, created_at=excluded.created_at, updated_at=excluded.updated_at
        """, [.text(contentHash), .int(r["enabled"] as? Int64 ?? 0), .int(r["page_count"] as? Int64 ?? 0),
              .blob(r["payload"] as? Data ?? Data()), .text(r["created_at"] as? String ?? ""),
              .text(r["updated_at"] as? String ?? "")])
        return true
    }

    // MARK: - OCR 缓存（ocr_page，v3）

    /// 取某内容(hash) 某页某引擎的 OCR 缓存（miss → nil，上层再真跑 OCR 并回填）。
    func ocrPage(contentHash: String, page: Int, provider: String) throws -> OCRPage? {
        try db.query("SELECT * FROM ocr_page WHERE content_hash=? AND page=? AND provider=?",
                     [.text(contentHash), .int(Int64(page)), .text(provider)]).first.map(Self.ocr)
    }
    /// 回填/更新一页的 OCR 结果。
    func upsertOCRPage(_ p: OCRPage) throws {
        try db.run("""
        INSERT INTO ocr_page(content_hash,page,provider,payload,lang,created_at) VALUES(?,?,?,?,?,?)
        ON CONFLICT(content_hash,page,provider) DO UPDATE SET
          payload=excluded.payload, lang=excluded.lang, created_at=excluded.created_at
        """, [.text(p.contentHash), .int(Int64(p.page)), .text(p.provider),
              .blob(p.payload), p.lang.map { .text($0) } ?? .null, .text(ISO.string(p.createdAt))])
    }
    /// **只补不覆盖**地写一页（`INSERT OR IGNORE`）：目标库已经有这个键就一个字都不动。
    ///
    /// 离线镜像合并专用（方案 §4）。与 `upsertOCRPage` 的差别正是那里要的语义：合并只负责把
    /// 对面缺的页补上，不替用户判断「同一页的两份识别结果哪份更好」——同内容同引擎，本就等价。
    func insertOCRPageIfAbsent(_ p: OCRPage) throws {
        try db.run("""
        INSERT OR IGNORE INTO ocr_page(content_hash,page,provider,payload,lang,created_at)
        VALUES(?,?,?,?,?,?)
        """, [.text(p.contentHash), .int(Int64(p.page)), .text(p.provider),
              .blob(p.payload), p.lang.map { .text($0) } ?? .null, .text(ISO.string(p.createdAt))])
    }
    /// 清除某内容(hash)的全部 OCR 缓存（hash 变化/重关联时用）。
    func deleteOCRPages(contentHash: String) throws {
        try db.run("DELETE FROM ocr_page WHERE content_hash=?", [.text(contentHash)])
    }
    /// 某内容(hash) 某引擎已缓存的**全部**页 payload（页 → JSON）。
    /// 用途：一次性建水印指纹（`OCRWatermark.Profile`）——它要的是**跨页**统计，
    /// 而阅读区是逐页懒加载的，攒不出样本；库里往往整本都跑完了，一次读出来即可。
    func allOCRPayloads(contentHash: String, provider: String) throws -> [Int: Data] {
        let rows = try db.query("SELECT page,payload FROM ocr_page WHERE content_hash=? AND provider=?",
                                [.text(contentHash), .text(provider)])
        var out: [Int: Data] = [:]
        for r in rows {
            guard let page = r["page"] as? Int64, let payload = r["payload"] as? Data else { continue }
            out[Int(page)] = payload
        }
        return out
    }

    /// 某内容(hash) 某引擎已缓存的 OCR 页数（>0 → 打开文档时自动启用 OCR 文本层，缓存直接复用）。
    func ocrPageCount(contentHash: String, provider: String) throws -> Int {
        let rows = try db.query("SELECT COUNT(*) AS c FROM ocr_page WHERE content_hash=? AND provider=?",
                                [.text(contentHash), .text(provider)])
        return Int((rows.first?["c"] as? Int64) ?? 0)
    }

    // MARK: - 行 → 模型

    private static func doc(_ r: [String: Any]) -> LibDocument {
        LibDocument(id: r["id"] as? String ?? "", title: r["title"] as? String ?? "",
                    pageCount: Int(r["page_count"] as? Int64 ?? 0),
                    addedAt: ISO.date(r["added_at"] as? String) ?? .now,
                    lastOpenedAt: ISO.date(r["last_opened_at"] as? String) ?? .now,
                    sortOrder: Int(r["sort_order"] as? Int64 ?? 0),
                    readPage: Int(r["read_page"] as? Int64 ?? 0),
                    readFrac: r["read_frac"] as? Double ?? 0,
                    readZoom: r["read_zoom"] as? Double ?? 1,
                    readHFrac: r["read_hfrac"] as? Double ?? 0,
                    group: r["group_name"] as? String ?? "",
                    canvasMode: (r["canvas_mode"] as? Int64 ?? 0) != 0)
    }
    private static func mdDoc(_ r: [String: Any]) -> LibMarkdownDoc {
        LibMarkdownDoc(id: r["id"] as? String ?? "", title: r["title"] as? String ?? "",
                       relPath: r["rel_path"] as? String ?? "",
                       group: r["group_name"] as? String ?? "",
                       sortOrder: Int(r["sort_order"] as? Int64 ?? 0),
                       createdAt: ISO.date(r["created_at"] as? String) ?? .now,
                       updatedAt: ISO.date(r["updated_at"] as? String) ?? .now,
                       lastOpenedAt: ISO.date(r["last_opened_at"] as? String) ?? .now)
    }
    private static func variant(_ r: [String: Any]) -> LibVariant {
        LibVariant(id: r["id"] as? String ?? "", documentId: r["document_id"] as? String ?? "",
                   contentHash: r["content_hash"] as? String ?? "",
                   pageCount: Int(r["page_count"] as? Int64 ?? 0),
                   addedAt: ISO.date(r["added_at"] as? String) ?? .now)
    }
    private static func location(_ r: [String: Any]) -> LibLocation {
        LibLocation(id: r["id"] as? String ?? "", variantId: r["variant_id"] as? String ?? "",
                    path: r["path"] as? String ?? "",
                    isValid: (r["is_valid"] as? Int64 ?? 0) != 0,
                    lastValidatedAt: ISO.date(r["last_validated_at"] as? String),
                    inWorkspace: (r["in_workspace"] as? Int64 ?? 0) != 0,
                    isRelative: (r["is_relative"] as? Int64 ?? 0) != 0)
    }
    private static func note(_ r: [String: Any]) -> LibNote {
        LibNote(id: r["id"] as? String ?? "", documentId: r["document_id"] as? String ?? "",
                kind: Int(r["kind"] as? Int64 ?? 0), page: Int(r["page"] as? Int64 ?? 0),
                anchor: CGRect(x: r["anchor_x"] as? Double ?? 0, y: r["anchor_y"] as? Double ?? 0,
                               width: r["anchor_w"] as? Double ?? 0, height: r["anchor_h"] as? Double ?? 0),
                payload: r["payload"] as? Data ?? Data(),
                createdAt: ISO.date(r["created_at"] as? String) ?? .now,
                updatedAt: ISO.date(r["updated_at"] as? String) ?? .now,
                points: pointsBlob(r), pointsValid: pointsValid(r))
    }
    /// v18 二进制点集列（空 / NULL = 没有）
    private static func pointsBlob(_ r: [String: Any]) -> Data? {
        guard let d = r["points"] as? Data, !d.isEmpty else { return nil }
        return d
    }
    /// 二进制是否最新：`points_at` 与 `updated_at` 的**原始字符串**相等（两端时间戳写法不必一致）
    private static func pointsValid(_ r: [String: Any]) -> Bool {
        guard let at = r["points_at"] as? String, let up = r["updated_at"] as? String else { return false }
        return at == up
    }
    private static func inkLayer(_ r: [String: Any]) -> LibInkLayer {
        LibInkLayer(id: r["id"] as? String ?? "", documentId: r["document_id"] as? String ?? "",
                    name: r["name"] as? String ?? "", colorKey: r["color_key"] as? String ?? "",
                    sortOrder: Int(r["sort_order"] as? Int64 ?? 0),
                    visible: (r["visible"] as? Int64 ?? 1) != 0,
                    createdAt: ISO.date(r["created_at"] as? String) ?? .now)
    }
    private static func scratchPad(_ r: [String: Any]) -> LibScratchPad {
        LibScratchPad(id: r["id"] as? String ?? "", documentId: r["document_id"] as? String ?? "",
                      title: r["title"] as? String ?? "",
                      anchorPage: Int(r["anchor_page"] as? Int64 ?? 0),
                      anchorX: r["anchor_x"] as? Double ?? 0, anchorY: r["anchor_y"] as? Double ?? 0,
                      bg: r["bg"] as? String ?? "rgba(255,255,255,1.0)",
                      pattern: r["pattern"] as? String ?? "dots",
                      showPage: (r["show_page"] as? Int64 ?? 0) != 0,
                      createdAt: ISO.date(r["created_at"] as? String) ?? .now,
                      updatedAt: ISO.date(r["updated_at"] as? String) ?? .now)
    }
    private static func board(_ r: [String: Any]) -> LibBoard {
        LibBoard(id: r["id"] as? String ?? "", title: r["title"] as? String ?? "",
                 bg: r["bg"] as? String ?? "rgba(255,255,255,1.0)",
                 pattern: r["pattern"] as? String ?? "dots",
                 groupName: r["group_name"] as? String ?? "",
                 createdAt: ISO.date(r["created_at"] as? String) ?? .now,
                 updatedAt: ISO.date(r["updated_at"] as? String) ?? .now,
                 lastOpenedAt: ISO.date(r["last_opened_at"] as? String))
    }
    private static func boardItem(_ r: [String: Any]) -> LibBoardItem {
        LibBoardItem(id: r["id"] as? String ?? "", boardId: r["board_id"] as? String ?? "",
                     kind: Int(r["kind"] as? Int64 ?? 0),
                     rect: CGRect(x: r["x"] as? Double ?? 0, y: r["y"] as? Double ?? 0,
                                  width: r["w"] as? Double ?? 0, height: r["h"] as? Double ?? 0),
                     payload: r["payload"] as? Data ?? Data(),
                     createdAt: ISO.date(r["created_at"] as? String) ?? .now,
                     updatedAt: ISO.date(r["updated_at"] as? String) ?? .now,
                     points: pointsBlob(r), pointsValid: pointsValid(r))
    }
    private static func boardPage(_ r: [String: Any]) -> LibBoardPage {
        LibBoardPage(id: r["id"] as? String ?? "", boardId: r["board_id"] as? String ?? "",
                     sortKey: r["sort_key"] as? Double ?? 0,
                     width: r["width"] as? Double ?? 595, height: r["height"] as? Double ?? 842,
                     template: r["template"] as? String ?? "blank",
                     createdAt: ISO.date(r["created_at"] as? String) ?? .now,
                     updatedAt: ISO.date(r["updated_at"] as? String) ?? .now)
    }
    private static func image(_ r: [String: Any]) -> LibImage {
        LibImage(sha256: r["sha256"] as? String ?? "", ext: r["ext"] as? String ?? "png",
                 width: Int(r["width"] as? Int64 ?? 0), height: Int(r["height"] as? Int64 ?? 0),
                 bytes: Int(r["bytes"] as? Int64 ?? 0),
                 createdAt: ISO.date(r["created_at"] as? String) ?? .now,
                 orphanedAt: ISO.date(r["orphaned_at"] as? String))
    }
    private static func pageAlign(_ r: [String: Any]) -> PageAlignRow {
        PageAlignRow(contentHash: r["content_hash"] as? String ?? "",
                     enabled: (r["enabled"] as? Int64 ?? 0) != 0,
                     pageCount: Int(r["page_count"] as? Int64 ?? 0),
                     payload: r["payload"] as? Data ?? Data(),
                     createdAt: ISO.date(r["created_at"] as? String) ?? .now,
                     updatedAt: ISO.date(r["updated_at"] as? String) ?? .now)
    }
    private static func ocr(_ r: [String: Any]) -> OCRPage {
        OCRPage(contentHash: r["content_hash"] as? String ?? "",
                page: Int(r["page"] as? Int64 ?? 0),
                provider: r["provider"] as? String ?? "",
                payload: r["payload"] as? Data ?? Data(),
                lang: r["lang"] as? String,
                createdAt: ISO.date(r["created_at"] as? String) ?? .now)
    }
}
