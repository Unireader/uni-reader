// JumpHistory 纯值类型测试：记录/折叠/前进分支作废/后退前进/上限裁剪。运行：
//   cp spike/jump-history-test.swift /tmp/main.swift && swiftc Sources/App/JumpHistory.swift /tmp/main.swift -o /tmp/jht && /tmp/jht
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
// 覆盖：首次跳转垫离开点、跳后又滚动再跳会补记离开点、落在同一处就地更新（保留 id）、
//       同一搜索词（含边打字边搜的前缀词）连续命中只占一条（真换词才新增）、后退到中途再跳则前进分支作废、
//       back/forward 边界、go(to:)、超上限从最旧删且游标跟着挪、reset。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

func mark(_ page: Int, _ frac: Double = 0, _ kind: JumpKind = .toc, _ label: String = "") -> JumpMark {
    JumpMark(page: page, frac: frac, kind: kind, label: label)
}

// ---- 首次跳转：离开点被垫进来 ----
print("首次跳转")
var h = JumpHistory()
check(h.isEmpty && !h.canGoBack && !h.canGoForward, "空历史：不能前进也不能后退")
h.record(leaving: mark(3, 0.4, .reading), to: mark(20, 0, .toc, "第二章"))
check(h.marks.count == 2, "空历史里跳一次 → 离开点 + 目标共两条")
check(h.cursor == 1 && h.current?.page == 20, "游标停在目标上")
check(h.marks[0].page == 3 && h.marks[0].kind == .reading, "第一条是离开点")
check(h.canGoBack && !h.canGoForward, "能退不能进")

// ---- 跳完又自己滚了一段，再跳：补记那个离开点 ----
print("跳转后滚动过再跳")
h.record(leaving: mark(26, 0.5, .reading), to: mark(40, 0, .toc, "第三章"))
check(h.marks.count == 4, "离开点与当前条不同处 → 先垫离开点再压目标")
check(h.marks[2].page == 26 && h.marks[2].kind == .reading, "补记的那条是阅读位置")
check(h.cursor == 3 && h.current?.page == 40, "游标在最新目标上")

// ---- 落到同一处：就地更新，不新增，且 id 不变 ----
print("落到同一处")
let idBefore = h.current!.id
h.record(leaving: mark(40, 0.001, .reading), to: mark(40, 0.005, .toc, "第三章 一"))
check(h.marks.count == 4, "同一处（±1% 页高）→ 不新增")
check(h.current?.id == idBefore, "就地更新保留原 id（列表那一行不跳位）")
check(h.current?.label == "第三章 一", "标签换成新的那条")

// ---- 搜索连续命中：同词只占一条，换词才新增 ----
print("搜索命中折叠")
var s = JumpHistory()
s.record(leaving: mark(1, 0, .reading), to: mark(10, 0.2, .search, "傅里叶"))
s.record(leaving: mark(10, 0.2, .reading), to: mark(33, 0.6, .search, "傅里叶"))
s.record(leaving: mark(33, 0.6, .reading), to: mark(57, 0.1, .search, "傅里叶"))
check(s.marks.count == 2, "同一个词连按「下一个」三次 → 仍只有离开点 + 一条搜索")
check(s.current?.page == 57, "那条搜索记的是最新命中页")
s.record(leaving: mark(57, 0.1, .reading), to: mark(70, 0, .search, "卷积"))
check(s.marks.count == 3 && s.current?.label == "卷积", "换个词 → 新增一条")
// 边打字边搜：防抖每跑一批就跳一次首命中，半截词不该各留一条
var t = JumpHistory()
t.record(leaving: mark(0, 0, .reading), to: mark(5, 0, .search, "傅"))
t.record(leaving: mark(5, 0, .reading), to: mark(9, 0, .search, "傅里"))
t.record(leaving: mark(9, 0, .reading), to: mark(12, 0, .search, "傅里叶"))
check(t.marks.count == 2 && t.current?.label == "傅里叶", "打字过程（前缀关系）→ 仍只占一条")
t.record(leaving: mark(12, 0, .reading), to: mark(30, 0, .search, "卷"))
check(t.marks.count == 3, "「卷」与「傅里叶」无前缀关系 → 新增")

// ---- 后退 / 前进 ----
print("后退与前进")
var n = JumpHistory()
n.record(leaving: mark(0, 0, .reading), to: mark(10))
n.record(leaving: mark(10, 0, .reading), to: mark(20))
n.record(leaving: mark(20, 0, .reading), to: mark(30))
check(n.marks.count == 4 && n.cursor == 3, "轨迹：离开点 + 三次跳转")
check(n.back()?.page == 20, "后退一步 → 20")
check(n.back()?.page == 10, "再退 → 10")
check(n.back()?.page == 0, "再退 → 起点")
check(n.back() == nil && !n.canGoBack, "到头了：再退是 nil")
check(n.forward()?.page == 10, "前进 → 10")
check(n.cursor == 1 && n.canGoForward, "游标与可前进态同步")

// ---- 后退到中途再跳：前进分支作废 ----
print("前进分支作废")
n.record(leaving: mark(10, 0, .reading), to: mark(99, 0, .toc, "附录"))
check(n.marks.count == 3, "游标后面那截被截断，再压新目标")
check(n.marks.map(\.page) == [0, 10, 99], "轨迹 = 起点 → 10 → 99")
check(!n.canGoForward, "新目标就是末端")

// ---- 点列表里的某一条 ----
print("直接跳到某一条")
let target = n.marks[1]
check(n.go(to: target.id)?.page == 10, "go(to:) 回到那一条")
check(n.cursor == 1, "游标落到那一条上")
check(n.go(to: UUID()) == nil, "不存在的 id → nil，游标不动")
check(n.cursor == 1, "游标确实没动")

// ---- 上限裁剪 ----
print("超上限裁剪")
var big = JumpHistory()
for i in 0..<(JumpHistory.limit + 20) {
    big.record(leaving: mark(i * 2, 0, .reading), to: mark(i * 2 + 1))
}
check(big.marks.count == JumpHistory.limit, "条数封顶在 limit")
check(big.cursor == JumpHistory.limit - 1, "游标仍在最新那条")
check(big.current?.page == (JumpHistory.limit + 19) * 2 + 1, "最新那条没被裁掉")

// ---- reset ----
print("清空")
big.reset()
check(big.isEmpty && big.cursor == -1 && !big.canGoBack && !big.canGoForward, "reset 后回到空态")

print("\n通过 \(pass) 项，失败 \(fail) 项")
exit(fail == 0 ? 0 : 1)
