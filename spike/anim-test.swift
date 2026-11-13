// ```anim 分步演示块：解析 / 状态 / 布局测试（`ANIM-BLOCK-PLAN.md`）。运行：
//   mkdir -p build/spike && cp spike/anim-test.swift build/spike/main.swift && swiftc Sources/Anim/AnimText.swift Sources/Anim/AnimReference.swift Sources/Anim/AnimState.swift Sources/Anim/AnimStructures.swift Sources/Anim/AnimLayout.swift Sources/Anim/AnimLayout+Structures.swift build/spike/main.swift -o build/spike/anim-test && build/spike/anim-test
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
// 覆盖：词法（引号、注释、A->B）、元素与动作解析、按行报错、状态（交换跟着身份走、窗口滑动、栈 / 队列、标记）、
//       时序图时间（流水线错开、到达后才交付、丢失、计时器、arrive=next）、多场景步数、布局高度各步一致 / 物件不越界、`reference` 里的示例无错。
import CoreGraphics
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

print("词法")
check((try? AnimText.tokenize("send A->B \"DATA 2\" lost # 注释")) == ["send", "A", "->", "B", "DATA 2", "lost"], "引号、-> 不带空格、注释")
check((try? AnimText.tokenize("seq SW 0..7 window=4 at=发送方")) == ["seq", "SW", "0..7", "window=4", "at=发送方"], "key=value 是一个词")
check((try? AnimText.tokenize("array A = [3, 1, 4]")) == ["array", "A", "=", "[3,", "1,", "4]"], "等号单独成词")
check((try? AnimText.tokenize("say \"没关")) == nil, "引号没关 → 报错")
check((try? AnimText.tokenize("note B \"#3 号\"")) == ["note", "B", "#3 号"], "引号里的 # 不是注释")
check((try? AnimText.tokenize("set G[A->B] = 9")) == ["set", "G[A->B]", "=", "9"], "方括号里的 -> 不拆")

print("解析")
let gbn = """
title 回退 N 步：窗口 4，帧 2 丢失
lanes 发送方 接收方
seq SW 0..7 window=4 at=发送方
var 期望序号 = 0

step 连续发出 0~3，不等确认
  send 发送方 -> 接收方 "0"
  send 发送方 -> 接收方 "1"
  send 发送方 -> 接收方 "2" lost
  send 发送方 -> 接收方 "3"
  timer 发送方 "T0" start
step 接收方收下 0、1 并确认；3 失序，丢弃
  deliver 接收方 "0"
  deliver 接收方 "1"
  set 期望序号 = 2
  discard 接收方 "3"
  send 接收方 -> 发送方 "ACK 0"
  send 接收方 -> 发送方 "ACK 1"
step 收到 ACK 1，窗口滑到 2~5
  timer 发送方 "T0" stop
  timer 发送方 "T2" start
  slide SW to=2
  send 发送方 -> 接收方 "4"
step 帧 2 超时，回退重发
  timer 发送方 "T2" expire
  mark SW[2..5] active
  send 发送方 -> 接收方 "2"
"""
let script = AnimText.parse(gbn)
check(script.errors.isEmpty, "GBN 示例无错 \(script.errors)")
check(script.title == "回退 N 步：窗口 4，帧 2 丢失", "标题")
check(script.scenes.count == 1 && script.scenes[0].steps.count == 4, "一个场景 4 步")
check(script.stepCount == 5, "步数含第 0 步")
check(script.scenes[0].rows == [["lanes"], ["期望序号"]], "挂在竖线上的序号条不单独占一行")

let bad = AnimText.parse("""
array A = [1, 2]
lanes X
step s
  mark A[0] shiny
  frobnicate
  swap A[0] A[0..1]
""")
check(bad.errors.map(\.line) == [2, 4, 5, 6], "按行报错：\(bad.errors.map { "\($0.line):\($0.message)" })")
check(AnimText.parse("").errors.count == 1, "空块报「没有东西可显示」")

let rowScript = AnimText.parse("array A = [1]\nstack S = [x]\nvar i = 0\nrow A S")
check(rowScript.errors.isEmpty && rowScript.scenes[0].rows == [["A", "S"], ["i"]], "row 把两个元素并成一行")

print("状态")
let sorting = AnimEngine.run("""
array A = [3, 1, 2]
stack S = []
queue Q = [a]
step 交换
  swap A[0] A[1]
  mark A[1] done
  push S x
  enqueue Q b
step 出
  pop S
  dequeue Q
  set A[2] = 9
step 越界
  mark A[5] active
""")
let s1 = sorting.state(scene: 0, step: 1), s0 = sorting.state(scene: 0, step: 0)
check(s1.cells["A"]!.map(\.value) == ["1", "3", "2"], "swap 换值")
check(s1.cells["A"]![0].id == s0.cells["A"]![1].id, "swap 后格子身份跟着值走（动画能配对）")
check(s1.cells["A"]![1].tone == .done, "mark 下标")
check(s1.cells["S"]!.map(\.value) == ["x"] && s1.cells["S"]![0].tone == .new, "push，新格子 new 色")
check(sorting.state(scene: 0, step: 2).cells["S"]!.isEmpty, "pop")
check(sorting.state(scene: 0, step: 2).cells["Q"]!.map(\.value) == ["b"], "dequeue 从头出")
check(sorting.state(scene: 0, step: 2).cells["Q"]![0].tone == .normal, "new 色只留一步")
check(sorting.state(scene: 0, step: 2).cells["A"]![2].value == "9", "set 改格子")
check(sorting.errors.contains { $0.line == 14 }, "执行时越界报行号 \(sorting.errors)")

let run = AnimEngine.run(script)
check(run.errors.isEmpty, "GBN 执行无错 \(run.errors)")
let st1 = run.state(scene: 0, step: 1)
let starts = st1.messages.map(\.start)
check(starts == [0, 1, 2, 3].map { $0 * AnimEngine.gap }, "同一步的发送错开（流水线）\(starts)")
check(st1.messages[2].lost && st1.messages[2].end < st1.messages[2].start + AnimEngine.travel, "丢失的消息只到半路")
check(st1.cursor > st1.messages.map(\.end).max()!, "第 1 步结束时消息都已到达")
let st2 = run.state(scene: 0, step: 2)
check(st2.marks.first { $0.kind == .deliver }!.time >= st1.cursor, "第 2 步的交付在第 2 步时段里")
check(st2.vars["期望序号"]!.value == "2", "set var")
let ack = st2.messages.first { $0.label == "ACK 0" }!
let lastDiscard = st2.marks.first { $0.kind == .discard }!
check(ack.start > lastDiscard.time, "同一条竖线上的事按顺序排")
let st3 = run.state(scene: 0, step: 3)
check(st3.seqs["SW"]!.start == 2, "slide")
check(st3.timers.first { $0.label == "T0" }!.end != nil, "计时器 stop")
let st4 = run.state(scene: 0, step: 4)
check(st4.timers.first { $0.label == "T2" }!.expired, "计时器 expire")
check(st4.seqs["SW"]!.tones[3] == .active, "mark 序号条范围")
check(run.timelineLength[0] == st4.cursor, "时间轴总长 = 最后一步的现在")

let next = AnimEngine.run("""
lanes A B
step 一
  send A -> B "x" arrive=next
step 二
  note B "收到"
""")
let n1 = next.state(scene: 0, step: 1), n2 = next.state(scene: 0, step: 2)
check(n1.cursor < n2.messages[0].end, "arrive=next：第 1 步结束时还在路上")
check(n2.cursor >= n2.messages[0].end, "第 2 步里到达")
check(n2.marks[0].time >= n2.messages[0].end - 0.001, "到达后才有接收方的事")
check(AnimEngine.run("lanes A B\nstep x\n  send A -> C \"m\"").errors.first?.line == 3, "没有的竖线报错")
check(AnimEngine.run("lanes A B\nstep x\n  timer A \"T\" expire").errors.first?.line == 3, "没启动的计时器报错")

print("多场景")
let compare = AnimEngine.run("""
title 对比
scene 甲
  array A = [1]
  step 一
    mark A[0] done
scene 乙
  array B = [2]
  step 一
    mark B[0] wrong
  step 二
    set B[0] = 3
""")
check(compare.errors.isEmpty && compare.script.scenes.count == 2, "两个场景 \(compare.errors)")
check(compare.stepCount == 3, "步数按多的算")
check(compare.state(scene: 0, step: 2).cells["A"]![0].tone == .done, "步数少的场景停在最后一步")
check(compare.script.scenes[0].title == "甲", "场景标题")

print("布局")
for (name, r) in [("GBN", run), ("排序", sorting), ("对比", compare)] + AnimText.examples.enumerated().map({ ("示例\($0.offset + 1)", AnimEngine.run($0.element)) }) {
    for width in [320.0, 560.0, 720.0] {
        let layout = AnimLayout(run: r, width: CGFloat(width))
        var inside = true
        for k in 0..<r.stepCount {
            let f = layout.frame(step: k)
            if f.size.height != layout.height { inside = false }
            for item in f.items {
                let rect: CGRect
                switch item.shape {
                case .box(let b, _, _, _, _, _): rect = b
                case .text(_, let fr, _, _, _, _, _): rect = fr
                case .line(let pts, _, _, _, _, _): rect = pts.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
                case .cross(let c, let s, _): rect = CGRect(x: c.x - s, y: c.y - s, width: 2 * s, height: 2 * s)
                }
                if rect.minX < -0.5 || rect.maxX > CGFloat(width) + 0.5 || rect.minY < -0.5 || rect.maxY > layout.height + 0.5 {
                    inside = false
                    print("     越界 \(item.id) \(rect) 宽 \(width) 高 \(layout.height)")
                }
            }
            let ids = f.items.map(\.id)
            if Set(ids).count != ids.count { inside = false; print("     重复 id 第 \(k) 步") }
        }
        check(inside, "\(name) 宽 \(Int(width))：各步高度一致、物件不越界、id 不重复（高 \(Int(layout.height))）")
    }
}
let wide = AnimLayout(run: compare, width: 720), narrow = AnimLayout(run: compare, width: 400)
check(wide.height < narrow.height, "宽时两场景并排、窄时上下排")

print("链表 / 树 / 图 / 二维表 / 指针（A2）")
let ll = AnimEngine.run("""
list L = a -> b -> c
pointer p -> L[1]
step 插入
  insert L 1 x
step 删掉 b、反指
  remove L 2
  link L[2] -> L[0]
step 越界
  remove L 9
""")
let l1 = ll.state(scene: 0, step: 1).lists["L"]!, l2 = ll.state(scene: 0, step: 2).lists["L"]!
check(l1.nodes.map(\.value) == ["a", "x", "b", "c"] && l1.nodes[0].next == l1.nodes[1].id && l1.nodes[1].next == l1.nodes[2].id, "list insert 接好前后指向")
check(l2.nodes.map(\.value) == ["a", "x", "c"] && l2.nodes[1].next == l2.nodes[2].id, "list remove 前一个接到后一个")
check(l2.nodes[2].next == l2.nodes[0].id, "link 改指向")
check(ll.state(scene: 0, step: 1).pointers["p"]! == .node(element: "L", id: ll.state(scene: 0, step: 0).lists["L"]!.nodes[1].id), "指针跟着节点走（插入后还指着 b）")
check(ll.state(scene: 0, step: 2).pointers["p"]! == nil, "节点删了，指针变成不指")
check(ll.errors.map(\.line) == [9], "list 越界报行号 \(ll.errors)")

let bst = AnimEngine.run(AnimText.examples[5])
let t0 = bst.state(scene: 0, step: 0).trees["T"]!, t4 = bst.state(scene: 0, step: 4).trees["T"]!
check(t0.depth == 3 && t0.nodes.count == 6, "括号写法建树")
check(t0.child(t0.find("10")!, 0) == nil && t0.child(t0.find("10")!, 1) == t0.find("14"), "_ 是空的左孩子")
check(bst.state(scene: 0, step: 3).trees["T"]!.child(t0.find("6")!, 0) != nil, "insert under 6 left")
check(t4.root == t4.find("3") && t4.child(t4.find("3")!, 1) == t4.find("8") && t4.child(t4.find("8")!, 0) == t4.find("6"), "右旋：3 上来，6 挂到 8 左边")
check(t4.root.map { t4.nodes[$0]!.id } == t0.find("3"), "旋转不换节点身份（动画按 id 挪位置）")
let heap = AnimEngine.run("tree H = (1 (5 9) 3)\nstep 换\n  swap H[1] H[5]\n  remove H 9\nstep 错\n  rotate H 3 left\n  insert H 7 under 3 left")
let h1 = heap.state(scene: 0, step: 1).trees["H"]!
check(h1.nodes[h1.root!]!.value == "5" && h1.nodes[h1.root!]!.valueID == heap.state(scene: 0, step: 0).trees["H"]!.nodes[h1.find("1")!]!.valueID, "swap 交换值，值的身份跟着走")
check(h1.nodes.count == 3, "remove 删子树（9 是叶子）")
check(heap.errors.map(\.line) == [6], "没有右孩子不能左旋 \(heap.errors)")

let bfs = AnimEngine.run(AnimText.examples[6])
let g3 = bfs.state(scene: 0, step: 3).graphs["G"]!
check(g3.nodes["A"]!.tone == .done && g3.nodes["C"]!.label == "d=1", "图节点 mark / set 标签")
check(g3.edges.first { $0.a == "A" && $0.b == "B" }!.tone == .active && g3.edges.first { $0.a == "C" && $0.b == "D" }!.tone == .muted, "图的边按 A-B 找（不分方向）")
check(AnimEngine.run("graph G = A->B:3\nstep x\n  set G[A->B] = 9\n  mark G[B-A] done").state(scene: 0, step: 1).graphs["G"]!.edges[0].weight == "9", "有向边改权")
check(AnimText.parse("graph G = A-B, A-").errors.contains { $0.line == 1 && $0.message.hasPrefix("graph") }, "坏的边报错")

let dp = AnimEngine.run(AnimText.examples[7])
let d3 = dp.state(scene: 0, step: 3).grids["D"]!
check(d3.rows == 3 && d3.cols == 3 && d3.values[1][2] == "1" && d3.values[2][2] == "1" && d3.values[1][0] == "1", "二维表初值、set")
check(d3.tones[2][2] == .done && d3.tones[0][1] == .normal, "二维表范围 mark / unmark")
check(dp.state(scene: 0, step: 3).pointers["here"]! == .grid(element: "D", row: 2, col: 2), "指针指表格")
check(AnimText.parse("grid D rows=[a] = 2x2").errors.contains { $0.message.hasPrefix("rows=") }, "行标题数不对报错")
check(AnimEngine.run("array A = [1, 2]\npointer i -> A[2]\npointer j -> A[3]").errors.map(\.line) == [3], "指针可以指末尾之后一格，再远报错")

print("写法说明里的示例")
for (i, example) in AnimText.examples.enumerated() {
    let r = AnimEngine.run(example)
    check(r.errors.isEmpty, "示例 \(i + 1) 无错 \(r.errors)")
}

print("\n通过 \(pass)，失败 \(fail)")
exit(fail == 0 ? 0 : 1)
