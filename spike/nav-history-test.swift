// 工具栏「返回」/ ⌘[ ⌘] 的窗口历史（`Sources/App/NavHistory.swift`，2026-11-13）：编的是真代码。
// 运行：
//   O=/tmp/nav-history; mkdir -p $O && cp spike/nav-history-test.swift $O/main.swift \
//   && swiftc Sources/App/NavHistory.swift $O/main.swift -o $O/t && $O/t
//
// 盯这几件事：后退 / 前进的顺序；新的一次走动让前进作废；连着记同一处只留一条；
// 后退时眼下这处能前进回来；空标签（没有眼下这处）不进前进栈；上限；去不了的地方拿掉。
import Foundation

var failures = 0, checks = 0
func check(_ ok: Bool, _ what: String) {
    checks += 1
    if !ok { failures += 1; print("  ✗ \(what)") }
}

typealias H = NavHistory<String>
let same: (String, String) -> Bool = { $0 == $1 }

// 笔记 A → 点链接到书 p50（切标签）→ 目录跳到 p80（书里跳转）
var h = H()
h.record(leaving: "noteA", same: same)
h.record(leaving: "book@50", same: same)
check(h.canGoBack && !h.canGoForward, "走过两处：能后退、不能前进")
check(h.back(from: "book@80") == "book@50", "后退一步：回到书里跳转前的 p50")
check(h.canGoForward, "后退之后能前进")
check(h.back(from: "book@50") == "noteA", "再后退：回到笔记")
check(!h.canGoBack, "退到头了")
check(h.forward(from: "noteA") == "book@50", "前进：回到 p50")
check(h.forward(from: "book@50") == "book@80", "再前进：回到 p80")
check(!h.canGoForward, "前进到头了")

// 后退后又走了新的一步：前进作废
h = H()
h.record(leaving: "a", same: same)
h.record(leaving: "b", same: same)
_ = h.back(from: "c")
check(h.canGoForward, "后退后可前进（测试前提）")
h.record(leaving: "b", same: same)
check(!h.canGoForward, "新的一次走动让前进作废")

// 连着记同一处只留一条（点链接：切标签记一次，紧跟的跳页若又记同一处也不重复）
h = H()
h.record(leaving: "a", same: same)
h.record(leaving: "a", same: same)
check(h.backStack == ["a"], "连着记同一处只留一条：\(h.backStack)")

// 空标签：眼下没有这一处，不进前进栈
h = H()
h.record(leaving: "a", same: same)
check(h.back(from: nil) == "a" && !h.canGoForward, "从空标签后退：不留前进")

// 上限
h = H()
for i in 0..<(H.limit + 20) { h.record(leaving: "p\(i)", same: same) }
check(h.backStack.count == H.limit && h.backStack.first == "p20", "超过上限丢最旧的：\(h.backStack.count) 条，最早 \(h.backStack.first ?? "-")")

// 去不了的地方拿掉（文档删了）
h = H()
for p in ["a", "gone", "b"] { h.record(leaving: p, same: same) }
_ = h.back(from: "c")
h.remove { $0 == "gone" || $0 == "c" }
check(h.backStack == ["a"] && h.forwardStack.isEmpty, "删掉的文档两个栈里都拿掉：\(h.backStack) / \(h.forwardStack)")

print(failures == 0 ? "✅ \(checks) 项全过" : "❌ \(checks) 项里 \(failures) 项没过")
exit(failures == 0 ? 0 : 1)
