// ```anim 跨端向量：Mac 版（参照实现）把一批写法跑一遍，写出 `spike/anim-vectors.txt`；
// 安卓 `shared/anim/` 的 `AnimVectorsTest` 读同一份逐条比对（展开后的文字、报错、每个场景每一步的状态摘要、时序图长度）。
// 比的是「画面上该有什么」，不比坐标（两端字体不同，文字宽度对不上）。改了 Swift 的解析 / 套件 / 执行，重跑本脚本、安卓测试跟着过。
// 运行：
//   mkdir -p build/spike && cp spike/anim-vectors.swift build/spike/main.swift && swiftc Sources/Anim/AnimText.swift Sources/Anim/AnimKits.swift Sources/Anim/AnimReference.swift Sources/Anim/AnimState.swift Sources/Anim/AnimStructures.swift build/spike/main.swift -o build/spike/anim-vectors && build/spike/anim-vectors > spike/anim-vectors.txt
import Foundation

func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
}

func f3(_ x: Double) -> String { String(format: "%.3f", x) }

/// 一个场景某一步的状态摘要（安卓 `AnimDigest.state` 逐字同一份）。
func digest(_ s: AnimSceneState) -> String {
    var parts: [String] = []
    parts.append("cap=" + s.caption)
    if !s.says.isEmpty { parts.append("says=" + s.says.joined(separator: "|")) }
    for name in s.cells.keys.sorted() {
        parts.append("cells:\(name)=" + s.cells[name]!.map { "\($0.value):\($0.tone.rawValue)" }.joined(separator: ","))
    }
    for name in s.vars.keys.sorted() { parts.append("var:\(name)=\(s.vars[name]!.value):\(s.vars[name]!.tone.rawValue)") }
    for name in s.seqs.keys.sorted() {
        let q = s.seqs[name]!
        parts.append("seq:\(name)=\(q.start),\(q.window)," + q.tones.keys.sorted().map { "\($0):\(q.tones[$0]!.rawValue)" }.joined(separator: ";"))
    }
    for name in s.elementTones.keys.sorted() { parts.append("et:\(name)=\(s.elementTones[name]!.rawValue)") }
    for name in s.lists.keys.sorted() {
        let l = s.lists[name]!
        parts.append("list:\(name)=" + l.nodes.map { n in "\(n.value):\(n.tone.rawValue):" + (n.next.flatMap { l.index(of: $0) }.map(String.init) ?? "-") }.joined(separator: ","))
    }
    for name in s.trees.keys.sorted() {
        let t = s.trees[name]!
        func ser(_ id: Int?) -> String {
            guard let id, let n = t.nodes[id] else { return "_" }
            return "\(n.value):\(n.tone.rawValue)(" + n.children.map(ser).joined(separator: " ") + ")"
        }
        parts.append("tree:\(name)=" + ser(t.root))
    }
    for name in s.graphs.keys.sorted() {
        let g = s.graphs[name]!
        let nodes = g.order.map { "\($0):\(g.nodes[$0]!.tone.rawValue):\(g.nodes[$0]!.label)" }.joined(separator: ";")
        let edges = g.edges.map { "\($0.a)\($0.directed ? ">" : "-")\($0.b):\($0.weight ?? ""):\($0.tone.rawValue)" }.joined(separator: ";")
        parts.append("graph:\(name)=\(nodes)/\(edges)")
    }
    for name in s.grids.keys.sorted() {
        let g = s.grids[name]!
        parts.append("grid:\(name)=" + (0..<g.rows).map { i in (0..<g.cols).map { j in "\(g.values[i][j]):\(g.tones[i][j].rawValue)" }.joined(separator: ",") }.joined(separator: ";"))
    }
    for name in s.sheets.keys.sorted() {
        let sh = s.sheets[name]!
        var cells: [String] = []
        for r in sh.cells.keys.sorted() { for c in sh.cells[r]!.keys.sorted() { cells.append("\(r),\(c)=\(sh.cells[r]![c]!.char):\(sh.cells[r]![c]!.tone.rawValue)") } }
        let rules = sh.rules.map { "\($0.row):\($0.from):\($0.to):\($0.above ? 1 : 0)" }.joined(separator: ";")
        let arrows = sh.arrows.map { "\($0.col):\($0.fromRow):\($0.toRow)" }.joined(separator: ";")
        let labels = sh.labels.keys.sorted().map { "\($0)=\(sh.labels[$0]!)" }.joined(separator: ";")
        parts.append("sheet:\(name)=" + cells.joined(separator: ";") + "/" + rules + "/" + arrows + "/" + labels)
    }
    for name in s.pointers.keys.sorted() {
        let desc: String
        switch s.pointers[name]! {
        case nil: desc = "null"
        case .index(let e, let i)?: desc = "idx(\(e),\(i))"
        case .node(let e, let id)?:
            if let l = s.lists[e], let i = l.index(of: id) { desc = "lnode(\(e),\(i))" }
            else if let t = s.trees[e], let n = t.nodes[id] { desc = "tnode(\(e),\(n.value))" }
            else { desc = "node(\(e),?)" }
        case .graphNode(let e, let n)?: desc = "gn(\(e),\(n))"
        case .grid(let e, let r, let c)?: desc = "cell(\(e),\(r),\(c))"
        }
        parts.append("ptr:\(name)=\(desc)")
    }
    for m in s.messages {
        parts.append("msg:\(m.from)>\(m.to):\(m.label):\(m.lost ? 1 : 0):\(m.tone.rawValue):\(f3(m.start)):\(f3(m.end)):\(m.step)")
    }
    for k in s.marks {
        let kind: String
        switch k.kind {
        case .deliver: kind = "deliver"
        case .discard: kind = "discard"
        case .buffer: kind = "buffer"
        case .note: kind = "note"
        case .timerStart: kind = "tstart"
        case .timerStop: kind = "tstop"
        case .timerExpire: kind = "texpire"
        }
        parts.append("mark:\(k.lane):\(k.label):\(kind):\(k.tone.rawValue):\(f3(k.time)):\(k.step)")
    }
    for t in s.timers {
        parts.append("timer:\(t.lane):\(t.label):\(f3(t.start)):\(t.end.map(f3) ?? "-"):\(t.expired ? 1 : 0)")
    }
    parts.append("cursor=\(f3(s.cursor))")
    return parts.joined(separator: "\n")
}

var cases: [(String, String)] = []
for (i, e) in AnimText.examples.enumerated() { cases.append(("example\(i + 1)", e)) }
for lang in ["zh", "en"] {
    cases += [
        ("gbn-\(lang)", "kit gbn frames=6 window=4 lose=2 lang=\(lang)"),
        ("gbn-ack-\(lang)", "kit gbn frames=6 window=4 lose=2,3 loseack=4 timeout=3 mod=8 lang=\(lang)"),
        ("sr-\(lang)", "kit sr frames=8 window=4 lose=2,6 loseack=3 lang=\(lang)"),
        ("stopwait-\(lang)", "kit stopwait frames=3 lose=1 loseack=2 lang=\(lang)"),
        ("bubble-\(lang)", "kit bubble A=[5, 1, 4, 2, 3] lang=\(lang)"),
        ("selection-\(lang)", "kit selection A=[3, 1, 3, 2, 10] lang=\(lang)"),
        ("insertion-\(lang)", "kit insertion A=[b, d, a, c] lang=\(lang)"),
        ("quick-\(lang)", "kit quick A=[5, 1, 4, 2, 8, 3] lang=\(lang)"),
        ("crc-\(lang)", "kit crc data=101001 gen=1101 lang=\(lang)"),
        ("crc2-\(lang)", "kit crc data=1101011011 gen=10011 lang=\(lang)"),
        ("preorder-\(lang)", "kit preorder T=(8 (3 1 6) (10 _ 14)) lang=\(lang)"),
        ("inorder-\(lang)", "kit inorder T=(8 (3 1 6) (10 _ 14)) lang=\(lang)"),
        ("postorder-\(lang)", "kit postorder T=(1 (2 4 5) (3 6 7)) lang=\(lang)"),
        ("levelorder-\(lang)", "kit levelorder T=(1 (2 4 5) (3 _ 7)) lang=\(lang)"),
        ("bfs-\(lang)", "kit bfs G=\"A-B, A-C, B-D, C-D, D-E\" lang=\(lang)"),
        ("dfs-\(lang)", "kit dfs G=\"A->B, A->C, B->D, C->D, D->E\" from=A lang=\(lang)"),
        ("dijkstra-\(lang)", "kit dijkstra G=\"A-B:4, A-C:2, C-B:1, B-D:5, C-D:8, E\" from=A lang=\(lang)"),
    ]
}
cases += [
    ("compare-kits", "title 对比\nscene 停等\n  kit stopwait frames=3 lose=2 lang=zh\nscene 回退 N 步\n  kit gbn frames=6 window=3 lose=2 lang=zh\nscene 选择重传\n  kit sr frames=6 window=3 lose=2 lang=zh"),
    ("arrive-next", "lanes A B C\nstep 一\n  send A -> B \"x\" arrive=next as=m1\n  send A -> C \"y\" lost\nstep 二\n  note B \"收到\"\n  mark m1 done\n  timer B \"T\" start\nstep 三\n  send B -> A \"z\" arrive=next"),
    ("cells", "array A = [3, 1, 2]\nstack S = []\nqueue Q = [a]\nvar i = 0\nrow S Q\nstep 交换\n  swap A[0] A[1]\n  mark A[1] done\n  push S x\n  enqueue Q b\n  say \"提示\"\nstep 出\n  pop S\n  dequeue Q\n  set A[2] = 9\n  set i = 2\n  mark A wrong\n  unmark A[1]"),
    ("seq-standalone", "seq W 0..7 window=3 mod=4\nstep\n  slide W by=2\n  mark W[2..3] done\nstep\n  slide W to=5\n  unmark W[3]"),
    ("structures", "list L = a -> b -> c\npointer p -> L[1]\ntree T = (5 (3 1 4) 8)\ngraph G = A->B:3, B->A, B-C\ngrid D rows=[x, y] cols=[1, 2, 3] = [[1, , 3], [4]]\npointer q -> D[1,1]\nstep 一\n  insert L 1 x\n  link L[3] -> L[0]\n  insert T 9 under 8 right\n  rotate T 5 right\n  set G[A->B] = 7\n  mark G[B-A] done\n  mark G[C] new\n  set G[C] = \"d=1\"\n  set D[0..1,2] = 0\n  mark D[1,0..1] active\n  move q -> D[0,0]\nstep 二\n  remove L 2\n  swap T[3] T[9]\n  remove T 1\n  move p -> null\n  link L[0] -> null"),
    ("sheet", "sheet S\nwrite S[1,0] \"12 4\"\nrule S[1,0..3] above\nlabel S[0] \"商\"\nstep 写\n  write S[2,1] \"x\"\n  arrow S[1..2,3]\n  mark S[1,0..3] active\n  set S[3,0] = \"7\""),
    ("errors", "array A = [1, 2]\nlanes X\nstep s\n  mark A[0] shiny\n  frobnicate\n  swap A[0] A[0..1]\n  mark A[5] active\n  send X -> Y \"m\"\n  timer A \"T\" expire\nkit frobnicate x=1\nkit bubble A=[2, 1] colour=red\nkit sr window=5 mod=8\nkit dijkstra G=\"A-B\""),
    ("empty", ""),
    ("scene-bad", "array A = [1]\nscene 乙\n  array B = [2]\n  step x\n    mark B[0] done"),
]

print("# anim 跨端向量（Mac spike/anim-vectors.swift 生成，安卓 AnimVectorsTest 比对；只许重新生成，别手改）")
for (name, src) in cases {
    let run = AnimEngine.run(src)
    print("== \(name)")
    print("src \(esc(src))")
    print("exp \(esc(AnimKits.expand(src).text))")
    print("title \(esc(run.script.title ?? "-"))")
    print("steps \(run.stepCount) scenes \(run.script.scenes.count)")
    for e in run.errors { print("err \(e.line) \(esc(e.message))") }
    for (i, len) in run.timelineLength.enumerated() { print("tl \(i) \(f3(len))") }
    for i in run.states.indices {
        for k in 0..<run.stepCount { print("st \(i) \(k) \(esc(digest(run.state(scene: i, step: k))))") }
    }
}
