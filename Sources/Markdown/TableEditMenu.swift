import AppKit
import MarkdownEngine

/// 表格单元格里的右键菜单：行 / 列的增删挪 + 列对齐（两处 Markdown 编辑器共用）。
///
/// 引擎 0.14.0-xvan.2 起表格默认就地编辑（点单元格直接改），但**不自带**这个菜单：它把「编辑器自己的菜单 +
/// `TableCellMenuContext`」交给 `onTableCellContextMenu`，标题与语言由 App 出（引擎模块里的资源包按宿主的
/// 本地化解析，跟不了 App 的语言）。不接这个钩子，单元格里右键只剩普通文字菜单，加行加列就没处点了。
/// 能不能点照引擎给的算（`context.isEnabled`：表头不能删 / 上移，只剩一列不能删…），这里不重述规则；
/// 对齐三项永远可点，当前那项打勾。做法与 Perch 的同名文件一致。
enum TableEditMenu {
    /// 三组（行 / 列 / 对齐）插在编辑器自己的菜单最上面，剪切 / 拷贝 / 粘贴接在下面。
    static func decorate(_ menu: NSMenu, context: TableCellMenuContext) -> NSMenu {
        let groups: [[TableEditOperation]] = [
            [.insertRowAbove, .insertRowBelow, .moveRowUp, .moveRowDown, .deleteRow],
            [.insertColumnLeft, .insertColumnRight, .moveColumnLeft, .moveColumnRight, .deleteColumn],
            [.alignLeft, .alignCenter, .alignRight],
        ]
        var items: [NSMenuItem] = []
        for group in groups {
            if !items.isEmpty { items.append(.separator()) }
            items.append(contentsOf: group.map { item($0, context: context) })
        }
        // 倒着插到最前面，最终顺序就是 items 的顺序，再接一条分隔线隔开编辑器自己的项
        menu.insertItem(.separator(), at: 0)
        for item in items.reversed() { menu.insertItem(item, at: 0) }
        return menu
    }

    private static func item(_ op: TableEditOperation, context: TableCellMenuContext) -> NSMenuItem {
        let entry = ClosureMenuItem(title(op)) { context.perform(op) }
        entry.isEnabled = context.isEnabled(op)
        entry.state = checked(op, context.alignment) ? .on : .off
        return entry
    }

    private static func title(_ op: TableEditOperation) -> String {
        switch op {
        case .insertRowAbove:    return L("Insert Row Above")
        case .insertRowBelow:    return L("Insert Row Below")
        case .moveRowUp:         return L("Move Row Up")
        case .moveRowDown:       return L("Move Row Down")
        case .deleteRow:         return L("Delete Row")
        case .insertColumnLeft:  return L("Insert Column Left")
        case .insertColumnRight: return L("Insert Column Right")
        case .moveColumnLeft:    return L("Move Column Left")
        case .moveColumnRight:   return L("Move Column Right")
        case .deleteColumn:      return L("Delete Column")
        case .alignLeft:         return L("Align Left")
        case .alignCenter:       return L("Align Center")
        case .alignRight:        return L("Align Right")
        }
    }

    private static func checked(_ op: TableEditOperation, _ alignment: TableEditAlignment) -> Bool {
        switch op {
        case .alignLeft:   return alignment == .left
        case .alignCenter: return alignment == .center
        case .alignRight:  return alignment == .right
        default:           return false
        }
    }
}
