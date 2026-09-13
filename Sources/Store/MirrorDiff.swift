import Foundation

/// 离线镜像的**三方合并**：算出「哪些行要写进源盘、哪些要拉回镜像、哪些冲突」。
/// 方案 `OFFLINE-MIRROR-PLAN.md` §3.1 的判定表 + §6 的冲突规则。
///
/// 🔴 **本文件只算不写。** 应用合并是 M5 的事（单事务 + 合并前备份源库）。
/// 分开的理由不是洁癖：干跑预览是这个功能唯一的安全闸，它必须能在**完全不碰任何库**的前提下
/// 跑出完整结论给用户看。算和写混在一起，预览就永远只是"大概会这样"。
///
/// 🔴 跨端契约：与安卓 `local/mirror/MirrorDiff.kt` 是同一套判定，改一边必须同步另一边。
/// 判错一格的后果不是"某个功能不好用"，是**静默丢笔迹**。
enum MirrorDiff {

    // MARK: - 输入

    /// 一侧的全部行：`表名 → (row_id → 行)`。
    typealias Snapshot = [String: [String: [String: Any]]]

    /// 基线：`表名 → (row_id → fp)`（镜像库的 `sync_base`）。
    typealias Base = [String: [String: String]]

    // MARK: - 输出

    /// 这条改动要落到哪一边。
    enum Side: String { case source, mirror }

    enum Op: String { case upsert, delete }

    /// 为什么产生这条改动 —— 给报告用，也让「为什么它要删我的东西」永远答得上来。
    enum Reason: String {
        case mirrorAdded, mirrorDeleted, mirrorModified   // 镜像侧的动作，落到源盘
        case sourceAdded, sourceDeleted, sourceModified   // 源盘侧的动作，落到镜像
        case conflictNewer      // 两端都改 → 按 lww 取新的
        case conflictKeptSource // 两端都改但表没有时间戳列 → 保留源盘
        case conflictKeptEdit   // 一端删一端改 → 保留"改"（不丢数据优先）
    }

    struct Change {
        var table: String
        var rowId: String
        var op: Op
        var side: Side
        var reason: Reason
        /// upsert 时要写入的整行；delete 时为 nil。
        var row: [String: Any]?
        /// 这行属于哪篇文档、`note` 的话是哪一类（kind）。**删除也带**——报告要说
        /// 「《高等数学》的一条笔迹」，而删除那条 `row` 是 nil，事后就查不出来了。
        var docId: String?
        var kind: Int?
        var page: Int?
    }

    enum ConflictKind: String {
        case bothModified   // 两端都改了同一行
        case deleteVsEdit   // 一端删了、另一端改了
        case bothAdded      // 两端各自新建了同一个 id 的行（UUID 表几乎不可能，`meta` 会）
    }

    struct Conflict {
        var table: String
        var rowId: String
        var kind: ConflictKind
        var kept: Side
        /// 人话说明（报告直接用）。
        var note: String
    }

    /// `ocr_page` 的一行的键。**这张表不走上面那套 `Change`**：它是三列复合主键
    /// （`content_hash,page,provider`）、没有 `document_id`，而 `Change`/`sync_base` 那套
    /// 从头到尾假设「单列 TEXT 主键」。方案 §4 给它定的是另一条通道：纯 additive、
    /// 双向 `INSERT OR IGNORE`、不进基线。
    ///
    /// 🔴 跨端契约：与安卓 `local/mirror/MirrorDiff.kt` 的 `OcrKey` 是同一个东西。
    struct OCRKey: Hashable, Comparable {
        var contentHash: String
        var page: Int
        var provider: String

        static func < (a: OCRKey, b: OCRKey) -> Bool {
            (a.contentHash, a.page, a.provider) < (b.contentHash, b.page, b.provider)
        }
    }

    struct Plan {
        var changes: [Change] = []
        var conflicts: [Conflict] = []
        /// OCR 缓存里**对面缺的那些页**（方案 §4：纯 additive，只补不删、不覆盖）。
        ///
        /// 只带键不带 payload：干跑要在「一个字都不写」的前提下跑完，而整库的 OCR JSON 是几百 MB
        /// 级的——把它们读进内存只为数个数，预览本身就成了卡顿源。payload 到 `MirrorApply` 那一步
        /// 再按键逐页取。
        var ocrToSource: [OCRKey] = []
        var ocrToMirror: [OCRKey] = []
        /// 图片本体（`image` 表 + `Images/` 文件，`IMAGE-NOTE-PLAN.md §7`）里**对面缺的那些**（sha256）：
        /// 与 OCR 同一条纯 additive 通道——补行（`INSERT OR IGNORE`，`orphaned_at` 原样带过去）+ 拷文件，
        /// 不删不改、不进基线。「缺」= 对面没有这一行、**或**有行但文件不在（见 `MirrorStore.imageKeys`）。
        var imagesToSource: [String] = []
        var imagesToMirror: [String] = []
        /// `document.last_opened_at` **不在指纹里**（方案 §4：进了指纹「翻开过」就把整行标记成改过），
        /// 所以 diff 看不见它 —— 这里单独算出「两边取较大的那个」，`docId → ISO`。
        ///
        /// 放在 Plan 里而不是留给 M5 自己记：一条不在主流程里的规则，交代在文档里迟早被漏掉。
        var lastOpenedMerges: [String: String] = [:]

        /// 「两端都翻过、但**只差读到哪儿**」的文档 id。照常写（按 `last_opened_at` 取最近读过的
        /// 那次），但**不进 `conflicts`** —— 那不是要用户裁决的事，报出去只是噪音。
        var progressMerges: Set<String> = []

        var isEmpty: Bool {
            changes.isEmpty && lastOpenedMerges.isEmpty && ocrToSource.isEmpty && ocrToMirror.isEmpty
                && imagesToSource.isEmpty && imagesToMirror.isEmpty
        }

        /// 这份 plan 能不能**自动静默地**从源盘推给副本（用户 2026-09-01 拍板的方向不对称：
        /// 源→副本自动，副本→源必须人工确认）。
        ///
        /// 🔴 门槛是「整份都是推给副本、且零冲突」，不是「把推给副本的那些挑出来应用」。
        /// 因为 `MirrorApply` 收尾会 `rebuildSyncBase()`，而基线是**按副本当前状态**重算的：
        /// 只应用一半就重算，等于把没应用的那半的证据抹掉 —— 副本上你自己加的那条
        /// （本来等着推给源盘）会在下一轮被判成「源盘删了它」，然后**静默从副本删掉**。
        /// 所以副本只要有任何自己的改动、或有任何冲突，就一律不自动动手。
        ///
        /// ⚠️ **OCR 缓存刻意不参与这道门槛**（既不挡自动推送，也算进"有东西可推"）：它是
        /// `INSERT OR IGNORE` 的派生缓存 —— 不覆盖、不删除任何东西，也不进 `sync_base`，
        /// 所以上面那条「只应用一半就重算基线会抹掉证据」对它根本不成立。挡住它的唯一效果
        /// 是让"算过一次的页还要再花一次 API 钱"，那正是这张表存在的理由。
        /// 图片本体与 OCR 同一口径（同样是只增不改不删的 additive 通道）。
        var isCleanPushToMirror: Bool {
            !(changes.isEmpty && ocrToSource.isEmpty && ocrToMirror.isEmpty
              && imagesToSource.isEmpty && imagesToMirror.isEmpty)
                && conflicts.isEmpty && changes.allSatisfy { $0.side == .mirror }
        }

        /// 待人工确认的条数（副本 → 源盘那个方向）。提示条报的就是它。
        var pendingToSource: Int { changes.lazy.filter { $0.side == .source }.count }

        func changes(to side: Side) -> [Change] { changes.filter { $0.side == side } }

        func count(_ side: Side, _ op: Op) -> Int {
            changes.lazy.filter { $0.side == side && $0.op == op }.count
        }
    }

    // MARK: - 判定

    /// 一侧的某一行相对基线处于什么状态。
    enum RowState { case added, deleted, unchanged, modified, absent }

    static func state(base: String?, now: String?) -> RowState {
        switch (base, now) {
        case (nil, nil): return .absent
        case (nil, _): return .added
        case (_, nil): return .deleted
        case (let b?, let n?): return b == n ? .unchanged : .modified
        }
    }

    /// 三方合并主函数。**纯函数，不碰任何库**。
    ///
    /// - Parameters:
    ///   - base: 建镜像那一刻的指纹（镜像库的 `sync_base`）
    ///   - mine: 镜像库现在的全部行
    ///   - theirs: 源库现在的全部行
    ///   - mineOCR / theirsOCR: 两侧 `ocr_page` 的键集合（不含 payload，见 `Plan.ocrToSource`）
    static func compute(base: Base, mine: Snapshot, theirs: Snapshot,
                        mineOCR: Set<OCRKey> = [], theirsOCR: Set<OCRKey> = [],
                        mineImages: Set<String> = [], theirsImages: Set<String> = []) -> Plan {
        var plan = Plan()
        // OCR 缓存：**只补对面缺的、不判改删**（方案 §4）。
        // 「一边清了缓存」于是会被另一边补回来 —— 这是刻意的：这张表是派生数据，
        // 删它的语义是"腾空间/想重跑"，不是"这份内容作废了"，而重跑一次要真花 API 的钱。
        plan.ocrToSource = mineOCR.subtracting(theirsOCR).sorted()
        plan.ocrToMirror = theirsOCR.subtracting(mineOCR).sorted()
        // 图片本体同一条通道：一边清理掉（30 天到期）的图，只要另一边还没到期就会被补回来——
        // 也是刻意的：`orphaned_at` 原样带过去，两边到期时刻一致，下一轮各自删干净，不会来回补。
        plan.imagesToSource = mineImages.subtracting(theirsImages).sorted()
        plan.imagesToMirror = theirsImages.subtracting(mineImages).sorted()
        for spec in MirrorFp.specs {
            let t = spec.table
            let baseFps = base[t] ?? [:]
            let mineRows = mine[t] ?? [:]
            let theirsRows = theirs[t] ?? [:]
            let mineFps = mineRows.mapValues { MirrorFp.fingerprint(row: $0, spec: spec) }
            let theirsFps = theirsRows.mapValues { MirrorFp.fingerprint(row: $0, spec: spec) }

            for id in Set(baseFps.keys).union(mineFps.keys).union(theirsFps.keys).sorted() {
                let m = state(base: baseFps[id], now: mineFps[id])
                let s = state(base: baseFps[id], now: theirsFps[id])
                apply(spec: spec, id: id, m: m, s: s,
                      mineFp: mineFps[id], theirsFp: theirsFps[id],
                      mineRow: mineRows[id], theirsRow: theirsRows[id], into: &plan)
            }

            // `last_opened_at` 不进指纹，单独取 max（见 `Plan.lastOpenedMerges`）
            if t == "document" {
                for id in Set(mineRows.keys).intersection(theirsRows.keys) {
                    let a = mineRows[id]?["last_opened_at"] as? String ?? ""
                    let b = theirsRows[id]?["last_opened_at"] as? String ?? ""
                    if a != b, !max(a, b).isEmpty { plan.lastOpenedMerges[id] = max(a, b) }
                }
            }
        }
        return plan
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func apply(spec: MirrorFp.TableSpec, id: String,
                              m: RowState, s: RowState,
                              mineFp: String?, theirsFp: String?,
                              mineRow: [String: Any]?, theirsRow: [String: Any]?,
                              into plan: inout Plan) {
        let t = spec.table
        // 删除那条没有 row，所以标签信息要在这里、趁两侧的行还在手上时取下来
        let any = mineRow ?? theirsRow
        func mk(_ op: Op, _ side: Side, _ reason: Reason, _ row: [String: Any]?) -> Change {
            Change(table: t, rowId: id, op: op, side: side, reason: reason, row: row,
                   docId: any?["document_id"] as? String,
                   kind: (any?["kind"] as? Int64).map(Int.init),
                   page: (any?["page"] as? Int64).map(Int.init))
        }
        switch (m, s) {

        // —— 两边一致，什么都不用做 ——
        case (.unchanged, .unchanged), (.absent, .absent), (.deleted, .deleted):
            return

        // —— 只有一边动了 ——
        case (.added, .absent):      // 镜像新增 → 写进源盘
            plan.changes.append(mk(.upsert, .source, .mirrorAdded, mineRow))
        case (.absent, .added):      // 源盘新增 → 拉进镜像
            plan.changes.append(mk(.upsert, .mirror, .sourceAdded, theirsRow))
        case (.deleted, .unchanged): // 镜像删了、源盘没动 → 源盘也删
            plan.changes.append(mk(.delete, .source, .mirrorDeleted, nil))
        case (.unchanged, .deleted): // 源盘删了、镜像没动 → 镜像也删
            plan.changes.append(mk(.delete, .mirror, .sourceDeleted, nil))
        case (.modified, .unchanged):
            plan.changes.append(mk(.upsert, .source, .mirrorModified, mineRow))
        case (.unchanged, .modified):
            plan.changes.append(mk(.upsert, .mirror, .sourceModified, theirsRow))

        // —— 一端删、一端改：**保留"改"**（方案 §6，不丢用户数据优先）——
        case (.deleted, .modified):
            plan.changes.append(mk(.upsert, .mirror, .conflictKeptEdit, theirsRow))
            plan.conflicts.append(Conflict(table: t, rowId: id, kind: .deleteVsEdit, kept: .source,
                                           note: "本机删掉了它、硬盘上又改过它 —— 保留了硬盘上那份"))
        case (.modified, .deleted):
            plan.changes.append(mk(.upsert, .source, .conflictKeptEdit, mineRow))
            plan.conflicts.append(Conflict(table: t, rowId: id, kind: .deleteVsEdit, kept: .mirror,
                                           note: "硬盘上删掉了它、本机又改过它 —— 保留了本机那份"))

        // —— 两端都动了 ——
        case (.modified, .modified), (.added, .added):
            if mineFp == theirsFp { return }   // 两边改成一样了，无操作
            let kind: ConflictKind = (m == .added) ? .bothAdded : .bothModified
            resolveBoth(spec: spec, id: id, kind: kind,
                        mineRow: mineRow, theirsRow: theirsRow, mk: mk, into: &plan)

        // —— 剩下的组合在数学上到不了（一边 absent 意味着 base 里没有，另一边就不可能是
        //     unchanged/modified/deleted）。真到了说明判定表被改坏了，宁可留个痕迹也不要静默。——
        default:
            assertionFailure("MirrorDiff: 不该出现的状态组合 \(t)/\(id) mine=\(m) theirs=\(s)")
        }
    }

    /// 两端都改了同一行：有时间戳列就取新的，没有就保留源盘（方案 §6）。
    private static func resolveBoth(spec: MirrorFp.TableSpec, id: String, kind: ConflictKind,
                                    mineRow: [String: Any]?, theirsRow: [String: Any]?,
                                    mk: (Op, Side, Reason, [String: Any]?) -> Change,
                                    into plan: inout Plan) {
        let t = spec.table
        // 🔴 **只差「读到哪儿」不算冲突**：两端各翻过同一本书就会走到这里，但那是正常使用。
        // 照常按 lww 选一边写，只是**不报成冲突** —— 报了用户既判断不了也不该判断
        // （2026-09-01 用户实测："几乎什么都没动"却收到一条看不懂的冲突）。
        if t == "document", let m = mineRow, let s = theirsRow,
           MirrorFp.fingerprint(row: m, spec: spec, ignoring: MirrorFp.progressColumns)
            == MirrorFp.fingerprint(row: s, spec: spec, ignoring: MirrorFp.progressColumns) {
            let a = mineRow?[spec.lww ?? ""] as? String ?? ""
            let b = theirsRow?[spec.lww ?? ""] as? String ?? ""
            let keepMine = a > b
            plan.changes.append(mk(.upsert, keepMine ? .source : .mirror, .conflictNewer,
                                   keepMine ? mineRow : theirsRow))
            plan.progressMerges.insert(id)
            return
        }
        if let col = spec.lww {
            // 时间戳是定宽 UTC（`yyyy-MM-ddTHH:mm:ss.SSSZ`，两端同一格式，见 `ISO`/`Iso`），
            // **直接比字符串**：不引入日期解析，也就没有「两端的解析器对同一个串给出不同结果」这条缝。
            let a = mineRow?[col] as? String ?? ""
            let b = theirsRow?[col] as? String ?? ""
            let keepMine = a > b
            plan.changes.append(mk(.upsert, keepMine ? .source : .mirror, .conflictNewer, keepMine ? mineRow : theirsRow))
            plan.conflicts.append(Conflict(table: t, rowId: id, kind: kind,
                                           kept: keepMine ? .mirror : .source,
                                           note: "两端都改过 —— 保留了较新的那份（\(max(a, b))）"))
        } else {
            // 无时间戳列的表（document/variant/ink_layer/meta）：可冲突的字段只有标题、分组、
            // 阅读进度这类低价值项，保守选一边即可，但**必须报出来**。
            plan.changes.append(mk(.upsert, .mirror, .conflictKeptSource, theirsRow))
            plan.conflicts.append(Conflict(table: t, rowId: id, kind: kind, kept: .source,
                                           note: "两端都改过，这张表没有时间戳可比 —— 保留了硬盘上那份"))
        }
    }
}
