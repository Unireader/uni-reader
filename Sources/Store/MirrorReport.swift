import Foundation

/// 把 `MirrorDiff.Plan` 翻成人话 —— **干跑预览就是这个功能唯一的安全闸**，
/// 用户要在这里看懂「按下去会发生什么」，所以一行 id 都不许出现在报告里。
///
/// 反面教材是「note 3f2a… → upsert」这种：用户既判断不了该不该同意，出了事也复盘不了。
/// 报告只说三件事：**动了谁的什么、往哪个方向、多少条**。
enum MirrorReport {

    /// 一行摘要。`detail` 为空表示这条不用展开。
    struct Line {
        var text: String
        var detail: [String] = []
    }

    /// `note.kind` → 人话。取值见 `InkStroke.noteKind` / `TextNote` / `Highlight`。
    static func noteKindName(_ kind: Int?) -> String {
        switch kind {
        case 0: return "文字注解"
        case 1: return "AI 会话"
        case 2: return "笔迹"
        case 3: return "高亮"
        case 4: return "草稿纸笔迹"
        default: return "笔记"
        }
    }

    static func tableName(_ table: String) -> String {
        switch table {
        // 「文档信息」是表名漏到界面上（2026-09-01 用户问「这是什么意思」）。这张表存的就是
        // 书名、分组、排序这些——说「书的信息」谁都懂。
        case "document": return "书的信息"
        case "variant": return "文档版本"
        case "ink_layer": return "笔迹图层"
        case "scratch_pad": return "草稿纸"
        case "meta": return "工作区设置"
        default: return table
        }
    }

    /// 一条改动的类别名（`note` 按 kind 细分，其余按表）。
    static func categoryName(_ c: MirrorDiff.Change) -> String {
        c.table == "note" ? noteKindName(c.kind) : tableName(c.table)
    }

    /// 干跑摘要。`titles` = `documentId → 书名`（两侧合并后的，源盘新增的书也要能查到名字）。
    static func summary(_ plan: MirrorDiff.Plan, titles: [String: String]) -> [Line] {
        var out: [Line] = []
        for (side, heading) in [(MirrorDiff.Side.source, "写入硬盘"), (.mirror, "拉回本机")] {
            // 只差阅读进度的那些**不进明细**：底下「阅读进度取最近读的那次」已经把它说完整了，
            // 再以「修改书的信息 1」的面目出现一次，用户只会问「这是什么意思」（2026-09-01 实测）。
            // ⚠️ 只是不"报"，`plan.changes` 一条不少 —— M5 照常要把它们写下去。
            let list = plan.changes(to: side).filter { !isProgressOnly($0, plan) }
            if list.isEmpty { continue }
            // 按「类别 + 增/删/改」聚合。逐条列出来的话，一次正常同步就是几百行，等于没给用户看。
            var buckets: [String: Int] = [:]
            for c in list {
                let verb: String
                switch c.reason {
                case .mirrorAdded, .sourceAdded: verb = "新增"
                case .mirrorDeleted, .sourceDeleted: verb = "删除"
                default: verb = "修改"
                }
                buckets["\(verb)\(categoryName(c))", default: 0] += 1
            }
            let parts = buckets.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
            out.append(Line(text: "\(heading)：" + parts.joined(separator: "、"),
                            detail: bookBreakdown(list, titles: titles)))
        }
        // 「另有」只在**真的还有别的**时候才说得通
        func also(_ s: String) -> String { out.isEmpty ? s : "另有" + s }
        if !plan.progressMerges.isEmpty {
            out.append(Line(text: also("\(plan.progressMerges.count) 篇文档两端都读过，阅读进度取最近读的那次")))
        }
        // 「上次打开」是纯记账（进度那条已经涵盖了用户真正关心的），只在没有进度合并时单独说一句
        if !plan.lastOpenedMerges.isEmpty, plan.progressMerges.isEmpty {
            out.append(Line(text: also("\(plan.lastOpenedMerges.count) 篇文档的「上次打开」两端取较晚的那个")))
        }
        if !plan.conflicts.isEmpty {
            out.append(Line(text: "冲突 \(plan.conflicts.count) 条", detail: conflictLines(plan, titles: titles)))
        }
        if out.isEmpty { out.append(Line(text: "两端一致，没有要同步的东西")) }
        return out
    }

    /// 这条改动属于哪本书。
    ///
    /// 🔴 `document` 表自己那一行**没有 `document_id` 列**，`Change.docId` 因此是 nil ——
    /// 直接拿它归组会把「改了某本书的信息」算成「工作区级设置」（2026-09-01 用户实测截图里
    /// 就是这么显示的）。那一行的主键本身就是文档 id。
    static func bookId(_ c: MirrorDiff.Change) -> String? {
        c.docId ?? (c.table == "document" ? c.rowId : nil)
    }

    /// 按书分组的明细：「《高等数学》：笔迹 +132 −8」。用户是按书来记事的，不是按表。
    static func bookBreakdown(_ list: [MirrorDiff.Change], titles: [String: String]) -> [String] {
        var byBook: [String: [String: (add: Int, del: Int, mod: Int)]] = [:]
        var loose: [String: Int] = [:]
        for c in list {
            guard let doc = bookId(c) else { loose[tableName(c.table), default: 0] += 1; continue }
            var cat = byBook[doc] ?? [:]
            var t = cat[categoryName(c)] ?? (0, 0, 0)
            switch c.reason {
            case .mirrorAdded, .sourceAdded: t.add += 1
            case .mirrorDeleted, .sourceDeleted: t.del += 1
            default: t.mod += 1
            }
            cat[categoryName(c)] = t
            byBook[doc] = cat
        }
        var out = byBook.map { doc, cats -> String in
            let name = titles[doc].map { "《\($0)》" } ?? "（已删除的文档）"
            let parts = cats.sorted { $0.key < $1.key }.map { cat, t -> String in
                var bits: [String] = []
                if t.add > 0 { bits.append("+\(t.add)") }
                if t.del > 0 { bits.append("−\(t.del)") }
                if t.mod > 0 { bits.append("改 \(t.mod)") }
                return "\(cat) \(bits.joined(separator: " "))"
            }
            return "\(name)：\(parts.joined(separator: "，"))"
        }.sorted()
        // 不属于任何一本书的（`meta` 这类）按表名说，别一律扣上「工作区级设置」的帽子
        out += loose.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value) 项" }
        return out
    }

    /// 冲突明细。**每条都要说清「保留了哪份」**——用户同意的是一个具体结果，不是一个数字。
    static func conflictLines(_ plan: MirrorDiff.Plan, titles: [String: String]) -> [String] {
        // 冲突里没有 docId（Conflict 只带表与 id），从 changes 里回查同一行拿标签
        var label: [String: MirrorDiff.Change] = [:]
        for c in plan.changes { label["\(c.table)/\(c.rowId)"] = c }
        return plan.conflicts.map { k in
            let c = label["\(k.table)/\(k.rowId)"]
            let what = c.map { categoryName($0) } ?? tableName(k.table)
            // `document` 行的书名要用它自己的主键去查（同 `bookId`）；查不到书名就别硬拼
            // ——原先在这里会拼出「的一条文档信息：…」这种断头句（2026-09-01 用户截图）。
            let docId = c.flatMap(bookId) ?? (k.table == "document" ? k.rowId : nil)
            let book = docId.flatMap { titles[$0] }.map { "《\($0)》" } ?? ""
            let page = c?.page.map { "第 \($0 + 1) 页" } ?? ""
            let where_ = book + page
            return where_.isEmpty ? "\(what)：\(k.note)" : "\(where_)的一条\(what)：\(k.note)"
        }.sorted()
    }

    /// 这条改动是不是「只差读到哪儿」。**只影响报告，不影响要不要写**（见 `summary`）。
    static func isProgressOnly(_ c: MirrorDiff.Change, _ plan: MirrorDiff.Plan) -> Bool {
        c.table == "document" && plan.progressMerges.contains(c.rowId)
    }

    /// 一行式结论（顶栏/按钮旁用）。数的口径与明细一致 —— 明细里不显示的，这里也不该计数，
    /// 否则就是「顶上写着 1 条，底下找不到是哪条」。
    static func headline(_ plan: MirrorDiff.Plan) -> String {
        if plan.isEmpty { return "两端一致" }
        let toSource = plan.changes(to: .source).filter { !isProgressOnly($0, plan) }.count
        let toMirror = plan.changes(to: .mirror).filter { !isProgressOnly($0, plan) }.count
        var bits: [String] = []
        if toSource > 0 { bits.append("写入硬盘 \(toSource)") }
        if toMirror > 0 { bits.append("拉回本机 \(toMirror)") }
        if plan.conflicts.count > 0 { bits.append("冲突 \(plan.conflicts.count)") }
        if !bits.isEmpty { return bits.joined(separator: " · ") }
        return plan.progressMerges.isEmpty ? "只更新「上次打开」" : "只更新阅读进度"
    }
}
