import AppKit

/// 离屏验证 Agent 面板对话记录的**增量重排**与**分段建视图**（`AgentChatNSView.refreshTranscript` /
/// `applyTranscriptViews` / `loadEarlier` / `syncScroll` 的钉住条目，`AgentTranscript.windowStart`）。
/// 跑：`swift spike/agent-transcript-test.swift`
///
/// 这里是同款算法的第二份实现（视图那边改了要同步这边）。盯这几件事：
///  1. **宽度约束必须等视图进了 stack 再激活**——刚建出来的视图没有父视图，当场激活
///     Auto Layout 直接抛异常、进程 abort（2026-09-21 实测：一点历史对话就崩）。
///  2. **同样的条目再刷一次要零操作**——每次都把整排拆下来装回去就是「回答长了变卡」的根因。
///  3. 条目只在末尾追加 vs. 换了一段对话（回放 / 新对话），这决定要不要把用户拽回底部。
///  4. **长对话只建最后一段**，往上翻再往前补（用户 2026-10-07：长对话要渲染好几秒）；补的时候插在最前面、
///     不重装已有视图；回放中一条都不建。
///  5. **没贴底时钉住视口里最上面那条**：上面补进条目、上面的正文变高，它在视口里的位置都不动。
///  6. **贴着底往下说时这排视图不许越攒越多**（2026-10-10 Agent 记笔记整窗卡住）：建了视图的那段超过 `liveBudget`
///     就从顶上摘（`trimTop`），只摘离视口顶两屏以外的、最后 `initialBudget` 那段不动；没贴底不摘；
///     摘完剩下的视图原样不动（不拆了重装）；往上翻照样补回来。

_ = NSApplication.shared

var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: String) {
    checks += 1
    if !ok { failures += 1; print("  ✗ \(what)") }
}

/// 一条条目。`inPlace` = 内容变了能就地换文字（回复 / 思考），否则要重建视图（工具调用 / 计划…）。
/// `weight` = 建视图的分量（真代码里按字数，见 `AgentTranscript.weight`）。
struct Item {
    let id: Int
    var kind: String
    var inPlace: Bool = true
    var weight: Int = 100
}

/// 同 `AgentTranscript.windowStart`。
func windowStart(_ items: [Item], before end: Int, budget: Int) -> Int {
    var start = end, sum = 0
    while start > 0, sum < budget || start == end {
        start -= 1
        sum += items[start].weight
    }
    return start
}

let initialBudget = 4000, earlierBudget = 3000, liveBudget = 8000

/// 对话记录视口（`trimTop` 要看贴没贴底、视口在哪）。
struct Viewport {
    var stuck: Bool
    var top: CGFloat
    var height: CGFloat
}

final class FlippedStack: NSStackView { override var isFlipped: Bool { true } }

final class Harness {
    let stack = FlippedStack()
    let spinner = NSProgressIndicator()
    private var itemViews: [Int: (kind: String, view: NSView)] = [:]
    private(set) var order: [Int] = []
    private(set) var shownFrom = 0
    /// 每个视图激活过几次宽度约束（应当只有一次）。
    private(set) var activations: [ObjectIdentifier: Int] = [:]
    /// 新建过几个视图（流式就地更新时不该涨）。
    private(set) var made = 0
    /// 条目视图的高度（几何测试用；没给的按 0 高，由 stack 间距撑开）。
    var heights: [Int: CGFloat] = [:]
    private var heightConstraints: [Int: NSLayoutConstraint] = [:]
    let widthAnchorTarget: NSLayoutDimension

    init(widthTarget: NSLayoutDimension? = nil) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let widthTarget {
            widthAnchorTarget = widthTarget
        } else {
            stack.widthAnchor.constraint(equalToConstant: 300).isActive = true
            widthAnchorTarget = stack.widthAnchor
        }
    }

    private func make(_ item: Item) -> NSView {
        let v = NSView()
        made += 1
        if let h = heights[item.id] {
            let c = v.heightAnchor.constraint(equalToConstant: h)
            c.isActive = true
            heightConstraints[item.id] = c
        }
        itemViews[item.id] = (item.kind, v)
        return v
    }

    private func activateWidth(_ fresh: [NSView]) {
        for v in fresh {
            // 🔴 这道检查就是上面第 1 条：顺序错了这里先报出来（真代码里是直接 abort）
            check(v.superview != nil, "新建的条目视图激活宽度约束前必须已经进了 stack")
            guard v.superview != nil else { continue }
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
            activations[ObjectIdentifier(v), default: 0] += 1
        }
    }

    /// 同 `refreshTranscript`。
    /// - Returns: (这排视图动过没有, 是不是「只在末尾追加」)
    @discardableResult
    func refresh(_ items: [Item], running: Bool = false, loading: Bool = false,
                 viewport: Viewport? = nil) -> (moved: Bool, appended: Bool, trimmed: Bool) {
        if loading {
            if !order.isEmpty || !itemViews.isEmpty { clear() }
            return (false, false, false)
        }
        let ids = items.map(\.id)
        let appended = !order.isEmpty && ids.count >= order.count && Array(ids.prefix(order.count)) == order
        if !appended {
            let keep = Set(ids)
            for (id, v) in itemViews where !keep.contains(id) {
                v.view.removeFromSuperview()
                itemViews.removeValue(forKey: id)
            }
            shownFrom = windowStart(items, before: ids.count, budget: initialBudget)
        }
        shownFrom = min(shownFrom, ids.count)
        let trimmed = appended && viewport.map { trimTop(items, $0) } == true
        var views: [NSView] = []
        var fresh: [NSView] = []
        for item in items[shownFrom...] {
            if let cur = itemViews[item.id], cur.kind == item.kind {
                views.append(cur.view)
            } else if let cur = itemViews[item.id], item.inPlace {
                itemViews[item.id] = (item.kind, cur.view)   // 就地换文字
                views.append(cur.view)
            } else {
                itemViews[item.id]?.view.removeFromSuperview()
                let v = make(item)
                views.append(v)
                fresh.append(v)
            }
        }
        if running { views.append(spinner) }
        let moved = apply(views)
        activateWidth(fresh)
        order = ids
        return (moved, appended, trimmed)
    }

    /// 同 `AgentChatNSView.trimTop`（贴没贴底、视口位置由调用方给）。
    private func trimTop(_ items: [Item], _ vp: Viewport) -> Bool {
        guard vp.stuck, shownFrom < items.count else { return false }
        let live = items[shownFrom...].reduce(0) { $0 + $1.weight }
        guard live > liveBudget else { return false }
        let keepFrom = windowStart(items, before: items.count, budget: initialBudget)
        let limit = vp.top - 2 * vp.height
        var to = shownFrom
        while to < keepFrom, let v = itemViews[items[to].id]?.view, v.superview === stack, v.frame.maxY < limit {
            to += 1
        }
        guard to > shownFrom else { return false }
        for item in items[shownFrom..<to] { itemViews.removeValue(forKey: item.id)?.view.removeFromSuperview() }
        shownFrom = to
        return true
    }

    /// 同 `clearTranscript`。
    private func clear() {
        for (_, v) in itemViews { v.view.removeFromSuperview() }
        itemViews.removeAll()
        order = []
        shownFrom = 0
    }

    /// 同 `loadEarlier`（钉住条目那部分在 `ScrollRig`）。
    /// - Returns: 补了几条。
    @discardableResult
    func loadEarlier(_ items: [Item]) -> Int {
        guard shownFrom > 0 else { return 0 }
        let from = windowStart(items, before: shownFrom, budget: earlierBudget)
        var fresh: [NSView] = []
        for (k, item) in items[from..<shownFrom].enumerated() {
            let v = itemViews[item.id]?.view ?? make(item)
            stack.insertArrangedSubview(v, at: k)
            fresh.append(v)
        }
        activateWidth(fresh)
        let n = shownFrom - from
        shownFrom = from
        return n
    }

    /// 同 `applyTranscriptViews`。
    private func apply(_ views: [NSView]) -> Bool {
        let current = stack.arrangedSubviews
        var k = 0
        while k < current.count, k < views.count, current[k] === views[k] { k += 1 }
        guard k < current.count || k < views.count else { return false }
        let keep = Set(views.map(ObjectIdentifier.init))
        for v in current[k...] {
            stack.removeArrangedSubview(v)
            if !keep.contains(ObjectIdentifier(v)) { v.removeFromSuperview() }
        }
        for v in views[k...] { stack.addArrangedSubview(v) }
        return true
    }

    func setHeight(_ id: Int, _ h: CGFloat) { heightConstraints[id]?.constant = h }
    func view(_ id: Int) -> NSView? { itemViews[id]?.view }
    var arranged: [NSView] { stack.arrangedSubviews }
}

// MARK: - 1. 追加

print("1. 追加条目")
let h = Harness()
var items = [Item(id: 1, kind: "a"), Item(id: 2, kind: "b"), Item(id: 3, kind: "c")]
var r = h.refresh(items)
check(r.moved, "第一次填充算动过")
check(!r.appended, "从空开始填算「换了一段」：要回到底部、从最后一段建起")
check(h.arranged.count == 3, "三条条目 → 三个视图，实得 \(h.arranged.count)")
check(h.arranged.allSatisfy { $0.superview === h.stack }, "每个条目视图都挂在 stack 上")
check(h.activations.values.allSatisfy { $0 == 1 }, "每个视图只激活一次宽度约束")

items.append(Item(id: 4, kind: "d"))
r = h.refresh(items)
check(r.appended, "末尾多一条算「末尾追加」")
check(h.arranged.count == 4 && h.arranged[3] === h.view(4), "新条目排在最后")
check(h.made == 4, "只新建了 4 个视图，实得 \(h.made)")

// MARK: - 2. 流式就地更新（性能修复的核心）

print("2. 流式就地更新")
let before = h.arranged
items[3].kind = "d+"          // 同一条回复又长了一段
r = h.refresh(items)
check(!r.moved, "🔴 只是最后一条内容变了 → 这排视图一动不动（不然回答长了必卡）")
check(h.arranged.map(ObjectIdentifier.init) == before.map(ObjectIdentifier.init), "视图序列原样不动")
check(h.made == 4, "没有重建视图，实得 \(h.made)")

r = h.refresh(items)
check(!r.moved, "🔴 内容也没变时更该零操作")

// MARK: - 3. 重建视图（工具调用状态变了这类）

print("3. 条目视图重建")
let oldTail = h.view(4)!
items[3] = Item(id: 4, kind: "tool:done", inPlace: false)
r = h.refresh(items)
check(h.made == 5, "不能就地更新的条目会重建视图")
check(oldTail.superview == nil, "被换掉的旧视图已从 stack 摘掉")
check(h.arranged.count == 4 && h.arranged[3] === h.view(4), "新视图落在原来的位置")

let kept = h.view(2)!
items[1] = Item(id: 2, kind: "tool:running", inPlace: false)   // 中间那条重建
r = h.refresh(items)
check(kept.superview == nil, "中间被换掉的旧视图也摘干净了")
check(h.arranged.map(ObjectIdentifier.init) == [1, 2, 3, 4].map { ObjectIdentifier(h.view($0)!) },
      "重建中间条目后整排顺序仍然对")
check(h.activations.values.allSatisfy { $0 == 1 }, "重排不会给同一个视图重复加约束")

// MARK: - 4. 转圈

print("4. 回答中的转圈")
r = h.refresh(items, running: true)
check(h.arranged.last === h.spinner, "回答中转圈排在最后")
check(h.arranged.count == 5, "转圈不顶掉条目")
r = h.refresh(items, running: true)
check(!r.moved, "转圈还在时再刷一次仍是零操作")
r = h.refresh(items, running: false)
check(h.spinner.superview == nil, "回答完转圈摘掉")
check(h.arranged.count == 4, "摘掉转圈后剩四条条目")

// MARK: - 5. 换一段对话（新对话 / 回放）

print("5. 换一段对话")
let all = (1...4).map { h.view($0)! }
r = h.refresh([])
check(!r.appended, "清空不是「末尾追加」→ 强制回到底部")
check(h.arranged.isEmpty, "清空后这排视图为空")
check(all.allSatisfy { $0.superview == nil }, "旧对话的视图全部摘干净（不留悬空子视图）")

let replay = (10...14).map { Item(id: $0, kind: "r\($0)") }
r = h.refresh(replay)
check(h.arranged.count == 5, "回放 5 条（短对话一次建完）")
check(h.arranged.map(ObjectIdentifier.init) == replay.map { ObjectIdentifier(h.view($0.id)!) }, "回放顺序正确")

r = h.refresh(Array(replay.prefix(3)))
check(!r.appended, "条目变少也不是「末尾追加」")
check(h.arranged.count == 3, "少掉的条目视图摘掉了")

// MARK: - 6. 真的排一次版（约束有没有打架）

print("6. 排版")
let holder = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
holder.addSubview(h.stack)
NSLayoutConstraint.activate([
    h.stack.topAnchor.constraint(equalTo: holder.topAnchor),
    h.stack.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
])
holder.layoutSubtreeIfNeeded()
check(h.arranged.allSatisfy { $0.frame.width > 0 }, "条目视图排出了宽度")

// MARK: - 7. 长对话分段建视图

print("7. 长对话分段")
check(windowStart([Item(id: 1, kind: "x", weight: 99_999)], before: 1, budget: 10) == 0, "一条超过预算也至少建一条")
check(windowStart([], before: 0, budget: 10) == 0, "没有条目时起点是 0")
let long = (100..<160).map { Item(id: $0, kind: "k\($0)", weight: 1000) }   // 60 条，每条 1000
let w = Harness()
w.refresh([], loading: true)
check(w.arranged.isEmpty && w.made == 0, "回放中一条视图都不建")
r = w.refresh(long)
check(!r.appended, "回放完第一次刷新 = 换了一段（回底）")
check(w.shownFrom == 56 && w.arranged.count == 4, "先只建最后一段（4000 / 1000 = 4 条），实得 \(w.arranged.count) 条、起点 \(w.shownFrom)")
check(w.made == 4, "只新建了 4 个视图，实得 \(w.made)")
let tailViews = w.arranged
let n1 = w.loadEarlier(long)
check(n1 == 3 && w.shownFrom == 53, "往前补一段（3000 / 1000 = 3 条），实得 \(n1) 条、起点 \(w.shownFrom)")
check(w.arranged.count == 7, "这排视图变成 7 条")
check(Array(w.arranged.suffix(4)).map(ObjectIdentifier.init) == tailViews.map(ObjectIdentifier.init),
      "🔴 原来那段视图原样留在后面（补的时候不重装）")
check(w.arranged.prefix(3).map(ObjectIdentifier.init) == (53..<56).map { ObjectIdentifier(w.view(long[$0].id)!) },
      "补进来的按顺序排在最前面")
check(w.activations.values.allSatisfy { $0 == 1 }, "补进来的视图也只激活一次宽度约束")
r = w.refresh(long)
check(!r.moved, "补完再刷一次是零操作（refresh 认得已经补进来的条目）")
var longer = long
longer.append(Item(id: 999, kind: "new", weight: 1000))
r = w.refresh(longer)
check(r.appended && w.shownFrom == 53, "之后新来的条目照常追加，起点不变")
while w.loadEarlier(longer) > 0 {}
check(w.shownFrom == 0 && w.arranged.count == 61, "一路往上补到开头，实得 \(w.arranged.count) 条")
w.refresh(longer, loading: true)
check(w.arranged.isEmpty, "再回放一段：旧视图全部摘掉")

// MARK: - 8. 钉住视口里的条目（真滚动视图）

print("8. 往前补 / 上面变高时眼前的内容不跳")

/// 同 `AgentChatNSView` 的滚动部分：`topVisibleItem` + `syncScroll` 的钉住分支。
final class ScrollRig {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
    let harness: Harness
    var anchor: (view: NSView, offset: CGFloat)?

    init() {
        harness = Harness(widthTarget: nil)
        scroll.documentView = harness.stack
        harness.stack.widthAnchor.constraint(equalToConstant: 300).isActive = true
    }
    var clip: NSClipView { scroll.contentView }

    func layout() { harness.stack.layoutSubtreeIfNeeded(); scroll.layoutSubtreeIfNeeded() }

    func topVisibleItem() -> (view: NSView, offset: CGFloat)? {
        let top = clip.bounds.minY
        for v in harness.arranged where v.frame.maxY > top { return (v, v.frame.minY - top) }
        return nil
    }

    func syncScroll() {
        layout()
        let maxY = max(0, harness.stack.frame.height - clip.bounds.height)
        if let a = anchor, a.view.superview === harness.stack {
            let y = min(maxY, max(0, a.view.frame.minY - a.offset))
            clip.scroll(to: NSPoint(x: 0, y: y))
        }
    }

    func scroll(to y: CGFloat) { layout(); clip.scroll(to: NSPoint(x: 0, y: y)); anchor = topVisibleItem() }

    /// 钉住的条目此刻离视口顶多远。
    var anchorOffsetNow: CGFloat? { anchor.map { $0.view.frame.minY - clip.bounds.minY } }
}

let rig = ScrollRig()
let tall = (200..<230).map { Item(id: $0, kind: "t\($0)", weight: 1000) }   // 30 条，每条 150 高
for it in tall { rig.harness.heights[it.id] = 150 }
rig.harness.refresh(tall)
rig.layout()
check(rig.harness.arranged.count == 4, "先建最后 4 条，实得 \(rig.harness.arranged.count)")
rig.scroll(to: 100)                                  // 没贴底，翻在中间
let pinned = rig.anchor
check(pinned != nil, "取到了视口里最上面那条")
let pinnedID = rig.harness.arranged.firstIndex { $0 === pinned?.view }
rig.harness.loadEarlier(tall)
rig.syncScroll()
check(abs((rig.anchorOffsetNow ?? 99) - (pinned?.offset ?? 0)) < 0.5,
      "🔴 上面补进 3 条（450 高）后，钉住的条目离视口顶仍是 \(pinned?.offset ?? -1)，实得 \(rig.anchorOffsetNow ?? -1)")
check(rig.clip.bounds.minY > 400, "滚动位置跟着往下挪了补进来的高度，实得 \(rig.clip.bounds.minY)")
check(pinnedID != nil && rig.harness.arranged.firstIndex(where: { $0 === pinned?.view }) == pinnedID! + 3,
      "钉住的还是同一条（往后移了 3 位）")

check(pinned?.view === rig.harness.view(tall[26].id), "钉住的是原来那段的第一条（tall[26]）")
rig.harness.setHeight(tall[24].id, 600)              // 它上面那条「排完版」变高 450
rig.syncScroll()
check(abs((rig.anchorOffsetNow ?? 99) - (pinned?.offset ?? 0)) < 0.5,
      "🔴 上面那条变高 450 后，钉住的条目位置仍不动，实得 \(rig.anchorOffsetNow ?? -1)")

// MARK: - 9. 贴着底往下说：顶上摘视图

print("9. 贴着底往下说时顶上摘视图")
let t = Harness()
let tHolder = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
tHolder.addSubview(t.stack)
NSLayoutConstraint.activate([
    t.stack.topAnchor.constraint(equalTo: tHolder.topAnchor),
    t.stack.leadingAnchor.constraint(equalTo: tHolder.leadingAnchor),
])
/// 工具调用那种条目：分量 200、高 30。
func tool(_ id: Int) -> Item {
    t.heights[id] = 30
    return Item(id: id, kind: "tool\(id)", inPlace: false, weight: 200)
}
/// 此刻的视口：贴底时视口顶 = 内容高 − 视口高。
func viewport(height: CGFloat = 300, stuck: Bool = true) -> Viewport {
    tHolder.layoutSubtreeIfNeeded()
    return Viewport(stuck: stuck, top: max(0, t.stack.frame.height - height), height: height)
}
func live(_ items: [Item]) -> Int { items[t.shownFrom...].reduce(0) { $0 + $1.weight } }

var conv = (0..<60).map(tool)
t.refresh(conv)
check(t.shownFrom == 40 && t.arranged.count == 20, "打开时只建最后 20 条（4000 / 200），实得 \(t.arranged.count) 条")
var trimmedAt: [Int] = []
var maxShown = 0
for k in 0..<30 {
    let vp = viewport()
    let before = t.arranged
    let madeBefore = t.made
    conv.append(tool(1000 + k))
    let r = t.refresh(conv, viewport: vp)
    if r.trimmed {
        trimmedAt.append(k)
        let survivors = before.filter { $0.superview === t.stack }
        check(survivors.count < before.count, "第 \(k + 1) 条：摘掉了顶上的视图")
        check(Array(t.arranged.prefix(survivors.count)).map(ObjectIdentifier.init) == survivors.map(ObjectIdentifier.init),
              "🔴 第 \(k + 1) 条：摘完剩下的视图原样留着、顺序不变（没有整排拆了重装）")
        check(t.made == madeBefore + 1, "第 \(k + 1) 条：只新建了新来的那一条，实得 \(t.made - madeBefore) 个")
        check(t.arranged.first === t.view(conv[t.shownFrom].id), "第 \(k + 1) 条：排在最前的就是 shownFrom 那条")
    }
    maxShown = max(maxShown, t.arranged.count)
}
check(trimmedAt.first == 20, "第 21 条来时（41 条 × 200 > 8000）才第一次摘，实得第 \(trimmedAt.first.map { $0 + 1 } ?? -1) 条")
check(trimmedAt.count >= 2, "一路往下说会反复摘，实得 \(trimmedAt.count) 次")
check(maxShown <= 41, "🔴 建了视图的条目不再越攒越多（最多 41 条），实得 \(maxShown)")
check(t.activations.values.allSatisfy { $0 == 1 }, "摘过之后每个视图仍只激活一次宽度约束")
var again = t.refresh(conv, viewport: viewport())
check(!again.moved && !again.trimmed, "摘完再刷一次是零操作")

let shownBeforeScroll = t.arranged.count
for k in 0..<15 {
    conv.append(tool(1100 + k))
    again = t.refresh(conv, viewport: viewport(stuck: false))
    check(!again.trimmed, "没贴底（往上翻着）第 \(k + 1) 条：不摘")
}
check(t.arranged.count == shownBeforeScroll + 15, "没贴底：一条都不摘，眼前的内容不动")
check(live(conv) > liveBudget, "这时建了视图的那段已经超过分量上限（等回到底再摘）")
conv.append(tool(2000))
again = t.refresh(conv, viewport: viewport())
check(again.trimmed, "回到底再来一条：摘")
check(t.shownFrom <= windowStart(conv, before: conv.count, budget: initialBudget), "最后 4000 分量那段一条不摘")

// 视口很高：两屏以外没有东西，超了分量也不摘（不然刚摘完 `loadEarlierIfNeeded` 就会补回来）
for k in 0..<25 {
    conv.append(tool(3000 + k))
    again = t.refresh(conv, viewport: viewport(height: 5000))
    check(!again.trimmed, "视口高 5000、第 \(k + 1) 条：视口顶两屏以外没有条目，不摘")
}
check(live(conv) > liveBudget, "这时同样超过分量上限，但几何上不该摘")
// 视口高 0（极端）：分量上限之外的全摘，但最后那段一条不动
conv.append(tool(4000))
again = t.refresh(conv, viewport: Viewport(stuck: true, top: viewport().top + 300, height: 0))
check(again.trimmed && t.shownFrom == windowStart(conv, before: conv.count, budget: initialBudget),
      "视口高 0：摘到最后 4000 分量那段为止，实得起点 \(t.shownFrom)")

// 往上翻：摘掉的照样补回来
let madeBeforeEarlier = t.made
let headBefore = t.arranged.first
let n2 = t.loadEarlier(conv)
check(n2 > 0 && t.made == madeBeforeEarlier + n2, "往上翻：摘掉的条目重新建视图补回来，补了 \(n2) 条")
check(t.arranged[n2] === headBefore, "补进来的排在原来最前那条前面")
check(t.arranged.prefix(n2).map(ObjectIdentifier.init) == (t.shownFrom..<t.shownFrom + n2).map { ObjectIdentifier(t.view(conv[$0].id)!) },
      "补进来的按顺序排")

print(failures == 0 ? "\n✅ \(checks) 项全过" : "\n❌ \(checks) 项里 \(failures) 项没过")
exit(failures == 0 ? 0 : 1)
