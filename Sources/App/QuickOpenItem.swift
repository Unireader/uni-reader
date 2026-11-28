import Foundation

/// ⌘P 快速打开里的一条（`QUICK-OPEN-PLAN.md`）：当前窗口工作区里的 PDF / Markdown 笔记 / 画板 / 习题的一组，
/// 以及（2026-11-28 加的，§6）**单道题**和**目录项**。回车打开 = 侧栏单击那一行 / 跳到那道题 / 跳到那一页（`QuickOpenController.open`）。
struct QuickOpenItem: Equatable {
    enum Target: Equatable {
        case document(String)
        case markdown(NoteRef)
        case board(UUID)
        case exercises(ExerciseScope)
        /// 一道题：在它那本书（不关联 PDF 的题 = 它那个分组）的题里停到这一道。
        case exercise(id: String, scope: ExerciseScope)
        /// 目录项：打开这篇、跳到这一页的这个位置。
        case toc(documentId: String, page: Int, frac: Double, label: String)
    }

    var target: Target
    /// 主名字（参与匹配）：书名 / 笔记名 / 画板名 / 习题那一组的全称 / 题号 + 题干开头 / 目录项名字。
    var title: String
    /// 第二行（也参与匹配）：哪一类 + 在哪。
    var detail: String
    /// SF Symbols 名，同侧栏那一行。
    var symbol: String
    /// 只认「含」的长内容（题干全文、章节、别名、标签）。
    var keys: [String] = []
    /// 没输入时列不列（单道题、目录项太多，只在输入后出现）。
    var browse: Bool = true
    /// 名字认不认拼音（书 / 笔记 / 画板 / 习题组；题和目录项数量大，不算）。
    var pinyin: Bool = false
    /// 名字允许模糊命中。
    var fuzzy: Bool = true

    static func == (a: QuickOpenItem, b: QuickOpenItem) -> Bool { a.target == b.target }

    var fields: QuickOpenMatch.Fields {
        QuickOpenMatch.Fields(name: title, detail: detail, keys: keys, pinyin: pinyin, fuzzy: fuzzy)
    }

    /// 按输入排序（`QuickOpenMatch`）。`fields` 与 `items` 一一对应（弹出时算好，打字时不重算）。
    static func rank(_ items: [QuickOpenItem], fields: [QuickOpenMatch.Fields], query: String,
                     limit: Int = 60) -> [QuickOpenItem] {
        QuickOpenMatch.rank(items, fields: fields, query: query, limit: limit, browse: \.browse)
    }

    static func rank(_ items: [QuickOpenItem], query: String, limit: Int = 60) -> [QuickOpenItem] {
        rank(items, fields: items.map(\.fields), query: query, limit: limit)
    }

    /// 一道题的一行：题号（带小节）+ 题干开头。
    static func exercise(_ e: Exercise, bookTitle: String, scope: ExerciseScope) -> QuickOpenItem {
        let num = e.number.trimmingCharacters(in: .whitespaces)
        let sec = e.section.trimmingCharacters(in: .whitespaces)
        let label = [sec, num].filter { !$0.isEmpty }.joined(separator: " ")
        let stem = oneLine(e.payload.stem)
        let title = label.isEmpty ? String(stem.prefix(60)) : label + "  " + String(stem.prefix(50))
        var place = [L("Exercise"), bookTitle]
        if !e.chapterInGroup.isEmpty { place.append(e.chapterInGroup.joined(separator: " / ")) }
        if let p = e.page { place.append(String(format: L("Page %d"), p + 1)) }
        var keys = [String(stem.prefix(400)), e.chapter.joined(separator: " "), num + sec]
        keys += QuickOpenMatch.exerciseAliases(number: num, chapter: e.chapter)
        keys += e.tags
        if let t = e.payload.passage?.title { keys.append(t) }
        return QuickOpenItem(target: .exercise(id: e.id, scope: scope), title: title,
                             detail: place.filter { !$0.isEmpty }.joined(separator: " · "),
                             symbol: "questionmark.square", keys: keys, browse: false, fuzzy: false)
    }

    /// 目录树拍平成行：名字 = 目录项，第二行 = 目录 · 书名 › 上级 · 第几页。坏书签（没有页）跳过。
    static func tocItems(_ entries: [TOCEntry], documentId: String, bookTitle: String) -> [QuickOpenItem] {
        var out: [QuickOpenItem] = []
        func walk(_ list: [TOCEntry], _ path: [String]) {
            for e in list {
                let label = oneLine(e.label)
                if let p = e.pageIndex, !label.isEmpty {
                    let place = ([bookTitle] + path).joined(separator: " › ")
                    out.append(QuickOpenItem(target: .toc(documentId: documentId, page: p, frac: e.frac, label: label),
                                             title: label,
                                             detail: L("Contents") + " · " + place + " · " + String(format: L("Page %d"), p + 1),
                                             symbol: "list.bullet", browse: false))
                }
                walk(e.children, path + (label.isEmpty ? [] : [label]))
            }
        }
        walk(entries, [])
        return out
    }

    /// 压成一行（换行、连续空白 → 一个空格）。
    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}

@MainActor
extension QuickOpenItem {
    /// 这个工作区里能打开的全部：PDF、笔记、画板按「上次打开」混排（没打开过的排后面），
    /// 习题各组跟在后面、按侧栏的先后（全部 / 错题本 / 收藏 / 每本书 → 章节）；
    /// 再后面是目录项（`toc`：每篇文档当前能拿到的目录）和单道题——这两类只在输入后出现。
    static func all(in ws: WorkspaceManager, toc: [String: [TOCEntry]] = [:]) -> [QuickOpenItem] {
        var recent: [(Date, QuickOpenItem)] = []
        for d in ws.documents {
            let detail = d.group.isEmpty ? "PDF" : "PDF · " + d.group
            recent.append((d.lastOpenedAt, QuickOpenItem(target: .document(d.id), title: d.title, detail: detail,
                                                         symbol: "doc.richtext", pinyin: true)))
        }
        for n in ws.allNotes {
            let src = ws.noteSource(id: n.ref.sourceID)?.name ?? ""
            let place = [src, n.ref.folder].filter { !$0.isEmpty }.joined(separator: " / ")
            let detail = place.isEmpty ? L("Markdown Note") : L("Markdown Note") + " · " + place
            recent.append((n.lastOpenedAt ?? .distantPast,
                           QuickOpenItem(target: .markdown(n.ref), title: n.title, detail: detail, symbol: "text.document",
                                         pinyin: true)))
        }
        for b in ws.boards {
            recent.append((b.lastOpenedAt ?? .distantPast,
                           QuickOpenItem(target: .board(b.id), title: b.displayName, detail: L("Board"),
                                         symbol: "scribble.variable", pinyin: true)))
        }
        // 稳定排序：同一时间（多为「没打开过」）保持原来的先后
        var out = recent.enumerated()
            .sorted { $0.element.0 != $1.element.0 ? $0.element.0 > $1.element.0 : $0.offset < $1.offset }
            .map(\.element.1)
        let groups = ws.exerciseGroups()
        for g in ExerciseGroupNode.flatten(groups) {
            out.append(QuickOpenItem(target: .exercises(g.scope), title: ws.exerciseScopeTitle(g.scope),
                                     detail: L("Exercises") + " · " + String(format: L("%d questions"), g.count),
                                     symbol: g.scope.symbolName, pinyin: true))
        }
        // 目录项：按书库顺序
        for d in ws.documents {
            if let t = toc[d.id], !t.isEmpty { out += tocItems(t, documentId: d.id, bookTitle: d.title) }
        }
        out += exerciseItems(in: ws)
        return out
    }

    /// 单道题：每本书的题（`exercises(in: .document)` 有按库版本的缓存）+ 不关联 PDF 的题（按分组）。
    static func exerciseItems(in ws: WorkspaceManager) -> [QuickOpenItem] {
        var out: [QuickOpenItem] = []
        for d in ws.documents {
            let scope = ExerciseScope.document(d.id)
            for e in ws.exercises(in: scope) { out.append(exercise(e, bookTitle: d.title, scope: scope)) }
        }
        for e in ws.exercises(in: .document(ExerciseScope.looseId)) {
            let scope = ExerciseScope.chapter(ExerciseScope.looseId, e.group.map { [$0] } ?? [])
            out.append(exercise(e, bookTitle: e.group ?? L("Ungrouped Exercises"), scope: scope))
        }
        return out
    }
}
