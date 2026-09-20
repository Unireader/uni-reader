import AppKit
import Combine
import UniformTypeIdentifiers

/// 一次鼠标拖拽的状态（按下时建，松手清）。按下时只记起点与修饰键，**拖过 2pt 才决定做什么**
/// ——纯单击不会误触发拖选 / 落墨，2pt 内的抖动也不算拖。
struct MouseTrack {
    enum Kind {
        case pending
        case flowSelect(anchor: (page: Int, nx: CGFloat, ny: CGFloat))
        case boxSelect
        case ink(start: (page: Int, nx: Double, ny: Double), erase: Bool)
        case lasso(LassoDragMode)
        case snip
        case ignore
    }
    var startDoc: CGPoint
    var startDisplay: CGPoint
    var startWindow: NSPoint
    var kind: Kind = .pending
    var moved = false
    var option: Bool
    var shift: Bool
    var command: Bool
    /// 截图：存为图片笔记（⌥⇧ 起手，或拖到一半按上 ⇧）。
    var snipToNote = false
}

/// 鼠标 / 键盘 / 右键菜单 / 拖放（`APPKIT-REWRITE-PLAN.md` §3.4）。按指针工具（`app.pointerTool`）分派：
/// 文字工具拖选（起手按 ⌘ = 框选文字）、本机落墨 / 擦除（⇧ 尺子）、笔迹框选（移动 / 缩放）、⌥ 拖截图（⌥⇧ 存图片笔记）。
/// 图钉与气泡在覆盖层里、自己接鼠标，不经过这里。
extension ReaderView {

    // MARK: 安装

    func installInteraction() {
        let track = NSTrackingArea(rect: .zero,
                                   options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                   owner: self, userInfo: nil)
        addTrackingArea(track)
        registerForDraggedTypes([.fileURL])
        installKeyMonitor()

        let nc = NotificationCenter.default
        // Edit 菜单（没人接时路由给阅读区；草稿纸开着时归纸）
        let editCommands: [(Notification.Name, (ReaderView) -> Void)] = [
            (.readerUndo, { $0.performUndo(redo: false) }),
            (.readerRedo, { $0.performUndo(redo: true) }),
            (.readerCut, { $0.cutLassoSelection() }),
            (.readerPaste, { r in if InkClipboard.hasInk() { r.pasteInk() } else { r.pasteImageNote() } }),
            (.readerDelete, { $0.deleteLassoSelection() }),
            (.readerCopy, { r in if !r.copyLassoSelection() { r.copySelectionToPasteboard() } }),
            (.readerSelectAll, { $0.selectAllText() }),
        ]
        for (name, action) in editCommands {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isActiveWindow, self.session.openPadID == nil else { return }
                    action(self)
                }
            })
        }
        // Inspector 列表里的「编辑 / 查看」：图片笔记两种、文字笔记一种，都弹阅读区自己的 sheet
        let noteRequests: [(Notification.Name, (ReaderView, UUID) -> Void)] = [
            (.imageNoteEdit, { $0.openImageEditor($1) }),
            (.imageNoteView, { $0.openImageViewer($1) }),
            (.textNoteEdit, { $0.openNoteEditor($1) }),
        ]
        for (name, action) in noteRequests {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let req = note.object as? NoteRequest, req.sessionID == self.session.id else { return }
                    action(self, req.noteID)
                }
            })
        }

        // 会话数据 → 标记层 / 覆盖层（@Published 在写入前发，下一拍再读）
        let marks: [AnyPublisher<Void, Never>] = [
            session.$highlights.map { _ in () }.eraseToAnyPublisher(),
            session.$textNotes.map { _ in () }.eraseToAnyPublisher(),
            session.$noteTypes.map { _ in () }.eraseToAnyPublisher(),
            session.$searchMatches.map { _ in () }.eraseToAnyPublisher(),
            session.$currentMatchIndex.map { _ in () }.eraseToAnyPublisher(),
            session.$showOCRBlocks.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(marks)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshMarks(); self?.layoutOverlay() }
            .store(in: &bag)
        let overlays: [AnyPublisher<Void, Never>] = [
            session.$imageNotes.map { _ in () }.eraseToAnyPublisher(),
            session.$scratchPads.map { _ in () }.eraseToAnyPublisher(),
            session.$bookmarks.map { _ in () }.eraseToAnyPublisher(),
            session.$openPadID.map { _ in () }.eraseToAnyPublisher(),
            app.$pointerTool.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(overlays)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.layoutOverlay() }
            .store(in: &bag)
        let tablet: [AnyPublisher<Void, Never>] = [
            session.$hover.map { _ in () }.eraseToAnyPublisher(),
            session.$radial.map { _ in () }.eraseToAnyPublisher(),
            session.$pressRing.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(tablet)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateTabletOverlay() }
            .store(in: &bag)
        app.$pointerTool
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in
                guard let self else { return }
                if t != .lasso { self.clearLassoSelection() }   // 切走框选工具即放弃选中
                if t != .textSelect { self.dismissHighlightPopover() }
                self.updateEraserRing()
            }
            .store(in: &bag)
        app.$padMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateEraserRing() }
            .store(in: &bag)
    }

    // MARK: 键盘焦点

    /// 点阅读区 = 把第一响应者交还给窗口本身：工具栏搜索框 / AI 面板网页一旦拿了焦点就一直攥着键盘，
    /// 单键工具与 ⌘C（Edit 菜单先走响应者链）都会被它吃掉（用户 2026-09-12 报的两条）。
    func takeKeyboardFocus(_ event: NSEvent) {
        guard let w = event.window ?? window, w.firstResponder !== w else { return }
        w.makeFirstResponder(nil)
    }

    // MARK: 鼠标

    func readerMouseDown(_ e: NSEvent) {
        takeKeyboardFocus(e)
        guard didSetup, session.openPadID == nil else { mouseTrack = nil; return }
        let p = docPoint(of: e)
        let flags = e.modifierFlags
        if e.clickCount >= 2, app.pointerTool == .textSelect, !flags.contains(.option) {
            // 双击：OCR 页选整行、原生页选整词；落在高亮上时第一下已弹了气泡，选词时顺手收掉
            dismissHighlightPopover()
            selectWord(atDoc: p)
            mouseTrack = MouseTrack(startDoc: p, startDisplay: .zero, startWindow: e.locationInWindow,
                                    kind: .ignore, option: false, shift: false, command: false)
            return
        }
        mouseTrack = MouseTrack(startDoc: p, startDisplay: overlay.convert(e.locationInWindow, from: nil),
                                startWindow: e.locationInWindow,
                                option: flags.contains(.option), shift: flags.contains(.shift),
                                command: flags.contains(.command))
    }

    func readerMouseDragged(_ e: NSEvent) {
        guard var t = mouseTrack else { return }
        if case .ignore = t.kind { return }
        let p = docPoint(of: e)
        if !t.moved {
            let dx = e.locationInWindow.x - t.startWindow.x, dy = e.locationInWindow.y - t.startWindow.y
            guard hypot(dx, dy) >= 2 else { return }
            t.moved = true
            t.kind = beginDrag(&t)
        }
        switch t.kind {
        case .flowSelect(let a):
            flowSelect(anchor: a, focusDoc: p)
            docView.autoscroll(with: e)
        case .boxSelect:
            if var d = boxSelectDrag { d.current = p; boxSelectDrag = d; applyBoxDrag(start: d.start, current: d.current) }
            updateBoxSelectOverlay()
            docView.autoscroll(with: e)
        case .ink(let start, let erase):
            inkDragged(to: p, start: start, erase: erase, shift: e.modifierFlags.contains(.shift))
        case .lasso(let mode):
            lassoDragged(mode: mode, doc: p, display: overlay.convert(e.locationInWindow, from: nil),
                         startDisplay: t.startDisplay, shift: e.modifierFlags.contains(.shift))
        case .snip:
            if e.modifierFlags.contains(.shift) { t.snipToNote = true }   // 拖到一半按上 ⇧ 也算
            snipRect = (t.startDoc, p)
            updateSnipOverlay(toNote: t.snipToNote)
        case .pending, .ignore:
            break
        }
        mouseTrack = t
    }

    /// 拖过阈值那一刻：按工具与起手时的修饰键决定这次拖拽做什么。
    private func beginDrag(_ t: inout MouseTrack) -> MouseTrack.Kind {
        let tool = app.pointerTool
        // ⌥ 拖 = 截图（任何工具下；⌥⇧ = 存为图片笔记）；常驻截图工具同样
        if tool == .snip || t.option {
            t.snipToNote = t.shift
            snipRect = (t.startDoc, t.startDoc)
            return .snip
        }
        switch tool {
        case .ink:
            let erase = app.padMode == "erase"
            guard let n0 = pageNorm(atDoc: t.startDoc, xRange: inkXRange) else { return .ignore }
            growCanvasMargin(towardX: Double(n0.nx))
            let p0 = InkPoint(Double(n0.nx), Double(n0.ny), 0.5)
            if erase {
                app.inkErase([p0], page: n0.page, in: session)
            } else {
                guard let pen = app.pens.indices.contains(app.padPenIndex) ? app.pens[app.padPenIndex] : app.pens.first
                else { return .ignore }
                app.inkBegin(in: session, page: n0.page, color: pen.color, width: pen.width, type: pen.type, points: [p0])
            }
            return .ink(start: (n0.page, Double(n0.nx), Double(n0.ny)), erase: erase)
        case .lasso:
            var mode = LassoDragMode.select
            if let sel = lassoSelection, let box = lassoDisplayBox(sel) {
                if let h = lassoHandleHit(at: t.startDisplay, box: box) { mode = .scale(h) }
                else if box.insetBy(dx: -8, dy: -8).contains(t.startDisplay) { mode = .move }
            }
            if mode == .select {
                lassoSelection = nil
                lassoPath = [t.startDoc]
            }
            return .lasso(mode)
        case .textSelect:
            dismissHighlightPopover()
            if t.command {
                // ⌘ 起手 = 框选文字：当前选区与框选自己的账对不上（中途做过流式选择等）就整个拆进来
                if composeBoxSelection() != selection {
                    boxSelectPages = selection.map(decomposeIntoBoxSelectItems) ?? [:]
                }
                boxSelectStrokeBase = boxSelectPages
                boxSelectDrag = (t.startDoc, t.startDoc)
                return .boxSelect
            }
            guard let a = pageNorm(atDoc: t.startDoc) else { return .ignore }
            return .flowSelect(anchor: a)
        default:
            return .ignore
        }
    }

    func readerMouseUp(_ e: NSEvent) {
        guard let t = mouseTrack else { return }
        mouseTrack = nil
        guard t.moved else {
            if case .ignore = t.kind { return }
            click(atDoc: t.startDoc, display: t.startDisplay, clickCount: e.clickCount)
            return
        }
        switch t.kind {
        case .flowSelect:
            break
        case .boxSelect:
            boxSelectDrag = nil
            boxSelectStrokeBase = [:]
            updateBoxSelectOverlay()
        case .ink(_, let erase):
            if !erase { app.inkEnd(in: session) }   // 擦除每批已即时生效，无需收尾
            session.inkUndo.seal()                   // 抬笔 = 这一组封口（一次拖动 = 一步撤销）
        case .lasso(let mode):
            finishLassoDrag(mode: mode)
        case .snip:
            finishSnipDrag(toNote: t.snipToNote || e.modifierFlags.contains(.shift))
        case .pending, .ignore:
            break
        }
    }

    /// 单击：收起文字选区与框选；文字工具下点中高亮就弹它的操作气泡，没点中就收起。
    private func click(atDoc p: CGPoint, display: CGPoint, clickCount: Int) {
        guard clickCount < 2 else { return }   // 双击的第二下不算单击（否则会把刚选好的词清掉）
        clearSelection()
        clearLassoSelection()
        guard app.pointerTool == .textSelect else { dismissHighlightPopover(); return }
        if let hit = highlightHit(atDoc: p) {
            showHighlightPopover(hit.highlight, lineRect: hit.rect)
        } else {
            dismissHighlightPopover()
        }
    }

    // MARK: 指针移动（橡皮圈 / 右键落点）

    override func mouseMoved(with event: NSEvent) {
        cursorDoc = docPoint(of: event)
        updateEraserRing()
    }

    override func mouseEntered(with event: NSEvent) {
        cursorDoc = docPoint(of: event)
        updateEraserRing()
    }

    override func mouseExited(with event: NSEvent) {
        cursorDoc = nil
        updateEraserRing()
    }

    // MARK: 本机落墨

    /// 画板模式下笔迹落点的合法 x 区间（放宽到页边）。
    var inkXRange: ClosedRange<Double> { CanvasMargin.xRange(margin: canvasMargin) }

    private func inkDragged(to p: CGPoint, start: (page: Int, nx: Double, ny: Double), erase: Bool, shift: Bool) {
        guard let n = pageNorm(atDoc: p, xRange: inkXRange) else { return }
        if !erase { growCanvasMargin(towardX: Double(n.nx)) }
        let pt = InkPoint(Double(n.nx), Double(n.ny), 0.5)
        if erase {
            app.inkErase([pt], page: n.page, in: session)   // 擦除可跨页（按点所在页逐批）
            return
        }
        guard n.page == start.page else { return }            // 落墨不跨页：拖出页边即停笔
        if shift {
            // ⇧ 尺子：整笔替换为「起点 → 45° 吸附终点」两点直线（按本页显示纵横比吸附看上去的角度）
            let snapped = InkEdit.rulerSnap(start: SIMD2(start.nx, start.ny), current: SIMD2(pt.dx, pt.dy),
                                            aspect: pageAspect(page: start.page))
            if var st = session.liveStroke {
                st.points = [InkPoint(start.nx, start.ny, 0.5), InkPoint(snapped.x, snapped.y, 0.5)]
                session.liveStroke = st
            }
        } else {
            app.inkAppend([pt], in: session)
        }
    }

    // MARK: 单键工具 / Esc / ⌫

    /// 单键工具切换（e 橡皮 / b 书写 / v 翻页 / l 框选 / i 本机笔 / t 文字；有选中文字时 h / ⇧H / ⌥H / n；1–9 选笔）、
    /// 框选选中集的 Esc（放弃）/ ⌫（删除）。文本框焦点与内置 AI 面板的网页焦点一律放行。
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isActiveWindow, !self.tornDown,
                      !(NSApp.keyWindow?.firstResponder is NSText),
                      !aiWebInputHasFocus() else { return event }
                if self.lassoSelection != nil {
                    switch event.keyCode {
                    case 53: self.clearLassoSelection(); return nil                       // Esc
                    case 51, 117:                                                         // ⌫ / ⌦
                        guard self.session.openPadID == nil else { return event }
                        self.deleteLassoSelection(); return nil
                    default: break
                    }
                }
                guard let combo = KeyCombo(event: event) else { return event }
                if combo.mods.isEmpty, combo.key.count == 1, let d = Int(combo.key), (1...9).contains(d) {
                    guard d - 1 < self.app.pens.count else { return event }
                    self.app.applyPenSelection(index: d - 1)
                    return nil
                }
                guard let action = Shortcuts.shared.readerAction(for: combo) else { return event }
                let hasSelection = self.selection?.text.isEmpty == false && self.session.openPadID == nil
                let app = self.app
                switch action {
                case .highlightSelection:
                    guard hasSelection else { return event }
                    self.quickHighlight(style: .fill)
                case .underlineSelection:
                    guard hasSelection else { return event }
                    self.quickHighlight(style: .underline)
                case .boxSelection:
                    guard hasSelection else { return event }
                    self.quickHighlight(style: .box)
                case .noteFromSelection:
                    guard hasSelection else { return event }
                    self.beginAddNote()
                case .keyEraser: app.setPadMode(app.padMode == "erase" ? "note" : "erase")
                case .keyWrite: app.setPadMode("note")
                case .keyPageTurn: app.setPadMode(app.padMode == "page" ? "note" : "page")
                case .keyLasso: app.pointerTool = app.pointerTool == .lasso ? .textSelect : .lasso
                case .keyLocalInk: app.pointerTool = app.pointerTool == .ink ? .textSelect : .ink
                case .keyTextSelect: app.pointerTool = .textSelect
                default: return event
                }
                return nil
            }
        }
    }

    func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    // MARK: 拖放（图片 = 图片笔记；其余交给窗口层入库）

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        let (images, others) = urls.reduce(into: ([URL](), [URL]())) { acc, u in
            if Self.isImageFile(u) { acc.0.append(u) } else { acc.1.append(u) }
        }
        if !others.isEmpty { onDropFiles(others) }
        guard !images.isEmpty, session.openPadID == nil, session.pdf != nil else { return !others.isEmpty }
        let p = docView.convert(sender.draggingLocation, from: nil)
        if let n = pageNorm(atDoc: p) {
            importImageFiles(images, page: n.page, nx: Double(n.nx), ny: Double(n.ny))
        }
        return true
    }

    static func isImageFile(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
        return t.conforms(to: .image)
    }
}
