// 语义搜索质量评估（对着真实搜索索引，只读）。
// 用法：swift spike/semantic-eval.swift <SearchIndex/*.sqlite>
// 每问一句「换说法」的话（不含目标术语），看本机模型向量检索前 10 块里有没有含目标术语的块；
// 对照：字二元组词袋（关键词基线）与随机抽取的期望命中率。
import Foundation
import NaturalLanguage
import SQLite3

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
var db: OpaquePointer?
guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { fatalError("open \(path)") }

struct Chunk { let id: Int64; let kind: String; let title: String; let body: String; let norm: String; var vec: [Int8] }
var chunks: [Chunk] = []
var st: OpaquePointer?
sqlite3_prepare_v2(db, "SELECT c.id, c.kind, c.title, c.body, c.norm, v.v FROM chunk c JOIN vec v ON v.chunk_id = c.id WHERE v.model = 'system-cjk'", -1, &st, nil)
while sqlite3_step(st) == SQLITE_ROW {
    let n = Int(sqlite3_column_bytes(st, 5))
    let p = sqlite3_column_blob(st, 5)!.assumingMemoryBound(to: Int8.self)
    chunks.append(Chunk(id: sqlite3_column_int64(st, 0), kind: String(cString: sqlite3_column_text(st, 1)),
                        title: String(cString: sqlite3_column_text(st, 2)), body: String(cString: sqlite3_column_text(st, 3)),
                        norm: String(cString: sqlite3_column_text(st, 4)), vec: Array(UnsafeBufferPointer(start: p, count: n))))
}
sqlite3_finalize(st)
print("块数（system-cjk 向量）：\(chunks.count)")

guard let model = NLContextualEmbedding(language: .simplifiedChinese) else { fatalError("no model") }
try model.load()
func embed(_ text: String) -> [Float] {
    let r = try! model.embeddingResult(for: text, language: .simplifiedChinese)
    var sum = [Double](repeating: 0, count: model.dimension); var n = 0.0
    r.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { v, _ in
        for i in 0..<min(v.count, sum.count) { sum[i] += v[i] }; n += 1; return true
    }
    let f = sum.map { Float($0 / max(n, 1)) }
    let l = f.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return f.map { $0 / l }
}
func bigrams(_ s: String) -> Set<String> {
    let a = Array(s); guard a.count > 1 else { return [String(s)] }
    return Set((0..<(a.count - 1)).map { String(a[$0...$0 + 1]) })
}

// (换说法的问题, 目标术语——块里出现任何一个就算相关)
let cases: [(String, [String])] = [
    ("两个进程都在等对方释放手里的资源，谁也走不下去", ["死锁"]),
    ("几个进程同时改一个共享变量会出错，要让它们一个一个进去", ["互斥", "临界区"]),
    ("内存满了要把某一页换出去，挑哪一页", ["置换算法", "页面置换", "lru", "fifo"]),
    ("频繁地换进换出页面，CPU 几乎都在忙这个", ["抖动", "颠簸"]),
    ("运行时间最短的任务先上处理机", ["短作业优先", "sjf"]),
    ("程序里的逻辑地址怎么变成内存里真正的位置", ["地址变换", "地址转换", "页表"]),
    ("加快地址变换的一块小而快的相联存储器", ["快表", "tlb"]),
    ("磁头在磁道之间移动的先后顺序怎么安排", ["磁盘调度", "scan", "电梯", "sstf"]),
    ("分配资源之前先算一下系统会不会进入不安全状态", ["银行家", "安全序列"]),
    ("用一个整数和一个等待队列来实现进程同步的工具", ["信号量"]),
    ("发送端发得太快，接收端来不及处理", ["流量控制"]),
    ("网络里数据太多、路由器排队丢包，发送方主动减速", ["拥塞控制", "拥塞窗口", "慢开始"]),
    ("正式传数据之前双方先确认彼此都能收发", ["三次握手", "连接建立"]),
    ("把网站名字翻译成数字地址", ["dns", "域名"]),
    ("知道对方的网络层地址，求它的硬件地址", ["arp"]),
    ("大家共用一条线路，同时发送撞在一起怎么办", ["csma", "冲突", "碰撞"]),
    ("把一个大网络切成几个小网络", ["子网划分", "子网掩码", "cidr"]),
    ("传输过程中有的位翻转了，接收方怎么发现", ["检错", "crc", "循环冗余", "校验"]),
    ("不等确认就连续发好几帧", ["滑动窗口", "后退n帧", "gbn", "选择重传"]),
    ("内网的私有地址出去上网时换成公网地址", ["nat", "网络地址转换"]),
    ("先进来的元素先出去的线性结构", ["队列"]),
    ("每个结点最多只有左右两个孩子", ["二叉树"]),
    ("任意结点左右两边高度相差不超过 1", ["平衡二叉树", "avl", "平衡因子"]),
    ("根据关键字直接算出它该放在哪个位置", ["散列", "哈希"]),
    ("用最少的总边权把所有顶点连起来", ["最小生成树", "prim", "kruskal"]),
    ("从一个顶点出发到其他每个顶点的最近距离", ["dijkstra", "最短路径"]),
    ("每一趟比较相邻两个元素，逆序就交换", ["冒泡"]),
    ("选一个基准把序列分成比它小和比它大的两部分", ["快速排序", "枢轴", "划分"]),
    ("处理器与主存速度差太多，中间加一层小而快的存储", ["cache", "高速缓存"]),
    ("几条指令的不同阶段重叠着同时执行", ["流水线"]),
    ("负数在机器里表示：按位取反再加一", ["补码"]),
    ("外部设备做完事情后打断处理器让它来处理", ["中断"]),
    ("外设不经过处理器直接和内存成块交换数据", ["dma"]),
]
// 字面相同的对照组：问题里就含术语
let literal: [(String, [String])] = [
    ("死锁的四个必要条件", ["死锁"]), ("TCP 拥塞控制的慢开始和拥塞避免", ["拥塞"]),
    ("平衡二叉树的旋转", ["平衡二叉树", "avl"]), ("Cache 和主存的映射方式", ["cache"]),
    ("DMA 方式的特点", ["dma"]), ("快速排序的时间复杂度", ["快速排序"]),
]

func run(_ name: String, _ set: [(String, [String])], show: Bool) {
    var semHit = 0, semTop1 = 0, kwHit = 0, kwTop1 = 0, rr = 0.0, randExp = 0.0
    print("\n==== \(name)（\(set.count) 问）====")
    for (q, terms) in set {
        let rel = Set(chunks.indices.filter { i in terms.contains { chunks[i].norm.contains($0) } })
        let p = Double(rel.count) / Double(chunks.count)
        randExp += 1 - pow(1 - p, 10)
        let qv = embed(q).map { Int8(max(-127, min(127, ($0 * 127).rounded()))) }
        let sem = chunks.indices.map { i -> (Int, Int32) in
            var s: Int32 = 0; let v = chunks[i].vec
            for d in 0..<min(v.count, qv.count) { s &+= Int32(v[d]) * Int32(qv[d]) }
            return (i, s)
        }.sorted { $0.1 > $1.1 }.prefix(10).map { $0.0 }
        let qb = bigrams(q.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation })
        let kw = chunks.indices.map { i -> (Int, Double) in
            let cb = bigrams(chunks[i].norm); return (i, Double(qb.intersection(cb).count) / sqrt(Double(cb.count) + 20))
        }.sorted { $0.1 > $1.1 }.prefix(10).map { $0.0 }
        let sRank = sem.firstIndex { rel.contains($0) }
        let kRank = kw.firstIndex { rel.contains($0) }
        if sRank != nil { semHit += 1 }; if sRank == 0 { semTop1 += 1 }
        if kRank != nil { kwHit += 1 }; if kRank == 0 { kwTop1 += 1 }
        rr += sRank.map { 1.0 / Double($0 + 1) } ?? 0
        let tag = { (r: Int?) in r.map { "第\($0 + 1)" } ?? "  ✗ " }
        print("语义\(tag(sRank)) 关键词\(tag(kRank)) 相关占比\(String(format: "%5.1f%%", p * 100))  \(q)")
        if show {
            for i in sem.prefix(3) {
                let b = chunks[i].body.replacingOccurrences(of: "\n", with: " ").prefix(60)
                print("      \(rel.contains(i) ? "✓" : "·") [\(chunks[i].kind)] \(b)")
            }
        }
    }
    let n = Double(set.count)
    print(String(format: "语义：前10命中 %d/%d，首位 %d/%d，MRR@10 %.2f", semHit, set.count, semTop1, set.count, rr / n))
    print(String(format: "关键词（字二元组）：前10命中 %d/%d，首位 %d/%d", kwHit, set.count, kwTop1, set.count))
    print(String(format: "随机抽 10 块的期望命中：%.1f/%d", randExp, set.count))
}
run("换说法", cases, show: CommandLine.arguments.contains("--show"))
run("字面相同", literal, show: false)
