import AppKit
import Combine
import QuartzCore

/// 参考窗里的**只读页图流**（AppKit 版，替代 SwiftUI `RefPageStream`）：连续多页、自由滚动、捏合 / ⌘+滚轮缩放，仅此而已。
///
/// 主阅读区的一个很小子集：没有笔迹、没有注解、没有选择，不上报阅读进度（`REF-WINDOW-PLAN.md §3` 红线）。
/// 与阅读区共用 `ReaderScrollView` / `ReaderClipView`（系统放大倍率 + 窄内容居中）、`PageLayout`、`PageRenderEngine`。
///
/// 坐标：文档视图宽 = 视口宽（fit），页宽 = 视口宽，`sc = 视口宽 / PageLayout.refWidth`；缩放全交给滚动视图的
/// `magnification`（1…6）。视口记忆 `model.viewDocY` 用**布局单位**记（与缩放、视口宽都无关）。
///
/// 纪律沿用阅读区：图层无隐式动画（`QuietLayer`）、图只替换不清空、实化窗口有上界且滚出窗口的页图要丢。
@MainActor
final class RefPageStreamView: NSView {
    let model: RefWindowModel
    let host: RefViewHost

    private let scrollView = ReaderScrollView()
    private let docView = ReaderDocumentView()
    private var pages: [Int: QuietLayer] = [:]
    private var images: [Int: CGImage] = [:]
    private var realized: ClosedRange<Int>?
    private var fitW: CGFloat = 0
    private var basePixelW = 0
    private var night = UserDefaults.standard.bool(forKey: "nightMode")
    private var loadedKey = ""
    /// 本次视图生命周期内是否已经恢复过视口（折叠→展开只恢复一次）。
    private var restored = false
    /// 初始定位做完之前，滚动回报不许改写视口记忆（首帧的 y=0 会把记忆抹平）。
    private var positioned = false
    private var settleWork: DispatchWorkItem?
    /// 捏合进行中（这期间只拉伸已有页图，松手再按新倍率出图）。
    private var magnifying = false
    private var bag = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    /// 渲染引擎的认领 id（一个页流实例一个；形态切换时新旧两个可能短暂并存，别动对方的）。
    private let clientID = "ref-" + UUID().uuidString

    init(model: RefWindowModel, host: RefViewHost) {
        self.model = model
        self.host = host
        super.init(frame: .zero)
        let clip = ReaderClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = docView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1
        scrollView.maxMagnification = 6
        scrollView.drawsBackground = true
        scrollView.backgroundColor = voidColor
        scrollView.onCommandWheel = { [weak self] factor, p in self?.commandWheel(factor, at: p) ?? false }
        addSubview(scrollView)

        clip.postsBoundsChangedNotifications = true
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        })
        observers.append(nc.addObserver(forName: NSScrollView.willStartLiveMagnifyNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.magnifying = true }
        })
        observers.append(nc.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.magnifying = false
                self?.magnificationSettled()
            }
        })
        observers.append(nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.nightChanged() }
        })
        model.$seedRev.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.seedIfReady() }.store(in: &bag)
        model.$docKey.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadIfNeeded() }.store(in: &bag)
        // 关窗兜底（`RefWindowModel.close` / `releaseViews(host:)` 会调）
        model.renderClients[clientID] = (host, {})
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    override var isFlipped: Bool { true }

    /// 从视图树上摘下（折叠成气泡 / 关小窗 / 换形态）= 交还渲染认领。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            PageRenderEngine.shared.setWanted([], client: clientID)
            PageHoldings.shared.remove(client: clientID)
            model.renderClients.removeValue(forKey: clientID)
        } else {
            model.renderClients[clientID] = (host, {})
            needsLayout = true
        }
    }

    private var paperColor: CGColor { night ? CGColor(gray: 0.10, alpha: 1) : CGColor(gray: 1, alpha: 1) }
    private var voidColor: NSColor { night ? NSColor(white: 0.06, alpha: 1) : .windowBackgroundColor }
    private var sc: CGFloat { fitW / PageLayout.refWidth }
    private var clip: NSClipView { scrollView.contentView }

    // MARK: 布局

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        reloadIfNeeded()
        let w = scrollView.contentSize.width.rounded()
        guard w > 0, let layout = model.layout, layout.pageCount > 0 else { return }
        guard abs(w - fitW) > 0.5 else { return }
        // 视口宽变了（改小窗尺寸）→ 页宽跟着变，把视口对回原来那个文档位置
        let keepDocY = positioned ? currentDocY() : nil
        fitW = w
        docView.frame = NSRect(x: 0, y: 0, width: fitW, height: layout.totalHeight * sc)
        for (i, l) in pages { l.frame = pageFrame(i, layout) }
        if let y = keepDocY { scroll(toDocY: y) }
        seedIfReady()
        updateRealized()
        kick()
    }

    private func pageFrame(_ i: Int, _ layout: PageLayout) -> NSRect {
        NSRect(x: 0, y: layout.offsets[i] * sc, width: fitW, height: layout.heights[i] * sc)
    }

    /// 换书 = 全新一份状态（旧书的图留在引擎缓存里由 LRU 处置，别 purge：参考的若正是主视图那本，会把阅读区的图一起清掉）。
    private func reloadIfNeeded() {
        guard model.docKey != loadedKey else { return }
        loadedKey = model.docKey
        for l in pages.values { l.removeFromSuperlayer() }
        pages.removeAll()
        images.removeAll()
        realized = nil
        basePixelW = 0
        restored = false
        positioned = false
        fitW = 0
        scrollView.magnification = 1
        needsLayout = true
    }

    private func currentDocY() -> CGFloat { sc > 0 ? clip.bounds.minY / sc : 0 }

    private func scroll(toDocY docY: CGFloat) {
        let maxY = max(0, docView.frame.height - clip.bounds.height)
        let y = min(max(0, docY * sc), maxY)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: 定位到进度

    /// 「打开 = 回到那本书的阅读进度」；折叠→展开则原样接上视口（`REF-WINDOW-PLAN.md §6` 的两级语义）。
    private func seedIfReady() {
        guard let layout = model.layout, fitW > 0, layout.pageCount > 0 else { return }
        let docY: CGFloat
        if model.seededRev != model.seedRev {
            model.seededRev = model.seedRev
            docY = layout.docY(page: model.seedPage, frac: model.seedFrac)
        } else if !restored, let saved = model.viewDocY {
            restored = true
            scrollView.magnification = min(max(model.viewZoom, 1), 6)
            docY = saved
        } else {
            if !positioned { positioned = true }
            return
        }
        scroll(toDocY: docY)
        model.viewDocY = currentDocY()
        positioned = true
        updateRealized()
        kick()
    }

    // MARK: 滚动 / 缩放

    private func scrolled() {
        if positioned, !magnifying { model.viewDocY = currentDocY() }
        updateRealized()
        reportPage()
        if !magnifying { kick() }
    }

    private func magnificationSettled() {
        model.viewZoom = scrollView.magnification
        model.viewDocY = currentDocY()
        kick()
    }

    /// ⌘+滚轮：以光标为锚缩放（系统的 `setMagnification(_:centeredAt:)` 保证锚点不动），停一拍再出清晰图。
    private func commandWheel(_ factor: CGFloat, at p: NSPoint) -> Bool {
        guard model.layout != nil, fitW > 0 else { return false }
        let z = min(max(scrollView.magnification * factor, 1), 6)
        guard abs(z - scrollView.magnification) > 0.0001 else { return true }
        scrollView.setMagnification(z, centeredAt: p)
        model.viewZoom = z
        model.viewDocY = currentDocY()
        settleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.kick() }
        settleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
        return true
    }

    private func reportPage() {
        guard let layout = model.layout, sc > 0 else { return }
        // 视口上三分之一处那一页当「当前页」（同主阅读区口径）
        let b = clip.bounds
        model.reportCurrentPage(layout.locate(docY: (b.minY + b.height * 0.3) / sc).page)
    }

    // MARK: 实化窗口

    /// 只扩不缩 + 上界（可见页数 + 2）；滚出窗口的页图与图层都丢掉（丢掉的在引擎 LRU 与磁盘缓存里都还在）。
    private func updateRealized() {
        guard let layout = model.layout, sc > 0, layout.pageCount > 0 else { return }
        let b = clip.bounds
        let vis = layout.pageRange(fromDocY: b.minY / sc, toDocY: b.maxY / sc)
        let cap = vis.count + 2
        var lo = min(realized?.lowerBound ?? vis.lowerBound, vis.lowerBound)
        var hi = max(realized?.upperBound ?? vis.upperBound, vis.upperBound)
        if hi - lo + 1 > cap {
            lo = max(0, vis.lowerBound - 1)
            hi = lo + cap - 1
        }
        lo = max(0, lo)
        hi = min(layout.pageCount - 1, max(hi, lo))
        let r = lo...hi
        guard r != realized else { return }
        realized = r
        for (i, l) in pages where !r.contains(i) {
            l.removeFromSuperlayer()
            pages.removeValue(forKey: i)
            images.removeValue(forKey: i)
        }
        for i in r where pages[i] == nil {
            let l = QuietLayer()
            l.backgroundColor = paperColor
            l.contentsGravity = .resize
            l.minificationFilter = .trilinear
            l.frame = pageFrame(i, layout)
            if let img = images[i] { l.contents = img }
            docView.layer?.addSublayer(l)
            pages[i] = l
        }
        reportHoldings()
    }

    // MARK: 出图

    private func key(_ i: Int, width: Int) -> String {
        PageRenderEngine.baseKey(doc: model.docKey, page: i, pixelWidth: width, night: night)
    }

    private func setImage(_ i: Int, _ img: CGImage?) {
        images[i] = img
        pages[i]?.contents = img
    }

    /// 档位化像素宽（必须 snap：不 snap 的话每停一档就是一整套新键，缓存被打散且单调涨），与平板同一张阶梯。
    private func kick() {
        guard let pdf = model.pdf, fitW > 0, let r = realized else { return }
        let scale = window?.backingScaleFactor ?? 2
        let w = LANServer.snapPageWidth(max(1, Int((fitW * scrollView.magnification * scale).rounded())))
        basePixelW = w
        var wanted = Set<String>()
        for i in r {
            let k = key(i, width: w)
            wanted.insert(k)
            if let hit = PageRenderEngine.shared.cached(k) {
                if images[i] !== hit { setImage(i, hit) }
                continue
            }
            guard let page = pdf.page(at: i) else { continue }
            let nightAtRequest = night
            PageRenderEngine.shared.request(
                .init(key: k, page: page, pixelWidth: w, tileRect: nil, tileScale: 1, night: night,
                      diskCache: true, align: model.align?.page(i))
            ) { [weak self] doneKey, img in
                guard let self, self.realized?.contains(i) == true else { return }   // 已滚出窗口的迟到完成不写
                // 仍是当前期望的那一版才写；否则只在这页空着时先顶上（夜间变过的一律不顶，宁可空一下）
                let fresh = doneKey == self.key(i, width: self.basePixelW)
                if fresh || (self.images[i] == nil && nightAtRequest == self.night) { self.setImage(i, img) }
                self.reportHoldings()
            }
        }
        // 不声明就会被引擎当「无人认领的滞留请求」丢弃 → 完成回调永不触发、小窗永远停在占位
        PageRenderEngine.shared.setWanted(wanted, client: clientID)
    }

    /// 夜间切换：先用缓存里的同参异色图同步顶上，没有就先空着——不能把亮色图压在夜间模式上。
    private func nightChanged() {
        let n = UserDefaults.standard.bool(forKey: "nightMode")
        guard n != night else { return }
        night = n
        scrollView.backgroundColor = voidColor
        for l in pages.values { l.backgroundColor = paperColor }
        if basePixelW > 0, let r = realized {
            for i in r { setImage(i, PageRenderEngine.shared.cached(key(i, width: basePixelW))) }
        }
        kick()
    }

    private func reportHoldings() {
        var h = PageHolding(kind: .ref, label: model.title, active: false, realized: realized)
        for img in images.values { h.imageCount += 1; h.imageBytes += PageHolding.bytes(of: img) }
        PageHoldings.shared.report(h, client: clientID)
    }
}
