// 表格单元格右键菜单（`TableEditMenu`）的离屏测试：三组插在编辑器原有菜单前面、能不能点照引擎的规则、
// 对齐打勾、点一项真的把操作交回引擎、中英文标题都有。运行（先按 AGENTS.md 编一次 Debug，要用它的引擎产物）：
//   P=build/dev/Build/Products/Debug; mkdir -p /tmp/tem && cp spike/table-edit-menu-test.swift /tmp/tem/main.swift \
//     && swiftc -I $P Sources/Support/L.swift Sources/Markdown/TableEditMenu.swift /tmp/tem/main.swift $P/MarkdownEngine.o \
//        -o /tmp/tem/run && /tmp/tem/run
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
// `ClosureMenuItem`（真身在 `ReaderBubbleViews.swift`，那个文件牵连太多）用同样写法的替身顶上。
import AppKit
import MarkdownEngine

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc func fire() { handler() }
}

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

func editorMenu() -> NSMenu {
    let m = NSMenu()
    m.addItem(withTitle: "Cut", action: nil, keyEquivalent: "")
    m.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
    return m
}

print("表头单元格（第 0 行、最后一列）")
var performed: [TableEditOperation] = []
let header = TableCellMenuContext(row: 0, column: 2, rowCount: 3, columnCount: 3, alignment: .center) { performed.append($0) }
let menu = TableEditMenu.decorate(editorMenu(), context: header)
let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
check(titles.count == 5 + 1 + 5 + 1 + 3 + 1 + 2, "5 行项 + 5 列项 + 3 对齐 + 3 条分隔线 + 原有 2 项（实际 \(titles.count)）")
check(titles.suffix(3) == ["—", "Cut", "Copy"], "编辑器原有的项留在最下面，中间隔一条线（实际 \(titles.suffix(3))）")
func item(_ t: String) -> NSMenuItem? { menu.items.first { $0.title == t } }
check(item("Delete Row")?.isEnabled == false && item("Move Row Up")?.isEnabled == false, "表头不能删、不能上移")
check(item("Insert Row Below")?.isEnabled == true, "表头下方能插行")
check(item("Move Column Right")?.isEnabled == false, "最后一列不能右移")
check(item("Align Center")?.state == .on && item("Align Left")?.state == .off, "当前对齐（居中）打勾，其余不打")
check(menu.items.allSatisfy { $0.isSeparatorItem || $0.title == "Cut" || $0.title == "Copy" || $0.action != nil },
      "表格项都有动作")
if let ins = item("Insert Column Left") as? ClosureMenuItem { ins.fire() }
check(performed == [.insertColumnLeft], "点「Insert Column Left」把操作交回引擎（实际 \(performed)）")

print("正文单元格")
let body = TableCellMenuContext(row: 2, column: 0, rowCount: 3, columnCount: 3, alignment: .left) { _ in }
let m2 = TableEditMenu.decorate(editorMenu(), context: body)
check(m2.items.first { $0.title == "Delete Row" }?.isEnabled == true && m2.items.first { $0.title == "Move Row Up" }?.isEnabled == true,
      "正文行能删、能上移")

print("本地化")
let src = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources")
let keys = ["Insert Row Above", "Insert Row Below", "Move Row Up", "Move Row Down", "Delete Row",
            "Insert Column Left", "Insert Column Right", "Move Column Left", "Move Column Right", "Delete Column",
            "Align Left", "Align Center", "Align Right"]
for lang in ["en", "zh-Hans"] {
    let url = src.appendingPathComponent("\(lang).lproj/Localizable.strings")
    let dict = NSDictionary(contentsOf: url) as? [String: String] ?? [:]
    let missing = keys.filter { dict[$0] == nil }
    check(missing.isEmpty, "\(lang) 13 条标题齐全（缺 \(missing)）")
}

print("\n\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
