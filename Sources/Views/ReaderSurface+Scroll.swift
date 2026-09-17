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
        // 🔴 **高度退化的那几拍必须整帧丢掉**（2026-08-29 实测定位，切标签闪烁的真凶）。
        // 上面那条只兜得住「宽退化」；视图重建后 ScrollView 会先来几拍 `containerH == 0` 的几何，
        // 它一路走下去的后果是致命的：`updateRealized` 据此把实化窗口算成 **0…0**，紧接着
        // 「驱逐窗口外页图」把 `images` 清空 —— 切标签刚在 `init` 里种好的那一屏，在 `onAppear`
        // 之前就被当场抹掉了（日志表现：快照明明有料，`已装载` 却恒为 `realized=0…0 图0张`）。
        // 顺带也是坏快照的来源：那一帧算出的 0…0 会被写回快照，自我复制。
        // 先用未遮视口的高度兜一次（与上面同一口径），仍然退化就这一帧什么都不做，等下一拍真几何。
        if n.containerH <= 1, unobSize.height > 0 { n.containerH = unobSize.height }
        guard n.containerH > 1 else { return }
        scratch.geo = n
        guard let layout else { return }
        // 首帧那一趟里 `fitBasis`/`zoom` 正要被写（下面那个 if），此刻读它们同样是旧值，
        // 所以那一趟不拍快照——等下一趟几何回调再拍，反正只差一帧。
        let hadInitialGeo = scratch.didInitialGeo
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
            session.openTrace?.markOnce("定基准", String(format: "fit %.0fpt zoom %.2f", fitAvail, rz))
        }
        verifyPendingTarget(n)
        // 🔴 **刚提交的 scrollTo 慢半拍时，实化按目标算，别按这一拍陈旧的几何**（2026-09-10 账本坐实：
        // 每次切标签都有 `实化 offY 0 … p283–285 → p1–1`，下一拍才 `offY 400327 … → p283–285`——
        // 种子在 `setup` 里提交的 `scrollTo(off)` 还没被 ScrollView 采纳，先来了一拍 offset 0 的几何，
        // 实化窗口于是塌到 p1、刚种好的三个页元胞当场销毁又重建，还白渲一张 p1 占着渲染队列）。
        // `pendingTarget` 非空 = 目标还没达成（`verifyPendingTarget` 达成即清空、5 次未达也清空），
        // 这期间报上来的几何就是过期的。缩放中不这么做：那条路每帧一个新目标，本来就靠「只扩不缩」兜着。
        if let a = scratch.pendingRestore {
            scratch.pendingRestore = nil
            follower.pageCount = layout.pageCount
            follower.apply(a)
            // 🔴 **恢复锚点也登记成 pendingTarget**（2026-09-10 账本：冷开「王道计组」进度在 p285，首帧
            // 曾 `实化 p1–1 需渲1`，p1 那张渲了 200ms 白做、还排在 p285 前面挡着；改成按锚点算之后，
            // **下一拍**仍会来一帧 offset 0 的陈旧几何把窗口塌回 p1——跟随器的 scrollTo 同样慢半拍）。
            // 登记之后直到 ScrollView 真报出目标位置为止，实化输入一律按目标算（下面那段），
            // 滚动本身照旧交给 `followStep`；`verifyPendingTarget` 的兜底重试与它同一个目标，幂等。
            if scratch.pendingTarget == nil {
                let y = layout.docY(page: a.page, frac: a.frac) * dispScale - n.insetTop
                scratch.pendingTarget = clampOffset(CGPoint(x: n.offsetX, y: y), pageWidth: pageW)
                scratch.pendingTries = 0
            }
        }
        if let t = scratch.pendingTarget, !isZooming {
            n.offsetX = t.x
            n.offsetY = t.y
            // `scratch.geo` 也换成按目标算的那份：读它的人（账本的可见页、`refitToViewport` 的锚定、
            // `followStep` 的 x）都不该看到那一拍陈旧的 0。2026-09-10 第六批账本：切标签「总 703ms」
            // 其实是账本按 `scratch.geo.offsetY == 0` 把可见页算成 p1–1、等一张永远不会来的 p1 页图，
            // 直到 0.7s 后进度节流存那一拍才重算——页图 +27、墨迹 +37 早就齐了。
            scratch.geo = n
        }
        scratch.topDocY = (n.offsetY + n.insetTop) / max(0.0001, dispScale)
        let liveRealized = updateRealized(n, layout: layout)
        // 横向恢复（一次性）：缩放态**或画板模式**才有横向可滚（后者 fit 下也有页边）。
        // 定位到上次的页宽比例，跟随器只驱动 y、保持 x。
        if let hf = scratch.pendingHFrac {
            scratch.pendingHFrac = nil
            if contentW > fitAvail + 0.5 {
                let target = clampOffset(CGPoint(x: hf * pageW, y: n.offsetY), pageWidth: pageW)
                pos.scrollTo(point: target)
                // 恢复锚点登记的 pendingTarget 是 x=0 的：横向也滚了就把目标换成带 x 的，否则校验环会把 x 拉回 0
                if scratch.pendingTarget != nil { scratch.pendingTarget = target; scratch.pendingTries = 0 }
            }
        }
        // 上报当前横向比例（非 @Published，不触发重渲；存进度时读）。
        session.readHFrac = pageW > 0 ? Double(n.offsetX / pageW) : 0
        // 留一份「现在长什么样」的快照：切标签回来时 `setup` 靠它让首帧就到位（见 ReaderSnapshot）。
        // 同 `readHFrac`，非 @Published，纯结构体赋值。
        // 阅读区快照（切标签时拿它种回去，见 `DocSession.ReaderSnapshot`）。三道门缺一不可：
        //  · `hadInitialGeo` —— 首帧那一趟 `fitBasis`/`zoom` 正要被写，此刻读到的是旧值；
        //  · `realized` 用 `updateRealized` 的**返回值**，别回头读 `@State`（同上，同一趟读到旧值）；
        //  · 🔴 **几何得是真的、且已经渲过图**：视图重建/布局未落位时会来几拍**退化几何**
        //    （`containerH == 0`）→ `updateRealized` 把实化窗口算成 `0…0`，拿这种帧覆盖快照，
        //    切回来的种子就是空的。2026-08-29 实测就是这条：快照里的 realized 恒为 `0…0`、
        //    页图 0 张，种子「命中」了却什么也没种上，画面照旧先空一帧。
        if hadInitialGeo, n.containerH > 1, scratch.basePixelW > 0 {
            session.readerSnapshot = DocSession.ReaderSnapshot(
                layoutW: layoutW, fitBasis: fitBasis, zoom: zoom, userZoomed: userZoomed,
                basePixelW: scratch.basePixelW, recentBaseWidths: scratch.recentBaseWidths)
        }
        maybeEmit(n, layout: layout)
        scheduleSettleRender()
    }

    /// commit 校验环：同 runloop 原子提交已由 spike 证实；此处兜底（万一被夹取/竞争）。
    ///
    /// 🔴 **缩放进行中不重试**（2026-08-29 真机探针定位）：缩放每帧都提交一个新目标，而
    /// `onScrollGeometryChange` 的回报是异步、慢半拍的 —— 于是每帧拿到的几何都对不上刚提交的
    /// 那个目标，判定"没达成"就补一次 `scrollTo`，那次 scrollTo 又触发一轮几何回调 + body 重算。
    /// 自激的结果：**每个动画帧有约 2 次 contentBody 求值**，日志里表现为"几何回调"在 250ms 窗口里
    /// 占到 33~64ms（比墨迹还贵）。上一帧的目标本来就已经作废，重试它没有任何意义。
    /// 缩放收尾（`settleRender` 那一轮）不在 `isZooming` 内，兜底照旧生效。
    func verifyPendingTarget(_ n: GeoSnap) {
        guard let t = scratch.pendingTarget else { return }
        if abs(n.offsetX - t.x) <= 1, abs(n.offsetY - t.y) <= 1 {
            scratch.pendingTarget = nil
        } else if scratch.pendingTries < 5, !isZooming {
            scratch.pendingTries += 1
            pos.scrollTo(point: t)   // ⚠️ 单轴 scrollTo(x:)/(y:) 是后写覆盖+重置另一轴（scroll-x-probe T1/T4），全文件禁用
        } else {
            scratch.pendingTarget = nil   // 5 次未达放弃（同 runloop 原子提交已由 spike 证实，此处仅兜底）
        }
    }

    /// 返回本帧**settle 后的实化窗口**。
    /// 🔴 一定要用这个返回值，别在调用方转头去读 `realized`：那是 `@State`，同一趟更新里
    /// 刚写完再读回来拿到的还是旧值（2026-08-29 实测——阅读区快照里的 `realized` 一直是初值
    /// `0…0`，于是切标签的种子等于没种，页图一张都取不回来）。
    @discardableResult
    func updateRealized(_ n: GeoSnap, layout: PageLayout) -> ClosedRange<Int> {
        let ds = max(0.0001, dispScale)
        // 🔴 **非活跃窗口只实化可见页、图也只留可见页**（2026-09-10 定）。上下各一屏的预实化 +
        // 图再多留 ±2 页，是给正在滚动的那个窗口准备的；后台窗口没人滚，却照样各攥一套——
        // 三个窗口开着就是三套，活动监视器 2.3GB 的主项就是它（每张图还有 CA 副本，×2）。
        // 代价：在非活跃窗口里滚动时，滑入的页要等渲染/磁盘解码（5~13ms/页）才出图，没有预热。
        let active = scratch.isActiveWindow
        let buffer = active ? n.containerH / ds : 0       // 活跃窗口上下各约一屏预实化
        let keepMargin = active ? 2 : 0                   // 图比实化窗口多留几页（滑回来立刻有图）
        let top = n.offsetY / ds - buffer
        let bottom = (n.offsetY + n.containerH) / ds + buffer
        var range = layout.pageRange(fromDocY: top, toDocY: bottom)
        // 缩放进行中（按钮/⌘± 动画、捏合、⌘滚轮）：**一页都不驱逐**（见下面的 `if !zooming`）。
        // 驱逐掉的正是刚还在屏幕上的页，缩放过程中它又回到视口 → 无图 → 白纸（用户报过的"白屏"）。
        // 窗口本身照实跟随视口收缩，只是图留在 `images`/`tiles` 里，滑回来立刻有图。
        //
        // 🔴 这里曾经还把窗口**冻成"只扩不缩"**（理由：`realized` 每变一次多一轮 body 重算）。
        // 2026-08-29 真机探针（`ZoomProbe`）实测证明那是笔糊涂账：缩小时锚点缩放会让 offset 大幅
        // 移动，"只扩不缩"的并集一路涨到 **74 页**（96…169，而视口只在 p128 附近 3 页），
        // 每帧要构建/布局/渲染 74 个 `PageCellView` ≈ 26ms。实测每页每帧约 0.35ms，且严格线性：
        // 实化 14 页 = 195fps / 30 页 = 55fps / 74 页 = 36fps。省下的那点 range 变动开销，
        // 换来的是二十倍的无用页——用户报的"缩放卡顿"主项就是它（且卡的都是**看不见的邻页**，
        // 所以"我缩放的页明明没有笔迹"和"照样卡"并不矛盾）。
        let zooming = isZooming
        // 缩放中**只扩不缩，但带上界**。两个方向的坑各踩过一次，这里同时躲开：
        //  ① 会收缩 → `realized` 一缩，刚还在屏幕上的 `PageCellView` 当场销毁，下一帧视口晃回来
        //     又要重建 —— 用户看到的就是「缩放时 PDF 页闪烁」（2026-08-29 报）。光"不驱逐 images"
        //     救不了：闪的是**视图**的销毁重建，不是图没了。
        //  ② 无上界的只扩不缩 → 缩小时锚点缩放让 offset 大幅移动，并集一路累积到 **74 页**，
        //     每帧构建 74 个页元胞 ≈ 26ms（36fps）。这是同一天早些时候的那个真凶。
        // 于是：合并（不缩），但合并结果超过「当前视口窗口 + 8 页」就放弃合并、直接跟随视口
        // ——只在真跑远了才收一次，日常缩放里窗口是稳的，不会反复抖。
        if zooming {
            let merged = min(range.lowerBound, realized.lowerBound)...max(range.upperBound, realized.upperBound)
            if merged.count <= range.count + 8 { range = merged }
        } else {
            scratch.keepRange = max(0, range.lowerBound - keepMargin)...(range.upperBound + keepMargin)
        }
        if range != realized || !scratch.didFirstKick {
            scratch.didFirstKick = true
            // 缩放中新滑入的页要补墨迹快照（在 realized 换掉之前算差集），否则那几页会逐帧重画 = 闪
            if zooming, inkFastDraw {
                addInkSnapshots(for: Set(range).subtracting(Set(realized)))
            }
            // 打开耗时账本：切标签的日志里 `首批页图` 一律是 `实化 p1–1 需渲1`，而首帧 body 已是正确的页
            // ——某一拍几何的 offset 是 0。把每次实化变更的输入记下来（账结清后 `mark` 自动不记）。
            session.openTrace?.mark("实化", "offY \(Int(n.offsetY)) H \(Int(n.containerH)) ds \(String(format: "%.2f", ds))"
                + " p\(realized.lowerBound + 1)–\(realized.upperBound + 1) → p\(range.lowerBound + 1)–\(range.upperBound + 1)")
            realized = range
            if !zooming {
                let keep = scratch.keepRange
                let evict = images.keys.filter { !keep.contains($0) }
                for k in evict { releaseImage(page: k) }
                for k in tiles.keys where !(range ~= k) { tiles.removeValue(forKey: k) }
            }
            ZoomProbe.measure("页图调度") { kickBaseRenders() }
            if session.ocrEnabled { session.enqueueOCR(Array(range)) }   // 「看到哪页处理哪页」：可见窗口入队 OCR
        }
        // 顶端页 → currentPageIndex（非程序化滚动期间；平板/进度依赖它）
        // 有 pendingRestore 时本帧偏移还是 0（恢复锚点在 geometryChanged 后段才应用），
        // 照它回写会把 ContentView 已恢复的页码打回第 1 页 → 标题显示 1/xxxx 直到用户滚动。
        if scratch.pendingRestore == nil, !follower.isSuppressing, CACurrentMediaTime() >= scratch.suppressEmitUntil {
            let page = layout.locate(docY: scratch.topDocY).page
            if session.currentPageIndex != page { session.currentPageIndex = page }
        }
        return range
    }

    func maybeEmit(_ n: GeoSnap, layout: PageLayout) {
        let now = CACurrentMediaTime()
        guard scratch.pendingRestore == nil,          // 恢复锚点未应用前偏移仍是 0，会误发 (0,0) 锚点
              !follower.isSuppressing,
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
        // 跑完置空——否则 `scratch → resizeWork → 闭包 → self 拷贝 → scratch` 成环，见 `scheduleSettleRender`。
        let work = DispatchWorkItem {
            scratch.resizeWork = nil
            refitToViewport()
        }
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
        let cur = layout.locate(docY: scratch.topDocY)
        var target = a
        if a.origin == "search" {
            // 搜索命中要落在视口**中间**，不是贴顶——贴顶常被工具栏/查找胶囊挡住，找到了也看不见
            // （用户 2026-09-17 实测反馈）。把命中行的文档 Y 上移半个视口高度再反解回 page/frac，
            // 落地时 `followStep` 那套「对齐到顶」的公式算出来就正好是「对齐到中间」。
            let ds = max(0.0001, dispScale)
            let matchDocY = layout.docY(page: a.page, frac: a.frac)
            let halfViewportDocY = (scratch.geo.containerH / ds) / 2
            let centered = layout.locate(docY: matchDocY - halfViewportDocY)
            target.page = centered.page
            target.frac = centered.frac
        }
        follower.apply(target, currentProgress: Double(cur.page) + cur.frac)
        // 闪烁不在这里现发——滚动动画还在半路上，此刻目标多半还没进视口，闪完用户也没看见
        // （长距离跳转尤其明显）。改成等 `followStep` 侦测到跟随落位（`isActive` 转假）才真正播。
        // `matchPulseEnabled` 关掉时干脆不进这条支路：`matchPulseT` 保持默认的 1，
        // `PageCellView` 天然只画常态高亮（0.55 透明度、无外扩），没有额外分支要维护。
        if a.origin == "search", matchPulseEnabled { scratch.matchPulsePending = true }
    }

    func followStep() {
        guard let layout else { follower.reset(); return }
        guard let prog = follower.step(now: CACurrentMediaTime()) else { return }
        let y = layout.docY(progress: prog) * dispScale - scratch.geo.insetTop
        // 只驱动 y，x 显式带当前值（单轴 scrollTo 会把另一轴重置为 0——scroll-x-probe T4）
        let clamped = clampOffset(CGPoint(x: scratch.geo.offsetX, y: y), pageWidth: pageW)
        pos.scrollTo(point: clamped)
        // 跟随刚落位（这一步过后 `isActive` 转假）：目标此刻真的在视口里了，这才开始闪烁。
        if scratch.matchPulsePending, !follower.isActive {
            scratch.matchPulsePending = false
            beginMatchPulse()
        }
    }

    // MARK: 搜索命中闪烁（滚动跟随落位后触发，见 `followStep`）
    //
    // 阅读区无隐式动画红线（`PageStreamView.contentBody` 的 `.transaction { $0.animation = nil }`）
    // 覆盖了整个页元胞子树，`withAnimation` 在这里会被吞掉、静默不生效——所以跟 `zoomAnimStep` 同款，
    // 逐帧手动算出一个 0…1 的进度值直接赋给 `@State`，靠数值本身的连续变化产生动画观感。

    var matchPulseDuration: CFTimeInterval { 0.45 }   // 计算属性：扩展里不能放存储属性

    func beginMatchPulse() {
        scratch.matchPulseStartedAt = CACurrentMediaTime()
        matchPulseT = 0
        matchPulseOn = true
    }

    func matchPulseStep() {
        let t = CGFloat(min(1, (CACurrentMediaTime() - scratch.matchPulseStartedAt) / matchPulseDuration))
        matchPulseT = t
        if t >= 1 { matchPulseOn = false }
    }

}
