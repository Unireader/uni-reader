// 侧栏拖拽排序的纯逻辑（`SIDEBAR-DRAG-PLAN.md`，`Sources/App/SidebarOrder.swift`）+ 笔记树按手动顺序排。运行：
//   cp spike/sidebar-order-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift Sources/App/SidebarOrder.swift \
//     Sources/App/MarkdownLink.swift Sources/App/MarkdownImport.swift Sources/App/NoteTree.swift \
//     Sources/App/NoteTypeModel.swift Sources/App/TextNoteModel.swift Sources/App/InkModel.swift \
//     Sources/App/InkLayerModel.swift Sources/App/PenPreset.swift Sources/Support/L.swift \
//     /tmp/main.swift -o /tmp/so && /tmp/so
// 覆盖：拖到某个位置后的新顺序（单个 / 多选整批 / 放到最前 / 最后 / 原地 / 越界）、组内顺序填回全局顺序
//       （书库分组、错题本底下的书）、按存下的顺序排（没存过的在最前、存的里已经没有的忽略）、笔记树只排笔记不排目录。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

print("拖到某个位置")
let s = ["a", "b", "c", "d", "e"]
check(SidebarOrder.move(s, dragged: ["d"], to: 1) == ["a", "d", "b", "c", "e"], "往上拖：放到 b 前面")
check(SidebarOrder.move(s, dragged: ["b"], to: 4) == ["a", "c", "d", "b", "e"], "往下拖：放到 e 前面（下标按拖之前算）")
check(SidebarOrder.move(s, dragged: ["c"], to: 0) == ["c", "a", "b", "d", "e"], "放到最前")
check(SidebarOrder.move(s, dragged: ["a"], to: 5) == ["b", "c", "d", "e", "a"], "放到最后")
check(SidebarOrder.move(s, dragged: ["c"], to: 2) == s && SidebarOrder.move(s, dragged: ["c"], to: 3) == s,
      "放回自己前后 = 原地不动")
check(SidebarOrder.move(s, dragged: ["e", "b"], to: 0) == ["b", "e", "a", "c", "d"], "多选整批：保持彼此原来的先后")
check(SidebarOrder.move(s, dragged: ["b", "d"], to: 3) == ["a", "c", "b", "d", "e"], "多选拖到中间（被拖的不算位置）")
check(SidebarOrder.move(s, dragged: ["a"], to: 99) == ["b", "c", "d", "e", "a"] &&
      SidebarOrder.move(s, dragged: ["e"], to: -3) == ["e", "a", "b", "c", "d"], "越界收到两头")
check(SidebarOrder.move(s, dragged: ["x"], to: 2) == s, "拖的不在这一组 → 不变")

print("组内顺序填回全局顺序")
let global = ["g1", "x1", "g2", "x2", "g3"]          // g = 某个分组的书，x = 别的分组的
check(SidebarOrder.fill(global, group: ["g3", "g1", "g2"]) == ["g3", "x1", "g1", "x2", "g2"],
      "只换这一组占着的那几个位置，别的组原地不动")
check(SidebarOrder.fill(global, group: ["g2", "zz", "g1"]) == ["g2", "x1", "g1", "x2", "g3"],
      "组里有全局没有的忽略；组里没提到的成员留在原位")
check(SidebarOrder.fill([], group: ["a"]) == [], "全局为空")

print("按存下的顺序排")
let items = ["n1", "n2", "o1", "o2", "o3"]           // n = 新加的（没存过）
check(SidebarOrder.apply(items, order: ["o3", "o1", "o2"], id: { $0 }) == ["n1", "n2", "o3", "o1", "o2"],
      "存过的按存的先后，没存过的在最前、保持传进来的先后")
check(SidebarOrder.apply(items, order: [], id: { $0 }) == items, "没存过 = 原顺序")
check(SidebarOrder.apply(["a", "b"], order: ["gone", "b", "a"], id: { $0 }) == ["b", "a"], "存的里已经没有的忽略")

print("笔记树：只排笔记，目录照旧按名字在前")
func item(_ rel: String) -> NoteItem { NoteItem(ref: NoteRef(sourceID: "ws", relPath: rel)) }
let root = NoteFolder.build([item("b.md"), item("a.md"), item("c.md"), item("数学/y.md"), item("数学/x.md")],
                            dirs: ["数学", "英语"], rootName: "笔记")
check(root.notes.map(\.ref.relPath) == ["a.md", "b.md", "c.md"], "没排过：按名字")
root.reorderNotes { SidebarOrder.apply($0, order: ["c.md", "a.md"], id: \.ref.relPath) }
check(root.notes.map(\.ref.relPath) == ["b.md", "c.md", "a.md"], "排过：没存的 b 在最前，其余按存的")
check(root.folders.map(\.name) == ["数学", "英语"], "子目录不动")
let math = root.folders[0]
math.reorderNotes { SidebarOrder.apply($0, order: ["数学/y.md", "数学/x.md"], id: \.ref.relPath) }
check(math.notes.map(\.ref.relPath) == ["数学/y.md", "数学/x.md"], "子目录里各排各的")

print("\n\(pass) 通过，\(fail) 失败")
exit(fail == 0 ? 0 : 1)
