// ```anim 分步演示块：解析 / 状态 / 布局测试（`ANIM-BLOCK-PLAN.md`）。运行：
//   mkdir -p build/spike && cp spike/anim-test.swift build/spike/main.swift && swiftc Sources/Anim/AnimText.swift Sources/Anim/AnimKits.swift Sources/Anim/AnimKits2.swift Sources/Anim/AnimKits3.swift Sources/Anim/AnimKits4.swift Sources/Anim/AnimKits5.swift Sources/Anim/AnimReference.swift Sources/Anim/AnimState.swift Sources/Anim/AnimStructures.swift Sources/Anim/AnimLayout.swift Sources/Anim/AnimLayout+Structures.swift build/spike/main.swift -o build/spike/anim-test && build/spike/anim-test
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
for (name, r) in [("GBN", run), ("排序", sorting), ("对比", compare)] + AnimText.examples.enumerated().map({ ("示例\($0.offset + 1)", AnimEngine.run($0.element)) })
    + ["kit gbn frames=8 window=4 lose=2 loseack=5", "kit sr frames=8 window=4 lose=2,6", "kit quick A=[5, 1, 4, 2, 8, 3]", "kit crc data=1101011011 gen=10011",
       "kit dijkstra G=\"A-B:4, A-C:2, C-B:1, B-D:5, C-D:8\"", "kit levelorder T=(1 (2 4 5) (3 6 7))",
       "kit page alg=lru refs=7,0,1,2,0,3,0,4,2,3,0,3,2,1,2,0,1,7,0,1 frames=3", "kit page alg=clock refs=1,2,3,4,1,2,5,1,2,3,4,5 frames=4",
       "kit disk alg=cscan start=100 requests=55,58,39,18,90,160,150,38,184", "kit cache map=set lines=8 ways=2 blocks=0,4,8,0,12,4,16,0,8",
       "kit base n=1000 to=16", "kit kmp P=abaabcac", "kit hash keys=19,14,23,1,68,20,84,27,55,11,10,79 size=13",
       "kit heap A=[53, 17, 78, 9, 45, 65, 87, 32] sort=yes", "kit bsearch A=[7, 10, 13, 16, 19, 29, 32, 33, 37, 41, 43] key=11",
       "kit tcp ssthresh=16 rounds=20 timeout=12 dup=17",
       "kit mul method=booth x=-0.11010101 y=0.10110011", "kit mul x=0.1101 y=-0.1011", "kit div method=restore x=0.101101 y=0.110111",
       "kit div method=nonrestore x=0.1011011 y=-0.1101111", "kit div method=comp x=-0.0101 y=0.1101",
       "kit header proto=ipv4", "kit header proto=tcp", "kit header proto=udp", "kit header proto=ipv6",
       "kit header proto=ipv4 hex=\"46 00 00 20 00 01 20 00 3f 11 00 00 0a 00 00 01 0a 00 00 02 01 01 00 00\"",
       "kit header proto=tcp hex=\"04 89 00 50 0d d6 01 f4 00 00 00 00 70 12 40 00 c0 29 00 00 02 04 05 b4 01 01 04 02\"",
       "kit header proto=ipv6 hex=\"60 00 00 00 00 20 06 40 20 01 0d b8 00 00 00 00 00 00 00 00 00 00 00 01 fe 80 00 00 00 00 00 00 02 1a 2b ff fe 3c 4d 5e\"",
       "kit encap data=1 transport=udp", "kit encap data=2000 net=ipv6", "kit frag total=4000 mtu=576", "kit frag data=3980 mtu=1500 df=1",
       "tree R dir=right = (A (B D E) (C _ F))\npointer p -> R[B]\nstep x\n  insert R G under C left\n  move p -> R[G]",
       "tree U dir=up = (1 (2 4 5) (3 6 7))\ntree L dir=left = (1 2 3 4)\nstep x\n  remove U 3",
       "graph SDN layout=layers dir=down layers=[[控制器], [交换机S1, 交换机S2, 交换机S3], [H1, H2, H3, H4]] = 控制器-交换机S1, 控制器-交换机S2, 控制器-交换机S3, 交换机S1-交换机S3, 交换机S1-H1, 交换机S2-H2, 交换机S3-H3, 交换机S3-H4\npointer p -> SDN[H1]\nstep x\n  mark SDN[交换机S1-交换机S3] done",
       "graph G layout=layers dir=up = A-B, A-C, B-D, C-D:5\ngraph K layout=layers dir=left = A->B, B->C",
       "kit ipclass", "kit ipaddr ip=172.16.37.200/20", "kit ipaddr ip=10.1.2.3", "kit ipaddr ip=224.0.0.5", "kit ipaddr ip=192.168.1.1 mask=255.255.255.252",
       "kit supernet nets=172.18.129.0/24,172.18.130.0/24,172.18.132.0/24,172.18.133.0/24", "kit subnet net=192.168.1.0/24 hosts=50",
       "kit subnet net=10.0.0.0/8 n=16", "kit lpm dst=192.168.1.37 routes=\"192.168.1.0/24 R1, 192.168.1.32/27 R2, 192.168.1.64/26 R4, 0.0.0.0/0 R3\"",
      ].map({ ($0, AnimEngine.run($0)) }) {
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

print("套件（A3）")
func sends(_ r: AnimRun, _ label: String, from lane: String = "发送方") -> Int {
    r.state(scene: 0, step: r.stepCount - 1).messages.filter { $0.from == lane && $0.label == label }.count
}
func finalCells(_ r: AnimRun, _ name: String) -> [String] { r.state(scene: 0, step: r.stepCount - 1).cells[name]!.map(\.value) }

let gbnKit = AnimEngine.run("kit gbn frames=6 window=4 lose=2 lang=zh")
check(gbnKit.errors.isEmpty, "gbn 套件无错 \(gbnKit.errors)")
check(gbnKit.script.title == "回退 N 步（窗口 4）", "套件给标题")
check(sends(gbnKit, "2") == 2 && sends(gbnKit, "3") == 2 && sends(gbnKit, "5") == 2 && sends(gbnKit, "0") == 1, "回退 N 步：丢 2 → 2~5 全部重发")
check(gbnKit.state(scene: 0, step: gbnKit.stepCount - 1).seqs["SW"]!.tones.filter { $0.value == .done }.count == 6, "最后 6 帧都确认")
check(gbnKit.state(scene: 0, step: gbnKit.stepCount - 1).vars["期望"]!.value == "6", "接收方期望序号走到 6")

let srKit = AnimEngine.run("kit sr frames=6 window=4 lose=2 lang=zh")
check(srKit.errors.isEmpty, "sr 套件无错 \(srKit.errors)")
check(sends(srKit, "2") == 2 && sends(srKit, "3") == 1 && sends(srKit, "5") == 1, "选择重传：只重发 2")
check(srKit.state(scene: 0, step: srKit.stepCount - 1).marks.contains { $0.kind == .buffer && $0.label == "3" }, "选择重传：失序的 3 先缓存")

let swKit = AnimEngine.run("kit stopwait frames=3 lose=1 loseack=2 lang=zh")
check(swKit.errors.isEmpty, "停等套件无错 \(swKit.errors)")
check(sends(swKit, "1") == 2 && sends(swKit, "2") == 2 && sends(swKit, "0") == 1, "停等：丢帧 1、丢 ACK 2 都靠超时重发")
check(swKit.state(scene: 0, step: swKit.stepCount - 1).marks.filter { $0.kind == .discard && $0.label == "2" }.count == 1, "停等：重发的 2 是重复帧，丢弃再确认")

let ackKit = AnimEngine.run("kit gbn frames=4 window=4 loseack=1 lang=zh")
check(ackKit.errors.isEmpty && (0..<4).allSatisfy { sends(ackKit, "\($0)") == 1 }, "回退 N 步：丢了 ACK 1 也不用重发（累积确认）")
check(AnimEngine.run("kit gbn frames=6 window=4 lose=2,3 loseack=4 timeout=3 mod=8").errors.isEmpty, "多处丢失、改超时、mod 也能推演完")
check(AnimEngine.run("kit sr window=5 mod=8").errors.first?.message.contains("mod / 2") == true, "选择重传窗口超过 mod/2 报错")

for kind in ["bubble", "selection", "insertion", "quick"] {
    let r = AnimEngine.run("kit \(kind) A=[5, 1, 4, 2, 3] lang=zh")
    check(r.errors.isEmpty && finalCells(r, "A") == ["1", "2", "3", "4", "5"], "\(kind) 排完有序 \(r.errors)")
    let d = AnimEngine.run("kit \(kind) A=[3, 1, 3, 2, 10] lang=en")
    check(d.errors.isEmpty && finalCells(d, "A") == ["1", "2", "3", "3", "10"], "\(kind)：重复值、按数字比（10 排最后）")
}
let crcKit = AnimEngine.run("kit crc data=101001 gen=1101 lang=zh")
let crcSheet = crcKit.state(scene: 0, step: crcKit.stepCount - 1).sheets["竖式"]!
func sheetRow(_ s: AnimSheetState, _ r: Int) -> String { (s.cells[r] ?? [:]).sorted { $0.key < $1.key }.map(\.value.char).joined() }
check(crcKit.errors.isEmpty, "CRC 竖式无错 \(crcKit.errors)")
check(sheetRow(crcSheet, 0) == "110101", "商 110101（同教材）")
check((2...13).map { sheetRow(crcSheet, $0) } == ["1101", "1110", "1101", "0111", "0000", "1110", "1101", "0110", "0000", "1100", "1101", "001"],
      "竖式每一行同教材图 3.8 \((2...13).map { sheetRow(crcSheet, $0) })")
check(AnimKits.polynomial("1101") == "x³ + x² + 1" && AnimKits.polynomial("10011") == "x⁴ + x + 1", "生成多项式写法")
let crcStep3 = crcKit.state(scene: 0, step: 3)
check(crcKit.state(scene: 0, step: 1).caption.contains("r = 3") && crcStep3.caption.contains("首位是 1") && crcStep3.says.first?.contains("1⊕1=0  0⊕1=1  1⊕0=1  0⊕1=1") == true,
      "讲 r 的来历、商为什么是 1、逐位异或 \(crcStep3.caption) \(crcStep3.says)")
check(crcKit.state(scene: 0, step: 5).caption.contains("首位是 0"), "商 0 的理由 \(crcKit.state(scene: 0, step: 5).caption)")
check(crcSheet.labels[13]?.contains("余数") == true && crcSheet.arrows.count == 5 && crcSheet.rules.count == 7, "余数注释、5 个落下箭头、7 条横线（含除号上的）")
check(crcKit.state(scene: 0, step: 0).sheets["竖式"]!.cells[1]!.count == 14, "第 0 步就有除数、)、被除数（4 + 1 + 9 个字）")
let sheetErr = AnimEngine.run("sheet S\nwrite S[0,0] \"12\"\narray A = [1]\nstep x\n  write A[0,0] \"1\"\n  arrow S[1,2]")
check(sheetErr.errors.map(\.line) == [5, 6], "竖式：写到非竖式、箭头只有一行都报错 \(sheetErr.errors)")

let tree = "(8 (3 1 6) (10 _ 14))"
for (kind, want) in [("preorder", "8 3 1 6 10 14"), ("inorder", "1 3 6 8 10 14"), ("postorder", "1 6 3 14 10 8"), ("levelorder", "8 3 10 1 6 14")] {
    let r = AnimEngine.run("kit \(kind) T=\(tree) lang=zh")
    check(r.errors.isEmpty && finalCells(r, "序列").joined(separator: " ") == want, "\(kind)：\(want)")
}
let graph = "\"A-B, A-C, B-D, C-D, D-E\""
let bfsKit = AnimEngine.run("kit bfs G=\(graph) lang=zh"), dfsKit = AnimEngine.run("kit dfs G=\(graph) from=A lang=zh")
check(bfsKit.errors.isEmpty && finalCells(bfsKit, "访问序列") == ["A", "B", "C", "D", "E"], "BFS 顺序 \(bfsKit.errors)")
check(dfsKit.errors.isEmpty && finalCells(dfsKit, "访问序列") == ["A", "B", "D", "C", "E"] && finalCells(dfsKit, "S").isEmpty, "DFS 顺序，最后栈空 \(dfsKit.errors)")
let dj = AnimEngine.run("kit dijkstra G=\"A-B:4, A-C:2, C-B:1, B-D:5, C-D:8, E\" from=A lang=zh")
let dg = dj.state(scene: 0, step: dj.stepCount - 1).graphs["G"]!
check(dj.errors.isEmpty && ["A", "B", "C", "D", "E"].map { dg.nodes[$0]!.label } == ["0", "3", "2", "8", "∞"], "Dijkstra 距离 0 3 2 8 ∞ \(dj.errors)")
check(dg.edges.filter { $0.tone == .done }.count == 3, "最短路径树 3 条边标出来")
check(AnimEngine.run("kit dijkstra G=\"A-B\"").errors.first?.message.contains("weight") == true, "Dijkstra 没权报错")

let kitErr = AnimText.parse("array A = [1]\nkit frobnicate x=1\nkit bubble A=[2, 1] colour=red")
check(kitErr.errors.map(\.line) == [2, 3], "套件错误报在 kit 那一行 \(kitErr.errors)")
let kitScenes = AnimEngine.run("title 对比\nscene 甲\n  kit gbn frames=4 lose=1\nscene 乙\n  kit sr frames=4 lose=1")
check(kitScenes.errors.isEmpty && kitScenes.script.scenes.count == 2 && kitScenes.script.title == "对比", "kit 放在 scene 里对比 \(kitScenes.errors)")

print("套件第二批（408）")
func lastState(_ r: AnimRun) -> AnimSceneState { r.state(scene: 0, step: r.stepCount - 1) }
let refs = "7,0,1,2,0,3,0,4,2,3,0,3,2,1,2,0,1,7,0,1"
for (alg, want) in [("fifo", 15), ("lru", 12), ("opt", 9)] {
    let r = AnimEngine.run("kit page alg=\(alg) refs=\(refs) frames=3 lang=zh")
    check(r.errors.isEmpty && lastState(r).vars["缺页次数"]?.value == "\(want)", "页面置换 \(alg)：缺页 \(want) 次（教材例题）\(r.errors) \(lastState(r).vars["缺页次数"]?.value ?? "-")")
}
let clockRun = AnimEngine.run("kit page alg=clock refs=1,2,3,4,1,2,5,1,2,3,4,5 frames=3 lang=zh")
check(clockRun.errors.isEmpty && lastState(clockRun).grids["P"]!.values[3].filter { $0 == "√" }.count == Int(lastState(clockRun).vars["缺页次数"]!.value)!, "CLOCK 无错，缺页行与计数一致 \(clockRun.errors)")
let reqs = "55,58,39,18,90,160,150,38,184"
for (alg, want) in [("fcfs", "498"), ("sstf", "248"), ("look", "250"), ("clook", "322"), ("scan", "280"), ("cscan", "388")] {
    let r = AnimEngine.run("kit disk alg=\(alg) start=100 requests=\(reqs) lang=zh")
    check(r.errors.isEmpty && lastState(r).vars["移动距离"]?.value == want, "磁盘调度 \(alg)：总移动 \(want)（\(lastState(r).vars["移动距离"]?.value ?? "-")）\(r.errors)")
    check(lastState(r).cells["访问序列"]!.count == 9, "磁盘调度 \(alg)：9 个请求都访问到")
}
let direct = AnimEngine.run("kit cache map=direct lines=4 blocks=0,4,0,4 lang=zh"), twoWay = AnimEngine.run("kit cache map=set lines=4 ways=2 blocks=0,4,0,4 lang=zh")
check(direct.errors.isEmpty && lastState(direct).vars["缺失"]?.value == "4", "直接映射：0 和 4 抢同一行，4 次全缺失")
check(twoWay.errors.isEmpty && lastState(twoWay).vars["命中"]?.value == "2", "2 路组相联：0、4 同组两路，后两次命中")
let lruCache = AnimEngine.run("kit cache map=full lines=2 blocks=1,2,1,3,2 replace=lru lang=zh"), fifoCache = AnimEngine.run("kit cache map=full lines=2 blocks=1,2,1,3,2 replace=fifo lang=zh")
check(lastState(lruCache).vars["命中"]?.value == "1" && lastState(fifoCache).vars["命中"]?.value == "2", "全相联 LRU 换出 2、FIFO 换出 1（命中 1 / 2）")
let b2 = AnimEngine.run("kit base n=156 to=2 lang=zh"), b16 = AnimEngine.run("kit base n=255 to=16 lang=zh")
check(b2.errors.isEmpty && b2.script.scenes[0].steps.last!.caption.contains("(10011100)₂"), "156 = (10011100)₂")
check(b16.errors.isEmpty && b16.script.scenes[0].steps.last!.caption.contains("(FF)₁₆"), "255 = (FF)₁₆")
let kmp = AnimEngine.run("kit kmp P=ababaa lang=zh")
let kg = lastState(kmp).grids["K"]!
check(kmp.errors.isEmpty && kg.values[1] == ["0", "1", "1", "2", "3", "4"] && kg.values[2] == ["0", "1", "0", "1", "0", "4"], "KMP ababaa：next 011234、nextval 010104 \(kg.values)")
let hash = AnimEngine.run("kit hash keys=19,14,23,1,68,20 size=13 lang=zh")
let hg = lastState(hash).grids["H"]!
check(hash.errors.isEmpty && hg.values[0][6] == "19" && hg.values[0][1] == "14" && hg.values[0][2] == "1" && hg.values[1][2] == "2", "散列：1 与 14 冲突，探到 2 号格、比较 2 次")
check(AnimEngine.run("kit hash keys=0,13,26 size=13 probe=quadratic lang=zh").errors.isEmpty, "平方探测放得下")
let heapRun = AnimEngine.run("kit heap A=[53, 17, 78, 9, 45, 65, 87, 32] lang=zh")
check(heapRun.errors.isEmpty && lastState(heapRun).cells["A"]!.map(\.value) == ["87", "45", "78", "32", "17", "65", "53", "9"], "建大根堆：87 45 78 32 17 65 53 9（教材例题）\(heapRun.errors)")
let hsort = AnimEngine.run("kit heap A=[53, 17, 78, 9, 45, 65, 87, 32] sort=yes lang=zh")
check(hsort.errors.isEmpty && lastState(hsort).cells["A"]!.map(\.value) == ["9", "17", "32", "45", "53", "65", "78", "87"] && lastState(hsort).trees["T"]!.nodes.count == 1, "堆排序升序，树只剩一个结点 \(hsort.errors)")
let minHeap = AnimEngine.run("kit heap A=[5, 3, 8, 1] type=min lang=zh")
check(minHeap.errors.isEmpty && lastState(minHeap).cells["A"]!.first?.value == "1", "小根堆堆顶是最小的")
let bs = "A=[7, 10, 13, 16, 19, 29, 32, 33, 37, 41, 43]"
let found = AnimEngine.run("kit bsearch \(bs) key=37 lang=zh"), miss = AnimEngine.run("kit bsearch \(bs) key=11 lang=zh")
check(found.errors.isEmpty && lastState(found).cells["A"]![8].tone == .done && lastState(found).vars["比较次数"]?.value == "2", "折半找 37：mid 5 → 8，比较 2 次")
check(miss.errors.isEmpty && miss.script.scenes[0].steps.last!.caption.contains("查找失败"), "折半找 11：失败")
let tcp = AnimEngine.run("kit tcp ssthresh=16 rounds=14 timeout=12 lang=zh")
check(tcp.errors.isEmpty && lastState(tcp).grids["W"]!.values[0] == ["1", "2", "4", "8", "16", "17", "18", "19", "20", "21", "22", "23", "1", "2"] && lastState(tcp).vars["ssthresh"]?.value == "11",
      "TCP：慢开始到 16，拥塞避免到 23，超时后 ssthresh = 11、cwnd 回 1 \(lastState(tcp).grids["W"]!.values[0])")
let reno = AnimEngine.run("kit tcp ssthresh=8 rounds=8 dup=5 lang=zh")
check(reno.errors.isEmpty && lastState(reno).grids["W"]!.values[0] == ["1", "2", "4", "8", "9", "4", "5", "6"], "TCP：3 个重复确认后快恢复 cwnd = ssthresh = 4 \(lastState(reno).grids["W"]!.values[0])")
check(AnimText.parse("kit page alg=lru refs=1,2 frames=9").errors.first?.message.contains("frames") == true, "参数越界报错")

print("定点数乘除（组成原理）")
let om = AnimEngine.run("kit mul method=orig x=-0.1101 y=0.1011 lang=zh")
check(om.errors.isEmpty && lastState(om).caption.contains("[x·y]原 = 1.10001111") && sheetRow(lastState(om).sheets["竖式"]!, 13) == "0.10001111",
      "原码一位乘：-0.1101 × 0.1011 = -0.10001111，最后一行部分积 + 乘数 \(sheetRow(lastState(om).sheets["竖式"]!, 13))")
let bm = AnimEngine.run("kit mul method=booth x=-0.1101 y=0.1011 lang=zh")
check(bm.errors.isEmpty && lastState(bm).caption.contains("[x·y]补 = 1.01110001") && bm.stepCount == 10,
      "Booth：[x·y]补 = 1.01110001，加 5 次移 4 次（9 步 + 第 0 步）\(bm.stepCount)")
let nr = AnimEngine.run("kit div method=nonrestore x=-0.1011 y=-0.1101 lang=zh")
check(nr.errors.isEmpty && lastState(nr).caption.contains("[x÷y]原 = 0.1101") && lastState(nr).caption.contains("-0.0111 × 2⁻⁴"), "加减交替：商 0.1101，余数 -0.0111 × 2⁻⁴（唐朔飞例题）")
let cd = AnimEngine.run("kit div method=comp x=0.1000 y=-0.1011 lang=zh")
check(cd.errors.isEmpty && lastState(cd).caption.contains("[x÷y]补 = 1.0101") && lastState(cd).caption.contains("[r]补 = 0.0111 × 2⁻⁴"), "补码除法：[x÷y]补 = 1.0101，余数 0.0111 × 2⁻⁴（王道例题）")
check(AnimText.parse("kit div x=0.1101 y=0.1011").errors.first?.message.contains("|x| < |y|") == true, "|x| ≥ |y| 报溢出")
check(AnimText.parse("kit div method=restore x=0.1 y=0.1111111").errors.first?.message.contains("6 bits") == true, "恢复余数法最多 6 位")
check(AnimText.parse("kit mul x=1.01 y=0.1").errors.first?.message.contains("binary fraction") == true, "不是定点小数报错")
let bi = AnimEngine.run("kit mul method=booth x=-1101 y=1011 lang=zh")
check(bi.errors.isEmpty && lastState(bi).caption.contains("[x·y]补 = 1,01110001") && lastState(bi).caption.hasSuffix("x·y = -10001111")
      && sheetRow(bi.state(scene: 0, step: 0).sheets["竖式"]!, 1).hasPrefix("00,0000"),
      "Booth 定点整数：-1101 × 1011 = -10001111，[x·y]补 = 1,01110001，逗号分开符号位 \(lastState(bi).caption)")
check(AnimText.parse("kit mul x=1101 y=0.1011").errors.first?.message.contains("both") == true, "整数和小数混用报错")
check(AnimText.parse("kit div x=101 y=1101").errors.first?.message.contains("binary fraction") == true, "除法仍只认小数")
// 穷举：1～3 位、所有符号与数值
func parseFrac(_ s: String) -> Double {
    let neg = s.hasPrefix("-"), body = neg ? String(s.dropFirst()) : s
    var v = 0.0, w = 1.0
    for c in body.dropFirst(2) { w /= 2; if c == "1" { v += w } }
    return neg ? -v : v
}
var mulBad: [String] = [], divBad: [String] = []
for n in 1...3 {
    for xm in 0..<(1 << n) { for ym in 0..<(1 << n) { for sx in [false, true] { for sy in [false, true] {
        let xs = (sx ? "-" : "") + "0." + AnimKits.binary(xm, n), ys = (sy ? "-" : "") + "0." + AnimKits.binary(ym, n)
        let X = sx ? -xm : xm, Y = sy ? -ym : ym
        for m in ["orig", "booth"] {
            let r = AnimEngine.run("kit mul method=\(m) x=\(xs) y=\(ys) lang=zh")
            if !r.errors.isEmpty || !lastState(r).caption.hasSuffix("x·y = \(AnimKits.trueValue(X * Y, 2 * n))") { mulBad.append("\(m) \(xs)×\(ys)") }
        }
        let xi = (sx ? "-" : "") + AnimKits.binary(xm, n), yi = (sy ? "-" : "") + AnimKits.binary(ym, n)
        for m in ["orig", "booth"] {
            let r = AnimEngine.run("kit mul method=\(m) x=\(xi) y=\(yi) lang=zh")
            if !r.errors.isEmpty || !lastState(r).caption.hasSuffix("x·y = \(AnimKits.trueValue(X * Y, 2 * n, ","))") { mulBad.append("\(m) \(xi)×\(yi)") }
        }
        guard xm < ym else { continue }
        let q = (xm << n) / ym, rem = (xm << n) % ym
        for m in ["restore", "nonrestore"] {
            let r = AnimEngine.run("kit div method=\(m) x=\(xs) y=\(ys) lang=zh")
            let cap = lastState(r).caption
            if !r.errors.isEmpty || !cap.contains("x ÷ y = \(AnimKits.trueValue(sx != sy ? -q : q, n))；") || !cap.contains("\(AnimKits.trueValue(sx ? -rem : rem, n)) × 2") {
                divBad.append("\(m) \(xs)÷\(ys)")
            }
        }
        let r = AnimEngine.run("kit div method=comp x=\(xs) y=\(ys) lang=zh")
        let cap = lastState(r).caption
        let qText = cap.components(separatedBy: "x ÷ y = ")[1].components(separatedBy: "；")[0]
        if !r.errors.isEmpty || abs(parseFrac(qText) - Double(X) / Double(Y)) > 1.0 / Double(1 << n) + 1e-9 { divBad.append("comp \(xs)÷\(ys) → \(qText)") }
    } } } }
}
check(mulBad.isEmpty, "原码 / Booth 乘法 1～3 位全部组合结果正确（小数与整数） \(mulBad.prefix(5))")
check(divBad.isEmpty, "恢复余数 / 加减交替商与余数精确、补码除法误差 ≤ 2⁻ⁿ（1～3 位全部组合）\(divBad.prefix(5))")

print("方向与分层、首部格式图、分组图（第四批）")
do {
    let t = AnimText.parse("tree T dir=right = (1 2 3)\ntree U = (1)\ngraph G layout=layers dir=down layers=[[A], [B, C], [D]] = A-B, A-C, B-D")
    check(t.errors.isEmpty, "tree dir= / graph layers= 解析无错 \(t.errors)")
    if case .tree(_, let d) = t.scenes[0].elements[0].kind { check(d == .right, "tree dir=right") }
    if case .tree(_, let d) = t.scenes[0].elements[1].kind { check(d == .down, "tree 默认 dir=down") }
    if case .graph(let n, _, let l, let d, let ranks) = t.scenes[0].elements[2].kind {
        check(l == .layers && d == .down && ranks == [["A"], ["B", "C"], ["D"]] && n == ["A", "B", "C", "D"], "graph 手动分层 + dir=down")
    }
    let lone = AnimText.parse("graph G layers=[[A, Z], [B]] = A-B")
    if case .graph(let n, _, let l, let d, _) = lone.scenes[0].elements[0].kind { check(n == ["A", "B", "Z"] && l == .layers && d == .right, "layers= 里多出的节点补上、隐含 layout=layers、默认 dir=right") }
    let bad: [(String, String)] = [
        ("graph G layers=[[A], [B]] = A-B, B-C", "C is not in any layer"),
        ("graph G layers=[[A], [A, B]] = A-B", "A is listed twice"),
        ("graph G layout=circle dir=down = A-B", "dir= only works with layout=layers"),
        ("graph G layout=circle layers=[[A], [B]] = A-B", "layers=[…] needs layout=layers"),
        ("tree T dir=north = (1)", "dir= takes down, up, right or left"),
        ("bits H = A:4, B:x", "the size is a number of bits"),
        ("bits H width=8 = A:200", "at most 20 rows"),
        ("packet P = a:1\nstep x\n  group P[0..3] \"y\"", "P has 1 part(s): P[0..3] is out of range"),
        ("array A = [1]\nstep x\n  group A[0] \"y\"", "is not a packet"),
    ]
    for (src, msg) in bad {
        let r = AnimEngine.run(src)
        check(r.errors.contains { $0.message.contains(msg) }, "报错：\(msg) \(r.errors.map(\.message))")
    }
    // bits：字段偏移、* 补满一行、按名字 / 下标找、label
    let b = AnimEngine.run("bits H width=16 = A:4, B:4=7, 名 字:8, 可变:*\nlabel H[1] \"FF FF\"\nstep x\n  set H[2] = 9\n  mark H[0..1] active\n  set H[可变] = \"v\"")
    check(b.errors.isEmpty, "bits 解析执行无错 \(b.errors)")
    if case .bits(let fs, let w) = b.script.scenes[0].elements[0].kind {
        check(w == 16 && fs.map(\.bits) == [4, 4, 8, 16] && fs[3].variable && fs[1].value == "7", "字段位数、* 补满下一整行、初值")
    }
    let b0 = b.state(scene: 0, step: 0).bits["H"]!, b1 = b.state(scene: 0, step: 1).bits["H"]!
    check(b0.values == ["", "7", "", ""] && b0.labels[1] == "FF FF", "第 0 步：初值 + 行尾注释")
    check(b1.values == ["", "7", "9", "v"] && b1.tones == [.active, .active, .normal, .normal], "按下标 / 名字 set、范围 mark")
    let boxes = AnimLayout.bitFieldBoxes(offset: 64, bits: 128, width: 32)
    check(boxes.count == 1 && boxes[0].rows == 4, "128 位地址 = 一个 4 行高的框")
    let split = AnimLayout.bitFieldBoxes(offset: 24, bits: 16, width: 32)
    check(split.count == 2 && split[0].cols == 8 && split[1].cols == 8 && split[1].row == 1, "跨行的字段切成两段")
    // packet：插入、括号随两端段走、端点段删了括号消失、括号分层
    let pk = AnimEngine.run("packet P unit=B = 数据:100\nstep a\n  insert P 0 \"TCP首部:20\"\n  group P[0..1] \"段\"\nstep b\n  insert P 0 \"IP首部:20\"\n  group P[0..2] \"数据报\"\nstep c\n  remove P 0\nstep d\n  set P[1] = \"数据:50\"\n  mark P[1] done")
    check(pk.errors.isEmpty, "packet 执行无错 \(pk.errors)")
    let p2 = pk.state(scene: 0, step: 2).packets["P"]!, p3 = pk.state(scene: 0, step: 3).packets["P"]!, p4 = pk.state(scene: 0, step: 4).packets["P"]!
    check(p2.segments.map(\.name) == ["IP首部", "TCP首部", "数据"] && p2.groups.count == 2, "两次封装：三段、两个括号")
    check(AnimLayout.packetGroupLevels(p2).values.sorted() == [1, 2], "嵌套括号分两层")
    check(p3.groups.map(\.label) == ["段"], "去掉 IP 首部：「数据报」括号随之消失")
    check(p4.segments[1].length == "50" && p4.segments[1].tone == .done, "set 改段、mark 标色")
    check(pk.state(scene: 0, step: 2).packets["P"]!.segments[0].tone == .new && pk.state(scene: 0, step: 3).packets["P"]!.segments[0].tone == .normal, "新插入的段只在当步是 new 色")
    check(AnimLayout.leadingNumber("1480") == 1480 && AnimLayout.leadingNumber("20 B") == 20 && AnimLayout.leadingNumber("x") == 0, "长度开头的数字")
    // 节点框：长名字拉成长条，边从框边出发
    check(AnimLayout.graphHalfWidth("A") == AnimLayout.graphNode / 2 && AnimLayout.graphHalfWidth("交换机S1") > AnimLayout.graphNode / 2, "短名字是圆、长名字是长条")
    check(abs(AnimLayout.nodeExit(1, 0, hw: 40, hh: 15) - 40) < 0.01 && abs(AnimLayout.nodeExit(0, 1, hw: 40, hh: 15) - 15) < 0.01
          && abs(AnimLayout.nodeExit(0.6, 0.8, hw: 15, hh: 15) - 15) < 0.01, "从中心到框边：长条的横 / 竖方向、圆的斜方向")
}
do {
    // IPv6 地址的标准写法
    func v6(_ hex: String) -> String { AnimKits.ipv6Text(try! AnimKits.parseHex(hex), 0) }
    check(v6("00000000000000000000000000000000") == "::", "全 0 → ::")
    check(v6("00000000000000000000000000000001") == "::1", "::1")
    check(v6("20010db8000000000000000000000001") == "2001:db8::1", "2001:db8::1")
    check(v6("20010db8000000010001000100010001") == "2001:db8:0:1:1:1:1:1", "单独一组 0 不压缩")
    check(v6("20010000000000010000000000000001") == "2001:0:0:1::1", "一样长的全 0 段取前面那段……")
    check(v6("20010db800000000000100000000000a") == "2001:db8::1:0:0:a", "……长度相同取最前面")
    check(AnimKits.onesSum(try! AnimKits.parseHex("45 00 00 3c 1c 46 40 00 40 06 b1 e6 ac 10 0a 63 ac 10 0a 0c"), 20) == 0xFFFF, "首部检验和验算：正确的首部和为 0xFFFF")
    check(AnimKits.bitValue([0x40, 0x00], 1, 2) == 2 && AnimKits.bitValue([0x0F, 0xF0], 4, 8) == 0xFF, "按位取值（跨字节）")

    let ok = AnimEngine.run("kit header proto=ipv4 hex=\"45 00 00 3c 1c 46 40 00 40 06 b1 e6 ac 10 0a 63 ac 10 0a 0c\" lang=zh")
    check(ok.errors.isEmpty, "IPv4 解析无错")
    let okLast = lastState(ok).bits.values.first!
    check(okLast.values[3] == "60" && okLast.values[5] == "010" && okLast.values[8] == "6 TCP" && okLast.values[10] == "172.16.10.99" && okLast.tones[9] == .done,
          "IPv4：总长度 60、标志 010、协议 6 TCP、源地址、检验和正确标绿")
    check(ok.states[0].contains { $0.caption.contains("DF = 1（不许分片），MF = 0") }, "IPv4：DF / MF 讲清楚")
    let broken = AnimEngine.run("kit header proto=ipv4 hex=\"45 00 00 3c 1c 46 40 00 40 06 b1 e7 ac 10 0a 63 ac 10 0a 0c\" lang=zh")
    check(lastState(broken).bits.values.first!.tones[9] == .wrong && broken.states[0].contains { $0.caption.contains("首部有差错") }, "检验和错一位：标红并说明")
    let opt = AnimEngine.run("kit header proto=ipv4 hex=\"46 00 00 20 00 01 20 00 3f 11 00 00 0a 00 00 01 0a 00 00 02 01 01 00 00 ff\" lang=zh")
    if case .bits(let fs, _)? = opt.script.scenes.first?.elements.first?.kind {
        check(fs.count == 13 && fs[12].bits == 32, "首部长度 6：多一行 4 字节的可选字段")
    }
    check(opt.states[0].contains { $0.caption.contains("MF = 1（后面还有分片）") } && opt.states[0].contains { $0.caption.contains("后面 1 字节是数据部分") }, "MF = 1；多出来的字节算数据")
    let syn = AnimEngine.run("kit header proto=tcp hex=\"04 89 00 50 0d d6 01 f4 00 00 00 00 50 02 40 00 c0 29 00 00\" lang=zh")
    check(syn.errors.isEmpty && syn.states[0].contains { $0.caption.contains("SYN = 1：连接请求（第一次握手）") }, "TCP：SYN 报文段认出第一次握手")
    check(syn.states[0].contains { $0.caption.contains("80（HTTP）") } && lastState(syn).bits.values.first!.values[2] == "232129012", "TCP：端口名、序号十进制")
    let synack = AnimEngine.run("kit header proto=tcp hex=\"00 50 04 89 00 00 00 01 0d d6 01 f5 50 12 40 00 00 00 00 00\" lang=en")
    check(synack.states[0].contains { $0.caption.contains("connection accepted (second handshake)") }, "TCP：SYN + ACK = 第二次握手")
    let udp = AnimEngine.run("kit header proto=udp hex=\"c3 50 00 35 00 26 00 00\" lang=zh")
    check(udp.states[0].contains { $0.caption.contains("53（DNS）") } && udp.states[0].contains { $0.caption.contains("数据 38 − 8 = 30 字节") } && udp.states[0].contains { $0.caption.contains("没有使用检验和") },
          "UDP：DNS 端口、数据长度、检验和为 0")
    let v6run = AnimEngine.run("kit header proto=ipv6 hex=\"60 00 00 00 00 20 06 40 20 01 0d b8 00 00 00 00 00 00 00 00 00 00 00 01 fe 80 00 00 00 00 00 00 02 1a 2b ff fe 3c 4d 5e\" lang=zh")
    let v6last = lastState(v6run).bits.values.first!
    check(v6run.errors.isEmpty && v6last.values[6] == "2001:db8::1" && v6last.values[7] == "fe80::21a:2bff:fe3c:4d5e" && v6last.values[4] == "6 TCP", "IPv6：地址压缩写法、下一个首部")
    for (src, msg) in [("kit header proto=ipv4 hex=\"45 00\"", "needs at least 20"), ("kit header proto=ipv4 hex=\"4g\"", "hexadecimal"),
                       ("kit header proto=ipv6 hex=\"45 00 00 3c 1c 46 40 00 40 06 b1 e6 ac 10 0a 63 ac 10 0a 0c 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\"", "not an IPv6 header"),
                       ("kit header proto=ipv4 hex=\"47 00 00 3c 1c 46 40 00 40 06 b1 e6 ac 10 0a 63 ac 10 0a 0c\"", "says 28 bytes"),
                       ("kit header proto=icmp", "proto= takes")] {
        let r = AnimEngine.run(src)
        check(r.errors.contains { $0.message.contains(msg) }, "header 报错：\(msg) \(r.errors.map(\.message))")
    }
    let fmt = AnimEngine.run("kit header proto=tcp lang=zh")
    check(fmt.errors.isEmpty && fmt.stepCount == 13, "TCP 格式：13 步（控制位、选项各合一步）")

    // 封装
    let en = AnimEngine.run("kit encap data=1 transport=udp lang=zh")
    let frameStep = en.states[0].first { $0.packets.values.first!.segments.contains { $0.name == "FCS" } }!.packets.values.first!
    check(frameStep.segments.map(\.name) == ["以太网首部", "IPv4首部", "UDP首部", "应用数据", "填充", "FCS"] && frameStep.segments[4].length == "17",
          "封装：1 字节数据 + UDP 8 + IP 20 = 29，补 17 字节填充")
    check(frameStep.groups.map(\.label).contains("以太网帧 64 B"), "最短帧 64 字节")
    let enLast = lastState(en).packets.values.first!
    check(enLast.segments.map(\.name) == ["应用数据"] && enLast.groups.isEmpty, "拆封后只剩数据、括号都没了")
    let big = AnimEngine.run("kit encap data=2000 lang=zh")
    check(big.states[0].contains { $0.caption.contains("超过以太网 MTU 1500") }, "超过 MTU 时提示要分片")
    check(AnimEngine.run("kit encap data=10 mode=encap").stepCount == 6, "mode=encap 只有封装")

    // 分片
    let fr = AnimEngine.run("kit frag total=4000 mtu=1500 lang=zh")
    let grid = lastState(fr).grids.values.first!
    check(fr.errors.isEmpty && grid.values == [["1500", "1480", "1", "0", "0"], ["1500", "1480", "1", "0", "185"], ["1040", "1020", "0", "0", "370"]], "4000 / 1500：三片，片偏移 0、185、370")
    check(lastState(fr).packets.values.first!.segments.map(\.length) == ["20", "1480", "20", "1480", "20", "1020"], "分组图：每片自带首部")
    let fr2 = AnimEngine.run("kit frag data=3980 mtu=576 lang=zh")
    let g2 = lastState(fr2).grids.values.first!
    check(g2.rows == 8 && g2.values[0][1] == "552" && g2.values[7][1] == "116" && g2.values[7][4] == "483" && g2.values[6][2] == "1" && g2.values[7][2] == "0",
          "MTU 576：每片 552 字节（8 的倍数），共 8 片，末片 116 字节、偏移 483")
    let drop = AnimEngine.run("kit frag total=4000 mtu=1500 df=1 lang=zh")
    check(lastState(drop).elementTones.values.first == .wrong && drop.states[0].contains { $0.caption.contains("ICMP") }, "DF = 1：丢弃并发 ICMP")
    check(AnimEngine.run("kit frag total=1000 mtu=1500").stepCount == 2, "不超过 MTU：不分片")
    check(AnimEngine.run("kit frag total=4000 mtu=100").errors.contains { $0.message.contains("at most 8") }, "片太多报错")
}

print("IP 地址分类与 CIDR（第五批）")
do {
    check(try! AnimKits.parseIPv4("192.168.1.10") == 0xC0A8010A && AnimKits.ipText(0xC0A8010A) == "192.168.1.10", "点分十进制 ↔ 整数")
    check(AnimKits.ipBinary(0xC0A8010A) == "11000000.10101000.00000001.00001010" && AnimKits.ipBinary(0xC0A80100, upTo: 24) == "11000000.10101000.00000001"
          && AnimKits.ipBinary(0xC0A80120, upTo: 27) == "11000000.10101000.00000001.001", "二进制写法（只写前缀时末尾不留点）")
    check(AnimKits.ipColRanges(20, 32) == ["22..25", "27..34"] && AnimKits.ipColRanges(0, 3) == ["0..2"], "位 → 列范围按字节切开")
    check((try? AnimKits.maskLength(0xFFFFF000)) == 20 && (try? AnimKits.maskLength(0xFF00FF00)) == nil, "掩码长度、不连续的掩码报错")
    for bad in ["256.1.1.1", "1.2.3", "1.2.3.4/33", "a.b.c.d"] { check((try? AnimKits.parseCIDR(bad)) == nil, "非法地址报错：\(bad)") }
    let one = lastState(AnimEngine.run("kit ipaddr ip=172.16.37.200/20 lang=zh"))
    check(one.vars["网络地址"]?.value == "172.16.32.0/20" && one.vars["广播地址"]?.value == "172.16.47.255" && one.vars["可用主机"]?.value == "4094",
          "172.16.37.200/20：网络 172.16.32.0、广播 172.16.47.255、4094 台")
    let cls = AnimEngine.run("kit ipaddr ip=10.1.2.3 lang=zh")
    check(lastState(cls).vars["网络地址"]?.value == "10.0.0.0/8" && cls.states[0].contains { $0.caption.contains("A 类") } && cls.states[0].contains { $0.caption.contains("私有地址") },
          "不给掩码按类别：10.1.2.3 → A 类 /8，私有地址")
    let mc = AnimEngine.run("kit ipaddr ip=224.0.0.5 lang=zh")
    check(mc.errors.isEmpty && mc.stepCount == 3 && lastState(mc).caption.contains("多播"), "D 类：只讲类别")
    let p2p = lastState(AnimEngine.run("kit ipaddr ip=192.168.1.1 mask=255.255.255.252 lang=zh"))
    check(p2p.vars["网络地址"]?.value == "192.168.1.0/30" && p2p.vars["可用主机"]?.value == "2", "mask= 写法：/30 两台")
    check(lastState(AnimEngine.run("kit ipaddr ip=192.168.1.0/24 lang=zh")).caption.contains("本身就是网络地址"), "地址恰好是网络地址时提醒")
    let sup = AnimEngine.run("kit supernet nets=172.18.129.0/24,172.18.130.0/24,172.18.132.0/24,172.18.133.0/24 lang=zh")
    check(lastState(sup).caption.contains("172.18.128.0/21") && lastState(sup).caption.contains("多包含了 1024 个"), "聚合：172.18.128.0/21，多包含 1024 个地址（王道例题）")
    check(lastState(AnimEngine.run("kit supernet nets=192.168.0.0/24,192.168.1.0/24 lang=zh")).caption.contains("192.168.0.0/23") , "两个相邻 /24 → /23，正好覆盖")
    check(lastState(AnimEngine.run("kit supernet nets=192.168.0.0/24,192.168.1.0/24 lang=zh")).caption.contains("正好覆盖"), "正好覆盖时这样说")
    let sub = AnimEngine.run("kit subnet net=192.168.1.0/24 hosts=50 lang=zh")
    check(sub.stepCount == 7 && sub.states[0].contains { $0.caption.contains("192.168.1.192/26") && $0.caption.contains("广播 192.168.1.255") }, "按主机数分：/26 四个子网")
    let sub2 = AnimEngine.run("kit subnet net=172.16.0.0/16 n=5 lang=zh")
    check(sub2.states[0].contains { $0.caption.contains("2³ = 8 ≥ 5") } && sub2.states[0].contains { $0.caption.contains("172.16.224.0/19") }, "按个数分：5 个 → 借 3 位，/19")
    let lpm = AnimEngine.run("kit lpm dst=192.168.1.37 routes=\"192.168.1.0/24 R1, 192.168.1.32/27 R2, 192.168.1.64/26 R4, 0.0.0.0/0 R3\" lang=zh")
    check(lastState(lpm).caption.contains("192.168.1.32/27 → 下一跳 R2") && lpm.states[0].contains { $0.caption.contains("第 26 位不同") }, "最长前缀匹配取 /27")
    check(lastState(AnimEngine.run("kit lpm dst=10.0.0.1 routes=\"192.168.1.0/24 R1\" lang=zh")).caption.contains("丢弃"), "都不匹配：丢弃")
    for (src, msg) in [("kit subnet net=192.168.1.5/24 n=4", "not a network address"), ("kit subnet net=10.0.0.0/8 hosts=1000", "at most 16"), ("kit subnet net=192.168.1.0/24 n=64", "2…16"),
                       ("kit subnet net=192.168.1.0/30 n=2", "not enough"), ("kit subnet net=192.168.1.0/24 n=2 hosts=3", "not both"),
                       ("kit supernet nets=10.0.0.0/8", "takes 2…8"), ("kit ipaddr ip=1.2.3.4/8 mask=255.0.0.0", "not both"),
                       ("kit ipaddr ip=1.2.3.4 mask=255.0.255.0", "not a valid mask"), ("kit lpm dst=1.2.3.4", "usage")] {
        let r = AnimEngine.run(src)
        check(r.errors.contains { $0.message.contains(msg) }, "报错：\(msg) \(r.errors.map(\.message))")
    }
}

print("写法说明里的示例")
for (i, example) in AnimText.examples.enumerated() {
    let r = AnimEngine.run(example)
    check(r.errors.isEmpty, "示例 \(i + 1) 无错 \(r.errors)")
}

print("\n通过 \(pass)，失败 \(fail)")
exit(fail == 0 ? 0 : 1)
