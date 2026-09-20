import AppKit
import QuartzCore

/// 覆盖层的摆放：图钉 / 气泡（屏幕固定尺寸，跟着页面走）+ 框选 / 截图 / 平板笔尖等临时形状。
/// 滚动、缩放、实化变化、笔记数据变化、展开状态变化都会调 `layoutOverlay()`——只处理实化窗口里的页，
/// 每次滚动事件跑一遍也只是几十个 frame 赋值。
extension ReaderView {

    // MARK: 图钉落位（与 SwiftUI 版 `PageCellView.markerPos` / `imageMarkerPos` 同一套数，屏幕点）

    /// 文字批注图钉：选区批注落在末端右侧（不遮文字起点）；点批注（无行框）落在锚点处。钳在页内。
    static func notePinCenter(_ n: TextNote, size: CGSize) -> CGPoint {
        let x = n.rects.isEmpty ? n.anchor.minX * size.width : n.anchor.maxX * size.width + 9
        let y = n.rects.isEmpty ? n.anchor.minY * size.height : n.anchor.minY * size.height + 7
        return CGPoint(x: min(max(x, 12), size.width - 12), y: min(max(y, 10), size.height - 10))
    }

    /// 图片笔记图钉：PDF 节选（有框）落在框右上角外侧；导入（点锚）落在锚点处。
    static func imagePinCenter(_ n: ImageNote, size: CGSize) -> CGPoint {
        let boxed = n.anchor.width > 0 || n.anchor.height > 0
        let x = boxed ? n.anchor.maxX * size.width + 9 : n.anchor.minX * size.width
        let y = boxed ? n.anchor.minY * size.height + 7 : n.anchor.minY * size.height
        return CGPoint(x: min(max(x, 12), size.width - 12), y: min(max(y, 10), size.height - 10))
    }

    /// 本页两种气泡共用的尺寸口径（设置里的四个数，默认固定尺寸 12pt / 120…280）。
    func bubbleMetrics(pageWidth: CGFloat) -> NoteBubble.Metrics {
        let d = UserDefaults.standard
        let follows = d.bool(forKey: NoteBubble.followsZoomKey)
        let fs = (d.object(forKey: NoteBubble.fontSizeKey) as? Int).map { CGFloat($0) } ?? NoteBubble.fixedFont
        let minW = (d.object(forKey: NoteBubble.minWidthKey) as? Int).map { CGFloat($0) } ?? NoteBubble.fixedMinWidth
        let maxW = (d.object(forKey: NoteBubble.maxWidthKey) as? Int).map { CGFloat($0) } ?? NoteBubble.fixedMaxWidth
        return NoteBubble.metrics(pageWidth: pageWidth, followsZoom: follows, fontSize: fs, minWidth: minW, maxWidth: maxW)
    }

    /// 这条笔记此刻要不要画气泡（空正文没有可展开的东西）。
    func bubbleVisible(_ n: TextNote) -> Bool {
        guard !n.text.isEmpty else { return false }
        switch n.display {
        case .always: return true
        case .tap: return expandedNotes.contains(n.id)
        case .hover: return hoveredNote == n.id
        }
    }

    func imageBubbleVisible(_ n: ImageNote) -> Bool {
        switch n.display {
        case .always: return true
        case .tap: return expandedNotes.contains(n.id)
        case .hover: return hoveredNote == n.id
        }
    }

    /// 笔记卡片能不能拖动 / 改大小：文字工具 + 草稿纸没盖着。
    var cardsInteractive: Bool { app.pointerTool == .textSelect && session.openPadID == nil }

    // MARK: 摆放

    func layoutOverlay() {
        guard didSetup, !tornDown else { return }
        let range = realized
        let padOpen = session.openPadID != nil
        let interactive = cardsInteractive
        var wantPins = Set<String>()
        var wantNotes = Set<UUID>()
        var wantImages = Set<UUID>()
        let types = session.noteTypes

        // 草稿纸盖着时页面上的图钉 / 气泡都不显示（纸归纸）
        if !padOpen {
            for n in session.textNotes where range.contains(n.page) {
                let pr = displayPageRect(n.page)
                let key = "n-\(n.id.uuidString)"
                wantPins.insert(key)
                let typed = n.typeId != nil
                let t = NoteType.resolve(n.typeId, in: types)
                let pin = pinView(key)
                pin.kind = .note(symbol: typed ? t.icon : "note.text", color: typed ? t.nsColor : ReaderMarkColors.noteMarker)
                place(pin, center: Self.notePinCenter(n, size: pr.size), in: pr)
                pin.toolTip = n.display == .hover && !n.text.isEmpty ? nil
                    : (n.text.isEmpty ? n.quote : NoteMarkdown.plain(n.text))
                let id = n.id
                pin.onClick = { [weak self] in self?.notePinClicked(id) }
                pin.onHover = { [weak self] inside in self?.pinHover(id, inside) }
                pin.menuProvider = { [weak self] in self?.linkMenu(note: id) }
                if n.rects.isEmpty {   // 点批注可拖（选区批注的图钉跟着文字走，不拖）
                    pin.clampDrag = { [weak self] t in self?.clampPinDrag(id, t) ?? t }
                    pin.onDragEnd = { [weak self] t in self?.commitPinDrag(id, translation: t) }
                } else {
                    pin.clampDrag = nil
                    pin.onDragEnd = nil
                }
                if bubbleVisible(n) {
                    wantNotes.insert(n.id)
                    let b = noteBubble(n.id)
                    let m = bubbleMetrics(pageWidth: pr.width)
                    b.onEdit = n.display == .hover ? nil : { [weak self] in self?.openNoteEditor(id) }
                    b.onCopyLink = { [weak self] in self?.copyLinkToPasteboard(note: id) }
                    b.onCommit = { [weak self] card, zone in self?.commitCard(id, card: card, zone: zone) }
                    b.onReset = { [weak self] in self?.commitCard(id, card: nil, zone: nil) }
                    b.update(text: n.text, documentId: n.id.uuidString, metrics: m, pageRect: pr,
                             pin: Self.notePinCenter(n, size: pr.size), card: n.card,
                             interactive: interactive && n.display != .hover, hasEdit: n.display != .hover)
                }
            }
            for n in session.imageNotes where range.contains(n.page) {
                let pr = displayPageRect(n.page)
                let key = "i-\(n.id.uuidString)"
                wantPins.insert(key)
                let pin = pinView(key)
                pin.kind = .image
                place(pin, center: Self.imagePinCenter(n, size: pr.size), in: pr)
                pin.toolTip = n.display == .hover ? nil : (n.caption.isEmpty ? n.sourceLabel : NoteMarkdown.plain(n.caption))
                let id = n.id
                pin.onClick = { [weak self] in self?.imagePinClicked(id) }
                pin.onHover = { [weak self] inside in self?.pinHover(id, inside) }
                pin.menuProvider = nil
                pin.clampDrag = { [weak self] t in self?.clampPinDrag(id, t) ?? t }
                pin.onDragEnd = { [weak self] t in self?.commitPinDrag(id, translation: t) }
                if imageBubbleVisible(n) {
                    wantImages.insert(n.id)
                    let b = imageBubble(n.id)
                    let sticky = n.display != .hover
                    b.onEdit = sticky ? { [weak self] in self?.openImageEditor(id) } : nil
                    b.onView = sticky ? { [weak self] in self?.openImageViewer(id) } : nil
                    b.onDelete = sticky ? { [weak self] in self?.deleteImageNote(id) } : nil
                    b.onCommit = { [weak self] card, zone in self?.commitCard(id, card: card, zone: zone) }
                    b.onReset = { [weak self] in self?.commitCard(id, card: nil, zone: nil) }
                    b.update(note: n, info: workspace.imageInfo(sha256: n.image), metrics: bubbleMetrics(pageWidth: pr.width),
                             pageRect: pr, pin: Self.imagePinCenter(n, size: pr.size), interactive: interactive)
                }
            }
            for (i, p) in session.scratchPads.enumerated() where range.contains(p.anchorPage) {
                let pr = displayPageRect(p.anchorPage)
                let key = "s-\(p.id.uuidString)"
                wantPins.insert(key)
                let pin = pinView(key)
                pin.kind = .scratch
                let c = CGPoint(x: min(max(p.anchorX * pr.width, 12), pr.width - 12),
                                y: min(max(p.anchorY * pr.height, 10), pr.height - 10))
                place(pin, center: c, in: pr)
                pin.toolTip = p.displayName(index: i)
                let id = p.id, ny = p.anchorY, page = p.anchorPage
                pin.onClick = { [weak self] in self?.session.openPadID = id }
                pin.onHover = nil
                pin.clampDrag = nil
                pin.onDragEnd = nil
                pin.menuProvider = { [weak self] in
                    let m = NSMenu()
                    m.addItem(ClosureMenuItem(L("Copy Link")) { self?.copyLinkToPasteboard(page: page, frac: ny) })
                    return m
                }
            }
            for b in session.bookmarks where range.contains(b.page) {
                let pr = displayPageRect(b.page)
                let key = "b-\(b.id.uuidString)"
                wantPins.insert(key)
                let pin = pinView(key)
                pin.kind = .bookmark
                let s = ReaderPinView.ribbonSize
                let c = CGPoint(x: pr.width - s.width / 2, y: min(max(b.frac * pr.height, s.height), pr.height - s.height))
                place(pin, center: c, in: pr)
                pin.toolTip = b.title
                let id = b.id
                pin.onClick = { [weak self] in self?.showBookmarkPopover(id) }
                pin.onHover = nil
                pin.clampDrag = nil
                pin.onDragEnd = nil
                pin.menuProvider = { [weak self] in
                    let m = NSMenu()
                    m.addItem(ClosureMenuItem(L("Copy Link")) { self?.copyLinkToPasteboard(note: id) })
                    return m
                }
            }
        }
        for (k, v) in overlay.pins where !wantPins.contains(k) {
            v.removeFromSuperview()
            overlay.pins.removeValue(forKey: k)
        }
        for (k, v) in overlay.noteBubbles where !wantNotes.contains(k) {
            v.removeFromSuperview()
            overlay.noteBubbles.removeValue(forKey: k)
        }
        for (k, v) in overlay.imageBubbles where !wantImages.contains(k) {
            v.removeFromSuperview()
            overlay.imageBubbles.removeValue(forKey: k)
        }
        layoutTransientOverlay()
    }

    private func pinView(_ key: String) -> ReaderPinView {
        if let v = overlay.pins[key] { return v }
        let v = ReaderPinView(frame: .zero)
        overlay.pinLayerView.addSubview(v)
        overlay.pins[key] = v
        return v
    }

    private func noteBubble(_ id: UUID) -> NoteBubbleNSView {
        if let v = overlay.noteBubbles[id] { return v }
        let v = NoteBubbleNSView(frame: .zero)
        v.wiki = workspace.wiki
        v.onOpenNote = { id in NotificationCenter.default.post(name: .openMarkdownNote, object: nil,
                                                              userInfo: ["id": id]) }
        overlay.bubbleLayerView.addSubview(v)
        overlay.noteBubbles[id] = v
        return v
    }

    private func imageBubble(_ id: UUID) -> ImageBubbleNSView {
        if let v = overlay.imageBubbles[id] { return v }
        let v = ImageBubbleNSView(frame: .zero)
        v.wiki = workspace.wiki
        overlay.bubbleLayerView.addSubview(v)
        overlay.imageBubbles[id] = v
        return v
    }

    private func place(_ pin: ReaderPinView, center c: CGPoint, in pr: CGRect) {
        let s = ReaderPinView.size(for: pin.kind)
        let f = NSRect(x: pr.minX + c.x - s.width / 2, y: pr.minY + c.y - s.height / 2, width: s.width, height: s.height)
        if pin.frame != f { pin.frame = f }
    }

    // MARK: 临时形状（框选 / 截图 / 平板笔尖 / 长按环 / 选笔盘）

    func layoutTransientOverlay() {
        updateLassoOverlay()
        updateBoxSelectOverlay()
        updateSnipOverlay()
        updateTabletOverlay()
    }

    func updateBoxSelectOverlay() {
        guard let d = boxSelectDrag else { ReaderOverlayView.set(overlay.boxSelect, nil); return }
        let a = displayPoint(ofDoc: d.start), b = displayPoint(ofDoc: d.current)
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        ReaderOverlayView.set(overlay.boxSelect, CGPath(rect: r, transform: nil))
    }

    /// 平板笔尖光标 / 长按进度环 / 环形选笔盘（页锚定、屏幕固定尺寸）。
    func updateTabletOverlay() {
        if let h = session.hover, realized.contains(h.page), session.openPadID == nil {
            let c = displayPoint(ofDoc: docPoint(page: h.page, nx: h.nx, ny: h.ny))
            let d = app.padMode == "erase" && app.eraserRing ? app.eraserRadius * 2 * pageW : 10
            ReaderOverlayView.set(overlay.tabletHover, CGPath(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d), transform: nil))
        } else {
            ReaderOverlayView.set(overlay.tabletHover, nil)
        }
        if let r = session.pressRing, realized.contains(r.page) {
            let c = displayPoint(ofDoc: docPoint(page: r.page, nx: r.nx, ny: r.ny))
            let p = min(1, max(0, (Date().timeIntervalSince(r.start) - 0.3) / 0.7))
            let circle = CGMutablePath()
            circle.addArc(center: c, radius: 15, startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: false)
            ReaderOverlayView.set(overlay.pressTrack, p > 0.001 ? circle : nil)
            ReaderOverlayView.set(overlay.pressFill, p > 0.001 ? circle : nil)
            overlay.pressFill.strokeEnd = CGFloat(p)
            if p < 1 { startFrameLink() }
        } else {
            ReaderOverlayView.set(overlay.pressTrack, nil)
            ReaderOverlayView.set(overlay.pressFill, nil)
        }
        if let r = session.radial, realized.contains(r.page) {
            overlay.radial.show(r, pens: app.pens, center: displayPoint(ofDoc: docPoint(page: r.page, nx: r.cx, ny: r.cy)))
        } else {
            overlay.radial.isHidden = true
        }
    }

    /// 长按进度环在动（逐帧推进填充）。
    var pressRingAnimating: Bool {
        guard let r = session.pressRing else { return false }
        return Date().timeIntervalSince(r.start) < 1.0
    }

    // MARK: 本机橡皮圈（ink 工具 + 擦除模式，跟光标）

    func updateEraserRing() {
        guard app.pointerTool == .ink, app.padMode == "erase", app.eraserRing, let p = cursorDoc,
              session.openPadID == nil else {
            ReaderOverlayView.set(overlay.eraserRing, nil)
            return
        }
        let c = displayPoint(ofDoc: p)
        let d = app.eraserRadius * 2 * pageW
        ReaderOverlayView.set(overlay.eraserRing, CGPath(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d), transform: nil))
    }

    // MARK: 提示条

    func showToast(_ kind: ReaderToastView.Kind, _ text: String) {
        overlay.toast.show(kind, text, in: overlay, trailingInset: panelInset)
    }
}
