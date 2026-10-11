import AppKit

/// 「设置章节…」那张表（`EXERCISE-PLAN.md §2.3`）：标准 `NSAlert` + 一个下拉框（这本书的目录，按层缩进）+ 一个手填框。
/// 下拉框第一项是「按页码自动」（每道题各按自己的页从目录里定），第二项「不设章节」，最后一项「手动填写」。
@MainActor
enum ExerciseChapterPicker {
    enum Choice {
        /// 每道题按自己的页码从目录里定。
        case auto
        /// 统一设成这一节（空 = 不设章节）。
        case path([String])
    }

    private static let tagAuto = -1, tagNone = -2, tagCustom = -3

    static func present(on window: NSWindow, toc: [ExerciseChapterNode], current: [String]?,
                        done: @escaping (Choice) -> Void) {
        let paths = ExerciseChapter.flatten(toc)
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 30, width: 360, height: 26), pullsDown: false)
        popup.addItem(withTitle: toc.isEmpty ? L("Automatic (this PDF has no table of contents)") : L("Automatic, by page"))
        popup.lastItem?.tag = tagAuto
        popup.lastItem?.isEnabled = !toc.isEmpty
        popup.addItem(withTitle: L("No Chapter"))
        popup.lastItem?.tag = tagNone
        // 🔴 分隔线的 tag 默认是 0，会和目录第一项（tag 0）撞上，`selectItem(withTag: 0)` 选中分隔线
        func separator() { let s = NSMenuItem.separator(); s.tag = Int.min; popup.menu?.addItem(s) }
        separator()
        for (i, p) in paths.enumerated() {
            popup.addItem(withTitle: p.last ?? "")
            popup.lastItem?.tag = i
            popup.lastItem?.indentationLevel = max(0, p.count - 1)
            popup.lastItem?.toolTip = ExerciseChapter.display(p)
        }
        if !paths.isEmpty { separator() }
        popup.addItem(withTitle: L("Type a Name…"))
        popup.lastItem?.tag = tagCustom
        popup.autoenablesItems = false

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 22))
        field.placeholderString = L("e.g. Chapter 2 › 2.3")
        // 先选上它现在的章节（单选一道题时）；目录里没有的就放进手填框
        if let current, !current.isEmpty {
            if let i = paths.firstIndex(of: current) { popup.selectItem(withTag: i) }
            else { popup.selectItem(withTag: tagCustom); field.stringValue = ExerciseChapter.display(current) }
        } else {
            popup.selectItem(withTag: toc.isEmpty ? tagNone : tagAuto)
        }
        let sync = PopupSync { field.isEnabled = popup.selectedTag() == tagCustom }
        popup.target = sync
        popup.action = #selector(PopupSync.changed)
        sync.changed()

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 56))
        box.addSubview(popup)
        box.addSubview(field)

        let a = NSAlert()
        a.messageText = L("Set Chapter")
        a.informativeText = L("Practice by chapter from the sidebar. “Automatic” looks up each question’s page in the PDF’s table of contents.")
        a.accessoryView = box
        a.addButton(withTitle: L("OK"))
        a.addButton(withTitle: L("Cancel"))
        a.beginSheetModal(for: window) { resp in
            _ = sync   // 表开着期间留住下拉框的 target
            guard resp == .alertFirstButtonReturn else { return }
            switch popup.selectedTag() {
            case tagAuto: done(.auto)
            case tagNone: done(.path([]))
            case tagCustom:
                let parts = field.stringValue.components(separatedBy: CharacterSet(charactersIn: "›>"))
                done(.path(ExerciseChapter.clean(parts)))
            case let i where paths.indices.contains(i): done(.path(paths[i]))
            default: break
            }
        }
    }

    /// 下拉框换了选项 → 手填框跟着亮 / 灰（`NSPopUpButton` 的 target 得是个对象）。
    private final class PopupSync: NSObject {
        let onChange: () -> Void
        init(_ f: @escaping () -> Void) { onChange = f }
        @objc func changed() { onChange() }
    }
}
