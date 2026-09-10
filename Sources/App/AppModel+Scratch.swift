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
        switch obj["type"] as? String {
        case "ink":
            let phase = obj["phase"] as? String ?? ""
            if phase == "begin" {
                let pen = obj["pen"] as? [String: Any]
                // 直线（尺子）笔：整笔恒为「起点 + 当前终点」，后续 move 是**替换终点**而不是追加
                // （吸附已在平板侧算完）。与页内笔迹同一个标记，见 PROTOCOL.md §4.3 ink begin flags。
                padInkLine = (obj["line"] as? Bool) ?? false
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
                scratchErase(scratchPoints(obj["pts"]), in: s)
            }
            return true
        case "probe":
            // 草稿纸上不做长按环形选笔盘：那套判定（`beginLongPressWatch`）全建立在页内归一化坐标
            // 与 `padPageWidth` 上，喂画布坐标进去阈值会整个失真。平板侧同样不呼盘。
            return true
        default:
            return false
        }
    }

    /// 线上点集 → 画布坐标点（与页内的 `points(_:)` 同结构，只是不再是 0~1）。
    private func scratchPoints(_ any: Any?) -> [SIMD3<Double>] {
        guard let raw = any as? [[NSNumber]] else { return [] }
        return raw.map { p in
            SIMD3(p.count > 0 ? p[0].doubleValue : 0,
                  p.count > 1 ? p[1].doubleValue : 0,
                  p.count > 2 ? p[2].doubleValue : 0.5)
        }
    }

    // MARK: - 落墨 API（平板上行与 Mac 本机落墨共用，同 `inkBegin` 一族的分工）

    func scratchInkBegin(in s: DocSession, pad: UUID, color: InkColor, width: Double,
                         type: PenBrushType = .ballpoint, points: [SIMD3<Double>]) {
        s.scratchLive = InkStroke(page: 0, color: color, width: width, type: type,
                                  points: points, padId: pad)
    }

    func scratchInkAppend(_ pts: [SIMD3<Double>], in s: DocSession) {
        guard var st = s.scratchLive else { return }
        st.points.append(contentsOf: pts)
        s.scratchLive = st
    }

    /// 直线（尺子）笔：整笔恒为「起点 → 当前终点」两点，新点替换终点（同 `inkLineTo`，
    /// 压感同样取这一笔的峰值、两端同值——理由见那里）。
    func scratchInkLineTo(_ p: SIMD3<Double>?, in s: DocSession) {
        guard let p, var st = s.scratchLive, let a = st.points.first else { return }
        let z = AppModel.linePressure(st.points, p)
        st.points = [SIMD3(a.x, a.y, z), SIMD3(p.x, p.y, z)]
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
    func scratchErase(_ pts: [SIMD3<Double>], in s: DocSession) {
        let before = s.scratchStrokes    // COW 快照，O(1)
        eraseScratchNear(pts, in: s)
        // 撤销记账（同页内擦除：一次拖动里的多批并成一步，抬笔封口）。没擦到时 diff 为空、不入栈。
        s.scratchUndo.record(label: "Erase", kind: .erase,
                             strokesBefore: before, strokesAfter: s.scratchStrokes)
    }

    private func eraseScratchNear(_ pts: [SIMD3<Double>], in s: DocSession) {
        guard let padId = s.openPadID, !pts.isEmpty else { return }
        let r = eraserRadius * ScratchPad.eraserRefWidth
        let r2 = r * r
        if eraserMode == .stroke {
            let before = s.scratchStrokes.count
            s.scratchStrokes.removeAll { st in
                guard st.padId == padId else { return false }
                for sp in st.points {
                    for e in pts {
                        let dx = sp.x - e.x, dy = sp.y - e.y
                        if dx * dx + dy * dy <= r2 { return true }
                    }
                }
                return false
            }
            if s.scratchStrokes.count == before { return }   // 没擦到就别写 @Published（免得空刷一帧）
            return
        }
        // 局部擦除：`splitStroke` 用 z 槽位区分「不同页不串」，草稿纸只有一张画布 → 恒填 0。
        let eps = pts.map { SIMD3($0.x, $0.y, 0.0) }
        var out: [InkStroke] = []
        out.reserveCapacity(s.scratchStrokes.count)
        var changed = false
        for st in s.scratchStrokes {
            guard st.padId == padId else { out.append(st); continue }
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
        guard let i = (obj["index"] as? NSNumber)?.intValue, s.scratchPads.indices.contains(i) else { return }
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
        guard let i = (obj["index"] as? NSNumber)?.intValue, s.scratchPads.indices.contains(i) else { return }
        let show = (obj["show"] as? Bool) ?? ((obj["show"] as? NSNumber)?.boolValue ?? false)
        guard s.scratchPads[i].showPage != show else { return }
        s.scratchPads[i].showPage = show
        s.scratchPads[i].updatedAt = .now
    }

    /// 平板请求删掉第 index 张纸（连同纸上笔迹）。与 Inspector 里的删除是同一条路径。
    func applyScratchDelete(_ obj: [String: Any], to s: DocSession) {
        guard let i = (obj["index"] as? NSNumber)?.intValue, s.scratchPads.indices.contains(i) else { return }
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
        let maxPage = max(0, (s.pdf?.pageCount ?? 1) - 1)
        let page = min(max(0, (obj["page"] as? NSNumber)?.intValue ?? 0), maxPage)
        let nx = min(max(0, (obj["nx"] as? NSNumber)?.doubleValue ?? 0.5), 1)
        let ny = min(max(0, (obj["ny"] as? NSNumber)?.doubleValue ?? 0.5), 1)
        addScratchPad(in: s, page: page, nx: nx, ny: ny)
    }

    /// 新建一张草稿纸并立刻打开（Mac 右键菜单、侧栏按钮、平板 `scratchAdd` 共用）。返回新纸。
    @discardableResult
    func addScratchPad(in s: DocSession, page: Int, nx: Double, ny: Double) -> ScratchPad {
        scratchInkCancel(in: s)
        let pad = ScratchPad(anchorPage: page, anchorX: nx, anchorY: ny)
        s.scratchPads.append(pad)
        s.openPadID = pad.id
        return pad
    }

    /// 删除一张草稿纸：连同纸上的笔迹一起摘掉（两个数组各自的 onChange 对账会把库里也清干净）。
    func removeScratchPad(in s: DocSession, id: UUID) {
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

    /// **当前打开的那张纸**上的全部笔迹（画布坐标）。没开纸就发空表——平板据此清掉本地残留。
    /// 与 `broadcastStrokes` 同款全量镜像语义（Mac 唯一真源，平板不落库），`ackRel` 由
    /// `LANServer.rawSend` 按收件人补（平板靠它分辨中途快照，见 PROTOCOL.md §4.2）。
    func broadcastScratchStrokes() {
        guard server.hasClients, let s = padSession else { return }
        let list: [[String: Any]] = (s.openPadID.map { s.strokes(pad: $0) } ?? []).map { st in
            ["pen": ["color": st.color.cssRGBA, "w": st.width, "t": st.type.rawValue],
             "pts": st.points.map { [$0.x, $0.y, $0.z] }]
        }
        server.broadcast(["type": "scratchStrokes", "list": list])
    }
}
