import Foundation
import CoreGraphics

/// 草稿纸的落墨链路与三端同步（AppModel 的一块，抽文件是因为 `AppModel.swift` 已近千行）。
///
/// 唯一要记住的：**草稿纸打开时，笔的坐标是画布坐标，不是页内归一化**（见 `ScratchPad` 的坐标系
/// 契约）。因此 `ink`/`erase` 这两条 RT 消息在草稿纸打开时被整条拦下改走本文件，`page` 字段作废。
/// 线格式一个字节都没改——Mac 是「哪张纸开着」的唯一真源，两端据此用同一套解释。
extension AppModel {

    // MARK: - 平板上行：草稿纸上的笔

    /// 草稿纸打开时的 `ink`/`erase`/`probe`。返回 true = 已消费（调用方不要再按页内笔迹处理）。
    func handleScratchInput(_ obj: [String: Any], to s: DocSession) -> Bool {
        guard let padId = s.openPadID else { return false }
        let type = obj["type"] as? String
        // 攒着的擦除点先落地，后面的消息（落笔、框选、剪贴板…）才能看到擦过的样子，与逐条处理时的先后一致
        if type != "erase" { flushScratchErase() }
        switch type {
        case "ink":
            let phase = obj["phase"] as? String ?? ""
            if phase == "begin" {
                let pen = obj["pen"] as? [String: Any]
                // 直线（尺子）笔：整笔恒为「起点 + 当前终点」，后续 move 是**替换终点**而不是追加
                // （吸附已在平板侧算完）。与页内笔迹同一个标记，见 PROTOCOL.md §4.3 ink begin flags。
                padInkLine = (obj["line"] as? Bool) ?? false
                // 相对粗细模式：pad 已按它自己的画布缩放折算好 `w`（PROTOCOL.md `relInk`），这里原样用。
                scratchInkBegin(in: s, pad: padId,
                                color: InkColor.parse(pen?["color"] as? String),
                                width: (pen?["w"] as? NSNumber)?.doubleValue ?? 8,
                                type: PenBrushType(rawValue: pen?["t"] as? String ?? "") ?? .ballpoint,
                                points: scratchPoints(obj["pts"]))
            } else if phase == "move" {
                let pts = scratchPoints(obj["pts"])
                if padInkLine { scratchInkLineTo(pts.last, in: s) } else { scratchInkAppend(pts, in: s) }
            } else if phase == "end" {
                scratchInkEnd(in: s)
            }
            return true
        case "erase":
            if obj["phase"] as? String == "move" {
                scratchPadErasing = true
                armScratchEraseIdle()
                queueScratchErase(scratchPoints(obj["pts"]), in: s)
            } else if obj["phase"] as? String == "end" {
                finishScratchPadErase()   // 里面先把攒着的点擦掉
            }
            return true
        case "probe":
            // 草稿纸上不做长按环形选笔盘：那套判定（`beginLongPressWatch`）全建立在页内归一化坐标
            // 与 `padPageWidth` 上，喂画布坐标进去阈值会整个失真。平板侧同样不呼盘。
            return true
        case "lassoMove", "lassoScale":
            // 纸上的框选（`PROTOCOL.md §4.4`）：选区多边形 / 位移 / 锚点都是画布坐标，`page` 作废
            applyScratchLasso(obj, in: s, pad: padId)
            return true
        case "clip":
            applyScratchClip(obj, in: s, pad: padId)
            return true
        default:
            return false
        }
    }

    // MARK: - 平板上行：纸上的框选移动 / 缩放与剪贴板（画布坐标）

    /// 按消息里的选区在真源上复判命中：纸上这张的笔迹，任一点落在多边形内（无多边形尾部时退回 x0..y1 矩形）。
    /// 与 Mac 本机 `ScratchPadNSView.finishLassoSelect` 的笔迹那一半同一口径；平板上的框选只作用于笔迹，不碰图片。
    private func scratchLassoHits(_ obj: [String: Any], in s: DocSession, pad: UUID) -> [Int] {
        var poly: [SIMD2<Double>]?
        if let flat = obj["poly"] as? [Any], flat.count >= 6 {
            let v = flat.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
            poly = stride(from: 0, to: v.count - v.count % 2, by: 2).map { SIMD2(v[$0], v[$0 + 1]) }
        }
        let x0 = (obj["x0"] as? NSNumber)?.doubleValue ?? 0, y0 = (obj["y0"] as? NSNumber)?.doubleValue ?? 0
        let x1 = (obj["x1"] as? NSNumber)?.doubleValue ?? 0, y1 = (obj["y1"] as? NSNumber)?.doubleValue ?? 0
        let rect = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        func hit(_ p: InkPoint) -> Bool {
            if let poly { return InkEdit.pointInPolygon(SIMD2(p.dx, p.dy), polygon: poly) }
            return rect.contains(CGPoint(x: p.dx, y: p.dy))
        }
        return s.scratchStrokes.indices.filter { i in
            s.scratchStrokes[i].padId == pad && s.scratchStrokes[i].points.contains(where: hit)
        }
    }

    /// `lassoMove` / `lassoScale` 落在纸上：复判命中 → 平移 / 缩放（`InkEdit.canvasTranslated/canvasScaled`，
    /// 与 Mac 本机框选同一份）→ 进撤销栈 → 广播。**零命中也回传镜像**：平板提交后在等回推结算本地预览。
    private func applyScratchLasso(_ obj: [String: Any], in s: DocSession, pad: UUID) {
        let isScale = obj["type"] as? String == "lassoScale"
        let hits = scratchLassoHits(obj, in: s, pad: pad)
        if isScale {
            let a = SIMD2((obj["ax"] as? NSNumber)?.doubleValue ?? 0, (obj["ay"] as? NSNumber)?.doubleValue ?? 0)
            let sx = (obj["sx"] as? NSNumber)?.doubleValue ?? 1, sy = (obj["sy"] as? NSNumber)?.doubleValue ?? 1
            if !hits.isEmpty, sx > 0, sy > 0, sx != 1 || sy != 1 {
                s.scratchEdit("Resize", kind: .scale) {
                    for i in hits { s.scratchStrokes[i] = InkEdit.canvasScaled(s.scratchStrokes[i], anchor: a, sx: sx, sy: sy) }
                }
            }
        } else {
            let dx = (obj["dx"] as? NSNumber)?.doubleValue ?? 0, dy = (obj["dy"] as? NSNumber)?.doubleValue ?? 0
            if !hits.isEmpty, dx != 0 || dy != 0 {
                s.scratchEdit("Move", kind: .move) {
                    for i in hits { s.scratchStrokes[i] = InkEdit.canvasTranslated(s.scratchStrokes[i], dx: dx, dy: dy) }
                }
            }
        }
        PadLog.log("纸上框选\(isScale ? "缩放" : "移动") 命中 \(hits.count) 条")
        broadcastScratchStrokes()
    }

    /// 纸上的剪切 / 复制 / 粘贴。剪贴板是 Mac 系统剪贴板（`space = .canvas`，粘回页里时由 `InkPaste` 折算）；
    /// 粘贴落点 `nx/ny` 是平板视口正中的**画布坐标**。
    private func applyScratchClip(_ obj: [String: Any], in s: DocSession, pad: UUID) {
        let op = obj["op"] as? String ?? "copy"
        if op == "paste" {
            guard let clip = InkClipboard.read() else { PadLog.log("平板 clip paste：剪贴板空"); return }
            let center = CGPoint(x: (obj["nx"] as? NSNumber)?.doubleValue ?? 0, y: (obj["ny"] as? NSNumber)?.doubleValue ?? 0)
            let out = InkPaste.placeOnCanvas(strokes: clip.strokes, space: clip.space,
                                             sourceAspect: clip.aspect, pad: pad, center: center)
            guard !out.isEmpty else { return }
            s.scratchEdit("Paste", kind: .paste) { s.scratchStrokes.append(contentsOf: out) }
            PadLog.log("平板 clip paste：纸上 \(out.count) 条")
            broadcastScratchStrokes()
            return
        }
        let hits = scratchLassoHits(obj, in: s, pad: pad)
        guard !hits.isEmpty else {
            PadLog.log("平板 clip \(op)：纸上零命中")
            if op == "cut" { broadcastScratchStrokes() }   // 平板剪切时已乐观删掉，零命中要把它们送回去
            return
        }
        let picked = hits.map { s.scratchStrokes[$0] }
        InkClipboard.write(strokes: picked, space: .canvas)
        PadLog.log("平板 clip \(op)：纸上 \(picked.count) 条")
        guard op == "cut" else { return }
        let gone = Set(picked.map(\.id))
        s.scratchEdit("Delete", kind: .delete) { s.scratchStrokes.removeAll { gone.contains($0.id) } }
        broadcastScratchStrokes()
    }

    /// 线上点集 → 画布坐标点（与页内的 `points(_:)` 同结构，只是不再是 0~1）。
    private func scratchPoints(_ any: Any?) -> [InkPoint] {
        guard let raw = any as? [[NSNumber]] else { return [] }
        return raw.map { p in
            InkPoint(p.count > 0 ? p[0].floatValue : 0,
                     p.count > 1 ? p[1].floatValue : 0,
                     p.count > 2 ? p[2].floatValue : 0.5)
        }
    }

    // MARK: - 落墨 API（平板上行与 Mac 本机落墨共用，同 `inkBegin` 一族的分工）

    func scratchInkBegin(in s: DocSession, pad: UUID, color: InkColor, width: Double,
                         type: PenBrushType = .ballpoint, points: [InkPoint]) {
        s.scratchLive = InkStroke(page: 0, color: color, width: width, type: type,
                                  points: points, padId: pad)
    }

    func scratchInkAppend(_ pts: [InkPoint], in s: DocSession) {
        guard var st = s.scratchLive else { return }
        st.points.append(contentsOf: pts)
        s.scratchLive = st
    }

    /// 直线（尺子）笔：整笔恒为「起点 → 当前终点」两点，新点替换终点（同 `inkLineTo`，
    /// 压感同样取这一笔的峰值、两端同值——理由见那里）。
    func scratchInkLineTo(_ p: InkPoint?, in s: DocSession) {
        guard let p, var st = s.scratchLive, let a = st.points.first else { return }
        let z = AppModel.linePressure(st.points, p)
        st.points = [InkPoint(a.x, a.y, z), InkPoint(p.x, p.y, z)]
        s.scratchLive = st
    }

    func scratchInkEnd(in s: DocSession) {
        guard let st = s.scratchLive else { return }
        s.scratchLive = nil
        guard st.points.count >= 1 else { return }
        s.scratchStrokes.append(st)   // @Published → ContentView 对账落库 + 广播
        s.scratchUndo.recordAdded(label: "Draw", kind: .draw, strokes: [st])   // 同 `inkEnd`：纯追加免 diff
    }

    /// 抬笔前放弃这一笔（关草稿纸/切纸时用）。
    func scratchInkCancel(in s: DocSession) {
        guard s.scratchLive != nil else { return }
        s.scratchLive = nil
    }

    /// 草稿纸擦除。半径按 `ScratchPad.eraserRefWidth` 从「页宽归一化」折成画布点（三端同一个数）。
    /// 整笔/局部两种模式与页内完全一致——`InkEdit.splitStroke` 不认坐标系，只认距离。
    func scratchErase(_ pts: [InkPoint], in s: DocSession) {
        let before = s.scratchStrokes    // COW 快照，O(1)
        eraseScratchNear(pts, in: s)
        // 撤销记账（同页内擦除：一次拖动里的多批并成一步，抬笔封口）。没擦到时 diff 为空、不入栈。
        s.scratchUndo.record(label: "Erase", kind: .erase,
                             strokesBefore: before, strokesAfter: s.scratchStrokes)
    }

    /// 平板上行的擦除点：先攒着，主线程这一轮已经排着的消息都收进来以后再一起擦一遍。
    /// 为什么：平板每 8ms 发一批，而每擦一遍都要把整块画板过好几遍（找命中、撤销记账、落库对账、出图对账），
    /// 画板写到近万条笔迹时一遍就远超 8ms，逐批处理会在主线程越积越多 → Mac 转彩虹圈、停手后才慢慢缓过来
    /// （2026-10-07 用户报「只要用橡皮擦 Mac 就卡死」，采样实测主线程全在找命中，Debug 包一批 117ms）。
    /// 攒着擦的话，处理慢了一批里的点就多些，遍数不会越积越多（修好后实测一遍收 12~42 个点）。
    private func queueScratchErase(_ pts: [InkPoint], in s: DocSession) {
        guard !pts.isEmpty else { return }
        if let p = scratchErasePending, p.session !== s { flushScratchErase() }
        if scratchErasePending == nil {
            scratchErasePending = (s, pts)
            DispatchQueue.main.async { [weak self] in self?.flushScratchErase() }
        } else {
            scratchErasePending?.pts.append(contentsOf: pts)
        }
    }

    /// 把攒着的平板擦除点擦掉。凡是要看到「擦过以后」的地方先调它：别的上行消息、抬笔、发全量。
    func flushScratchErase() {
        guard let p = scratchErasePending else { return }
        scratchErasePending = nil
        scratchErase(p.pts, in: p.session)
    }

    private func eraseScratchNear(_ pts: [InkPoint], in s: DocSession) {
        guard let padId = s.openPadID, !pts.isEmpty else { return }
        let r = eraserRadius * ScratchPad.eraserRefWidth
        let r2 = Float(r * r)
        // 预筛：擦除点的外框四周各放出 r。一个点都不在框里的笔迹不可能被擦到，整条原样留下，
        // 不用拿它的每个点去跟每个擦除点算距离（画板近万条、擦除只碰到几条）
        let rf = Float(r)
        var lo = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var hi = -lo
        for e in pts { lo = pointwiseMin(lo, SIMD2(e.x, e.y)); hi = pointwiseMax(hi, SIMD2(e.x, e.y)) }
        let x0 = lo.x - rf, y0 = lo.y - rf, x1 = hi.x + rf, y1 = hi.y + rf
        func near(_ st: InkStroke) -> Bool {
            st.points.withUnsafeBufferPointer { b in
                for p in b where p.x >= x0 && p.x <= x1 && p.y >= y0 && p.y <= y1 { return true }
                return false
            }
        }
        if eraserMode == .stroke {
            let kept = s.scratchStrokes.filter { st in
                guard st.padId == padId, near(st) else { return true }
                for sp in st.points {
                    for e in pts {
                        let dx = sp.x - e.x, dy = sp.y - e.y
                        if dx * dx + dy * dy <= r2 { return false }
                    }
                }
                return true
            }
            // 没擦到就别写 @Published（免得空刷一帧）。🔴 别在 `s.scratchStrokes` 上就地 `removeAll`：
            // 那样不管删没删都会发一次变化，下游（落库对账、出图对账、平板镜像）整块画板白过一遍
            guard kept.count != s.scratchStrokes.count else { return }
            s.scratchStrokes = kept
            return
        }
        // 局部擦除：`splitStroke` 用 z 槽位区分「不同页不串」，草稿纸只有一张画布 → 恒填 0。
        let eps = pts.map { InkPoint($0.x, $0.y, 0) }
        var out: [InkStroke] = []
        out.reserveCapacity(s.scratchStrokes.count)
        var changed = false
        for st in s.scratchStrokes {
            guard st.padId == padId, near(st) else { out.append(st); continue }
            let parts = InkEdit.splitStroke(st, erasePts: eps, r: r)
            if parts.count != 1 || parts.first != st { changed = true }
            out.append(contentsOf: parts)
        }
        guard changed else { return }
        s.scratchStrokes = out
    }

    // MARK: - 平板上行：开/关/新建草稿纸

    /// 平板请求打开第 `index` 张（-1 = 关闭）。Mac 是真源：应用后 `openPadID` 的 @Published 变化
    /// 会被 ContentView 的 onChange 捕获 → 回推 `scratchpads` + `scratchStrokes`，两端自然一致。
    func applyScratchOpen(_ obj: [String: Any], to s: DocSession) {
        guard !s.isBoard else { return }   // 画板那张纸永远开着（`BOARD-NOTE-PLAN.md §4.1`）
        let idx = (obj["index"] as? NSNumber)?.intValue ?? -1
        scratchInkCancel(in: s)
        if idx < 0 || !s.scratchPads.indices.contains(idx) {
            s.openPadID = nil
        } else {
            s.openPadID = s.scratchPads[idx].id
        }
    }

    /// 平板请求改第 index 张纸的纸样（底色 + 底纹）。Mac 是真源：改完 `scratchPads` 的 @Published
    /// 变化被 ContentView 的 onChange 捕获 → 落库 + 回推 `scratchpads`，两端自然一致。
    func applyScratchPaper(_ obj: [String: Any], to s: DocSession) {
        guard let i = (obj["index"] as? NSNumber)?.intValue, s.scratchPads.indices.contains(i) else { return }
        let bg = InkColor.parse(obj["bg"] as? String)
        let pat = ScratchPattern(rawValue: obj["pattern"] as? String ?? "") ?? .dots
        guard s.scratchPads[i].bg != bg || s.scratchPads[i].pattern != pat else { return }
        s.scratchPads[i].bg = bg
        s.scratchPads[i].pattern = pat
        s.scratchPads[i].updatedAt = .now
    }

    /// 平板请求把第 index 张纸的图钉锚点挪到**同页内** (nx, ny)（页不变，页内归一化 0~1，越界钳位）。
    /// 与 `applyScratchPaper` 同套路：改完 `scratchPads` 的 @Published 变化被 ContentView 的 onChange
    /// 捕获 → 落库 + 回推 `scratchpads`；本机 UI 的图钉位置同一条链路自动刷新（无需显式通知）。
    func applyScratchMove(_ obj: [String: Any], to s: DocSession) {
        guard !s.isBoard, let i = (obj["index"] as? NSNumber)?.intValue, s.scratchPads.indices.contains(i) else { return }
        let nx = min(max(0, (obj["nx"] as? NSNumber)?.doubleValue ?? 0.5), 1)
        let ny = min(max(0, (obj["ny"] as? NSNumber)?.doubleValue ?? 0.5), 1)
        guard s.scratchPads[i].anchorX != nx || s.scratchPads[i].anchorY != ny else { return }
        s.scratchPads[i].anchorX = nx
        s.scratchPads[i].anchorY = ny
        s.scratchPads[i].updatedAt = .now
    }

    /// 平板请求开/关第 index 张纸的**页面底图**（把它锚定的那一页垫在纸下面）。
    /// 与 `applyScratchPaper` 同套路：只改真源，落库 + 回推由 ContentView 的 onChange 接手。
    func applyScratchPageShow(_ obj: [String: Any], to s: DocSession) {
        guard !s.isBoard, let i = (obj["index"] as? NSNumber)?.intValue, s.scratchPads.indices.contains(i) else { return }
        let show = (obj["show"] as? Bool) ?? ((obj["show"] as? NSNumber)?.boolValue ?? false)
        guard s.scratchPads[i].showPage != show else { return }
        s.scratchPads[i].showPage = show
        s.scratchPads[i].updatedAt = .now
    }

    /// 平板请求删掉第 index 张纸（连同纸上笔迹）。与 Inspector 里的删除是同一条路径。
    func applyScratchDelete(_ obj: [String: Any], to s: DocSession) {
        guard !s.isBoard, let i = (obj["index"] as? NSNumber)?.intValue, s.scratchPads.indices.contains(i) else { return }
        removeScratchPad(in: s, id: s.scratchPads[i].id)
    }

    /// 平板请求改第 index 张纸的名字（空串 = 清掉自定义名，回到「草稿纸 N」兜底显示）。
    func applyScratchRename(_ obj: [String: Any], to s: DocSession) {
        guard let i = (obj["index"] as? NSNumber)?.intValue, s.scratchPads.indices.contains(i) else { return }
        let t = (obj["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.scratchPads[i].title != t else { return }
        s.scratchPads[i].title = t
        s.scratchPads[i].updatedAt = .now
    }

    /// 平板请求在某页某处新建一张草稿纸并打开它。
    func applyScratchAdd(_ obj: [String: Any], to s: DocSession) {
        guard !s.isBoard else { return }
        let maxPage = max(0, (s.pdf?.pageCount ?? 1) - 1)
        let page = min(max(0, (obj["page"] as? NSNumber)?.intValue ?? 0), maxPage)
        let nx = min(max(0, (obj["nx"] as? NSNumber)?.doubleValue ?? 0.5), 1)
        let ny = min(max(0, (obj["ny"] as? NSNumber)?.doubleValue ?? 0.5), 1)
        addScratchPad(in: s, page: page, nx: nx, ny: ny)
    }

    /// 新建一张草稿纸并立刻打开（Mac 右键菜单、侧栏按钮、平板 `scratchAdd` 共用）。返回新纸。
    @discardableResult
    func addScratchPad(in s: DocSession, page: Int, nx: Double, ny: Double) -> ScratchPad {
        if s.isBoard, let pad = s.openPad { return pad }   // 画板上没有「再建一张纸」这回事
        scratchInkCancel(in: s)
        let pad = ScratchPad(anchorPage: page, anchorX: nx, anchorY: ny)
        s.scratchPads.append(pad)
        s.openPadID = pad.id
        return pad
    }

    /// 删除一张草稿纸：连同纸上的笔迹一起摘掉（两个数组各自的 onChange 对账会把库里也清干净）。
    func removeScratchPad(in s: DocSession, id: UUID) {
        guard !s.isBoard else { return }   // 删画板走侧栏（进回收站），不走这里
        if s.openPadID == id { scratchInkCancel(in: s); s.openPadID = nil }
        s.scratchPads.removeAll { $0.id == id }
        s.scratchStrokes.removeAll { $0.padId == id }
    }

    // MARK: - 下行广播

    /// 草稿纸列表 + 当前打开的是第几张（-1 = 没开）。平板据此显示列表与切换覆盖层。
    func broadcastScratchPads() {
        guard server.hasClients, let s = padSession else { return }
        let open = s.scratchPads.firstIndex { $0.id == s.openPadID } ?? -1
        let list: [[String: Any]] = s.scratchPads.map { p in
            ["id": p.id.uuidString, "title": p.title, "page": p.anchorPage,
             "nx": p.anchorX, "ny": p.anchorY, "bg": p.bg.cssRGBA, "pattern": p.pattern.rawValue,
             "showPage": p.showPage]
        }
        server.broadcast(["type": "scratchpads", "open": open, "list": list])
    }

    /// 平板那份草稿纸 / 画板笔迹镜像此刻对应的状态：哪个会话、哪张纸、这张纸上的全部笔迹
    /// （全量发出去时的，之后每发一次追加跟着长），以及分页画板的全量发的是哪几页、以哪一页为中心。
    struct ScratchMirror {
        let sessionID: UUID
        let padID: UUID?
        var all: [InkStroke]
        let window: ClosedRange<Int>?
        let center: Int
    }

    /// 分页画板的全量只发平板所在页前后各 `boardWindowRadius` 页（`PROTOCOL.md §4.8`）。
    /// 擦除 / 撤销 / 框选这类改动没法用追加表达、只能发全量，而一整个画板几千笔就是好几 MB
    /// （2026-10-07 实测 9214 笔 ≈ 8MB），每擦一下整份发一次照样塞满 WiFi。
    static let boardWindowRadius = 3

    /// 这次全量该发哪几页；nil = 不分窗口（草稿纸、无限画板，全发）。中心 = 同步位置所在页（还没有就第 0 页）。
    private func boardWindow(_ s: DocSession) -> (pages: ClosedRange<Int>, center: Int)? {
        guard s.isPagedBoard else { return nil }
        let n = s.boardPages.count
        let p = min(max(s.boardScrollAnchor?.page ?? 0, 0), n - 1)
        let r = Self.boardWindowRadius
        return (max(0, p - r)...min(n - 1, p + r), p)
    }

    private func scratchDicts(_ strokes: [InkStroke]) -> [[String: Any]] {
        strokes.map { st in
            ["pen": ["color": st.color.cssRGBA, "w": st.width, "t": st.type.rawValue],
             "pts": st.points.map { [$0.x, $0.y, $0.z] }]
        }
    }

    /// **当前打开的那张纸**上的全部笔迹（画布坐标）。没开纸就发空表——平板据此清掉本地残留。
    /// 与 `broadcastStrokes` 同款全量镜像语义（Mac 唯一真源，平板不落库），`ackRel` 由
    /// `LANServer.rawSend` 按收件人补（平板靠它分辨中途快照，见 PROTOCOL.md §4.2）。
    /// 分页画板只发平板附近那几页（`boardWindow`），同 `strokes` 只发 Mac 装载窗口的口径。
    func broadcastScratchStrokes() {
        // 回推带的 ackRel 已经算上了收到的擦除帧，攒着没擦的点必须先擦掉，平板才不会拿到「说擦了其实没擦」的一份
        flushScratchErase()
        guard server.hasClients, let s = padSession else { scratchMirror = nil; return }
        let all = s.openPadID.map { s.strokes(pad: $0) } ?? []
        let window = boardWindow(s)
        let sent = window.map { w in all.filter { w.pages.contains(s.boardPageIndex(of: $0)) } } ?? all
        scratchMirror = ScratchMirror(sessionID: s.id, padID: s.openPadID, all: all,
                                      window: window?.pages, center: window?.center ?? 0)
        server.broadcast(["type": "scratchStrokes", "list": scratchDicts(sent)])
    }

    /// 草稿纸 / 画板笔迹变了（`DocTabModel` 的订阅）：原有的一条没动、只在末尾多了几条 → 只发新增的
    /// （`scratchStrokesAppend`，同 `broadcastStrokeAppended` 之于页内笔迹）；否则（擦除、框选移动 / 缩放、
    /// 撤销、换纸、从前面插入…）照旧发全量。
    /// 为什么：从前一律发全量，每写一笔整份重建、重发一次。分页画板写到近万笔时一份 ≈ 8MB
    /// （2026-10-07 实测 9214 笔），Debug 包里光在 Mac 主线程上建这一份就要几百毫秒（窗口内 1351 条 ≈ 60ms）。
    func scratchStrokesChanged(in s: DocSession) {
        guard server.hasClients, s.id == padSession?.id else { return }
        let all = s.openPadID.map { s.strokes(pad: $0) } ?? []
        if let m = scratchMirror, m.sessionID == s.id, m.padID == s.openPadID,
           all.count > m.all.count, all.prefix(m.all.count).elementsEqual(m.all) {
            let added = Array(all[m.all.count...])
            scratchMirror?.all = all
            server.broadcast(["type": "scratchStrokesAppend", "list": scratchDicts(added)])
            return
        }
        // 跟平板手上那份一模一样：框选 / 粘贴 / 撤销这些地方自己已经直接发过全量，这是同一处改动迟到的订阅，
        // 再发就是同样几百 KB 连发两遍
        if let m = scratchMirror, m.sessionID == s.id, m.padID == s.openPadID,
           all.count == m.all.count, all.elementsEqual(m.all) { return }
        // 平板擦除手势进行中：擦到了笔迹就得发全量（节流后也是每 0.2s 一份、每份约 1MB），而平板在擦除手势里
        // 本来就**一律信本地、不收全量**（安卓 `PadScratch.applyStrokes` 的 `erasing` 闸），这期间发的全是白发。
        // 先欠着，抬笔补一份。
        if scratchPadErasing { scratchFullDeferred = true; return }
        requestScratchFull()
    }

    /// 改动 / 换窗口引起的全量走这里：最多每 0.2s 发一份，期间再有改动就排一份、到点按那时最新的状态现建。
    /// Mac 本机拖着橡皮擦时每个拖动事件都改一次笔迹，不节流就是每秒几十份；也兜住哪条路径出了岔子连着要全量
    /// （2026-10-07 `boardAnchorMoved` 没夹页号时就是每 26ms 一份 ≈ 1MB）。
    /// 换会话、新客户端接入这些照旧直接 `broadcastScratchStrokes`（少见，且要立刻对上）。
    private func requestScratchFull() {
        guard scratchFullPending == nil else { return }   // 已经排着一份，到点会带上这次的改动
        let wait = scratchFullSentAt + 0.2 - CFAbsoluteTimeGetCurrent()
        if wait <= 0 {
            scratchFullSentAt = CFAbsoluteTimeGetCurrent()
            broadcastScratchStrokes()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scratchFullPending = nil
            self.scratchFullSentAt = CFAbsoluteTimeGetCurrent()
            self.broadcastScratchStrokes()
        }
        scratchFullPending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// 平板的一次擦除还在继续：擦除点停了 0.5s 也当它抬笔了（`erase end` 万一没到，别让平板一直等不到结果）。
    private func armScratchEraseIdle() {
        scratchEraseIdle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishScratchPadErase() }
        scratchEraseIdle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// 平板抬笔结束擦除：欠着的全量现在补发一份（按此刻最新的笔迹现建，`ackRel` 已盖过整次擦除）。
    /// 订阅是异步的，最后一批的改动若在这之后才到，那时 `scratchPadErasing` 已经是 false，照常立刻发。
    func finishScratchPadErase() {
        flushScratchErase()
        scratchEraseIdle?.cancel()
        scratchEraseIdle = nil
        guard scratchPadErasing else { return }
        scratchPadErasing = false
        if scratchFullDeferred {
            scratchFullDeferred = false
            requestScratchFull()
        }
    }

    /// 分页画板的同步位置变了（平板滚 / 本机滚）：离上次全量的中心页已经 2 页了，就按新位置重发一份全量，
    /// 免得平板滚进还没发过的那几页时是空白（窗口 ±3 页，屏幕上一般露 1~2 页，提前 1 页换）。
    /// 🔴 比的是 `boardWindow` 夹过的中心页：平板拉到最后一页下面（上拉加页那块）时报上来的页号比最后一页还大，
    /// 拿没夹过的页号比，跟夹过的中心永远差 2 页以上 → 每报一次位置就整份重发一次（2026-10-07 实测每 26ms 一份 ≈ 1MB）。
    func boardAnchorMoved(_ s: DocSession) {
        guard server.hasClients, s.id == padSession?.id, let m = scratchMirror, m.sessionID == s.id,
              m.window != nil, let w = boardWindow(s), abs(w.center - m.center) >= 2 else { return }
        requestScratchFull()
    }
}
