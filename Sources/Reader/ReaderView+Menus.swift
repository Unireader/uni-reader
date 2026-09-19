import AppKit

/// 右键菜单与两个弹出气泡（高亮操作 / 书签），全部系统控件（`NSMenu` / `NSPopover` / `NSSegmentedControl` / `NSButton`）。
/// 菜单项与顺序同 SwiftUI 版 `readerContextMenu`。
extension ReaderView {

    // MARK: 右键菜单

    func readerContextMenu(_ e: NSEvent) -> NSMenu? {
        guard didSetup, session.openPadID == nil else { return nil }
        cursorDoc = docPoint(of: e)
        let m = NSMenu()
        m.autoenablesItems = false
        // 框选选中集：剪切 / 复制 / 粘贴 / 删除；没有选中集时框选工具下只给粘贴
        if lassoSelection != nil {
            m.addItem(ClosureMenuItem(L("Cut")) { [weak self] in self?.cutLassoSelection() })
            m.addItem(ClosureMenuItem(L("Copy")) { [weak self] in self?.copyLassoSelection() })
            let paste = ClosureMenuItem(L("Paste")) { [weak self] in self?.pasteInk() }
            paste.isEnabled = InkClipboard.hasInk()
            m.addItem(paste)
            m.addItem(ClosureMenuItem(L("Delete")) { [weak self] in self?.deleteLassoSelection() })
            m.addItem(.separator())
        } else if app.pointerTool == .lasso, InkClipboard.hasInk() {
            m.addItem(ClosureMenuItem(L("Paste")) { [weak self] in self?.pasteInk() })
            m.addItem(.separator())
        }
        let docOK = session.documentId != nil
        if selection?.text.isEmpty == false {
            m.addItem(ClosureMenuItem(L("Add Note")) { [weak self] in self?.beginAddNote() })
            // 铺色 / 画线 / 画框各一个子菜单，里面是调色板四色
            for style in HighlightStyle.allCases {
                let sub = NSMenu()
                for item in Highlight.palette {
                    let color = item.color
                    sub.addItem(ClosureMenuItem(L(item.name)) { [weak self] in self?.addHighlight(color: color, style: style) })
                }
                let parent = NSMenuItem(title: style.title, action: nil, keyEquivalent: "")
                parent.submenu = sub
                m.addItem(parent)
            }
            m.addItem(ClosureMenuItem(L("Copy")) { [weak self] in self?.copySelectionToPasteboard() })
            if AIPanelModel.shared.enabled {
                let ask = ClosureMenuItem(String(format: L("Ask %@ About This"), aiProviderName)) { [weak self] in
                    self?.askAIAboutSelection()
                }
                ask.isEnabled = docOK
                m.addItem(ask)
            }
        } else {
            m.addItem(ClosureMenuItem(L("Add Note Here")) { [weak self] in self?.beginAddNoteAtCursor() })
            m.addItem(ClosureMenuItem(L("Copy Link")) { [weak self] in self?.copyLinkAtCursor() })
        }
        let importItem = ClosureMenuItem(L("Import Image Here…")) { [weak self] in self?.importImagesViaPanel() }
        importItem.isEnabled = docOK
        m.addItem(importItem)
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(L("Add Bookmark Here")) { [weak self] in self?.addBookmarkAtCursor() })
        m.addItem(ClosureMenuItem(L("New Scratchpad Here")) { [weak self] in self?.newScratchPadAtCursor() })
        if AIPanelModel.shared.enabled {
            m.addItem(.separator())
            let discuss = ClosureMenuItem(String(format: L("Discuss This Page with %@"), aiProviderName)) { [weak self] in
                self?.discussPageWithAI()
            }
            discuss.isEnabled = docOK
            m.addItem(discuss)
        }
        return m
    }

    // MARK: 高亮操作气泡

    /// 点中一条高亮：在**被点中的那一行**上挂气泡——原文、页码、换色（色点）、换画法、转笔记、删除。
    func showHighlightPopover(_ h: Highlight, lineRect: CGRect) {
        dismissHighlightPopover()
        activeHighlight = HighlightTap(id: h.id, rect: lineRect)
        let vc = HighlightPopoverController(highlight: h, reader: self)
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = vc
        pop.delegate = vc
        highlightPopover = pop
        let r = displayRect(page: h.page, norm: lineRect)
        pop.show(relativeTo: r.insetBy(dx: 0, dy: -1), of: overlay, preferredEdge: .maxY)
    }

    func dismissHighlightPopover() {
        activeHighlight = nil
        if let p = highlightPopover {
            highlightPopover = nil
            p.close()
        }
    }

    // MARK: 书签气泡

    func showBookmarkPopover(_ id: UUID) {
        guard let b = session.bookmarks.first(where: { $0.id == id }), let pin = overlay.pins["b-\(id.uuidString)"] else { return }
        let vc = NSViewController()
        let title = NSTextField(wrappingLabelWithString: b.title)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        title.textColor = .labelColor   // 气泡是材质底：文字一律主色（红线）
        title.maximumNumberOfLines = 2
        let page = NSTextField(labelWithString: String(format: L("Page %d"), b.page + 1))
        page.font = .preferredFont(forTextStyle: .caption1)
        page.textColor = .labelColor
        let pop = NSPopover()
        pop.behavior = .transient
        let rename = NSButton(title: L("Rename…"), target: nil, action: nil)
        let delete = NSButton(title: L("Delete"), target: nil, action: nil)
        delete.hasDestructiveAction = true
        let stack = NSStackView(views: [title, page, separator(), rename, delete])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        vc.view = stack
        pop.contentViewController = vc
        let actions = ButtonActions()
        actions.bind(rename) { [weak self, weak pop] in pop?.close(); self?.session.beginBookmarkRename(b) }
        actions.bind(delete) { [weak self, weak pop] in pop?.close(); self?.session.deleteBookmark(id: b.id) }
        objc_setAssociatedObject(pop, &ButtonActions.key, actions, .OBJC_ASSOCIATION_RETAIN)
        pop.show(relativeTo: pin.bounds, of: pin, preferredEdge: .maxX)
    }

    func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }
}

/// 给一组按钮挂闭包（弹出气泡里的按钮用；随气泡一起释放）。
final class ButtonActions: NSObject {
    static var key: UInt8 = 0
    private var handlers: [ObjectIdentifier: () -> Void] = [:]

    func bind(_ b: NSButton, _ h: @escaping () -> Void) {
        handlers[ObjectIdentifier(b)] = h
        b.target = self
        b.action = #selector(fire(_:))
    }

    @objc private func fire(_ sender: NSButton) { handlers[ObjectIdentifier(sender)]?() }
}

/// 高亮操作气泡的内容。换色 / 换画法即时生效（就地改那条高亮），气泡不关；转笔记 / 删除后关。
final class HighlightPopoverController: NSViewController, NSPopoverDelegate {
    private let highlightID: UUID
    private weak var reader: ReaderView?
    private var highlight: Highlight
    private var swatches: [NSButton] = []
    private let styles = NSSegmentedControl()

    init(highlight: Highlight, reader: ReaderView) {
        self.highlightID = highlight.id
        self.highlight = highlight
        self.reader = reader
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func loadView() {
        let quote = NSTextField(wrappingLabelWithString: highlight.quote.flattenedQuote)
        quote.font = .preferredFont(forTextStyle: .callout)
        quote.textColor = .labelColor   // 材质底：主色（红线）
        quote.maximumNumberOfLines = 3
        quote.preferredMaxLayoutWidth = 256
        let page = NSTextField(labelWithString: String(format: L("Page %d"), highlight.page + 1))
        page.font = .preferredFont(forTextStyle: .caption1)
        page.textColor = .labelColor

        // 色点一排（扁平色块，是内容不是仿系统控件）+ 画法分段（系统控件）
        var row: [NSView] = []
        for item in Highlight.palette {
            let b = SwatchButton(color: item.color.nsColor)
            b.toolTip = L(item.name)
            b.target = self
            b.action = #selector(pickColor(_:))
            b.tag = swatches.count
            swatches.append(b)
            row.append(b)
        }
        styles.segmentCount = HighlightStyle.allCases.count
        for (i, s) in HighlightStyle.allCases.enumerated() {
            styles.setImage(NSImage(systemSymbolName: s.iconName, accessibilityDescription: s.title), forSegment: i)
            styles.setToolTip(s.title, forSegment: i)
        }
        styles.trackingMode = .selectOne
        styles.target = self
        styles.action = #selector(pickStyle(_:))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let colorRow = NSStackView(views: row + [spacer, styles])
        colorRow.spacing = 8
        let addNote = NSButton(title: L("Add Note…"), target: self, action: #selector(addNote))
        let delete = NSButton(title: L("Delete Highlight"), target: self, action: #selector(deleteHighlight))
        delete.hasDestructiveAction = true
        let sep1 = NSBox(); sep1.boxType = .separator
        let sep2 = NSBox(); sep2.boxType = .separator
        let stack = NSStackView(views: [quote, page, sep1, colorRow, sep2, addNote, delete])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for v in [sep1, sep2, colorRow] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        stack.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
        view = stack
        syncState()
    }

    private func syncState() {
        for (i, b) in swatches.enumerated() {
            (b as? SwatchButton)?.selectedRing = Highlight.palette[i].color == highlight.color
        }
        styles.selectedSegment = HighlightStyle.allCases.firstIndex(of: highlight.style) ?? 0
    }

    @objc private func pickColor(_ sender: NSButton) {
        let c = Highlight.palette[sender.tag].color
        reader?.recolorHighlight(highlightID, color: c)
        highlight.color = c
        syncState()
    }

    @objc private func pickStyle(_ sender: NSSegmentedControl) {
        let s = HighlightStyle.allCases[sender.selectedSegment]
        reader?.restyleHighlight(highlightID, style: s)
        highlight.style = s
    }

    @objc private func addNote() {
        guard let reader, let h = reader.session.highlights.first(where: { $0.id == highlightID }) else { return }
        reader.beginNoteFromHighlight(h)
    }

    @objc private func deleteHighlight() { reader?.deleteHighlight(highlightID) }

    func popoverDidClose(_ notification: Notification) {
        if reader?.highlightPopover === notification.object as? NSPopover {
            reader?.highlightPopover = nil
            reader?.activeHighlight = nil
        }
    }
}

/// 一枚色点（换色用）：扁平圆 + 当前色描一圈。
final class SwatchButton: NSButton {
    let color: NSColor
    var selectedRing = false { didSet { needsDisplay = true } }

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        isBordered = false
        title = ""
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        color.setFill()
        NSBezierPath(ovalIn: r).fill()
        if selectedRing {
            NSColor.labelColor.withAlphaComponent(0.6).setStroke()
            let ring = NSBezierPath(ovalIn: r)
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}
