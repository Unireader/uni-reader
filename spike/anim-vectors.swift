// ```anim 跨端向量：Mac 版（参照实现）把一批写法跑一遍，写出 `spike/anim-vectors.txt`；
// 安卓 `shared/anim/` 的 `AnimVectorsTest` 读同一份逐条比对（展开后的文字、报错、每个场景每一步的状态摘要、时序图长度）。
// 比的是「画面上该有什么」，不比坐标（两端字体不同，文字宽度对不上）。改了 Swift 的解析 / 套件 / 执行，重跑本脚本、安卓测试跟着过。
// 运行：
//   mkdir -p build/spike && cp spike/anim-vectors.swift build/spike/main.swift && swiftc Sources/Anim/AnimText.swift Sources/Anim/AnimKits.swift Sources/Anim/AnimKits2.swift Sources/Anim/AnimKits3.swift Sources/Anim/AnimKits4.swift Sources/Anim/AnimKits5.swift Sources/Anim/AnimReference.swift Sources/Anim/AnimState.swift Sources/Anim/AnimStructures.swift build/spike/main.swift -o build/spike/anim-vectors && build/spike/anim-vectors > spike/anim-vectors.txt
import Foundation

func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
}

func f3(_ x: Double) -> String { String(format: "%.3f", x) }

/// 新几种声明的解析结果（方向 / 分层 / 首部字段 / 分组段）：只为这几种写，老的组不多出行（安卓 `AnimVectorsTest.decl` 同一份）。
func decl(_ e: AnimElement) -> String? {
    switch e.kind {
    case .tree(_, let dir) where dir != .down: return "tree dir=\(dir.rawValue)"
    case .graph(_, _, .layers, let dir, let ranks):
        return "graph layers dir=\(dir.rawValue) ranks=" + ranks.map { $0.joined(separator: ",") }.joined(separator: "|")
    case .bits(let fields, let width):
        return "bits w=\(width) f=" + fields.map { "\($0.variable ? "*" : "")\($0.name):\($0.bits)=\($0.value)" }.joined(separator: ",")
    case .packet(let segs, let unit):
        return "packet unit=\(unit) segs=" + segs.map { "\($0.name):\($0.length)" }.joined(separator: ",")
    default: return nil
    }
}

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
    for name in s.bits.keys.sorted() {
        let b = s.bits[name]!
        parts.append("bits:\(name)=" + zip(b.values, b.tones).map { "\($0):\($1.rawValue)" }.joined(separator: ";")
                     + "/" + b.labels.keys.sorted().map { "\($0)=\(b.labels[$0]!)" }.joined(separator: ";"))
    }
    for name in s.packets.keys.sorted() {
        let p = s.packets[name]!
        let groups = p.groups.map { "\(p.index(of: $0.from).map(String.init) ?? "?")..\(p.index(of: $0.to).map(String.init) ?? "?"):\($0.label)" }
        parts.append("packet:\(name)=" + p.segments.map { "\($0.name):\($0.length):\($0.tone.rawValue)" }.joined(separator: ";") + "/" + groups.joined(separator: ";"))
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
        ("page-fifo-\(lang)", "kit page alg=fifo refs=7,0,1,2,0,3,0,4,2,3,0,3,2,1,2,0,1,7,0,1 frames=3 lang=\(lang)"),
        ("page-lru-\(lang)", "kit page alg=lru refs=7,0,1,2,0,3,0,4,2,3,0,3,2 frames=3 lang=\(lang)"),
        ("page-opt-\(lang)", "kit page alg=opt refs=7,0,1,2,0,3,0,4,2,3,0,3,2 frames=3 lang=\(lang)"),
        ("page-clock-\(lang)", "kit page alg=clock refs=1,2,3,4,1,2,5,1,2,3,4,5 frames=3 lang=\(lang)"),
        ("disk-sstf-\(lang)", "kit disk alg=sstf start=100 requests=55,58,39,18,90,160,150,38,184 lang=\(lang)"),
        ("disk-scan-\(lang)", "kit disk alg=scan start=100 requests=55,58,39,18,90,160,150,38,184 dir=down lang=\(lang)"),
        ("disk-cscan-\(lang)", "kit disk alg=cscan start=100 requests=55,58,39,18,90,160,150,38,184 lang=\(lang)"),
        ("disk-look-\(lang)", "kit disk alg=look start=53 requests=98,183,37,122,14,124,65,67 max=199 lang=\(lang)"),
        ("disk-clook-\(lang)", "kit disk alg=clook start=53 requests=98,183,37,122,14,124,65,67 dir=down lang=\(lang)"),
        ("disk-fcfs-\(lang)", "kit disk alg=fcfs start=53 requests=98,183,37,122 lang=\(lang)"),
        ("cache-direct-\(lang)", "kit cache map=direct lines=4 blocks=0,1,4,0,5,1,4 lang=\(lang)"),
        ("cache-set-\(lang)", "kit cache map=set lines=4 ways=2 blocks=0,1,4,0,5,1,8,4 replace=lru lang=\(lang)"),
        ("cache-full-\(lang)", "kit cache map=full lines=3 blocks=1,2,3,1,4,2,5 replace=fifo lang=\(lang)"),
        ("base2-\(lang)", "kit base n=156 to=2 lang=\(lang)"),
        ("base16-\(lang)", "kit base n=1000 to=16 lang=\(lang)"),
        ("kmp-\(lang)", "kit kmp P=abaabcac lang=\(lang)"),
        ("kmp-next-\(lang)", "kit kmp P=aaaab nextval=no lang=\(lang)"),
        ("hash-linear-\(lang)", "kit hash keys=19,14,23,1,68,20,84,27,55,11,10,79 size=13 lang=\(lang)"),
        ("hash-quad-\(lang)", "kit hash keys=0,13,26,39 size=13 probe=quadratic lang=\(lang)"),
        ("heap-\(lang)", "kit heap A=[53, 17, 78, 9, 45, 65, 87, 32] lang=\(lang)"),
        ("heap-sort-\(lang)", "kit heap A=[5, 3, 8, 1, 9] type=min sort=yes lang=\(lang)"),
        ("bsearch-\(lang)", "kit bsearch A=[7, 10, 13, 16, 19, 29, 32, 33, 37, 41, 43] key=37 lang=\(lang)"),
        ("bsearch-miss-\(lang)", "kit bsearch A=[7, 10, 13, 16, 19] key=5 lang=\(lang)"),
        ("tcp-\(lang)", "kit tcp ssthresh=16 rounds=20 timeout=12 dup=17 lang=\(lang)"),
        ("mul-orig-\(lang)", "kit mul method=orig x=-0.1101 y=0.1011 lang=\(lang)"),
        ("mul-booth-\(lang)", "kit mul method=booth x=-0.1101 y=0.1011 lang=\(lang)"),
        ("mul-booth-neg-\(lang)", "kit mul method=booth x=0.101 y=-0.11 lang=\(lang)"),
        ("mul-booth-int-\(lang)", "kit mul method=booth x=-1101 y=1011 lang=\(lang)"),
        ("mul-orig-int-\(lang)", "kit mul method=orig x=111 y=-101 lang=\(lang)"),
        ("div-restore-\(lang)", "kit div method=restore x=0.1011 y=-0.1101 lang=\(lang)"),
        ("div-nonrestore-\(lang)", "kit div method=nonrestore x=-0.1011 y=-0.1101 lang=\(lang)"),
        ("div-nonrestore-fix-\(lang)", "kit div method=nonrestore x=0.0110 y=0.1110 lang=\(lang)"),
        ("div-comp-\(lang)", "kit div method=comp x=0.1000 y=-0.1011 lang=\(lang)"),
        ("div-comp-neg-\(lang)", "kit div method=comp x=-0.0101 y=0.1101 lang=\(lang)"),
        ("hdr-ipv4-\(lang)", "kit header proto=ipv4 lang=\(lang)"),
        ("hdr-ipv6-\(lang)", "kit header proto=ipv6 lang=\(lang)"),
        ("hdr-tcp-\(lang)", "kit header proto=tcp lang=\(lang)"),
        ("hdr-udp-\(lang)", "kit header proto=udp lang=\(lang)"),
        ("hdr-ipv4-hex-\(lang)", "kit header proto=ipv4 hex=\"45 00 00 3c 1c 46 40 00 40 06 b1 e6 ac 10 0a 63 ac 10 0a 0c\" lang=\(lang)"),
        ("hdr-ipv4-opt-\(lang)", "kit header proto=ipv4 hex=\"46 00 00 20 00 01 20 00 3f 11 00 00 0a 00 00 01 0a 00 00 02 01 01 00 00 ff\" lang=\(lang)"),
        ("hdr-tcp-hex-\(lang)", "kit header proto=tcp hex=\"04 89 00 50 0d d6 01 f4 00 00 00 00 70 12 40 00 c0 29 00 00 02 04 05 b4 01 01 04 02 aa\" lang=\(lang)"),
        ("hdr-tcp-fin-\(lang)", "kit header proto=tcp hex=\"00 50 04 89 00 00 00 01 0d d6 01 f5 50 31 40 00 00 00 00 07\" lang=\(lang)"),
        ("hdr-udp-hex-\(lang)", "kit header proto=udp hex=\"0x00 0x44 0x00 0x43 0x01 0x34 0xab 0xcd 0x01\" lang=\(lang)"),
        ("hdr-ipv6-hex-\(lang)", "kit header proto=ipv6 hex=\"6e 12 34 56 00 20 3a 01 20 01 00 00 00 00 00 01 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 01\" lang=\(lang)"),
        ("encap-\(lang)", "kit encap data=100 lang=\(lang)"),
        ("encap-pad-\(lang)", "kit encap data=1 transport=udp net=ipv6 lang=\(lang)"),
        ("encap-small-\(lang)", "kit encap data=5 transport=udp mode=encap lang=\(lang)"),
        ("encap-big-\(lang)", "kit encap data=3000 lang=\(lang)"),
        ("frag-\(lang)", "kit frag total=4000 mtu=1500 id=777 lang=\(lang)"),
        ("frag-576-\(lang)", "kit frag data=3980 mtu=576 header=24 lang=\(lang)"),
        ("frag-df-\(lang)", "kit frag total=4000 mtu=1500 df=1 lang=\(lang)"),
        ("frag-none-\(lang)", "kit frag total=1000 lang=\(lang)"),
        ("ipclass-\(lang)", "kit ipclass lang=\(lang)"),
        ("ipaddr-\(lang)", "kit ipaddr ip=172.16.37.200/20 lang=\(lang)"),
        ("ipaddr-a-\(lang)", "kit ipaddr ip=10.1.2.3 lang=\(lang)"),
        ("ipaddr-b-\(lang)", "kit ipaddr ip=128.0.0.0 lang=\(lang)"),
        ("ipaddr-c-\(lang)", "kit ipaddr ip=192.168.1.255 lang=\(lang)"),
        ("ipaddr-d-\(lang)", "kit ipaddr ip=224.0.0.5 lang=\(lang)"),
        ("ipaddr-e-\(lang)", "kit ipaddr ip=250.1.1.1 lang=\(lang)"),
        ("ipaddr-mask-\(lang)", "kit ipaddr ip=192.168.1.1 mask=255.255.255.252 lang=\(lang)"),
        ("ipaddr-31-\(lang)", "kit ipaddr ip=10.0.0.1/31 lang=\(lang)"),
        ("ipaddr-32-\(lang)", "kit ipaddr ip=127.0.0.1/32 lang=\(lang)"),
        ("ipaddr-0-\(lang)", "kit ipaddr ip=0.0.0.0/0 lang=\(lang)"),
        ("supernet-\(lang)", "kit supernet nets=172.18.129.0/24,172.18.130.0/24,172.18.132.0/24,172.18.133.0/24 lang=\(lang)"),
        ("supernet-exact-\(lang)", "kit supernet nets=[192.168.0.0/24, 192.168.1.0/24, 192.168.0.0/25] lang=\(lang)"),
        ("subnet-hosts-\(lang)", "kit subnet net=192.168.1.0/24 hosts=50 lang=\(lang)"),
        ("subnet-n-\(lang)", "kit subnet net=172.16.0.0/16 n=5 lang=\(lang)"),
        ("lpm-\(lang)", "kit lpm dst=192.168.1.37 routes=\"192.168.1.0/24 R1, 192.168.1.32/27 R2, 192.168.1.64/26 R4, 0.0.0.0/0 R3\" lang=\(lang)"),
        ("lpm-none-\(lang)", "kit lpm dst=10.0.0.1 routes=\"192.168.1.0/24, 172.16.0.0/12 路由器B\" lang=\(lang)"),
    ]
}
cases += [
    ("compare-kits", "title 对比\nscene 停等\n  kit stopwait frames=3 lose=2 lang=zh\nscene 回退 N 步\n  kit gbn frames=6 window=3 lose=2 lang=zh\nscene 选择重传\n  kit sr frames=6 window=3 lose=2 lang=zh"),
    ("arrive-next", "lanes A B C\nstep 一\n  send A -> B \"x\" arrive=next as=m1\n  send A -> C \"y\" lost\nstep 二\n  note B \"收到\"\n  mark m1 done\n  timer B \"T\" start\nstep 三\n  send B -> A \"z\" arrive=next"),
    ("cells", "array A = [3, 1, 2]\nstack S = []\nqueue Q = [a]\nvar i = 0\nrow S Q\nstep 交换\n  swap A[0] A[1]\n  mark A[1] done\n  push S x\n  enqueue Q b\n  say \"提示\"\nstep 出\n  pop S\n  dequeue Q\n  set A[2] = 9\n  set i = 2\n  mark A wrong\n  unmark A[1]"),
    ("seq-standalone", "seq W 0..7 window=3 mod=4\nstep\n  slide W by=2\n  mark W[2..3] done\nstep\n  slide W to=5\n  unmark W[3]"),
    ("structures", "list L = a -> b -> c\npointer p -> L[1]\ntree T = (5 (3 1 4) 8)\ngraph G = A->B:3, B->A, B-C\ngrid D rows=[x, y] cols=[1, 2, 3] = [[1, , 3], [4]]\npointer q -> D[1,1]\nstep 一\n  insert L 1 x\n  link L[3] -> L[0]\n  insert T 9 under 8 right\n  rotate T 5 right\n  set G[A->B] = 7\n  mark G[B-A] done\n  mark G[C] new\n  set G[C] = \"d=1\"\n  set D[0..1,2] = 0\n  mark D[1,0..1] active\n  move q -> D[0,0]\nstep 二\n  remove L 2\n  swap T[3] T[9]\n  remove T 1\n  move p -> null\n  link L[0] -> null"),
    ("sheet", "sheet S\nwrite S[1,0] \"12 4\"\nrule S[1,0..3] above\nlabel S[0] \"商\"\nstep 写\n  write S[2,1] \"x\"\n  arrow S[1..2,3]\n  mark S[1,0..3] active\n  set S[3,0] = \"7\""),
    ("errors", "array A = [1, 2]\nlanes X\nstep s\n  mark A[0] shiny\n  frobnicate\n  swap A[0] A[0..1]\n  mark A[5] active\n  send X -> Y \"m\"\n  timer A \"T\" expire\nkit frobnicate x=1\nkit bubble A=[2, 1] colour=red\nkit sr window=5 mod=8\nkit dijkstra G=\"A-B\"\nkit page alg=lru refs=1,2 frames=9\nkit cache map=set lines=5 ways=2 blocks=1\nkit tcp rounds=5 timeout=3 dup=3\nkit heap A=[1, 1]\nkit div x=0.11 y=0.1\nkit mul x=1.1 y=0.1\nkit div method=restore x=0.1 y=0.1111111\nkit mul x=1101 y=0.1\nkit div x=101 y=1101"),
    ("empty", ""),
    ("dir-layers", "tree R dir=right = (A (B D E) (C _ F))\ntree U dir=up = (1 2 3)\ntree L dir=left\ngraph SDN layout=layers dir=down layers=[[控制器], [S1, S2, S3], [H1, H2]] = 控制器-S1, 控制器-S2, 控制器-S3, S1-S3, S1-H1, S3-H2\ngraph G layout=layers = A-B, B-C\ngraph K layers=[[A, Z], [B]] = A->B:3\npointer p -> SDN[S1]\nstep x\n  insert L 1\n  insert R G under C left\n  mark SDN[S1-S3] done\n  move p -> SDN[H1]"),
    ("bits-packet", "bits H width=16 = A:4, B:4=7, 名 字:8, 可变:*\nlabel H[1] \"FF FF\"\npacket P unit=B = 数据:100\ngroup P[0..0] \"数据\"\nstep a\n  set H[2] = 9\n  mark H[0..1] active\n  set H[可变] = \"v\"\n  insert P 0 \"TCP首部:20\"\n  group P[0..1] \"段\"\nstep b\n  insert P 0 \"IP首部:20\"\n  group P[0..2] \"数据报\"\n  label H[0] \"x\"\n  mark H done\nstep c\n  remove P 0\n  set P[1] = \"数据:50\"\n  mark P[1] done\n  unmark H[0]"),
    ("bits-packet-errors", "bits H = A:4, B:x\nbits J width=8 = A:200\nbits K width=100 = A:1\ngraph G layers=[[A], [B]] = A-B, B-C\ngraph G2 layers=[[A], [A, B]] = A-B\ngraph G3 layout=circle dir=down = A-B\ngraph G4 layout=circle layers=[[A], [B]] = A-B\ntree T dir=north = (1)\npacket P = a:1\narray A = [1]\nstep x\n  group P[0..3] \"y\"\n  group A[0] \"y\"\n  remove P 5\n  insert P 9 \"z\"\n  set P[3] = \"q\"\n  mark P[0..4] done\n  label P[0] \"n\"\nkit header proto=icmp\nkit header hex=\"45 00\"\nkit header proto=ipv4 hex=\"4g\"\nkit header proto=ipv4 hex=\"47 00 00 3c 1c 46 40 00 40 06 b1 e6 ac 10 0a 63 ac 10 0a 0c\"\nkit header proto=ipv6 hex=\"45 00 00 3c 1c 46 40 00 40 06 b1 e6 ac 10 0a 63 ac 10 0a 0c 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\"\nkit header proto=tcp hex=\"04 89 00 50 0d d6 01 f4 00 00 00 00 30 02 40 00 c0 29 00 00\"\nkit encap data=0\nkit frag mtu=1500\nkit frag total=4000 data=3980\nkit frag total=4000 mtu=100\nkit frag total=4000 header=22\nkit frag total=100 mtu=30"),
    ("ip-errors", "kit ipaddr ip=256.1.1.1\nkit ipaddr ip=1.2.3.4/33\nkit ipaddr ip=1.2.3.4/8 mask=255.0.0.0\nkit ipaddr ip=1.2.3.4 mask=255.0.255.0\nkit ipaddr\nkit supernet nets=10.0.0.0/8\nkit supernet nets=10.0.0.1/8,10.1.0.0/16\nkit supernet nets=10.0.0.0,10.1.0.0/16\nkit subnet net=192.168.1.5/24 n=4\nkit subnet net=10.0.0.0/8 hosts=1000\nkit subnet net=192.168.1.0/30 n=2\nkit subnet net=192.168.1.0/24 n=2 hosts=3\nkit subnet net=192.168.1.0/24\nkit subnet net=192.168.1.0 n=2\nkit lpm dst=1.2.3.4\nkit lpm dst=1.2.3.4 routes=\"1.2.3.0 R\"\nkit lpm dst=1.2.3.4 routes=\"1.2.3.5/24 R\"\nkit ipclass x=1"),
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
    for (i, scene) in run.script.scenes.enumerated() {
        for e in scene.elements { if let d = decl(e) { print("el \(i) \(e.name) \(esc(d))") } }
    }
    for e in run.errors { print("err \(e.line) \(esc(e.message))") }
    for (i, len) in run.timelineLength.enumerated() { print("tl \(i) \(f3(len))") }
    for i in run.states.indices {
        for k in 0..<run.stepCount { print("st \(i) \(k) \(esc(digest(run.state(scene: i, step: k))))") }
    }
}
