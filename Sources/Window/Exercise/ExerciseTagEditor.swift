import AppKit

/// 改题目标签的那张表（练习页「标签」按钮 / 列表右键）：一个标记输入框（`NSTokenField`），敲完逗号或回车变成一枚标签，
/// 候选来自这一组题里已有的标签。标签是自由文字（真题、模拟、2023 …），规整规则在 `ExerciseTag.clean`。
@MainActor
enum ExerciseTagEditor {
    enum Kind { case edit, add, remove }

    /// `current` = 输入框里一开始有的（编辑 = 这道题现有的标签；添加 / 移除 = 空）。`apply` 收到规整过的标签。
    static func present(on win: NSWindow, kind: Kind, count: Int, current: [String], suggestions: [String],
                        apply: @escaping ([String]) -> Void) {
        let a = NSAlert()
        switch kind {
        case .edit: a.messageText = L("Edit Tags")
        case .add: a.messageText = count == 1 ? L("Add Tags") : String(format: L("Add Tags to %d Questions"), count)
        case .remove: a.messageText = count == 1 ? L("Remove Tags") : String(format: L("Remove Tags from %d Questions"), count)
        }
        a.informativeText = L("Type a tag and press Return or a comma. A tag can be anything, such as Past Paper or 2023.")
        let field = NSTokenField(frame: NSRect(x: 0, y: 0, width: 340, height: 48))
        let helper = Helper(suggestions)
        field.delegate = helper
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",，;；\n")
        field.objectValue = current
        field.placeholderString = L("Tags")
        a.accessoryView = field
        a.addButton(withTitle: kind == .remove ? L("Remove") : L("Save"))
        a.addButton(withTitle: L("Cancel"))
        a.window.initialFirstResponder = field
        a.beginSheetModal(for: win) { resp in
            _ = helper   // 代理不会被框持有，表收起前要活着
            guard resp == .alertFirstButtonReturn else { return }
            let raw = (field.objectValue as? [String]) ?? []
            apply(ExerciseTag.clean(raw))
        }
    }

    private final class Helper: NSObject, NSTokenFieldDelegate {
        let suggestions: [String]
        init(_ s: [String]) { suggestions = s }
        func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String,
                        indexOfToken tokenIndex: Int, indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            let q = substring.lowercased()
            return suggestions.filter { q.isEmpty || $0.lowercased().hasPrefix(q) }
        }
    }
}
