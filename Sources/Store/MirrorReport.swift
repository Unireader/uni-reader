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
        case "document": return "文档信息"
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
            let list = plan.changes(to: side)
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
        if !plan.lastOpenedMerges.isEmpty {
            out.append(Line(text: "另有 \(plan.lastOpenedMerges.count) 篇文档的「上次打开」两端取较晚的那个"))
        }
        if !plan.conflicts.isEmpty {
            out.append(Line(text: "冲突 \(plan.conflicts.count) 条", detail: conflictLines(plan, titles: titles)))
        }
        if out.isEmpty { out.append(Line(text: "两端一致，没有要同步的东西")) }
        return out
    }

    /// 按书分组的明细：「《高等数学》：笔迹 +132 −8」。用户是按书来记事的，不是按表。
    static func bookBreakdown(_ list: [MirrorDiff.Change], titles: [String: String]) -> [String] {
        var byBook: [String: [String: (add: Int, del: Int, mod: Int)]] = [:]
        var loose = 0
        for c in list {
            guard let doc = c.docId else { loose += 1; continue }
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
        if loose > 0 { out.append("工作区级设置 \(loose) 项") }
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
            let book = c?.docId.flatMap { titles[$0] }.map { "《\($0)》" } ?? ""
            let page = c?.page.map { "第 \($0 + 1) 页" } ?? ""
            return "\(book)\(page)的一条\(what)：\(k.note)"
        }.sorted()
    }

    /// 一行式结论（顶栏/按钮旁用）。
    static func headline(_ plan: MirrorDiff.Plan) -> String {
        if plan.isEmpty { return "两端一致" }
        let toSource = plan.changes(to: .source).count
        let toMirror = plan.changes(to: .mirror).count
        var bits: [String] = []
        if toSource > 0 { bits.append("写入硬盘 \(toSource)") }
        if toMirror > 0 { bits.append("拉回本机 \(toMirror)") }
        if plan.conflicts.count > 0 { bits.append("冲突 \(plan.conflicts.count)") }
        return bits.isEmpty ? "只更新「上次打开」" : bits.joined(separator: " · ")
    }
}
