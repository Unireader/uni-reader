import SwiftUI
import PDFKit
import QuartzCore
import AppKit

extension ReaderSurface {
    // MARK: 缩放（硬指标 3/4：锚定捏合点，不跳位、不闪烁）

    func clampZoom(_ z: CGFloat) -> CGFloat { min(max(z, zoomMin), zoomMax) }

    /// 缩放开始：墨迹层切到快速描边（缩放中每帧都要重画，别再逐段转轮廓）。切回在 `settleRender`
    /// ——所有缩放路径的收尾都会经它（连续 ⌘滚轮期间 settle 被反复取消 → 全程保持快速态）。
    /// 理由与实测数据见 `ReaderSurface` 的 `inkFastDraw` 一节。
    func beginFastInk() {
        guard !inkFastDraw else { return }
        // 顺序要紧：先渲快照（此刻 zoom/pageW 还是缩放前的值，与屏幕上正显示的那一版一致，
        // 切过去零跳变），再置 `inkFastDraw`——两个 @State 在同一次事件里写，合并成一轮 body。
        inkSnaps = makeInkSnapshots()
        inkFastDraw = true
        ZoomProbe.mark("缩放开始 → 墨迹切位图快照 \(inkSnaps.count) 页（zoom \(String(format: "%.2f", zoom))）")
    }

    /// 缩放正在进行（命令式动画 / 捏合任一在飞）。逐帧改 `zoom` 期间，凡是「反正马上要重来一遍」的
    /// 周边工作都按这个开关让路：实化窗口不收缩不驱逐、settle 不重排、不入队注定作废宽度的渲染。
    /// 每省一处就少一轮 body 重算或一次后台渲染抢占 —— 按钮缩放掉帧就是被这些每帧重复劳动堆出来的。
    var isZooming: Bool { zoomAnimOn || scratch.pinch != nil }

    /// 锚点计算用的「当前」内容偏移：优先用刚提交、尚未被 `verifyPendingTarget` 确认的
    /// `scratch.pendingTarget`，否则退回 `scratch.geo` 上次汇报值。
    /// ⚠️ **不能一律信 `scratch.geo`**：`onScrollGeometryChange` 汇报是异步的，比 `scrollTo`
    /// 慢半拍到几帧；两次缩放命令紧挨着触发时（连点工具栏按钮 / 命令刚落地又捏合），后一次会读到
    /// 「新 zoom 配旧 offset」的错配快照，算出的锚点内容坐标是错的——目标偏移仍会被 `clampOffset`
    /// 夹进合法范围，不会报错，却会稳稳当当地跳到文档里不相关的一段（未渲染区域先呈现空白纸，
    /// 表现为「PDF 页面消失」；再缩一次因起点又变了，落点继续偏、越点越乱）。
    var anchorOffset: CGPoint {
        scratch.pendingTarget ?? CGPoint(x: scratch.geo.offsetX, y: scratch.geo.offsetY)
    }

    /// 目标偏移夹取（用给定显示页宽下的内容尺寸）。
    /// `margin` 只在画板模式改边界的那一刻显式传（新边界还没落到 `@State` 上），其余一律用当前值。
    func clampOffset(_ o: CGPoint, pageWidth pw: CGFloat, margin m: Double? = nil) -> CGPoint {
        guard let layout else { return o }
        let g = scratch.geo
        // 与 contentW 同源（页边宽度是页宽的倍数，故缩放时跟着 pw 一起变）
        let cw = max(fitAvail, pw * CGFloat(1 + 2 * (m ?? canvasMargin)))
        let ch = layout.totalHeight * pw / PageLayout.refWidth
        // 水平有效视口 = fitAvail（= 未遮宽 − 占位竖滚动条 = 真实 clip 视口；ScrollGeometry 的 insets/containerW 不可用作视口）
        let minX: CGFloat = 0
        let maxX = max(0, cw - fitAvail)
        let minY = -g.insetTop
        let maxY = max(minY, ch - g.containerH + g.insetBottom)
        return CGPoint(x: min(max(o.x, minX), maxX), y: min(max(o.y, minY), maxY))
    }

    var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { v in pinchChanged(v) }
            .onEnded { _ in pinchEnded() }
    }

    func pinchChanged(_ v: MagnifyGesture.Value) {
        // 草稿纸盖着时捏合归草稿纸（它有自己的无限画布缩放），别让下面的 PDF 跟着一起缩。
        guard layout != nil, scratch.didInitialGeo, session.openPadID == nil else { return }
        if scratch.pinch == nil {
            follower.reset()                                   // 用户接管
            cancelZoomAnim()                                   // 捏合接管：停掉进行中的按钮/⌘ 缩放动画
            beginFastInk()                                     // 墨迹切快速描边（缩放中每帧都要重画）
            let o = anchorOffset
            // 手势现挂在 ScrollView 容器 → startLocation 为容器/视口坐标 P（屏幕不动点，与 ⌘wheel/anchorP 同约定）；
            // 内容锚点 c = 偏移 + P。（旧实现挂 content 层取内容坐标，捏合页外空白无手势 → 不缩放。）
            let P = v.startLocation
            let c = CGPoint(x: o.x + P.x, y: o.y + P.y)
            scratch.pinch = PinchInfo(startZoom: zoom, viewportP: P, cCur: c)
            scratch.suppressEmitUntil = CACurrentMediaTime() + 0.3
        }
        guard var p = scratch.pinch else { return }
        // 同 `zoomAnimStep` 的理由：触摸板手势事件可达 120Hz，而每次提交都要重画整页墨迹。
        // 限流到 ~60Hz（末次提交由 `pinchEnded` 的 settle 兜底，不会停在半路）。
        let now = CACurrentMediaTime()
        guard now - scratch.lastPinchCommitAt >= 1.0 / 62 else { return }
        scratch.lastPinchCommitAt = now
        let m = max(0.05, v.magnification)
        commitZoom(to: clampZoom(p.startZoom * m), pinch: &p)  // 逐帧真 commit（两方向统一）
        scratch.pinch = p
        scratch.suppressEmitUntil = now + 0.3
    }

    func pinchEnded() {
        guard scratch.pinch != nil else { return }
        scratch.pinch = nil
        scratch.suppressEmitUntil = CACurrentMediaTime() + 0.3
        scheduleSettleRender()
    }

    /// 原子缩放提交：布局（zoom）与偏移（scrollTo）同 runloop 写入 = 同一次 CA commit。
    func commitZoom(to z1raw: CGFloat, pinch p: inout PinchInfo) {
        let z0 = zoom
        let z1 = clampZoom(z1raw)
        guard abs(z1 - z0) > 0.0001 else { return }
        let r = z1 / z0
        let c1 = CGPoint(x: p.cCur.x * r, y: p.cCur.y * r)
        let target = clampOffset(CGPoint(x: c1.x - p.viewportP.x, y: c1.y - p.viewportP.y),
                                 pageWidth: basis * z1)
        var t = Transaction(); t.animation = nil
        withTransaction(t) {
            zoom = z1
            if !userZoomed { userZoomed = true }   // @State 写入不比较旧值，逐帧写 true = 逐帧多一次无谓失效
            pos.scrollTo(point: target)
        }
        scratch.zoomFromRestore = false   // 用户接管缩放：启动窗内的「按恢复倍率重算」到此为止
        p.cCur = c1
        scratch.pendingTarget = target
        scratch.pendingTries = 0
        scratch.suppressEmitUntil = CACurrentMediaTime() + 0.3
    }

    /// 以容器坐标 anchorP 为屏幕不动点做单次缩放 commit（⌘wheel 即时缩放；按钮/⌘ 命令走 animateZoom）。
    func zoomCommit(factor: CGFloat, anchorP P: CGPoint) {
        guard layout != nil, scratch.didInitialGeo else { return }
        follower.reset()
        cancelZoomAnim()   // 连续输入接管：停掉进行中的命令式动画，避免两路同时写 zoom
        beginFastInk()     // 连滚期间 settle 被反复取消 → 全程快速描边，停手 0.15s 才换回高质量
        let o = anchorOffset
        let c = CGPoint(x: o.x + P.x, y: o.y + P.y)
        var p = PinchInfo(startZoom: zoom, viewportP: P, cCur: c)
        commitZoom(to: clampZoom(zoom * factor), pinch: &p)
        scheduleSettleRender()
    }

    /// 未遮视口中心（容器坐标；⌘±/⌘0/1:1/缩放胶囊共用的锚点）。
    var viewportCenter: CGPoint {
        let g = scratch.geo
        return CGPoint(x: g.insetLeading + (g.containerW - g.insetLeading - g.insetTrailing) / 2,
                       y: g.insetTop + (g.containerH - g.insetTop - g.insetBottom) / 2)
    }

    /// ⌘+/⌘− / 工具栏缩放按钮：动画缩放到目标倍率，未遮视口中心为锚。
    func commandZoom(factor: CGFloat) {
        animateZoom(to: zoom * factor, anchorP: viewportCenter)
    }

    /// 1:1 实际大小（参考 Preview）：当前页 1 PDF pt = 1 屏幕 pt。未遮视口中心为锚。
    func commandZoomActual() {
        guard layout != nil, scratch.didInitialGeo, let pdf = session.pdf, pdf.pageCount > 0 else { return }
        let idx = min(max(0, session.currentPageIndex), pdf.pageCount - 1)
        guard let page = pdf.page(at: idx) else { return }
        let w = PageBitmap.displaySize(page).width
        guard w > 0, basis > 0 else { return }
        animateZoom(to: w / basis, anchorP: viewportCenter)
    }

    // MARK: 命令式缩放动画（逐帧插值；每帧 = pinch 同款原子 commit，平滑且零闪烁）

    /// **手感旋钮**：临界阻尼弹簧的响应时间（秒）。越小越快越干脆，**只改这一个数**。
    ///
    /// 演进：定长 0.22s smoothstep（**有缓动**，连点会跳）→ 指数趋近 tau=0.13（起步最快、
    /// 尾巴无限长，一步 1.25× 要 750ms 才收敛，用户 2026-09-02 报「动画让人感觉不好」）→
    /// 临界阻尼弹簧（S 形、零过冲）→ **匀速直线**（用户同日定：「就线性的就好了，不要弹性」）。
    ///
    /// 🔴 所以：**不要再往回加任何缓动**（smoothstep / spring / ease-*）。匀速的好处正在于
    /// 连点不会跳——线性没有「起步阶段」，改目标时只换斜率，位置与观感都是连续的；
    /// 当年 smoothstep 那版一跳一跳，就是因为重启缓动等于把速度归零再来一次。
    var zoomAnimDuration: CFTimeInterval { 0.18 }   // 计算属性：扩展里不能放存储属性

    /// 启动/续接一次缩放动画：锚点 P 不动，zoom 指数趋近 z1。
    /// **已有动画在飞时只更新目标**（速度、锚点都不重置）——这就是连点不再一跳一跳的原因。
    /// `fitAfter` 仅 ⌘0 用：动画到位后把 fitBasis 重定标、zoom 归 1（此时 pageW 恰好相等，零跳变）。
    func animateZoom(to z1raw: CGFloat, anchorP P: CGPoint, fitAfter: CGFloat? = nil) {
        guard layout != nil, scratch.didInitialGeo else { return }
        follower.reset()
        scratch.zoomFromRestore = false   // 用户接管缩放（⌘±/⌘0/工具栏），同 commitZoom
        let z1 = clampZoom(z1raw)
        if var a = scratch.zoomAnim {     // 续接：连点/连按从**当前位置**重新起一段匀速
            a.from = zoom
            a.progress = 0
            a.target = z1
            // ⚠️ `fitAfter` 必须**整个换成新命令的**（含 nil）：新命令完全接管旧的。
            // 只在非 nil 时覆盖的话，「⌘0 动画途中按 1:1」会留着 ⌘0 的 fitAfter，
            // 到位后 fitBasis 重定标 + zoom 归 1，把 1:1 的结果当场吃掉。
            a.fitAfter = fitAfter
            scratch.zoomAnim = a
            return
        }
        guard abs(z1 - zoom) > 0.0001 else {
            if let nb = fitAfter { fitBasis = nb; zoom = 1; userZoomed = false }   // 已在目标：仍刷新基准
            return
        }
        beginFastInk()     // 动画每帧改 zoom，同 pinch：走快速描边，到位后 settleRender 换回高质量
        let o = anchorOffset
        scratch.zoomAnim = ZoomAnim(target: z1, anchorP: P,
                                    cCur: CGPoint(x: o.x + P.x, y: o.y + P.y),
                                    lastT: CACurrentMediaTime(), from: zoom, fitAfter: fitAfter)
        zoomAnimOn = true
    }

    /// 动画帧：zoom 按 dt 指数趋近 target，锚点内容坐标等比缩放后减回 P 得目标偏移，同事务提交。
    func zoomAnimStep() {
        guard var a = scratch.zoomAnim else { zoomAnimOn = false; return }
        let now = CACurrentMediaTime()
        // 🔴 提交限流到 ~60Hz：墨迹层的 Canvas 尺寸每帧都变 → **每次提交都要重画整页笔迹**
        // （真机实测：一页 100+ 笔约 2.6ms，视口两页就是 5ms/帧）。ProMotion 屏上 TimelineView
        // 按 120Hz 给帧，等于这笔钱付两遍，而缩放动画在 60Hz 与 120Hz 之间肉眼分不出。
        // 注意是「不提交、也不推进 lastT」——dt 累积到下一次 tick，动画速度完全不受影响。
        guard now - a.lastT >= 1.0 / 62 else { return }
        let dt = min(0.05, max(0, now - a.lastT))   // 掉帧/后台回来时钳住，别一步跨过头
        a.lastT = now
        a.progress = min(1, a.progress + CGFloat(dt / zoomAnimDuration))
        if a.progress >= 1 || dt <= 0 {
            zoomAnimFrame(z: a.target, &a)   // 末帧显式对齐到目标（浮点推进不保证正好落上）
            scratch.zoomAnim = nil
            zoomAnimOn = false
            if let nb = a.fitAfter { fitBasis = nb; zoom = 1; userZoomed = false }
            scheduleSettleRender()
            return
        }
        // 🔴 **在 log 空间匀速**：缩放是乘性量，倍率上做算术插值看着是「先快后慢」
        //（1→2 的前半程涨 50%、后半程只涨 33%），那恰恰是这次要去掉的那种「不匀」。
        // 每帧乘同一个系数才是眼睛看到的匀速；而且它对起点/终点都不敏感，⌘0 那种大跨度同样干净。
        zoomAnimFrame(z: a.from * pow(a.target / a.from, a.progress), &a)
        scratch.zoomAnim = a
    }

    /// 单帧提交（与 `commitZoom` 同款增量数学：锚点内容坐标按比率滚动更新，不依赖起始快照）。
    func zoomAnimFrame(z: CGFloat, _ a: inout ZoomAnim) {
        let z0 = zoom
        let z1 = clampZoom(z)
        guard abs(z1 - z0) > 0.00001 else { return }
        let r = z1 / z0
        let c1 = CGPoint(x: a.cCur.x * r, y: a.cCur.y * r)
        let target = clampOffset(CGPoint(x: c1.x - a.anchorP.x, y: c1.y - a.anchorP.y),
                                 pageWidth: basis * z1)
        var t = Transaction(); t.animation = nil
        withTransaction(t) {
            zoom = z1
            if !userZoomed { userZoomed = true }   // 同 commitZoom：逐帧写同一个值也会逐帧触发失效
            pos.scrollTo(point: target)
        }
        a.cCur = c1
        scratch.pendingTarget = target
        scratch.pendingTries = 0
        scratch.suppressEmitUntil = CACurrentMediaTime() + 0.3
    }

    /// 取消进行中的缩放动画（pinch / ⌘wheel 等连续输入接管时调用）。
    func cancelZoomAnim() {
        scratch.zoomAnim = nil
        zoomAnimOn = false
    }

    // MARK: ⌘+滚轮缩放（光标为锚；系统缩放同向：自然滚动下两指上滑/滚轮向上 = 放大）
    // SwiftUI 无滚轮 API → NSEvent 本地监视器（纯事件管道，无 AppKit 视图）。
    // 只在「⌘按住 + 光标在本阅读区内 + 非动量惯性 + 无进行中 pinch」时消费事件，其余原样放行。

    func installWheelMonitor() {
        guard scratch.wheelMonitor == nil else { return }
        scratch.wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard session.openPadID == nil,   // 草稿纸开着时滚轮全归它（它自己也装了个监视器）
                  event.modifierFlags.contains(.command),
                  event.momentumPhase == [],
                  let p = scratch.cursorP,
                  layout != nil, scratch.didInitialGeo, scratch.pinch == nil else { return event }
            var delta = event.scrollingDeltaY
            if !event.hasPreciseScrollingDeltas { delta *= 10 }   // 有级滚轮（行单位）放大到像素量级
            guard delta != 0 else { return nil }
            let factor = min(max(exp(-delta * 0.008), 0.5), 2)    // 手感旋钮：0.008；负号=系统缩放方向约定
            zoomCommit(factor: factor, anchorP: p)
            return nil   // 消费：⌘滚轮不再触发滚动
        }
    }

    func removeWheelMonitor() {
        if let m = scratch.wheelMonitor {
            NSEvent.removeMonitor(m)
            scratch.wheelMonitor = nil
        }
    }

    // MARK: 阅读区单键快捷键（默认 e 橡皮 / b 书写 / v 翻页 / l 框选 / i 本机笔 / t 文字选择；
    //       **有选中文字时** h 铺色高亮 / ⇧H 画线 / ⌥H 画框 / n 文字笔记；1-9 选笔固定不可改）
    // 键位查 `Shortcuts`（设置 › 快捷键可改，默认值在 `ShortcutAction.defaultCombo`）；
    // 动作与 ⌥ 菜单项同一套 apply 路径，广播到平板天然生效。
    // 按下的键在表里没有对应动作就原样放行（含带 ⌘/⌥/⌃ 的组合键——那些归菜单）；
    // 文本框焦点（查找/笔记编辑/重命名）与**内置 AI 面板里的 webview 焦点**一律放行（后者见 `aiWebInputHasFocus`）。
    // 输入法：没有文本输入焦点时输入法根本不介入（它只挂在 NSTextInputClient 上），按键原样到这里；
    // 有文本焦点（含正在组字）则 firstResponder 是 NSText / WKWebView，上面两条守卫已放行。
    // 笔架里的 eraser/钢笔图标 Button 不能挂 `.keyboardShortcut("e")`——那在文本框焦点时也会抢键。

    func installToolKeyMonitor() {
        guard scratch.toolKeyMonitor == nil else { return }
        scratch.toolKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard scratch.isActiveWindow,
                  !(NSApp.keyWindow?.firstResponder is NSText),
                  !aiWebInputHasFocus(),          // 内置 AI 面板在打字 → 键归它（WKWebView 不是 NSText）
                  let combo = KeyCombo(event: event) else { return event }
            // 数字键 1–9 直选笔槽：固定不进映射表（9 个连号，三端同约定，见 `REQUIREMENTS.md §1.5`）。
            if combo.mods.isEmpty, combo.key.count == 1, let d = Int(combo.key), (1...9).contains(d) {
                guard d - 1 < app.pens.count else { return event }
                app.applyPenSelection(index: d - 1)
                return nil
            }
            guard let action = Shortcuts.shared.readerAction(for: combo) else { return event }
            // 选中了文字：高亮 / 笔记两个动作才有对象；没选区时这两个键原样放行。
            // 草稿纸盖着时阅读区没有选区可言。
            let hasSelection = selection?.text.isEmpty == false && session.openPadID == nil
            switch action {
            case .highlightSelection:
                guard hasSelection else { return event }
                quickHighlight(style: .fill)
            case .underlineSelection:
                guard hasSelection else { return event }
                quickHighlight(style: .underline)
            case .boxSelection:
                guard hasSelection else { return event }
                quickHighlight(style: .box)
            case .noteFromSelection:
                guard hasSelection else { return event }
                beginAddNote()
            case .keyEraser: app.setPadMode(app.padMode == "erase" ? "note" : "erase")
            case .keyWrite: app.setPadMode("note")
            case .keyPageTurn: app.setPadMode(app.padMode == "page" ? "note" : "page")
            case .keyLasso: app.pointerTool = app.pointerTool == .lasso ? .textSelect : .lasso
            case .keyLocalInk: app.pointerTool = app.pointerTool == .ink ? .textSelect : .ink
            case .keyTextSelect: app.pointerTool = .textSelect
            default: return event   // 菜单类动作不在这里处理
            }
            return nil
        }
    }

    func removeToolKeyMonitor() {
        if let m = scratch.toolKeyMonitor {
            NSEvent.removeMonitor(m)
            scratch.toolKeyMonitor = nil
        }
    }

    /// ⌘0：动画回 fit-width；到位后基准重定标到当前实测可用宽（fitAfter，pageW 不变零跳变）。
    func commandZoomFit() {
        guard layout != nil, scratch.didInitialGeo else { return }
        let newBasis = fitAvail
        animateZoom(to: newBasis / basis, anchorP: viewportCenter, fitAfter: newBasis)
    }

}

extension Scratch {
    /// 放掉所有会**长期持有 `ReaderSurface` 拷贝**的东西：三个 NSEvent 监视器（AppKit 攥着闭包）
    /// 与两个防抖 DispatchWorkItem。这些闭包捕获的 `self` 拷贝连着 `@State` 存储盒（页图字典就在里面）
    /// 与会话，不放掉阅读区就永远活着。
    ///
    /// 两个入口：`onDisappear`（正常拆视图）与 `DocSession.teardown`（关窗——AppKit 直接销毁 hosting
    /// 视图，`onDisappear` 来不来没有保证；`teardown` 是关窗必经之路，由它兜底）。幂等。
    /// 只挂在 `Scratch` 上、不捕获视图：会话里存的清理闭包只捕获这个对象，不能再把视图拷贝带进去。
    func releaseRetainers() {
        if let m = wheelMonitor { NSEvent.removeMonitor(m); wheelMonitor = nil }
        if let m = lassoEscMonitor { NSEvent.removeMonitor(m); lassoEscMonitor = nil }
        if let m = toolKeyMonitor { NSEvent.removeMonitor(m); toolKeyMonitor = nil }
        settleWork?.cancel(); settleWork = nil
        resizeWork?.cancel(); resizeWork = nil
    }
}
