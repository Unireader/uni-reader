import AppKit

/// 复制习题的文字（2026-11-25，`EXERCISE-PLAN.md §34`）：只复制题目（题干 + 选项），🔴 **不带答案和解析**
/// （用户同日改口「答案不要复制出来」）。练习页右键与 ⌘C、列表右键（可多选）都走这里。
/// 写成 Markdown 原文（公式 `$…$` 原样留着），贴进笔记 / Obsidian 能直接渲染，贴进纯文本也看得懂：
///
///     题号 3 · 单选
///
///     题干…
///     A. 选项
///     B. 选项
///
/// 几道题之间用 `---` 隔开；阅读理解 / 完形填空的文章只在同一篇的第一道题前面写一次（空号 `{{21}}` 写成 `(21)`）。
@MainActor
enum ExerciseCopy {
    static func copy(_ items: [Exercise], to pb: NSPasteboard = .general) {
        guard !items.isEmpty else { return }
        pb.clearContents()
        pb.setString(text(items), forType: .string)
    }

    /// 菜单项「复制题目」/「复制 N 道题目」。
    static func menuItem(_ items: [Exercise]) -> NSMenuItem {
        let title = items.count == 1 ? L("Copy Question") : String(format: L("Copy %d Questions"), items.count)
        return ClosureMenuItem(title) { copy(items) }
    }

    static func text(_ items: [Exercise]) -> String {
        var parts: [String] = []
        var lastPassage: String?
        for e in items {
            var s = ""
            if let p = e.payload.passage, let key = e.passageKey {
                if key != lastPassage { s += passageText(p) + "\n\n" }
                lastPassage = key
            } else {
                lastPassage = nil
            }
            s += question(e)
            parts.append(s)
        }
        // `---` 前后必须是空行：紧跟在一行字下面会被当成二级标题的下划线
        return parts.joined(separator: "\n\n---\n\n") + "\n"
    }

    /// 文章：标题 + 正文（完形填空的空 `{{21}}` 写成 `(21)`）。
    private static func passageText(_ p: ExercisePassage) -> String {
        let ns = p.text as NSString
        let body = ExercisePassage.blankPattern.stringByReplacingMatches(
            in: p.text, range: NSRange(location: 0, length: ns.length), withTemplate: "($1)")
        guard let t = p.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return body }
        return t + "\n\n" + body
    }

    private static func question(_ e: Exercise) -> String {
        // 头一行同练习页顶上那行的写法：题号（完形填空写第几空）· 题型
        var head: [String] = []
        if let b = e.payload.blank { head.append(String(format: L("Blank %@"), b)) }
        else if !e.number.isEmpty { head.append(String(format: L("No. %@"), e.number)) }
        head.append(ExercisePracticeView.kindName(e.kind, passage: e.payload.passage?.kind))
        var blocks = [head.joined(separator: " · ")]

        var body: [String] = []
        let stem = e.payload.stem.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stem.isEmpty { body.append(stem) }
        if e.kind.isChoice {
            body += e.payload.options.map { "\($0.key). " + $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if !body.isEmpty { blocks.append(body.joined(separator: "\n")) }
        return blocks.joined(separator: "\n\n")
    }
}
