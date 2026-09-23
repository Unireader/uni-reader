import AppKit
import Combine
import QuartzCore

/// 滚动锚点：本机滚动上报（节流）、接收别处发来的锚点（平板 / 目录 / 搜索 / 跳转）并平滑跟随。
/// 跟随**只跟随不预测**（临界阻尼低通，`ScrollFollower`，红线：禁速度外推）。
extension ReaderView {

    // MARK: 本机滚动

    /// clip view 的 bounds 变了（滚动 / 缩放 / 程序化定位）。
    @objc func clipBoundsChanged(_ note: Notification) {
        guard didSetup, !tornDown else { return }
        updateRealized()
        layoutOverlay()
        updateEraserRing()
        session.readHFrac = fitBasis > 0 ? Double(max(0, clipView.bounds.minX) / fitBasis) : 0
        maybeEmit()
        scheduleSettle()
    }

    /// 上报当前位置（页 + 页内比例）给平板与进度。程序化滚动 / 缩放期间、跟随进行中都不发（防回环）；
    /// 限到 120Hz、位置没实质变化不发。
    func maybeEmit() {
        guard let layout = pageLayout else { return }
        let now = CACurrentMediaTime()
        guard !follower.isSuppressing, now >= suppressEmitUntil, !isZooming, !relayouting,
              now - lastEmitAt >= 1.0 / 120 else { return }
        let (page, frac) = layout.locate(docY: topDocY)
        if let last = lastEmitted, last.page == page, abs(last.frac - frac) < 0.0005 { return }
        // 进度排查：滚动一帧跨过大半页以上就是位置算飞了（正常滚动做不到）。把当时的几何一并记下来——
        // 「跑到不知道什么地方」若是本机算出来的，现场就在这一行（`ProgressLog`，默认关）。
        if let last = lastEmitted, ProgressLog.enabled,
           abs((Double(page) + frac) - (Double(last.page) + last.frac)) > 0.75 {
            ProgressLog.log("滚动跳变 \(ProgressLog.pos(last.page, last.frac)) → \(ProgressLog.pos(page, frac)) "
                + String(format: "topDocY=%.1f ds=%.3f fit=%.1f clipY=%.1f clipH=%.1f docH=%.1f ",
                         Double(topDocY), Double(ds), Double(fitBasis), Double(clipView.bounds.minY),
                         Double(clipView.bounds.height), Double(docView.frame.height))
                + "缩放中=\(isZooming) 跟随中=\(follower.isActive) "
                + ProgressLog.doc(session.documentId, session.title))
        }
        lastEmitAt = now
        lastEmitted = (page, frac)
        session.emitAnchor(page: page, frac: frac, origin: "mac")
    }

    // MARK: 别处发来的锚点

    func incomingAnchor(_ a: ScrollAnchor?) {
        guard let a, a.origin != "mac", a.seq > lastAppliedSeq else { return }
        lastAppliedSeq = a.seq
        // 还没落位：`setupIfPossible` 会直接读 `session.scrollAnchor` 定位，这里不用管
        guard let layout = pageLayout, didSetup else { return }
        follower.pageCount = layout.pageCount
        follower.interpEnabled = interpEnabled
        let cur = layout.locate(docY: topDocY)
        var target = a
        if a.origin == "search" {
            // 搜索命中落在视口**中间**而不是贴顶（贴顶常被工具栏 / 查找条挡住，用户 2026-09-17）
            let matchDocY = layout.docY(page: a.page, frac: a.frac)
            let halfViewport = (clipView.bounds.height / max(0.0001, ds)) / 2
            let centered = layout.locate(docY: matchDocY - halfViewport)
            target.page = centered.page
            target.frac = centered.frac
        }
        follower.apply(target, currentProgress: Double(cur.page) + cur.frac)
        if a.origin == "search", UserDefaults.standard.object(forKey: "matchPulseEnabled") as? Bool ?? true {
            matchPulsePending = true
        }
        startFrameLink()
    }

    func followStep() {
        guard let layout = pageLayout else { follower.reset(); return }
        guard let prog = follower.step(now: CACurrentMediaTime()) else { return }
        let y = layout.docY(progress: prog) * ds - insetTopDoc
        scrollClip(to: NSPoint(x: clipView.bounds.minX, y: y))
        if matchPulsePending, !follower.isActive {
            matchPulsePending = false
            beginMatchPulse()
        }
    }

    /// 搜索命中闪烁：跟随落位（目标真的进了视口）才开始。
    func beginMatchPulse() { beginMatchPulseAnimation() }

    // MARK: 订阅

    func installObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(clipBoundsChanged(_:)),
                       name: NSView.boundsDidChangeNotification, object: clipView)
        observers.append(nc.addObserver(forName: NSScrollView.willStartLiveMagnifyNotification,
                                        object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveMagnifyStarted() }
        })
        observers.append(nc.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification,
                                        object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveMagnifyEnded() }
        })
        // 滚动条样式变了（系统设置改「始终显示滚动条」/ 插拔鼠标）：常驻要占一列、覆盖式不占，
        // 而 `fitAvail` 把这一列算在内，所以得按新样式重排一次（外框没变，`layout()` 自己不会被叫醒）。
        observers.append(nc.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refitNow() }
        })
        // 夜间模式（`@AppStorage("nightMode")`，窗口层的开关与自动跟随系统都写它）
        observers.append(nc.addObserver(forName: UserDefaults.didChangeNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.nightDefaultsChanged()
                self?.enhanceDefaultsChanged()
            }
        })
        // 菜单 / 工具栏的缩放命令：只有活跃窗口认领
        let zoomCommands: [(Notification.Name, (ReaderView) -> Void)] = [
            (.readerZoomIn, { $0.commandZoom(factor: 1.25) }),
            (.readerZoomOut, { $0.commandZoom(factor: 1 / 1.25) }),
            (.readerZoomFit, { $0.commandZoomFit() }),
            (.readerZoomActual, { $0.commandZoomActual() }),
        ]
        for (name, action) in zoomCommands {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isActiveWindow else { return }
                    action(self)
                }
            })
        }

        // 会话：@Published 在写入**之前**发，读会话的回调一律挪到下一拍（`DispatchQueue.main` 各种 runloop 模式都走）
        session.$foreignAnchor
            .receive(on: DispatchQueue.main)
            .sink { [weak self] a in self?.incomingAnchor(a) }
            .store(in: &bag)
        session.$strokes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshInk()
                self?.refreshCanvasMargin()
            }
            .store(in: &bag)
        session.$inkMovedRev
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshCanvasMargin() }
            .store(in: &bag)
        session.$liveStroke
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshLive()
                self?.growCanvasForLive()
            }
            .store(in: &bag)
        session.$canvasMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.canvasModeChanged(on) }
            .store(in: &bag)
        session.$ocrEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in
                guard let self, on, self.didSetup else { return }
                self.session.enqueueOCR(Array(self.realized))
            }
            .store(in: &bag)
        session.$revealNoteID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in self?.revealNote(id) }
            .store(in: &bag)

        // 关窗 teardown（`DocSession.teardown`）替本阅读区放掉帧驱动与防抖任务
        let cid = clientID
        session.renderClients[cid] = { [weak self] in self?.releaseRetainers() }
    }

    func nightDefaultsChanged() {
        let n = UserDefaults.standard.bool(forKey: "nightMode")
        guard n != nightLive else { return }
        nightLive = n
        guard didSetup else { imagesNight = n; applyNightColors(); return }
        scheduleNightRender()
    }

    /// 扫描页增强的开关 / 参数变了（菜单切换、设置页拖滑块都写 UserDefaults）。
    /// 防抖 0.3 秒：拖滑块时每一帧都在写，停手再按新参数出图。
    func enhanceDefaultsChanged() {
        let p = ScanEnhance.params(for: session.contentHash)
        enhanceWork?.cancel()
        guard p != enhanceLive else { enhanceWork = nil; return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.tornDown else { return }
            self.enhanceWork = nil
            let now = ScanEnhance.params(for: self.session.contentHash)
            guard now != self.enhanceLive else { return }
            self.enhanceLive = now
            self.staleImages = Set(self.images.keys)
            self.staleTiles = Set(self.tiles.keys)
            guard self.didSetup else { return }
            self.settleRender()
        }
        enhanceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
