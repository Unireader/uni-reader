import SwiftUI
import PDFKit
import QuartzCore
import AppKit

extension ReaderSurface {
    // MARK: 滚动几何（锚点上报 / 实化窗口 / commit 校验）

    func geometryChanged(_ raw: GeoSnap) {
        var n = raw
        // 首帧兜底：切文档时 ScrollView 被 `.id(docKey)` 整体重建，onScrollGeometryChange 未必重发首帧
        // 几何（容器尺寸与旧文档相同 → SwiftUI 认为"没变化"不回调）→ 新文档首屏空白，须拖窗口才恢复。
        // scroll 几何缺席（containerW≤0）时，用外层 GeometryReader 的 unobSize（布局同步可得、与内容无关）
        // 兜底填容器尺寸，仅供实化窗口/偏移使用，**绝不参与宽度/fit 决策**（那些只依赖 fullWidth，见 fitAvail 注释）。
        if n.containerW <= 0, unobSize.width > 0 {
            n.containerW = unobSize.width
            n.containerH = unobSize.height
        }
        scratch.geo = n
        guard let layout else { return }
        // ⚠️ 此处严禁读取 n.containerW/contentW 做宽度决策（会与内容互抬成环，见 fitAvail 注释）。
        // 首帧定基准必须等 `fullWidth > 0`（后台 GeometryReader 慢半拍）——否则 layoutW 回退未遮宽=窄，
        // 会把窄页渲染出来、40ms 后再跳到整窗宽 = 启动闪烁。未就绪则整体早退（didInitialGeo 前不实化/不渲染）。
        if !scratch.didInitialGeo {
            guard n.containerW > 0, fullWidth > 0 else { return }
            // ⚠️ **`fullWidth > 0` 挡不住 SwiftUI 的占位几何**（2026-08-10 日志实测：开窗首帧
            // `fullWidth=100`，真实值 900）。窗口帧恢复 / 分栏落位之前，两个 GeometryReader 会先报
            // 一个占位尺寸；按它定基准就是整条页图流按 83pt 页宽排版并真的出图，落位后再跳到 883
            // ——用户看到的「开窗一瞬页面很小、然后突然放大」。
            // 侧栏最小宽本身就有 200pt（`navigationSplitViewColumnWidth(min: 200)`），所以比这还窄的
            // 全宽不可能是真实布局。等真实测量到达再定基准；等待期间 didInitialGeo 仍为假 =
            // 不实化、不渲染 = **留白**，与 `RootView.resolve` 同一取舍：宁可白一下也不闪一下。
            // 重新进入本函数由 `onChange(of: fullWidth)` / `onChange(of: unobSize.width)` /
            // `onScrollGeometryChange` 三路兜底保证——占位值一旦被真实布局替换必然触发其中之一。
            guard layoutW >= minPlausibleLayoutW else { return }
            scratch.didInitialGeo = true
            fitBasis = fitAvail                   // 首帧定 fit 基准（全窗宽 − legacy 滚动条占位）
            // 恢复上次缩放（相对 fit 的倍率）：此刻定标 zoom 即首帧就以正确页宽渲染；
            // 随后 pendingRestore 的 page/frac 锚点用带缩放的 dispScale 换算 → 位置仍准。
            let rz = clampZoom(scratch.pendingZoom)
            // 恢复来的倍率也要置 userZoomed（否则窗口一变宽就被当成 fit 模式重排），但同时打上
            // `zoomFromRestore` —— 启动瞬态宽度落位时 refit 要按新基准重算倍率而不是锁死绝对页宽。
            if abs(rz - 1) > 0.001 { zoom = rz; userZoomed = true; scratch.zoomFromRestore = true }
            scratch.lastRefitFullW = fullWidth
        }
        verifyPendingTarget(n)
        scratch.topDocY = (n.offsetY + n.insetTop) / max(0.0001, dispScale)
        updateRealized(n, layout: layout)
        if let a = scratch.pendingRestore {
            scratch.pendingRestore = nil
            follower.pageCount = layout.pageCount
            follower.apply(a)
        }
        // 横向恢复（一次性）：缩放态才有横向可滚。定位到上次的页宽比例，跟随器只驱动 y、保持 x。
        if let hf = scratch.pendingHFrac {
            scratch.pendingHFrac = nil
            if pageW > fitAvail + 0.5 {
                let target = clampOffset(CGPoint(x: hf * pageW, y: n.offsetY), pageWidth: pageW)
                pos.scrollTo(point: target)
            }
        }
        // 上报当前横向比例（非 @Published，不触发重渲；存进度时读）。
        session.readHFrac = pageW > 0 ? Double(n.offsetX / pageW) : 0
        maybeEmit(n, layout: layout)
        scheduleSettleRender()
    }

    /// commit 校验环：同 runloop 原子提交已由 spike 证实；此处兜底（万一被夹取/竞争）。
    func verifyPendingTarget(_ n: GeoSnap) {
        guard let t = scratch.pendingTarget else { return }
        if abs(n.offsetX - t.x) <= 1, abs(n.offsetY - t.y) <= 1 {
            scratch.pendingTarget = nil
        } else if scratch.pendingTries < 5 {
            scratch.pendingTries += 1
            pos.scrollTo(point: t)   // ⚠️ 单轴 scrollTo(x:)/(y:) 是后写覆盖+重置另一轴（scroll-x-probe T1/T4），全文件禁用
        } else {
            scratch.pendingTarget = nil   // 5 次未达放弃（同 runloop 原子提交已由 spike 证实，此处仅兜底）
        }
    }

    func updateRealized(_ n: GeoSnap, layout: PageLayout) {
        let ds = max(0.0001, dispScale)
        let buffer = n.containerH / ds                    // 上下各约一屏预实化
        let top = n.offsetY / ds - buffer
        let bottom = (n.offsetY + n.containerH) / ds + buffer
        var range = layout.pageRange(fromDocY: top, toDocY: bottom)
        // 缩放进行中（按钮/⌘± 动画、捏合、⌘滚轮）：实化窗口**只扩不缩**，且一页都不驱逐。两个理由：
        //  ① 每帧收缩再扩张 → `realized` 反复变动，每变一次多一轮完整 body 重算（掉帧）；
        //  ② 收缩驱逐的正是刚还在屏幕上的页，缩放过程中它又回到视口 → 无图 → 白纸（用户报的"白屏"）。
        // 缩放收尾的 settleRender 会显式再跑一次本函数，那时 zooming 已假、窗口正常收回。
        let zooming = isZooming
        if zooming {
            range = min(range.lowerBound, realized.lowerBound)...max(range.upperBound, realized.upperBound)
        }
        if range != realized || !scratch.didFirstKick {
            scratch.didFirstKick = true
            realized = range
            if !zooming {
                var evict = [Int]()
                for k in images.keys where k < range.lowerBound - 2 || k > range.upperBound + 2 { evict.append(k) }
                for k in evict { images.removeValue(forKey: k) }
                for k in tiles.keys where !(range ~= k) { tiles.removeValue(forKey: k) }
            }
            kickBaseRenders()
            if session.ocrEnabled { session.enqueueOCR(Array(range)) }   // 「看到哪页处理哪页」：可见窗口入队 OCR
        }
        // 顶端页 → currentPageIndex（非程序化滚动期间；平板/进度依赖它）
        if !follower.isSuppressing, CACurrentMediaTime() >= scratch.suppressEmitUntil {
            let page = layout.locate(docY: scratch.topDocY).page
            if session.currentPageIndex != page { session.currentPageIndex = page }
        }
    }

    func maybeEmit(_ n: GeoSnap, layout: PageLayout) {
        let now = CACurrentMediaTime()
        guard !follower.isSuppressing,
              now >= scratch.suppressEmitUntil,
              scratch.pendingTarget == nil,
              now - scratch.lastEmitAt >= 1.0 / 120 else { return }
        let (page, frac) = layout.locate(docY: scratch.topDocY)
        if let last = scratch.lastEmitted, last.page == page, abs(last.frac - frac) < 0.0005 { return }
        scratch.lastEmitAt = now
        scratch.lastEmitted = (page, frac)
        session.emitAnchor(page: page, frac: frac, origin: "mac")
    }

    // MARK: 窗口/侧栏宽度变化（硬指标 3/4：resize 不闪、不跳）
    // 变化期间布局冻结（页尺寸不变 → 纵向绝对稳定）；稳定 0.2s 后一次性处理：
    //   · 侧栏/Inspector 开合（Option A / Preview 式）→ fullWidth 不变 → fitAvail 不变 → **guard 早退，纯 no-op**
    //     （页面纹丝不动，半透明玻璃盖住左侧——用户 2026-07-21 选定）。unobW 不参与布局。
    //   · 窗口宽真变（fullWidth 变，含 legacy 滚动条出现/消失）→ fit 模式做单次原子锚定 refit；
    //     手动缩放态只重定标基准保持页宽（Preview 的绝对尺寸语义）

    func scheduleRefit() {
        guard scratch.didInitialGeo else { return }
        scratch.resizeWork?.cancel()
        scratch.resizeWork = nil
        // 启动落位期（窗口帧恢复 / 分栏落位，宽度会连环变几次）**不防抖**：那 200ms 是为「用户拖窗口
        // 边框」准备的，落位期没有什么好等的，每多等一帧就是「先按旧基准显示一下再跳」的可见闪动。
        // 首帧定基准已挡掉占位宽（见 geometryChanged），这里是宽度分两步到位时的第二道防线。
        if CACurrentMediaTime() - scratch.appearAt < 1.5 { refitToViewport(); return }
        let work = DispatchWorkItem { refitToViewport() }
        scratch.resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func refitToViewport() {
        guard layout != nil, scratch.didInitialGeo else { return }
        let g = scratch.geo
        let newW = fitAvail                              // 全窗宽 − 滚动条占位（与内容无关，无环；侧栏开合不改它 → 下方 guard 早退）
        let windowWidthChanged = abs(fullWidth - scratch.lastRefitFullW) > 0.5
        scratch.lastRefitFullW = fullWidth
        guard abs(newW - fitBasis) > 0.5 || windowWidthChanged else { return }   // 无实质变化
        // 启动稳定窗（窗口恢复/分栏落位的瞬态宽度会连环变化）：未缩放前一律真 fit，
        // 否则首帧捕获的瞬态宽会被「零视觉变化」重定标逻辑永久锁死（页宽偏窄、跑到左边）。
        let inStartupWindow = CACurrentMediaTime() - scratch.appearAt < 1.5
        let startupSettling = !userZoomed && inStartupWindow
        // 恢复来的缩放：库里存的是**相对 fit 的倍率**，所以启动瞬态宽度落位时要按新基准重算倍率
        // （zoom 保持 = 页宽跟着窗口走），而**不能**走下面的「尺寸保持」——那会把首帧那个瞬态宽度
        // 对应的绝对页宽锁死，倍率被反算成别的值（首帧宽偏窄 → 倍率被压小），表现就是
        // 「关掉全部窗口后从 Dock 重开，PDF 恢复了但缩放回到 100%」。用户一动缩放即退出本分支。
        if scratch.zoomFromRestore, inStartupWindow, windowWidthChanged {
            let z = clampZoom(scratch.pendingZoom)
            let oldBasis = basis
            let newPageW = newW * z
            let r = newPageW / max(0.0001, pageW)
            let topDispY = g.offsetY + g.insetTop
            let target = clampOffset(CGPoint(x: g.offsetX * r, y: topDispY * r - g.insetTop),
                                     pageWidth: newPageW)
            var t = Transaction(); t.animation = nil
            withTransaction(t) {
                fitBasis = newW
                zoom = z
                pos.scrollTo(point: target)
            }
            scratch.pendingTarget = target
            scratch.pendingTries = 0
            scratch.suppressEmitUntil = CACurrentMediaTime() + 0.3
            scheduleSettleRender()
            return
        }
        if userZoomed || (!windowWidthChanged && !startupSettling) {
            // 尺寸保持：显示页宽不变，仅重定标 fit 基准 → 零视觉变化（窗口缩放且手动缩放态走这里）
            let eff = pageW
            var t = Transaction(); t.animation = nil
            withTransaction(t) {
                fitBasis = newW
                zoom = min(max(eff / newW, zoomMin), zoomMax)
            }
        } else {
            // fit 模式 + 窗口宽变化：单次原子锚定 refit（顶部文档点钉住）
            let r = newW / pageW
            let topDispY = g.offsetY + g.insetTop
            let target = clampOffset(CGPoint(x: -g.insetLeading, y: topDispY * r - g.insetTop),
                                     pageWidth: newW)
            var t = Transaction(); t.animation = nil
            withTransaction(t) {
                fitBasis = newW
                zoom = 1
                pos.scrollTo(point: target)
            }
            scratch.pendingTarget = target
            scratch.pendingTries = 0
            scratch.suppressEmitUntil = CACurrentMediaTime() + 0.3
        }
        scheduleSettleRender()
    }

    // MARK: 锚点接收 / 跟随

    func incomingAnchor(_ a: ScrollAnchor?) {
        guard let a, a.origin != "mac", a.seq > lastAppliedSeq else { return }
        lastAppliedSeq = a.seq
        guard let layout, scratch.didInitialGeo else {
            scratch.pendingRestore = a
            return
        }
        follower.pageCount = layout.pageCount
        follower.interpEnabled = interpEnabled
        follower.apply(a)
    }

    func followStep() {
        guard let layout else { follower.reset(); return }
        guard let prog = follower.step(now: CACurrentMediaTime()) else { return }
        let y = layout.docY(progress: prog) * dispScale - scratch.geo.insetTop
        // 只驱动 y，x 显式带当前值（单轴 scrollTo 会把另一轴重置为 0——scroll-x-probe T4）
        let clamped = clampOffset(CGPoint(x: scratch.geo.offsetX, y: y), pageWidth: pageW)
        pos.scrollTo(point: clamped)
    }

}
