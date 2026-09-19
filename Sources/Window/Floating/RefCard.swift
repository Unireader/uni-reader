import AppKit
import Combine

/// 参考窗的**覆盖层形态**（AppKit 版，替代 SwiftUI `RefWindowView`）：浮在阅读区上的只读 PDF 小窗，可折叠成一枚气泡。
/// 另一种形态是独立窗口（`RefWindowController`），两者共用同一份 `RefWindowModel`；`model.mode` 不是 `.overlay` 时这里什么都不显示。
///
/// 页流（`RefPageStreamView`）只在展开时存在：折叠 / 关闭 / 换形态就摘掉（交还渲染认领），
/// 再展开时新建一个，视口由 model 里的记忆接上（折叠→展开保持位置，关闭→重开回到进度）。
@MainActor
final class RefCard: NSObject {
    let model: RefWindowModel
    let workspace: WorkspaceManager
    let card: FloatingCardView
    let bubble = RefBubbleButton()
    /// 当前标签在读的那本（「在主视图显示这一页」只在参考的正是它时显示）。
    var currentDocID: () -> String? = { nil }
    var onGotoMain: (Int) -> Void = { _ in }
    /// 草稿纸开着时整个隐去。
    var suppressed = false { didSet { if oldValue != suppressed { sync() } } }

    private var stream: RefPageStreamView?
    private let titleLabel = NSTextField(labelWithString: "")
    private let pageLabel = NSTextField(labelWithString: "")
    private var tocButton: CardIconButton!
    private var mainButton: CardIconButton!
    private var popover: NSPopover?
    private var bag = Set<AnyCancellable>()
    private var lastContainer: CGSize = .zero
    private var queued = false

    /// 窄于此就不显示页码（先让文档名和那几枚按钮活下来）。
    private static let pageNumMinWidth: CGFloat = 330

    init(model: RefWindowModel, workspace: WorkspaceManager) {
        self.model = model
        self.workspace = workspace
        card = FloatingCardView(size: model.size, offset: model.offset)
        super.init()
        card.isHidden = true
        bubble.isHidden = true
        card.clampSize = { RefWindowModel.clampSize($0, in: $1) }
        card.clampOffset = { RefWindowModel.clampOffset($0, size: $1, in: $2) }
        card.onCommit = { [weak self] s, o in
            guard let self else { return }
            self.model.size = s
            self.model.offset = o
            self.model.persistGeometry()
            self.placeBubble()
            self.refreshHeader()
        }
        bubble.onClick = { [weak self] in self?.model.collapsed = false }
        buildHeader()
        model.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.queueSync() }.store(in: &bag)
    }

    private func buildHeader() {
        let picker = CardIconButton("book", L("Pick a document to reference")) { [weak self] in self?.showDocMenu() }
        pickerButton = picker
        tocButton = CardIconButton("list.bullet", L("Contents")) { [weak self] in self?.toggleTOC() }
        titleLabel.font = .preferredFont(forTextStyle: .callout)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        titleLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        pageLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        pageLabel.textColor = .secondaryLabelColor
        pageLabel.setContentHuggingPriority(.required, for: .horizontal)
        pageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let rewind = CardIconButton("arrow.uturn.backward", L("Back to Progress")) { [weak self] in
            guard let self else { return }
            self.model.rewindToProgress(workspace: self.workspace)
        }
        mainButton = CardIconButton("arrow.up.forward.app", L("Show This Page in Main View")) { [weak self] in
            guard let self else { return }
            self.onGotoMain(self.model.currentPage)
        }
        // 弹成独立窗口：只改 model 的形态，窗口由 `ReaderWindowController` 按它开出来，滚动位置与缩放原样带过去
        let detach = CardIconButton("macwindow", L("Open as Separate Window")) { [weak self] in self?.model.setMode(.window) }
        let collapse = CardIconButton("minus", L("Collapse")) { [weak self] in self?.model.collapsed = true }
        let close = CardIconButton("xmark", L("Close")) { [weak self] in self?.model.close() }
        let stack = NSStackView(views: [picker, tocButton, titleLabel, pageLabel, rewind, mainButton, detach, collapse, close])
        stack.spacing = 4
        stack.setCustomSpacing(6, after: pageLabel)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.header.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.header.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.header.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.header.bottomAnchor),
        ])
    }
    private weak var pickerButton: NSButton?

    // MARK: 状态

    private func queueSync() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            self?.queued = false
            self?.sync()
        }
    }

    func layout(in container: CGSize) {
        lastContainer = container
        if !card.isHidden { card.place(in: container) }
        placeBubble()
    }

    func sync() {
        let visible = model.isOpen && model.mode == .overlay && !suppressed
        let showCard = visible && !model.collapsed
        let showBubble = visible && model.collapsed
        if showCard {
            if stream == nil {
                let s = RefPageStreamView(model: model, host: .overlay)
                s.frame = card.body.bounds
                s.autoresizingMask = [.width, .height]
                card.body.addSubview(s)
                stream = s
            }
            if card.isHidden {
                // 打开 / 从独立窗口切回来：关着的时候容器可能变过，按当前容器重新夹
                card.size = model.size
                card.offset = model.offset
                card.place(in: lastContainer)
                fade(card, in: true)
            }
        } else {
            if !card.isHidden { fade(card, in: false) }
            stream?.removeFromSuperview()
            stream = nil
            popover?.close()
        }
        if showBubble != !bubble.isHidden {
            placeBubble()
            fade(bubble, in: showBubble)
        }
        refreshHeader()
    }

    private func fade(_ v: NSView, in show: Bool) {
        if show {
            v.alphaValue = 0
            v.isHidden = false
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            v.animator().alphaValue = show ? 1 : 0
        }, completionHandler: {
            MainActor.assumeIsolated { if !show, v.alphaValue < 0.01 { v.isHidden = true } }
        })
    }

    /// 气泡与面板同一份摆位（夹在容器内），外边距 16。
    private func placeBubble() {
        let d: CGFloat = 44, m: CGFloat = 16
        let o = RefWindowModel.clampOffset(model.offset, size: model.size, in: lastContainer)
        bubble.frame = NSRect(x: lastContainer.width - m - d + o.width, y: lastContainer.height - m - d + o.height,
                              width: d, height: d)
    }

    private func refreshHeader() {
        let t = model.title.isEmpty ? L("Reference") : model.title
        if titleLabel.stringValue != t { titleLabel.stringValue = t }
        titleLabel.toolTip = model.title
        tocButton.isHidden = model.toc.isEmpty
        if card.size.width >= Self.pageNumMinWidth, let n = model.pdf?.pageCount, n > 0 {
            pageLabel.stringValue = "\(model.currentPage + 1) / \(n)"
            pageLabel.isHidden = false
        } else {
            pageLabel.isHidden = true
        }
        mainButton.isHidden = !(model.docID != nil && model.docID == currentDocID())
    }

    // MARK: 选书 / 目录

    /// 换一本书看：列的是当前工作区的全部文档（不只已打开的那几篇）。
    private func showDocMenu() {
        guard let b = pickerButton else { return }
        let m = NSMenu()
        for d in workspace.documents {
            let it = ClosureMenuItem(d.title, action: { [weak self] in
                guard let self else { return }
                self.model.load(documentId: d.id, workspace: self.workspace)
            })
            it.state = d.id == model.docID ? .on : .off
            m.addItem(it)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    private func toggleTOC() {
        if let p = popover, p.isShown { p.performClose(nil); return }
        let p = RefTOCPopover.make(model: model) { [weak self] in self?.popover?.performClose(nil) }
        popover = p
        p.show(relativeTo: tocButton.bounds, of: tocButton, preferredEdge: .maxY)
    }
}

/// 参考窗的目录弹窗（覆盖层与独立窗口共用）：标题 + 目录树（与 Inspector 同一个 `TOCOutlineView`）。
/// 跳转只动小窗自己的视口，不写回那本书的阅读进度（`REF-WINDOW-PLAN.md §3` 红线）。
enum RefTOCPopover {
    @MainActor
    static func make(model: RefWindowModel, onPicked: @escaping () -> Void) -> NSPopover {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 420))
        let title = NSTextField(labelWithString: L("Contents"))
        title.font = .preferredFont(forTextStyle: .headline)
        title.frame = NSRect(x: 12, y: 10, width: 276, height: 20)
        let toc = TOCOutlineView(frame: NSRect(x: 0, y: 40, width: 300, height: 380))
        toc.autoresizingMask = [.width, .height]
        toc.update(entries: model.toc, bookmarks: [], currentPage: model.currentPage)
        toc.onSelect = { [weak model] e in
            guard let page = e.pageIndex else { return }   // 坏书签：跳不过去
            model?.goto(page: page, frac: e.frac)
            onPicked()
        }
        root.addSubview(title)
        root.addSubview(toc)
        let vc = NSViewController()
        vc.view = root
        let p = NSPopover()
        p.contentViewController = vc
        p.behavior = .transient
        p.contentSize = root.frame.size
        return p
    }
}

/// 折叠后的气泡：系统材质圆钮 + 描边 + 阴影，点一下展开。
final class RefBubbleButton: NSView {
    var onClick: () -> Void = {}
    private let shell = NSVisualEffectView()
    private let icon = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.18)
            s.shadowBlurRadius = 6
            s.shadowOffset = NSSize(width: 0, height: -2)
            return s
        }()
        shell.material = .popover
        shell.blendingMode = .withinWindow
        shell.state = .active
        shell.wantsLayer = true
        shell.layer?.masksToBounds = true
        shell.layer?.borderWidth = 0.5
        shell.layer?.borderColor = NSColor.separatorColor.cgColor
        icon.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: L("Reference Window"))
        icon.symbolConfiguration = .init(pointSize: 17, weight: .medium)
        icon.contentTintColor = .labelColor
        addSubview(shell)
        shell.addSubview(icon)
        toolTip = L("Reference Window")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func layout() {
        super.layout()
        shell.frame = bounds
        shell.layer?.cornerRadius = bounds.width / 2
        icon.frame = bounds
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        shell.layer?.borderColor = NSColor.separatorColor.cgColor
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
}
