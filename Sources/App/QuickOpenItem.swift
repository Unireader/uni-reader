import Foundation

/// ⌘P 快速打开里的一条（`QUICK-OPEN-PLAN.md`）：当前窗口工作区里的 PDF / Markdown 笔记 / 画板 / 习题的一组
/// （用户 2026-10-31 选的范围）。回车打开 = 侧栏单击那一行（`QuickOpenController.open`）。
struct QuickOpenItem: Equatable {
    enum Target: Equatable {
        case document(String)
        case markdown(NoteRef)
        case board(UUID)
        case exercises(ExerciseScope)
    }

    var target: Target
    /// 主名字（参与匹配）：书名 / 笔记名 / 画板名 / 习题那一组的全称（「高数 · 第一章」）。
    var title: String
    /// 第二行（也参与匹配）：哪一类 + 在哪（分组 / 笔记源与目录 / 题数）。
    var detail: String
    /// SF Symbols 名，同侧栏那一行。
    var symbol: String

    /// 按输入排序（同 Agent 输入框 `@` 的分档：名字开头 > 名字含 > 第二行含 > 模糊）。空输入 = 原顺序。
    static func rank(_ items: [QuickOpenItem], query: String, limit: Int = 60) -> [QuickOpenItem] {
        AgentMentionMatch.rank(items, query: query, limit: limit, name: \.title, detail: \.detail)
    }
}

@MainActor
extension QuickOpenItem {
    /// 这个工作区里能打开的全部：PDF、笔记、画板按「上次打开」混排（没打开过的排后面），
    /// 习题各组跟在后面、按侧栏的先后（全部 / 错题本 / 收藏 / 每本书 → 章节）。
    static func all(in ws: WorkspaceManager) -> [QuickOpenItem] {
        var recent: [(Date, QuickOpenItem)] = []
        for d in ws.documents {
            let detail = d.group.isEmpty ? "PDF" : "PDF · " + d.group
            recent.append((d.lastOpenedAt, QuickOpenItem(target: .document(d.id), title: d.title, detail: detail,
                                                         symbol: "doc.richtext")))
        }
        for n in ws.allNotes {
            let src = ws.noteSource(id: n.ref.sourceID)?.name ?? ""
            let place = [src, n.ref.folder].filter { !$0.isEmpty }.joined(separator: " / ")
            let detail = place.isEmpty ? L("Markdown Note") : L("Markdown Note") + " · " + place
            recent.append((n.lastOpenedAt ?? .distantPast,
                           QuickOpenItem(target: .markdown(n.ref), title: n.title, detail: detail, symbol: "text.document")))
        }
        for b in ws.boards {
            recent.append((b.lastOpenedAt ?? .distantPast,
                           QuickOpenItem(target: .board(b.id), title: b.displayName, detail: L("Board"),
                                         symbol: "scribble.variable")))
        }
        // 稳定排序：同一时间（多为「没打开过」）保持原来的先后
        var out = recent.enumerated()
            .sorted { $0.element.0 != $1.element.0 ? $0.element.0 > $1.element.0 : $0.offset < $1.offset }
            .map(\.element.1)
        let groups = ws.exerciseGroups()
        for g in ExerciseGroupNode.flatten(groups) {
            out.append(QuickOpenItem(target: .exercises(g.scope), title: ws.exerciseScopeTitle(g.scope),
                                     detail: L("Exercises") + " · " + String(format: L("%d questions"), g.count),
                                     symbol: g.scope.symbolName))
        }
        return out
    }
}
