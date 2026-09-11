import AppKit
import SwiftUI
import PDFKit
import QuartzCore

/// 参考窗内部的**只读页图流**：连续多页、自由上下滚动、捏合缩放，仅此而已。
///
/// 它是主阅读区的一个**很小子集**——没有笔迹、没有 hover、没有选笔盘、没有框选、不上报滚动锚点，
/// 所以刻意**不复用 `ReaderSurface`**（那是 1000+ 行、与 `DocSession` 深度耦合的东西），
/// 只复用两样真正通用的：`PageLayout`（纯数学的 fit-width 连续布局）与 `PageRenderEngine`（出图）。
///
/// 沿用主阅读区三条已被实测钉死的纪律：
///  · **一律 `scrollTo(point:)`**（单轴 `scrollTo(x:)/(y:)` 后写覆盖前写、且把未指定轴重置为 0）；
///  · **精确内容尺寸的自研虚拟化**，不用 `LazyVStack` 估算（否则滚动条与 scrollTo 会漂移，
///    而「打开定位到进度」正是靠 scrollTo 精确落点）；
///  · **图只被替换、不被清空**（换档位/夜间切换时先用缓存顶上，新图到达再原位换）。
struct RefPageStream: View {
    @ObservedObject var model: RefWindowModel
    let nightMode: Bool
    /// 挂在覆盖层里还是独立窗口里。只用来给 model 的认领登记分组（见 `RefWindowModel.renderClients`），
    /// 页流本身两种形态下一行都不差。
    let host: RefViewHost

    @Environment(\.displayScale) private var displayScale

    @State private var pos = ScrollPosition()
    @State private var geo = GeoSnap()
    /// 视口尺寸（外层 GeometryReader 测得，已量化）。**页宽的唯一基准**。
    @State private var viewport: CGSize = .zero
    @State private var images: [Int: CGImage] = [:]
    @State private var realized: ClosedRange<Int> = 0...0
    @State private var zoom: CGFloat = 1
    /// 逃逸闭包（渲染完成回调）捕获的 self 是 View 的**值拷贝**，从拷贝上读 `@State` 拿到的是
    /// 请求发出那一刻的旧值 → 守卫会失效。可变的判定依据一律放这个引用类型里（同 `ReaderSurface.scratch`）。
    @State private var scratch = RefScratch()

    var paper: Color { nightMode ? Color(white: 0.10) : .white }
    var voidColor: Color { nightMode ? Color(white: 0.06) : Color(nsColor: .windowBackgroundColor) }

    var body: some View {
        GeometryReader { g in
            scrollBody
                .onAppear { viewportChanged(g.size) }
                .onChange(of: g.size) { _, s in viewportChanged(s) }
        }
    }

    private var scrollBody: some View {
        ScrollView([.vertical, .horizontal]) {
            content
        }
        .defaultScrollAnchor(.topLeading)
        .scrollPosition($pos)
        .background(voidColor)
        .onScrollGeometryChange(for: GeoSnap.self) { g in
            GeoSnap(offsetX: g.contentOffset.x, offsetY: g.contentOffset.y,
                    containerW: g.containerSize.width, containerH: g.containerSize.height,
                    contentW: g.contentSize.width, contentH: g.contentSize.height,
                    insetTop: g.contentInsets.top, insetLeading: g.contentInsets.leading,
                    insetBottom: g.contentInsets.bottom, insetTrailing: g.contentInsets.trailing)
        } action: { _, new in
            geometryChanged(new)
        }
        .gesture(magnify)
        // ⌘+滚轮缩放的锚点（容器坐标，与 `magnify` 的 startLocation 同一空间）。
        // 光标不在小窗里时置 nil —— 监视器据此放行事件，主阅读区那个才拿得到。
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let p): scratch.cursorP = p
            case .ended: scratch.cursorP = nil
            }
        }
        .onAppear {
            installWheelMonitor()
            // 关窗兜底（`RefWindowModel.close` / `releaseViews(host:)` 会调）：只捕获 `scratch`，不捕获视图。
            model.renderClients[scratch.clientID] = (host, { [scratch] in
                if let m = scratch.wheelMonitor { NSEvent.removeMonitor(m); scratch.wheelMonitor = nil }
            })
        }
        .onChange(of: model.seedRev) { _, _ in seedIfReady() }
        .onChange(of: model.docKey) { _, _ in
            // 换书 = 全新一份状态（旧书的图留在引擎缓存里由 LRU 处置，别在这儿 purge：
            // 参考的若正是主视图那本，purge 会把阅读区的图一起清掉）。
            images.removeAll(); realized = 0...0; zoom = 1
            scratch.basePixelW = 0
            scratch.restored = false
            scratch.positioned = false
        }
        .onChange(of: nightMode) { _, _ in nightChanged() }
        .onDisappear {
            // 全部按**本实例**的 id 清：形态切换时新旧两个页流可能短暂并存，别动对方的（见 `renderClients`）。
            PageRenderEngine.shared.setWanted([], client: scratch.clientID)
            PageHoldings.shared.remove(client: scratch.clientID)
            removeWheelMonitor()   // 折叠成气泡 / 关小窗 / 换形态 = 这个页流没了，监视器不能留着
            model.renderClients.removeValue(forKey: scratch.clientID)
        }
    }

    private func reportHoldings() {
        var h = PageHolding(kind: .ref, label: model.title, active: false, realized: realized)
        for img in images.values { h.imageCount += 1; h.imageBytes += PageHolding.bytes(of: img) }
        PageHoldings.shared.report(h, client: scratch.clientID)
    }

    /// 🔴 **视口尺寸只认外层 `GeometryReader`，绝不用 `ScrollGeometry.containerSize`。**
    ///
    /// 后者会因滚动条占位而自己摆动，而页宽又是由它算出来的 → 页宽变 → 内容尺寸变 →
    /// 滚动条占位变 → 它又变：一个**自激环**。2026-08-30 真机日志里逮到的就是这个：
    /// 容器宽在 469↔470 之间来回摆 1px，每摆一次就触发一次「保持文档位置」的补偿滚动，
    /// 而长书上 1px 页宽差 ≈ 25pt 位置差 —— 用户看到的「松手后位置跳变」其实是**持续三秒的振荡**，
    /// 手早就松开了。主阅读区那条「ScrollGeometry 的 insets/containerW 不可用作视口」是同一笔账。
    private func viewportChanged(_ s: CGSize) {
        let w = s.width.rounded(), h = s.height.rounded()
        guard w > 0, h > 0 else { return }
        let old = viewport
        viewport = CGSize(width: w, height: h)
        // 用户真的改了小窗尺寸 → 页宽跟着变，把视口重新对回原来那个文档位置，否则越拖越偏。
        if old.width > 0, abs(old.width - w) > 0.5, scratch.positioned,
           let layout = model.layout, let docY = model.viewDocY {
            let sc = max(1, w * zoom) / PageLayout.refWidth
            let maxY = max(0, layout.totalHeight * sc - h)
            let target = CGPoint(x: 0, y: min(max(0, docY * sc), maxY))
            var t = Transaction(); t.animation = nil
            withTransaction(t) { pos.scrollTo(point: target) }
            noteCommitted(target)
            ZoomProbe.mark(String(format: "REF refit(viewport %.0f→%.0f) → y=%.1f", old.width, w, target.y))
        }
        updateRealized()
        seedIfReady()
        kick()
    }

    /// 几何回报**只用来读滚动偏移**（那是真的），容器尺寸一律走 `viewport`（见上）。
    ///
    /// 🔴 视口记忆只在「稳定态」写：定位没做完（`positioned`）或正在缩放（`zooming`）时，
    /// 回报要么是 ScrollView 重建后的 offsetY=0、要么是慢半拍的旧偏移配新缩放——
    /// 拿它算 docY 就是「折叠再打开位置丢了」和「缩放把进度带跑偏」这两个 bug。
    private func geometryChanged(_ raw: GeoSnap) {
        ZoomProbe.mark(String(format: "REF geo  y=%.1f (vp %.0fx%.0f) contH=%.1f | zoom=%.3f zooming=%d pend=%.1f",
                              raw.offsetY, viewport.width, viewport.height, raw.contentH,
                              zoom, scratch.zooming ? 1 : 0, scratch.pendingTarget?.y ?? -1))
        geo = raw
        if scratch.positioned, !scratch.zooming, dispScale > 0 {
            // 刚提交过 scrollTo 的话，回报可能还是**提交之前**那一版（异步、慢半拍到几帧）。
            // 拿它写记忆 = 把位置往回带。等它追上目标、或超时认输，才恢复记账。
            if let pt = scratch.pendingTarget {
                if abs(raw.offsetY - pt.y) < 1.5 || CACurrentMediaTime() - scratch.pendingSince > 0.4 {
                    scratch.pendingTarget = nil
                    model.viewDocY = raw.offsetY / dispScale
                }
            } else {
                model.viewDocY = raw.offsetY / dispScale
            }
        }
        updateRealized()
        seedIfReady()
        reportPage()
        kick()
    }

    // MARK: - 几何（全部由 zoom + 容器宽推出，无状态可失配）

    private var pageW: CGFloat { max(1, viewport.width * zoom) }
    private var dispScale: CGFloat { pageW / PageLayout.refWidth }
    private var contentW: CGFloat { max(pageW, viewport.width) }
    private func contentH(_ layout: PageLayout) -> CGFloat { layout.totalHeight * dispScale }

    @ViewBuilder private var content: some View {
        if let layout = model.layout, viewport.width > 0, layout.pageCount > 0 {
            let _ = reportHoldings()   // 台账：小窗此刻攥着几张页图（同主阅读区，见 `PageHoldings`）
            ZStack(alignment: .topLeading) {
                // 🔴 **必须夹一道**：换书时 `layout` 当帧就是新书的，而 `realized` 要等
                // `onChange(of: docKey)` 才归零——两者不同步的那一帧里，旧书的页号会拿去索引
                // 新书的 `heights[i]`，页数变少就是数组越界崩溃。
                ForEach(Array(clampedRealized(layout)), id: \.self) { i in
                    cell(i, layout: layout)
                }
            }
            .frame(width: contentW, height: contentH(layout), alignment: .topLeading)
            .transaction { $0.animation = nil }   // 小窗里同样不要隐式动画：滚动中改图会拖出残影
        } else {
            Color.clear.frame(width: 10, height: 10)
        }
    }

    private func clampedRealized(_ layout: PageLayout) -> ClosedRange<Int> {
        let hi = layout.pageCount - 1
        let lo = min(max(0, realized.lowerBound), hi)
        return lo...min(max(lo, realized.upperBound), hi)
    }

    private func cell(_ i: Int, layout: PageLayout) -> some View {
        RefPageCell(size: CGSize(width: pageW, height: layout.heights[i] * dispScale),
                    image: images[i], paper: paper)
            .offset(x: (contentW - pageW) / 2, y: layout.offsets[i] * dispScale)
    }

    // MARK: - 实化窗口

    /// 🔴 **只扩不缩 + 上界**。两个坑都要躲（主阅读区 2026-08-29 刚踩过）：无上界时实化窗口会一路
    /// 累积膨胀（那次涨到 74 页、每帧构建约 26ms）；而彻底去掉「只扩不缩」则页元胞反复销毁重建 = 闪烁。
    /// 小窗比正文视口小得多，上界取「可见页数 + 2」即可（正文那边是 +8）。
    private func updateRealized() {
        guard let layout = model.layout, viewport.height > 0, dispScale > 0 else { return }
        let vis = layout.pageRange(fromDocY: geo.offsetY / dispScale,
                                   toDocY: (geo.offsetY + viewport.height) / dispScale)
        let cap = vis.count + 2
        var lo = min(realized.lowerBound, vis.lowerBound)
        var hi = max(realized.upperBound, vis.upperBound)
        if hi - lo + 1 > cap {
            lo = max(0, vis.lowerBound - 1)
            hi = lo + cap - 1
        }
        lo = max(0, lo)
        hi = min(layout.pageCount - 1, max(hi, lo))
        let r = lo...hi
        scratch.keepRange = r
        guard r != realized else { return }
        realized = r
        // 🔴 滚出窗口的页图**必须丢**（2026-09-10 实测定位）：原来这里只改 `realized`、从不动 `images`，
        // 小窗滚过的每一页都留在字典里，缩放换档后旧宽度的也留——参考窗开着看一阵子就攒下十几张
        // 整页位图（每张 13MB，还各有一份 CA 副本）。丢掉的在引擎 LRU 与磁盘缓存里都还在，滑回来很快。
        for k in images.keys where !r.contains(k) { images.removeValue(forKey: k) }
    }

    private func reportPage() {
        guard let layout = model.layout, dispScale > 0 else { return }
        // 取视口上三分之一处那一页当「当前页」（同主阅读区口径：顶部那页才是在读的那页）。
        let p = layout.locate(docY: (geo.offsetY + viewport.height * 0.3) / dispScale).page
        model.reportCurrentPage(p)   // 页号没变时是空操作，不会逐帧发布
    }

    // MARK: - 出图

    /// 档位化像素宽。**必须 snap**：不 snap 的话捏合每停一档就产生一整套新键的页图，
    /// 缓存被打散且单调涨（主阅读区 2026-08-29 实测 ⌘+ ×5 涨 723MB，堆的就是这批图）。
    /// 与平板同一张阶梯（`LANServer.pageWidthSteps`）。
    private func snapWidth(_ w: CGFloat) -> Int {
        LANServer.snapPageWidth(max(1, Int(w.rounded())))
    }

    private func key(_ i: Int, width: Int) -> String {
        PageRenderEngine.baseKey(doc: model.docKey, page: i, pixelWidth: width, night: nightMode)
    }

    private func kick() {
        guard let pdf = model.pdf, viewport.width > 0 else { return }
        let w = snapWidth(pageW * displayScale)
        scratch.basePixelW = w
        scratch.night = nightMode
        var wanted = Set<String>()
        for i in realized {
            let k = key(i, width: w)
            wanted.insert(k)
            if let hit = PageRenderEngine.shared.cached(k) {
                if images[i] !== hit { images[i] = hit }
                continue
            }
            guard let page = pdf.page(at: i) else { continue }
            PageRenderEngine.shared.request(
                // 落盘：小窗的宽度本来就走档位阶梯（`snapWidth`），键稳定、复用率高。
                .init(key: k, page: page, pixelWidth: w, tileRect: nil, tileScale: 1, night: nightMode,
                      diskCache: true)
            ) { doneKey, img in
                guard scratch.keepRange.contains(i) else { return }   // 页已滚出窗口的迟到完成不写
                // 仍是当前期望的那一版（宽度/夜间都没变过）才写；否则只在这页空着时先顶上。
                let fresh = doneKey == key(i, width: scratch.basePixelW) && scratch.night == nightMode
                if fresh || images[i] == nil { images[i] = img }
            }
        }
        // 🔴 不声明就会被引擎当「无人认领的滞留请求」丢弃 → 完成回调永不触发、小窗永远停在占位。
        PageRenderEngine.shared.setWanted(wanted, client: scratch.clientID)
    }

    /// 夜间切换：先用缓存里的同参异色图**同步顶上**（引擎的夜间快路会把反转结果写回缓存，多数命中），
    /// 没有就先空着——宁可空一下，也不能把亮色图压在夜间模式上。
    private func nightChanged() {
        let w = scratch.basePixelW
        guard w > 0 else { return }
        for i in realized { images[i] = PageRenderEngine.shared.cached(key(i, width: w)) }
        kick()
    }

    // MARK: - 定位到进度

    /// 「打开 = 回到那本书的阅读进度」。几何还没到位时不做——`seedRev` 与 `onScrollGeometryChange`
    /// 两条路都会再叫一次，先到的那条负责。
    private func seedIfReady() {
        guard let layout = model.layout, viewport.height > 0, dispScale > 0, layout.pageCount > 0
        else { return }
        let docY: CGFloat
        if model.seededRev != model.seedRev {
            // 打开 / 换书 / 点了「回到进度」→ 定位到那本书在库里的阅读进度。
            model.seededRev = model.seedRev
            docY = layout.docY(page: model.seedPage, frac: model.seedFrac)
            ZoomProbe.mark(String(format: "REF seed PROGRESS page=%d frac=%.3f docY=%.1f", model.seedPage, model.seedFrac, docY))
        } else if !scratch.restored, let saved = model.viewDocY {
            // 折叠→展开：页流是新建的，但视口该原样接上（方案 §6 的两级语义）。
            scratch.restored = true
            zoom = model.viewZoom
            docY = saved
            ZoomProbe.mark(String(format: "REF seed RESTORE docY=%.1f zoom=%.3f", saved, model.viewZoom))
        } else {
            return
        }
        // 缩放可能刚被上面改过，`dispScale` 要用改后的值重算。
        let sc = max(1, viewport.width * zoom) / PageLayout.refWidth
        let maxY = max(0, layout.totalHeight * sc - viewport.height)
        let y = min(max(0, docY * sc), maxY)
        var t = Transaction(); t.animation = nil
        withTransaction(t) { pos.scrollTo(point: CGPoint(x: 0, y: y)) }
        noteCommitted(CGPoint(x: 0, y: y))
        model.viewDocY = y / sc          // 记忆立刻对齐到刚提交的目标，别等慢半拍的回报
        scratch.positioned = true        // 从这一刻起才允许几何回报改写记忆
        updateRealized()
        kick()
    }

    // MARK: - 缩放

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { v in pinchChanged(v) }
            .onEnded { _ in pinchEnded() }
    }

    /// 捏合。结构照搬主阅读区 `ReaderSurface+Zoom`（那条路径被真机磨过多轮），三条一条都不能省：
    ///
    ///  ① 🔴 **锚点用「刚提交的目标」而不是几何回报**（`anchorOffset`）：回报慢半拍到几帧，
    ///     每帧拿它重推锚点会一路累积漂移；
    ///  ② 🔴 **`withTransaction { animation = nil }` 把 `zoom` 与 `scrollTo` 包成一次原子提交**：
    ///     不禁隐式动画的话，逐帧 scrollTo 会各自起一段动画，手势期间看着是跟手的，
    ///     **松手后那些动画继续落定就是「跳一下」**（用户 2026-08-30 报的正是这个）；
    ///  ③ 限流 ~60Hz：触摸板事件可达 120Hz，而每次提交都要重排整条内容。
    private func pinchChanged(_ v: MagnifyGesture.Value) {
        guard model.layout != nil, viewport.width > 0 else { return }
        if scratch.pinch == nil {
            let o = anchorOffset
            // 手势挂在 ScrollView 容器上 → `startLocation` 是容器（视口）坐标，即屏幕上的不动点。
            let P = v.startLocation
            scratch.pinch = RefPinch(startZoom: zoom, viewportP: P,
                                     cCur: CGPoint(x: o.x + P.x, y: o.y + P.y))
            scratch.zooming = true
            ZoomProbe.mark(String(format: "REF pinch BEGIN zoom=%.3f P=(%.1f,%.1f) anchor=(%.1f,%.1f) geoY=%.1f",
                                  zoom, v.startLocation.x, v.startLocation.y,
                                  anchorOffset.x, anchorOffset.y, geo.offsetY))
        }
        guard var p = scratch.pinch else { return }
        let now = CACurrentMediaTime()
        guard now - scratch.lastCommitAt >= 1.0 / 62 else { return }
        scratch.lastCommitAt = now
        commitZoom(to: clampZoom(p.startZoom * max(0.05, v.magnification)), pinch: &p)
        scratch.pinch = p
    }

    private func pinchEnded() {
        ZoomProbe.mark(String(format: "REF pinch END zoom=%.3f geoY=%.1f pend=%.1f viewDocY=%.2f",
                              zoom, geo.offsetY, scratch.pendingTarget?.y ?? -1, model.viewDocY ?? -1))
        scratch.pinch = nil
        // 解冻要等一拍：立刻放行的话，第一条回来的仍是「旧偏移配新缩放」，拿它写记忆就是又跑偏一次。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            scratch.zooming = false
            ZoomProbe.mark(String(format: "REF unfreeze geoY=%.1f pend=%.1f viewDocY=%.2f",
                                  geo.offsetY, scratch.pendingTarget?.y ?? -1, model.viewDocY ?? -1))
        }
    }

    /// 锚点计算用的「当前」偏移：优先用刚提交、尚未被回报确认的目标。
    private var anchorOffset: CGPoint {
        scratch.pendingTarget ?? CGPoint(x: geo.offsetX, y: geo.offsetY)
    }

    // MARK: ⌘+滚轮缩放（光标为锚，与主阅读区 `ReaderSurface+Zoom` 同一套做法与手感旋钮）
    //
    // SwiftUI 没有滚轮 API → `NSEvent` 本地监视器（**纯事件管道，不引 AppKit 视图**，
    // 与阅读区那条红线的分寸一致）。只在「⌘按住 + 光标在小窗页流里 + 非动量惯性 + 无进行中捏合」
    // 时消费，其余原样 `return event` 放行——光标在主阅读区时 `cursorP` 为 nil，
    // 事件照旧落到阅读区自己的监视器上，两者互不抢。

    private func installWheelMonitor() {
        guard scratch.wheelMonitor == nil else { return }
        scratch.wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.modifierFlags.contains(.command),
                  event.momentumPhase == [],
                  let p = scratch.cursorP,
                  model.layout != nil, viewport.width > 0, scratch.pinch == nil else { return event }
            var delta = event.scrollingDeltaY
            if !event.hasPreciseScrollingDeltas { delta *= 10 }   // 有级滚轮（行单位）放大到像素量级
            guard delta != 0 else { return nil }
            let factor = min(max(exp(-delta * 0.008), 0.5), 2)    // 手感旋钮 0.008；负号 = 系统缩放方向约定
            wheelZoom(factor: factor, anchorP: p)
            return nil   // 消费：⌘滚轮不再触发小窗滚动
        }
    }

    private func removeWheelMonitor() {
        if let m = scratch.wheelMonitor {
            NSEvent.removeMonitor(m)
            scratch.wheelMonitor = nil
        }
    }

    /// 一次滚轮缩放 = 一次性的捏合账本（同主阅读区 `zoomCommit`）：走 `commitZoom` 那条原子提交，
    /// 于是「锚点不动 / 禁隐式动画 / 记忆同步」三件事与捏合完全一致，不必再写第二套。
    private func wheelZoom(factor: CGFloat, anchorP P: CGPoint) {
        guard model.layout != nil, viewport.width > 0 else { return }
        let o = anchorOffset
        var p = RefPinch(startZoom: zoom, viewportP: P, cCur: CGPoint(x: o.x + P.x, y: o.y + P.y))
        commitZoom(to: clampZoom(zoom * factor), pinch: &p)
    }

    private func clampZoom(_ z: CGFloat) -> CGFloat { min(max(z, 1), 6) }

    /// 原子缩放提交：布局（`zoom`）与偏移（`scrollTo`）写在同一个 runloop = 同一次 CA commit。
    private func commitZoom(to z1: CGFloat, pinch p: inout RefPinch) {
        guard let layout = model.layout else { return }
        let z0 = zoom
        guard abs(z1 - z0) > 0.0001 else { return }
        let r = z1 / z0
        let c1 = CGPoint(x: p.cCur.x * r, y: p.cCur.y * r)   // 内容坐标随内容尺寸等比放大
        let target = clampOffset(CGPoint(x: c1.x - p.viewportP.x, y: c1.y - p.viewportP.y),
                                 zoom: z1, layout: layout)
        ZoomProbe.mark(String(format: "REF commit z %.3f→%.3f | anchorY=%.1f cCurY=%.1f → targetY=%.1f (geoY=%.1f pend=%.1f) contH=%.1f",
                              z0, z1, p.viewportP.y, c1.y, target.y, geo.offsetY,
                              scratch.pendingTarget?.y ?? -1,
                              layout.totalHeight * max(1, viewport.width * z1) / PageLayout.refWidth))
        var t = Transaction(); t.animation = nil
        withTransaction(t) {
            zoom = z1
            pos.scrollTo(point: target)
        }
        p.cCur = c1
        noteCommitted(target)
        model.viewZoom = z1
        model.viewDocY = target.y / (max(1, viewport.width * z1) / PageLayout.refWidth)
    }

    private func clampOffset(_ o: CGPoint, zoom z: CGFloat, layout: PageLayout) -> CGPoint {
        let pw = max(1, viewport.width * z)
        let cw = max(pw, viewport.width)
        let ch = layout.totalHeight * pw / PageLayout.refWidth
        return CGPoint(x: min(max(0, o.x), max(0, cw - viewport.width)),
                       y: min(max(0, o.y), max(0, ch - viewport.height)))
    }

    /// 记下「刚提交了这个偏移」，几何回报据此分辨自己是不是陈旧的。
    private func noteCommitted(_ target: CGPoint) {
        scratch.pendingTarget = target
        scratch.pendingSince = CACurrentMediaTime()
    }
}

/// 页流里那些「必须逃过 View 值拷贝」的可变量（见 `RefPageStream.scratch`）。
final class RefScratch {
    /// 渲染引擎的认领 id（**一个页流实例一个**，理由见 `RefWindowModel.renderClients`）。
    /// 🔴 不声明 `setWanted` 的话，`PageRenderEngine` 会把入队超 1s 无人认领的请求直接丢弃，
    /// 结果是「完成回调永不触发、小窗永远停在占位图」。
    let clientID = "ref-" + UUID().uuidString
    var basePixelW = 0
    var night = false
    /// 允许留图的页范围（= 实化窗口，`updateRealized` 维护）。渲染完成回调按它守门，同主阅读区
    /// `Scratch.keepRange`：迟到的完成不能把早已滚出窗口的页写回 `images`。
    var keepRange: ClosedRange<Int> = 0...Int.max
    /// 本次视图生命周期内是否已经恢复过视口（折叠→展开只恢复一次，之后照常滚动）。
    var restored = false
    /// 初始定位是否已完成。🔴 **完成之前绝不让几何回报改写视口记忆**：ScrollView 重建后的
    /// 第一条回报必然是 `offsetY = 0`，那一下会把记忆抹平——「折叠再打开滚动位置就丢失了」
    /// （用户 2026-08-30 报）就是它。
    var positioned = false
    /// 捏合进行中。回报的几何慢半拍（旧偏移配新缩放），此时的记忆由 `applyZoom` 自己维护。
    var zooming = false
    /// 捏合进行中的状态（起手倍率 / 屏幕不动点 / 该点当前的内容坐标）。
    var pinch: RefPinch?
    /// 刚提交给 ScrollView 的偏移目标 + 提交时刻。几何回报靠它分辨自己陈不陈旧。
    var pendingTarget: CGPoint?
    var pendingSince: CFTimeInterval = 0
    var lastCommitAt: CFTimeInterval = 0
    /// 光标在小窗页流里的位置（容器坐标；域外为 nil）。⌘+滚轮缩放的锚点，也是「这一下归不归我」的判据。
    var cursorP: CGPoint?
    /// ⌘+滚轮监视器的登记凭据（`NSEvent.addLocalMonitorForEvents` 的返回值）。
    var wheelMonitor: Any?
}

/// 一次捏合的锚点账本：屏幕上的不动点 `viewportP`，以及它当前对应的**内容坐标** `cCur`。
/// 每次提交后 `cCur` 按倍率就地更新——**不从几何回报重推**，那是漂移的来源。
struct RefPinch {
    var startZoom: CGFloat
    var viewportP: CGPoint
    var cCur: CGPoint
}

/// 一页：白纸打底 + 页图铺满。**只有这两样**——参考窗没有笔迹、注解、选区、OCR 框（对比 `PageCellView`
/// 那二十来个参数），所以另写一个七行的元胞比复用它干净得多。
private struct RefPageCell: View {
    let size: CGSize
    let image: CGImage?
    let paper: Color

    var body: some View {
        Rectangle()
            .fill(paper)
            .frame(width: size.width, height: size.height)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.high)
                }
            }
    }
}
