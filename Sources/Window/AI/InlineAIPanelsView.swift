import AppKit
import Combine

/// 阅读窗格右侧的两块内置 AI 面板（AppKit 版，替代 SwiftUI `InlinePanelsColumn` + `AgentInlineLayer` + `AIInlineLayer`）：
///  · 从左到右「阅读区 | Agent | 咨询 AI」，**浮在阅读区上面**，阅读区外框不变（外框一变玻璃工具栏按钮就变浅，
///    2026-09-19 录屏确认）；盖住的宽度经 `onInset` 交给阅读区自己适配；
///  · 开合时从右边滑入 / 滑出（0.28s），开合只走阅读窗口工具栏上的两枚开关（面板里没有收起按钮）；
///  · 底是系统 Liquid Glass（与左侧边栏同材质，用户 2026-09-19 确认一致），一直铺到工具栏底下；左缘可拖动改宽度。
@MainActor
final class InlineAIPanelsView: NSView {
    let windowID: UUID
    let workspace: WorkspaceManager
    /// 盖住的宽度变了（开合 / 拖宽）。第二个参数 = 这次是开合（要带动画）。
    var onInset: (CGFloat, Bool) -> Void = { _, _ in }
    /// 面板内容要让开的顶部高度（工具栏）。
    var topInset: CGFloat = 0 { didSet { if oldValue != topInset { needsLayout = true } } }

    private let agentBox = InlinePanelContainer()
    private let consultBox = InlinePanelContainer()
    private var agentView: AgentChatNSView?
    private var consultView: ConsultPanelNSView?
    private let agentPlaceholder = PlaceholderView()
    private var agentOpen = false
    private var consultOpen = false
    private var bag = Set<AnyCancellable>()
    private var queued = false
    private var seeded = false

    init(windowID: UUID, workspace: WorkspaceManager) {
        self.windowID = windowID
        self.workspace = workspace
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true   // 滑入前 / 滑出后面板在右边界外，别画到窗口别处
        for b in [agentBox, consultBox] {
            b.isHidden = true
            addSubview(b)
        }
        agentBox.onResize = { AgentPanelModel.shared.setInlineWidth($0) }
        agentBox.currentWidth = { CGFloat(AgentPanelModel.shared.inlineWidth) }
        consultBox.onResize = { AIPanelModel.shared.setInlineWidth($0) }
        consultBox.currentWidth = { CGFloat(AIPanelModel.shared.inlineWidth) }
        agentPlaceholder.set(symbol: "folder", title: L("No Workspace"), detail: L("Open a workspace to talk to the agent about it."))
        AgentPanelModel.shared.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.queueRefresh() }.store(in: &bag)
        AIPanelModel.shared.$mode.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.queueRefresh() }.store(in: &bag)
        AIPanelModel.shared.$inlineOpenWindows.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.queueRefresh() }.store(in: &bag)
        AIPanelModel.shared.$inlineWidth.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.queueRefresh() }.store(in: &bag)
        AIPanelModel.shared.$enabled.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.queueRefresh() }.store(in: &bag)
        AIPanelModel.shared.$currentID.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.queueRefresh() }.store(in: &bag)
        workspace.$folder.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.queueRefresh() }.store(in: &bag)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    /// 只有面板本身接鼠标，空白处透到下面的阅读区。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }

    private func queueRefresh() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            self?.queued = false
            self?.refresh()
        }
    }

    var inset: CGFloat {
        (agentOpen ? CGFloat(AgentPanelModel.shared.inlineWidth) : 0) + (consultOpen ? CGFloat(AIPanelModel.shared.inlineWidth) : 0)
    }

    func refresh() {
        let agent = AgentPanelModel.shared, consult = AIPanelModel.shared
        if !seeded {
            // 新窗口沿用「上次是展开还是收着」
            seeded = true
            if agent.mode == .inline { agent.seedInlineOpen(windowID) }
            if consult.mode == .inline { consult.seedInlineOpen(windowID) }
        }
        let a = agent.mode == .inline && agent.enabled && agent.isInlineOpen(windowID)
        let c = consult.mode == .inline && consult.enabled && consult.isInlineOpen(windowID)
        let toggled = a != agentOpen || c != consultOpen
        agentOpen = a
        consultOpen = c
        if a { ensureAgentContent() }
        if c { ensureConsultContent() }
        if toggled {
            animateLayout()
        } else {
            needsLayout = true
        }
        // 🔴 跟「上次报给阅读区的值」比，不能跟刷新前现算的 `inset` 比：拖宽度时模型里的宽度已经先改了，
        // 现算出来的「旧值」就是新值，阅读区收不到通知、右侧让位停在旧宽度，面板变宽后盖住滚动条（2026-09-19 用户报）
        let newInset = inset
        if abs(newInset - reportedInset) > 0.5 || toggled {
            reportedInset = newInset
            onInset(newInset, toggled)
        }
    }
    private var reportedInset: CGFloat = 0

    private func ensureAgentContent() {
        guard let folder = workspace.folder else {
            agentView?.removeFromSuperview()
            agentView = nil
            agentBox.setContent(agentPlaceholder)
            return
        }
        let cwd = folder.deletingLastPathComponent()
        let chat = AgentPanelModel.shared.chat(for: .inline(windowID), cwd: cwd)
        if agentView?.chat !== chat {
            // 换了一份对话（切了工作区）→ 视图重建，出现时重新建会话
            let v = AgentChatNSView(chat: chat, workspaceName: workspace.name, showsHeader: true)
            agentView = v
            agentBox.setContent(v)
        } else {
            agentView?.workspaceName = workspace.name
        }
    }

    private func ensureConsultContent() {
        let host = AIHost.inline(windowID)
        _ = AIPanelModel.shared.page(for: host)   // 展开时才建网页（收着就不占着）
        if consultView == nil {
            let v = ConsultPanelNSView(host: host, inline: true)
            consultView = v
            consultBox.setContent(v)
        }
        consultView?.refresh()
    }

    // MARK: 布局 / 动画

    /// 打开的面板贴右排（咨询在最右，Agent 在它左边）；收着的停在右边界外。
    private func targetFrames() -> (agent: NSRect, consult: NSRect) {
        let b = bounds
        let aw = CGFloat(AgentPanelModel.shared.inlineWidth), cw = CGFloat(AIPanelModel.shared.inlineWidth)
        let consultX = consultOpen ? b.maxX - cw : b.maxX
        let agentRight = consultOpen ? consultX : b.maxX
        let agentX = agentOpen ? agentRight - aw : b.maxX
        return (NSRect(x: agentX, y: 0, width: aw, height: b.height), NSRect(x: consultX, y: 0, width: cw, height: b.height))
    }

    override func layout() {
        super.layout()
        let f = targetFrames()
        agentBox.frame = f.agent
        consultBox.frame = f.consult
        agentBox.isHidden = !agentOpen
        consultBox.isHidden = !consultOpen
        agentBox.topInset = topInset
        consultBox.topInset = topInset
    }

    private func animateLayout() {
        let f = targetFrames()
        if agentOpen { agentBox.isHidden = false }
        if consultOpen { consultBox.isHidden = false }
        agentBox.topInset = topInset
        consultBox.topInset = topInset
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            agentBox.animator().frame = f.agent
            consultBox.animator().frame = f.consult
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.agentBox.isHidden = !self.agentOpen
                self.consultBox.isHidden = !self.consultOpen
            }
        }
    }
}

/// 一块内置面板的外壳：玻璃底（铺满，含工具栏底下）+ 左侧分隔线 + 左缘改宽手柄 + 内容（让开工具栏）。
final class InlinePanelContainer: NSView {
    var onResize: (Double) -> Void = { _ in }
    var currentWidth: () -> CGFloat = { 400 }
    var topInset: CGFloat = 0 { didSet { if oldValue != topInset { needsLayout = true } } }

    private let glass = NSGlassEffectView()
    private let line = NSBox()
    private let handle = ResizeHandleView()
    private var content: NSView?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.style = .regular
        line.boxType = .separator
        addSubview(glass)
        addSubview(line)
        addSubview(handle)
        handle.onDrag = { [weak self] dx, begin in
            guard let self else { return }
            if begin { self.handle.baseWidth = self.currentWidth() }
            self.onResize(Double(self.handle.baseWidth - dx))
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    func setContent(_ v: NSView) {
        guard content !== v else { return }
        content?.removeFromSuperview()
        content = v
        addSubview(v, positioned: .below, relativeTo: handle)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        glass.frame = b
        // 分隔线只画在工具栏以下（同原 SwiftUI 版：玻璃底铺进工具栏，线挂在内容上）——画满的话工具栏里会露出一条边界
        line.frame = NSRect(x: 0, y: topInset, width: 1, height: max(0, b.height - topInset))
        handle.frame = NSRect(x: 0, y: topInset, width: 6, height: max(0, b.height - topInset))
        content?.frame = NSRect(x: 1, y: topInset, width: b.width - 1, height: max(0, b.height - topInset))
    }
}

/// 左缘改宽手柄：列宽箭头指针，拖动回调累计位移（基准在起手时定死，别每帧拿当前宽度去减）。
final class ResizeHandleView: NSView {
    var onDrag: (CGFloat, Bool) -> Void = { _, _ in }
    var baseWidth: CGFloat = 0
    private var startX: CGFloat?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .columnResize) }
    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
        onDrag(0, true)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let s = startX else { return }
        onDrag(event.locationInWindow.x - s, false)
    }
    override func mouseUp(with event: NSEvent) { startX = nil }
}
