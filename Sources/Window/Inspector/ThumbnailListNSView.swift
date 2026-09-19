import AppKit
import PDFKit

/// 缩略图列表：
///  · 点击跳到该页顶部；当前页描一圈强调色、自动滚到正中；
///  · 出图复用 `PageRenderEngine`（独立像素宽 `pixelWidth`，落磁盘缓存）；
///  · 当前页立即请求，其余页 150ms 后仍可见才请求（快速滚动途经的页不占串行渲染队列）；
///  · 视图层最多留 48 张（离当前页最远的先丢），持有量报给 `PageHoldings`。
final class ThumbnailListNSView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: (Int) -> Void = { _ in }

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: L("No pages to show."))
    private var pdf: PDFDocument?
    private var docKey = ""
    private var align: ScanAlignTable?
    private var currentPage = 0
    private var images: [Int: CGImage] = [:]
    private var aspects: [Int: CGFloat] = [:]
    private let clientID = "thumbs-" + UUID().uuidString
    private static let maxKept = 48

    /// 缩略图渲染像素宽。阅读区也会读它：目标宽度的页图还没渲出来时，拿这份小图当最后兜底（同 doc/page 键空间）。
    /// 必须跟得上侧栏的物理像素：栏最小宽约 276pt 可用，Retina 下 552 物理像素；原来的 160 糊得认不出字
    /// （用户 2026-09-03 报），480 只放大 1.15 倍。改大它要连带看视图层留图上限与共享 LRU 的开销。
    static let pixelWidth = 480
    /// 缩略图圆角（图、底、选中描边共用一个值，三者必须一致，否则方角图会盖住圆角底）。
    static let corner: CGFloat = 5

    override init(frame: NSRect) {
        super.init(frame: frame)
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 10)
        table.addTableColumn(NSTableColumn(identifier: .init("thumb")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        scroll.automaticallyAdjustsContentInsets = false
        addSubview(scroll)
        emptyLabel.textColor = .secondaryLabelColor
        addSubview(emptyLabel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    deinit { PageHoldings.shared.remove(client: clientID) }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let s = emptyLabel.fittingSize
        emptyLabel.frame = NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
    }

    /// 换文档（显示身份变了）= 整个列表重来；只换当前页 = 重画两格 + 滚到位。
    func update(pdf: PDFDocument?, docKey: String, align: ScanAlignTable?, currentPage: Int) {
        if pdf !== self.pdf || docKey != self.docKey {
            self.pdf = pdf
            self.docKey = docKey
            self.align = align
            images = [:]
            aspects = [:]
            self.currentPage = currentPage
            table.reloadData()
            emptyLabel.isHidden = (pdf?.pageCount ?? 0) > 0
            scroll.isHidden = !emptyLabel.isHidden
            scrollToCurrent(animated: false)
            return
        }
        guard currentPage != self.currentPage else { return }
        let old = self.currentPage
        self.currentPage = currentPage
        reload(rows: [old, currentPage])
        scrollToCurrent(animated: true)
    }

    private func scrollToCurrent(animated: Bool) {
        guard currentPage >= 0, currentPage < table.numberOfRows else { return }
        let r = table.rect(ofRow: currentPage)
        let clip = scroll.contentView
        let y = r.midY - clip.bounds.height / 2
        let p = NSPoint(x: 0, y: max(-scroll.contentInsets.top, y))
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                clip.animator().setBoundsOrigin(p)
            }
        } else {
            clip.setBoundsOrigin(p)
        }
        scroll.reflectScrolledClipView(clip)
    }

    private func reload(rows: [Int]) {
        let valid = rows.filter { $0 >= 0 && $0 < table.numberOfRows }
        table.reloadData(forRowIndexes: IndexSet(valid), columnIndexes: IndexSet(integer: 0))
    }

    // MARK: 数据源

    func numberOfRows(in tableView: NSTableView) -> Int { pdf?.pageCount ?? 0 }

    private func aspect(_ i: Int) -> CGFloat {
        if let a = aspects[i] { return a }
        guard let p = pdf?.page(at: i) else { return 0.75 }
        let s = PageBitmap.displaySize(p, align: align?.page(i))
        let a = s.height > 0 ? s.width / s.height : 0.75
        aspects[i] = a
        return a
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let w = max(40, bounds.width - 24)
        return w / aspect(row) + 18
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: ThumbCell.id, owner: nil) as? ThumbCell) ?? ThumbCell()
        cell.configure(page: row, image: images[row], current: row == currentPage)
        if images[row] == nil { requestImage(row) }
        return cell
    }

    @objc private func clicked() {
        let r = table.clickedRow
        if r >= 0 { onSelect(r) }
    }

    // MARK: 出图

    private func requestImage(_ page: Int) {
        guard let pdf, let p = pdf.page(at: page) else { return }
        let key = PageRenderEngine.baseKey(doc: docKey, page: page, pixelWidth: ThumbnailListNSView.pixelWidth, night: false)
        if let hit = PageRenderEngine.shared.cached(key) { keep(page, hit); return }
        let doc = docKey
        let go = { [weak self] in
            guard let self, self.docKey == doc, self.images[page] == nil else { return }
            // 非当前页：去抖期间滚出去了就不渲
            if page != self.currentPage, !self.table.rows(in: self.table.visibleRect).contains(page) { return }
            PageRenderEngine.shared.request(.init(key: key, page: p, pixelWidth: ThumbnailListNSView.pixelWidth,
                                                  tileRect: nil, tileScale: 1, night: false, diskCache: true,
                                                  align: self.align?.page(page))) { [weak self] doneKey, img in
                guard let self, doneKey == key, self.docKey == doc else { return }
                self.keep(page, img)
            }
        }
        if page == currentPage { go() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: go) }
    }

    private func keep(_ page: Int, _ image: CGImage) {
        images[page] = image
        let excess = images.count - Self.maxKept
        if excess > 0 {
            for p in images.keys.sorted(by: { abs($0 - currentPage) > abs($1 - currentPage) }).prefix(excess) {
                images.removeValue(forKey: p)
            }
        }
        var h = PageHolding(kind: .thumbs, label: String(docKey.prefix(8)), active: false, realized: nil)
        for img in images.values { h.imageCount += 1; h.imageBytes += PageHolding.bytes(of: img) }
        PageHoldings.shared.report(h, client: clientID)
        if page < table.numberOfRows, let cell = table.view(atColumn: 0, row: page, makeIfNecessary: false) as? ThumbCell {
            cell.configure(page: page, image: image, current: page == currentPage)
        }
    }
}

/// 一格缩略图：页图（圆角、底色、当前页描边三者同一圆角）+ 页码。
private final class ThumbCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("thumbCell")
    private let frameView = NSView()
    private let imageLayer = CALayer()
    private let number = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        frameView.wantsLayer = true
        frameView.layer?.cornerRadius = ThumbnailListNSView.corner
        frameView.layer?.masksToBounds = true
        frameView.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.3).cgColor
        imageLayer.contentsGravity = .resize
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        frameView.layer?.addSublayer(imageLayer)
        number.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)
        number.alignment = .center
        addSubview(frameView)
        addSubview(number)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    func configure(page: Int, image: CGImage?, current: Bool) {
        number.stringValue = "\(page + 1)"
        number.textColor = current ? .controlAccentColor : .secondaryLabelColor
        imageLayer.contents = image
        frameView.layer?.borderWidth = current ? 2 : 0
        frameView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        frameView.frame = NSRect(x: 12, y: 16, width: b.width - 24, height: max(0, b.height - 18))
        imageLayer.frame = frameView.bounds
        number.frame = NSRect(x: 0, y: 0, width: b.width, height: 14)
    }
}
