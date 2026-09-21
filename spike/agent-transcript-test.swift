import AppKit

/// 离屏验证 Agent 面板对话记录的**增量重排**（`AgentChatNSView.refreshTranscript` /
/// `applyTranscriptViews`）。跑：`swift spike/agent-transcript-test.swift`
///
/// 这里是同款算法的第二份实现（视图那边改了要同步这边）。盯三件事：
///  1. **宽度约束必须等视图进了 stack 再激活**——刚建出来的视图没有父视图，当场激活
///     Auto Layout 直接抛异常、进程 abort（2026-09-21 实测：一点历史对话就崩）。
///  2. **同样的条目再刷一次要零操作**——每次都把整排拆下来装回去就是「回答长了变卡」的根因。
///  3. 条目只在末尾追加 vs. 换了一段对话（回放 / 新对话），这决定要不要把用户拽回底部。

_ = NSApplication.shared

var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: String) {
    checks += 1
    if !ok { failures += 1; print("  ✗ \(what)") }
}

/// 一条条目。`inPlace` = 内容变了能就地换文字（回复 / 思考），否则要重建视图（工具调用 / 计划…）。
struct Item {
    let id: Int
    var kind: String
    var inPlace: Bool = true
}

final class Harness {
    let stack = NSStackView()
    let spinner = NSProgressIndicator()
    private var itemViews: [Int: (kind: String, view: NSView)] = [:]
    private(set) var order: [Int] = []
    /// 每个视图激活过几次宽度约束（应当只有一次）。
    private(set) var activations: [ObjectIdentifier: Int] = [:]
    /// 新建过几个视图（流式就地更新时不该涨）。
    private(set) var made = 0

    init() {
        stack.orientation = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 300).isActive = true
    }

    /// 同 `refreshTranscript`。
    /// - Returns: (这排视图动过没有, 是不是「只在末尾追加」)
    @discardableResult
    func refresh(_ items: [Item], running: Bool = false) -> (moved: Bool, appended: Bool) {
        let ids = items.map(\.id)
        let appended = ids.count >= order.count && Array(ids.prefix(order.count)) == order
        if !appended {
            let keep = Set(ids)
            for (id, v) in itemViews where !keep.contains(id) {
                v.view.removeFromSuperview()
                itemViews.removeValue(forKey: id)
            }
        }
        var views: [NSView] = []
        var fresh: [NSView] = []
        for item in items {
            if let cur = itemViews[item.id], cur.kind == item.kind {
                views.append(cur.view)
            } else if let cur = itemViews[item.id], item.inPlace {
                itemViews[item.id] = (item.kind, cur.view)   // 就地换文字
                views.append(cur.view)
            } else {
                itemViews[item.id]?.view.removeFromSuperview()
                let v = NSView()
                made += 1
                itemViews[item.id] = (item.kind, v)
                views.append(v)
                fresh.append(v)
            }
        }
        if running { views.append(spinner) }
        let moved = apply(views)
        for v in fresh {
            // 🔴 这道检查就是上面第 1 条：顺序错了这里先报出来（真代码里是直接 abort）
            check(v.superview != nil, "新建的条目视图激活宽度约束前必须已经进了 stack")
            guard v.superview != nil else { continue }
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
            activations[ObjectIdentifier(v), default: 0] += 1
        }
        order = ids
        return (moved, appended)
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

    func view(_ id: Int) -> NSView? { itemViews[id]?.view }
    var arranged: [NSView] { stack.arrangedSubviews }
}

// MARK: - 1. 追加

print("1. 追加条目")
let h = Harness()
var items = [Item(id: 1, kind: "a"), Item(id: 2, kind: "b"), Item(id: 3, kind: "c")]
var r = h.refresh(items)
check(r.moved, "第一次填充算动过")
check(r.appended, "从空开始填算「末尾追加」")
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
check(h.arranged.count == 5, "回放 5 条")
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

print(failures == 0 ? "\n✅ \(checks) 项全过" : "\n❌ \(checks) 项里 \(failures) 项没过")
exit(failures == 0 ? 0 : 1)
