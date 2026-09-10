import Foundation

/// 一次「打开 / 切到文档」的耗时账本：从点下去那一刻起，到**可见页的页图与笔迹都画出来**为止。
///
/// 用户 2026-09-10 报「有时候打开 tab 挺久才显示完整页面 + 笔迹」——这种「有时候」只能靠逐次记账
/// 才抓得住：每次打开一条记录，同步分段（开 PDF / 读库各项）+ 里程碑（种子 / 布局 / 定基准 /
/// 首批请求 / 每页页图落地 / 每页笔迹首绘），完成或中断时一行摘要进 `wsLog`
/// （`touch ~/Library/Logs/UniReader-ws.log` 开），同时留在 `OpenStats.records` 里给设置页看。
///
/// 完成判定：`visible`（最近一次几何回报的可见页范围）里每一页都有**当前宽度**的页图，
/// 且有笔迹的页都至少画过一次墨迹层。恢复进度会让视口在首帧之后再跳一次，所以可见范围
/// 每次几何回报都刷新，以最后那次为准。30s 未齐按超时结账，账不会丢。
///
/// 全部在主线程上记（渲染回调回主线程、Canvas 绘制也在主线程），不加锁。
@MainActor
final class OpenTrace {
    struct Phase { let name: String; let ms: Double; let detail: String }
    struct Mark { let name: String; let atMs: Double; let detail: String }

    /// 结清后的值类型记录（设置页显示 / 日志摘要）。
    struct Record: Identifiable {
        let id: UUID
        let title: String
        let reason: String
        let startedAt: Date
        let outcome: String          // 完成 / 超时 / 中断：…
        let totalMs: Double
        let loadMs: Double           // 同步装载段合计（`select` 里那一串读库/开 PDF）
        let phases: [Phase]
        let marks: [Mark]
        let imagesLine: String
        let inkLine: String

        /// 单行摘要（日志用）。
        var summary: String {
            let ph = phases.map { "\($0.name) \(Int($0.ms.rounded()))" + ($0.detail.isEmpty ? "" : "(\($0.detail))") }
                .joined(separator: " · ")
            let mk = marks.map { "\($0.name) +\(Int($0.atMs.rounded()))" + ($0.detail.isEmpty ? "" : "(\($0.detail))") }
                .joined(separator: " · ")
            return "打开「\(title)」(\(reason)) \(outcome) 总 \(Int(totalMs.rounded()))ms"
                + " | 装载 \(Int(loadMs.rounded()))ms[\(ph)]"
                + " | \(mk)"
                + " | \(imagesLine) | \(inkLine)"
        }
    }

    let id = UUID()
    let title: String
    let reason: String
    let startedAt = Date()
    private let t0 = CFAbsoluteTimeGetCurrent()
    private(set) var phases: [Phase] = []
    private(set) var marks: [Mark] = []
    private var markedOnce = Set<String>()
    private(set) var finished = false

    // 视图侧：可见范围 / 当前目标宽度 / 各页笔数 / 各页页图与墨迹落地时刻
    private var visible: ClosedRange<Int>?
    private var targetWidth = 0
    private var strokesByPage: [Int: Int] = [:]
    private var imageAt: [Int: (ms: Double, source: String, width: Int)] = [:]
    private var inkAt: [Int: (ms: Double, strokes: Int, drawMs: Double)] = [:]

    init(title: String, reason: String) {
        self.title = title
        self.reason = reason
        // 超时兜底：只捕获弱引用，账本被别人结清/丢弃后这一下什么都不做。
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !self.finished else { return }
            self.finish("超时（未齐）")
        }
    }

    private var elapsedMs: Double { (CFAbsoluteTimeGetCurrent() - t0) * 1000 }

    /// 「刚开的账、视图还没上过任何一笔」——`TabsModel.activate` 在同一轮里先 `realize()`（开账）
    /// 再 `prepareForReactivation()`，后者据此沿用这本账，而不是把它当成上一次没齐的旧账作废。
    var isFreshWithoutView: Bool { !finished && elapsedMs < 2000 && visible == nil && markedOnce.isEmpty }

    /// 同步分段计时（装载那一串）。
    @discardableResult
    func phase<T>(_ name: String, detail: @autoclosure () -> String = "", _ body: () throws -> T) rethrows -> T {
        let s = CFAbsoluteTimeGetCurrent()
        defer { phases.append(Phase(name: name, ms: (CFAbsoluteTimeGetCurrent() - s) * 1000, detail: detail())) }
        return try body()
    }

    /// 里程碑（相对 t0 的毫秒）。
    func mark(_ name: String, _ detail: String = "") {
        guard !finished else { return }
        marks.append(Mark(name: name, atMs: elapsedMs, detail: detail))
    }

    /// 只记第一次（视图的 `init`/首帧这类会被 SwiftUI 反复走到的地方用）。
    func markOnce(_ name: String, _ detail: String = "") {
        guard markedOnce.insert(name).inserted else { return }
        mark(name, detail)
    }

    /// 视图每次 body 求值报一次：此刻的可见页范围、目标页图宽度、各可见页的笔数。
    func noteViewport(_ range: ClosedRange<Int>, width: Int, strokes: [Int: Int]) {
        guard !finished else { return }
        if visible != range { markOnce("可见页", "p\(range.lowerBound + 1)–\(range.upperBound + 1)") }
        visible = range
        targetWidth = width
        strokesByPage.merge(strokes) { _, new in new }
        checkComplete()
    }

    /// 某页拿到了 `width` 宽的页图（种子 / 缓存 / 渲染）。同一页只记第一次到达当前宽度的那次。
    func noteImage(page: Int, width: Int, source: String) {
        guard !finished else { return }
        if let cur = imageAt[page], cur.width == width { return }
        imageAt[page] = (elapsedMs, source, width)
        if imageAt.count == 1 { markOnce("首张页图", "p\(page + 1) \(source)") }
        checkComplete()
    }

    /// 某页的静态墨迹层画了一次（Canvas 绘制闭包里报）。
    func noteInkDraw(page: Int, strokes: Int, ms: Double) {
        guard !finished, inkAt[page] == nil else { return }
        inkAt[page] = (elapsedMs, strokes, ms)
        if inkAt.count == 1 { markOnce("首页墨迹", "p\(page + 1) \(strokes)笔 绘\(Int(ms.rounded()))ms") }
        checkComplete()
    }

    /// 笔迹还在后台解码（`DocSession.inkLoading`）：可见页此刻笔数为 0 是假象，别提前结账。
    var inkPending = false

    private func checkComplete() {
        guard let visible, targetWidth > 0, !inkPending else { return }
        for p in visible {
            guard let img = imageAt[p], img.width == targetWidth else { return }
            if (strokesByPage[p] ?? 0) > 0, inkAt[p] == nil { return }
        }
        finish("完成")
    }

    /// 结账（完成 / 超时 / 中断）。幂等。
    func finish(_ outcome: String) {
        guard !finished else { return }
        finished = true
        let total = elapsedMs
        let loadMs = phases.reduce(0) { $0 + $1.ms }
        // 页图那一行：可见页里各来源几张、最晚一张何时到
        var imagesLine = "页图 无可见页"
        var inkLine = "墨迹 无"
        if let visible {
            let vis = Array(visible)
            let got = vis.compactMap { imageAt[$0] }
            // 来源串形如「磁盘12ms」/「渲染163ms」/「缓存」：按种类归并，毫秒累加。
            var bySource: [String: (n: Int, ms: Int)] = [:]
            for g in got {
                let kind = String(g.source.prefix { !$0.isNumber })
                let ms = Int(g.source.drop { !$0.isNumber }.prefix { $0.isNumber }) ?? 0
                bySource[kind, default: (0, 0)].n += 1
                bySource[kind, default: (0, 0)].ms += ms
            }
            let srcDesc = bySource.sorted { $0.key < $1.key }
                .map { "\($0.key)\($0.value.n)" + ($0.value.ms > 0 ? "(\($0.value.ms)ms)" : "") }
                .joined(separator: " ")
            let last = got.map(\.ms).max() ?? 0
            imagesLine = got.count == vis.count
                ? "页图齐 +\(Int(last.rounded()))ms（\(srcDesc)）"
                : "页图 \(got.count)/\(vis.count) 张（\(srcDesc)）"
            let inkPages = vis.filter { (strokesByPage[$0] ?? 0) > 0 }
            if inkPages.isEmpty {
                inkLine = "墨迹 无"
            } else {
                let drawn = inkPages.compactMap { inkAt[$0] }
                let strokes = inkPages.reduce(0) { $0 + (strokesByPage[$1] ?? 0) }
                let drawMs = drawn.reduce(0) { $0 + $1.drawMs }
                let lastInk = drawn.map(\.ms).max() ?? 0
                inkLine = drawn.count == inkPages.count
                    ? "墨迹齐 +\(Int(lastInk.rounded()))ms（\(inkPages.count)页 \(strokes)笔 绘\(Int(drawMs.rounded()))ms）"
                    : "墨迹 \(drawn.count)/\(inkPages.count) 页（\(strokes)笔）"
            }
        }
        let rec = Record(id: id, title: title, reason: reason, startedAt: startedAt, outcome: outcome,
                         totalMs: total, loadMs: loadMs, phases: phases, marks: marks,
                         imagesLine: imagesLine, inkLine: inkLine)
        OpenStats.append(rec, trace: self)
    }
}

extension Optional where Wrapped == OpenTrace {
    /// 没开账（`nil`）时照常执行、不记；有账就分段计时。装载那一串每步都包一层，调用处不必判空。
    @MainActor @discardableResult
    func phase<T>(_ name: String, detail: @autoclosure () -> String = "", _ body: () throws -> T) rethrows -> T {
        guard let t = self else { return try body() }
        return try t.phase(name, detail: detail(), body)
    }
}

/// 打开耗时的全局台账：进行中的按 docKey 查（笔迹层只知道 docKey），结清的留最近 20 条给设置页。
@MainActor
enum OpenStats {
    static let keep = 20
    private(set) static var records: [OpenTrace.Record] = []   // 最新在前
    private static var active: [String: OpenTrace] = [:]        // docKey → 进行中

    /// 让视图层（`ReaderSurface`）与笔迹层（`InkStaticLayer`）按 docKey 找到进行中的账本。
    static func bind(_ trace: OpenTrace, docKey: String) {
        guard !docKey.isEmpty else { return }
        if let old = active[docKey], old !== trace { old.finish("中断：同文档再次打开") }
        active[docKey] = trace
    }

    static func trace(docKey: String) -> OpenTrace? { active[docKey] }

    fileprivate static func append(_ rec: OpenTrace.Record, trace: OpenTrace) {
        for (k, t) in active where t === trace { active.removeValue(forKey: k) }
        records.insert(rec, at: 0)
        if records.count > keep { records.removeLast(records.count - keep) }
        wsLog(rec.summary)
    }
}
