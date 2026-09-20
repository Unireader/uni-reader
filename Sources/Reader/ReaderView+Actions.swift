import AppKit

/// 阅读区里的「动作」：批注 / 高亮 / 图片笔记 / 书签 / 草稿纸 / 复制链接 / 卡片与图钉提交 / 问 AI（逻辑同 SwiftUI 版
/// `ReaderSurface+Selection` / `+ImageNote` 各处，逐条移植）。
///
/// 三个编辑弹窗（批注编辑器、图片笔记编辑器、看大图）见 `Window/Sheets/NoteSheets.swift`，以 sheet 弹出。
extension ReaderView {

    // MARK: 弹窗（sheet）

    func presentSheet(_ vc: NSViewController) {
        guard let win = window, currentSheet == nil else { return }
        let sheet = NSWindow(contentViewController: vc)
        currentSheet = sheet
        win.beginSheet(sheet)
    }

    func dismissSheet() {
        guard let s = currentSheet else { return }
        currentSheet = nil
        window?.endSheet(s)
    }

    // MARK: 批注编辑器

    func presentNoteEditor(_ target: NoteEditorTarget) {
        dismissHighlightPopover()
        presentSheet(NoteEditorController(.init(
            quote: target.quote, initialText: target.initialText, initialTypeId: target.initialTypeId,
            initialDisplay: target.initialDisplay, initialColor: target.initialColor, initialStyle: target.initialStyle,
            hasRects: target.hasRects, documentId: target.id.uuidString, wiki: workspace.wiki,
            noteTypes: session.noteTypes,
            usageCount: { [session] id in session.textNotes.filter { $0.typeId == id }.count },
            onSave: { [weak self] out in self?.saveEditor(target, out) },
            onDelete: target.editedNote == nil ? nil : { [weak self] in self?.deleteEditorNote(target) },
            onChangeTypes: { [weak self] types in self?.saveNoteTypes(types) },
            onCancel: { [weak self] in self?.dismissSheet() })))
    }

    func openNoteEditor(_ id: UUID) {
        guard let n = session.textNotes.first(where: { $0.id == id }) else { return }
        presentNoteEditor(.edit(n))
    }

    /// 由当前选区起一条批注草稿：锚到选区起始页（逐行框 + 包围盒），原文完整保留（可能跨页）。
    func beginAddNote() {
        guard let sel = selection, !sel.text.isEmpty, let page = sel.rects.keys.min() else { return }
        let rects = sel.rects[page] ?? []
        let bbox = rects.reduce(CGRect.null) { $0.union($1) }
        presentNoteEditor(.new(PendingNote(page: page, anchor: bbox.isNull ? .zero : bbox, rects: rects, quote: sel.text)))
    }

    /// 点批注：锚到右键处（零尺寸 anchor、无行框、无引文）。
    func beginAddNoteAtCursor() {
        guard let p = cursorDoc, let n = pageNorm(atDoc: p) else { return }
        presentNoteEditor(.new(PendingNote(page: n.page, anchor: CGRect(x: n.nx, y: n.ny, width: 0, height: 0),
                                           rects: [], quote: "")))
    }

    /// 高亮转文字笔记（用户 2026-09-16 拍板为转换）：保存时落成笔记并删掉原高亮，取消什么都不动。
    func beginNoteFromHighlight(_ h: Highlight) {
        dismissHighlightPopover()
        presentNoteEditor(.new(PendingNote(page: h.page, anchor: h.anchor, rects: h.rects, quote: h.quote,
                                           color: h.color, style: h.style, replacesHighlight: h.id)))
    }

    func saveEditor(_ target: NoteEditorTarget, _ out: NoteEditorOutput) {
        switch target {
        case .new(let draft): commitNote(draft: draft, out)
        case .edit(let note): updateNote(note, out)
        }
        dismissSheet()
    }

    /// 新建批注。点批注必须有文字（否则是个空图钉，丢弃）；选区批注允许空文字（= 纯标记）。
    func commitNote(draft: PendingNote, _ out: NoteEditorOutput) {
        if draft.quote.isEmpty, out.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clearSelection(); return
        }
        session.inkEdit("Note", kind: .note) {
            session.textNotes.append(TextNote(page: draft.page, anchor: draft.anchor, quote: draft.quote,
                                              text: out.text, rects: draft.rects, color: out.color, style: out.style,
                                              typeId: out.typeId, display: out.display))
        }
        if let hid = draft.replacesHighlight { session.highlights.removeAll { $0.id == hid } }
        clearSelection()
    }

    func updateNote(_ note: TextNote, _ out: NoteEditorOutput) {
        guard let idx = session.textNotes.firstIndex(where: { $0.id == note.id }) else { return }
        var n = session.textNotes[idx]
        n.text = out.text
        n.typeId = out.typeId
        n.display = out.display
        n.color = out.color
        n.style = out.style
        n.updatedAt = .now
        session.inkEdit("Note", kind: .note) { session.textNotes[idx] = n }
    }

    func deleteEditorNote(_ target: NoteEditorTarget) {
        guard let note = target.editedNote else { return }
        session.inkEdit("Delete", kind: .delete) { session.textNotes.removeAll { $0.id == note.id } }
        dismissSheet()
    }

    /// 类型增删改回写；被删类型的笔记回落通用。
    func saveNoteTypes(_ types: [NoteType]) {
        let removed = Set(session.noteTypes.map(\.id)).subtracting(types.map(\.id))
        session.noteTypes = types
        workspace.saveNoteTypes(types)
        guard !removed.isEmpty else { return }
        if case .only(let id?) = session.noteTypeFilter, removed.contains(id) { session.noteTypeFilter = .all }
        for i in session.textNotes.indices where session.textNotes[i].typeId.map({ removed.contains($0) }) ?? false {
            session.textNotes[i].typeId = nil
            session.textNotes[i].updatedAt = .now
        }
    }

    // MARK: 图钉

    /// 文字批注图钉：tap 模式且有正文 → 展开 / 收起气泡；其余进编辑器。
    func notePinClicked(_ id: UUID) {
        guard let n = session.textNotes.first(where: { $0.id == id }) else { return }
        if n.display == .tap && !n.text.isEmpty {
            if expandedNotes.contains(id) { expandedNotes.remove(id) } else { expandedNotes.insert(id) }
        } else {
            presentNoteEditor(.edit(n))
        }
    }

    func imagePinClicked(_ id: UUID) {
        guard let n = session.imageNotes.first(where: { $0.id == id }) else { return }
        if n.display == .tap {
            if expandedNotes.contains(id) { expandedNotes.remove(id) } else { expandedNotes.insert(id) }
        } else {
            openImageEditor(id)
        }
    }

    func pinHover(_ id: UUID, _ inside: Bool) {
        if inside { hoveredNote = id } else if hoveredNote == id { hoveredNote = nil }
    }

    func linkMenu(note id: UUID) -> NSMenu {
        let m = NSMenu()
        m.addItem(ClosureMenuItem(L("Copy Link")) { [weak self] in self?.copyLinkToPasteboard(note: id) })
        return m
    }

    /// 图钉拖动位移（屏幕点）夹到锚点不出本页。
    func clampPinDrag(_ id: UUID, _ t: CGSize) -> CGSize {
        guard let a = pinAnchor(id: id) else { return t }
        let pr = displayPageRect(a.page)
        let ax = a.anchor.minX * pr.width, ay = a.anchor.minY * pr.height
        return CGSize(width: min(max(t.width, -ax), pr.width - ax), height: min(max(t.height, -ay), pr.height - ay))
    }

    func pinAnchor(id: UUID) -> (page: Int, anchor: CGRect)? {
        if let n = session.textNotes.first(where: { $0.id == id }) { return (n.page, n.anchor) }
        if let n = session.imageNotes.first(where: { $0.id == id }) { return (n.page, n.anchor) }
        return nil
    }

    /// 图钉拖动提交：屏幕点位移 → 页内归一化平移（点批注用 `InkEdit.translated`，图片笔记锚矩形钳在页内）。
    func commitPinDrag(_ id: UUID, translation t: CGSize) {
        guard let a = pinAnchor(id: id) else { return }
        let pr = displayPageRect(a.page)
        guard pr.width > 0, pr.height > 0 else { return }
        let dx = Double(t.width / pr.width), dy = Double(t.height / pr.height)
        guard dx != 0 || dy != 0 else { return }
        if let i = session.textNotes.firstIndex(where: { $0.id == id }) {
            session.inkEdit("Move", kind: .move) {
                session.textNotes[i] = InkEdit.translated(session.textNotes[i], dx: dx, dy: dy)
            }
            if session.id == app.padSession?.id { app.broadcastNotes() }
        } else if let i = session.imageNotes.firstIndex(where: { $0.id == id }) {
            var r = session.imageNotes[i].anchor
            r.origin.x = min(max(r.origin.x + dx, 0), max(0, 1 - r.width))
            r.origin.y = min(max(r.origin.y + dy, 0), max(0, 1 - r.height))
            guard r != session.imageNotes[i].anchor else { return }
            session.inkEdit("Move", kind: .move) {
                session.imageNotes[i].anchor = r
                session.imageNotes[i].updatedAt = .now
            }
        }
    }

    /// 卡片松手提交（拖动 / 改大小）或右键「恢复自动」（`card == nil`）。进撤销栈。
    func commitCard(_ id: UUID, card: NoteCard?, zone: NoteCardZone?) {
        let label = zone == .move ? "Move" : "Resize"
        if let i = session.textNotes.firstIndex(where: { $0.id == id }) {
            guard session.textNotes[i].card != card else { return }
            session.inkEdit(label, kind: .move) {
                session.textNotes[i].card = card
                session.textNotes[i].updatedAt = .now
            }
        } else if let i = session.imageNotes.firstIndex(where: { $0.id == id }) {
            guard session.imageNotes[i].card != card else { return }
            session.inkEdit(label, kind: .move) {
                session.imageNotes[i].card = card
                session.imageNotes[i].updatedAt = .now
            }
        }
    }

    // MARK: 高亮

    func addHighlight(color: InkColor, style: HighlightStyle = .fill) {
        guard let sel = selection, !sel.text.isEmpty else { return }
        for (page, rects) in sel.rects where !rects.isEmpty {
            let bbox = rects.reduce(CGRect.null) { $0.union($1) }
            session.highlights.append(Highlight(page: page, anchor: bbox.isNull ? .zero : bbox,
                                                quote: sel.text, rects: rects, color: color, style: style))
        }
        if app.quickHighlightColor != color { app.quickHighlightColor = color }
        clearSelection()
    }

    func quickHighlight(style: HighlightStyle = .fill) { addHighlight(color: app.quickHighlightColor, style: style) }

    func recolorHighlight(_ id: UUID, color: InkColor) {
        guard let i = session.highlights.firstIndex(where: { $0.id == id }), session.highlights[i].color != color else { return }
        session.highlights[i].color = color
        session.highlights[i].updatedAt = .now
        if app.quickHighlightColor != color { app.quickHighlightColor = color }
    }

    func restyleHighlight(_ id: UUID, style: HighlightStyle) {
        guard let i = session.highlights.firstIndex(where: { $0.id == id }), session.highlights[i].style != style else { return }
        session.highlights[i].style = style
        session.highlights[i].updatedAt = .now
    }

    func deleteHighlight(_ id: UUID) {
        dismissHighlightPopover()
        session.highlights.removeAll { $0.id == id }
    }

    // MARK: 图片笔记

    func openImageEditor(_ id: UUID) {
        guard let n = session.imageNotes.first(where: { $0.id == id }) else { return }
        presentSheet(ImageNoteEditorController(
            note: n, info: workspace.imageInfo(sha256: n.image), wiki: workspace.wiki,
            onSave: { [weak self] caption, display in
                self?.updateImageNote(id, caption: caption, display: display)
                self?.dismissSheet()
            },
            onDelete: { [weak self] in self?.deleteImageNote(id); self?.dismissSheet() },
            onView: { [weak self] in
                self?.dismissSheet()
                DispatchQueue.main.async { self?.openImageViewer(id) }
            },
            onCancel: { [weak self] in self?.dismissSheet() }))
    }

    func openImageViewer(_ id: UUID) {
        guard let n = session.imageNotes.first(where: { $0.id == id }) else { return }
        if let info = workspace.imageInfo(sha256: n.image) {
            presentSheet(ImageViewerController(note: n, url: info.url, onClose: { [weak self] in self?.dismissSheet() }))
        } else {
            let alert = NSAlert()
            alert.messageText = L("Image file is missing (not in this copy, or already cleaned up).")
            alert.addButton(withTitle: L("Close"))
            if let window { alert.beginSheetModal(for: window) }
        }
    }

    func updateImageNote(_ id: UUID, caption: String, display: NoteDisplay) {
        guard let i = session.imageNotes.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.imageNotes[i].caption != trimmed || session.imageNotes[i].display != display else { return }
        session.inkEdit("Edit Image Note", kind: .note) {
            session.imageNotes[i].caption = trimmed
            session.imageNotes[i].display = display
            session.imageNotes[i].updatedAt = .now
        }
    }

    func deleteImageNote(_ id: UUID) {
        session.inkEdit("Delete Image Note", kind: .delete) { session.imageNotes.removeAll { $0.id == id } }
        expandedNotes.remove(id)
    }

    /// 存图 + 追加一条图片笔记（撤销栈记账、对账落库）。false = 存图失败。
    @discardableResult
    func addImageNote(_ p: ImageAssets.Prepared, page: Int, anchor: CGRect, source: ImageNote.Source) -> Bool {
        guard workspace.storeImage(p) != nil else { return false }
        session.inkEdit("Image Note", kind: .note) {
            session.imageNotes.append(ImageNote(page: page, anchor: anchor, image: p.sha256, source: source))
        }
        return true
    }

    func importImageFiles(_ urls: [URL], page: Int, nx: Double, ny: Double) {
        guard session.documentId != nil else { return }
        showToast(.working, L("Importing image…"))
        DispatchQueue.global(qos: .userInitiated).async {
            let prepared: [(ImageAssets.Prepared, String)] = urls.compactMap { u in
                guard let data = try? Data(contentsOf: u), let p = ImageAssets.prepare(data) else { return nil }
                return (p, u.lastPathComponent)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var ok = 0
                for (i, (p, name)) in prepared.enumerated() {
                    let y = min(1, ny + Double(i) * 0.03)   // 多个文件依次往下错开一点，别叠成一枚图钉
                    if self.addImageNote(p, page: page, anchor: CGRect(x: nx, y: y, width: 0, height: 0),
                                         source: .file(name: name)) { ok += 1 }
                }
                if ok == urls.count {
                    self.showToast(.ok, ok == 1 ? L("Saved as image note") : String(format: L("Saved %d image notes"), ok))
                } else if ok == 0 {
                    self.showToast(.fail, L("That file isn't an image we can read."))
                } else {
                    self.showToast(.fail, String(format: L("Saved %d of %d images."), ok, urls.count))
                }
            }
        }
    }

    func importImagesViaPanel() {
        guard session.documentId != nil else { return }
        let anchor = cursorDoc.flatMap { pageNorm(atDoc: $0) }
        let page = anchor?.page ?? session.currentPageIndex
        let nx = anchor.map { Double($0.nx) } ?? 0.5
        let ny = anchor.map { Double($0.ny) } ?? 0.5
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = L("Choose images to add as notes on this page")
        panel.begin { [weak self] resp in
            guard resp == .OK, !panel.urls.isEmpty else { return }
            self?.importImageFiles(panel.urls, page: page, nx: nx, ny: ny)
        }
    }

    /// ⌘V 且剪贴板不是笔迹：是图片就粘成图片笔记（文件形态优先，原字节能原样存）。
    func pasteImageNote() {
        guard session.openPadID == nil, session.pdf != nil, session.documentId != nil else { return }
        let pb = NSPasteboard.general
        var payload: (data: Data, name: String)?
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let u = urls.first(where: Self.isImageFile), let data = try? Data(contentsOf: u) {
            payload = (data, u.lastPathComponent)
        } else if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            payload = (data, "")
        }
        guard let payload else { return }
        var page = session.currentPageIndex
        var nx = 0.5, ny = 0.5
        if let p = cursorDoc, let n = pageNorm(atDoc: p) { page = n.page; nx = Double(n.nx); ny = Double(n.ny) }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = ImageAssets.prepare(payload.data)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let p else { self.showToast(.fail, L("That file isn't an image we can read.")); return }
                let ok = self.addImageNote(p, page: page, anchor: CGRect(x: nx, y: ny, width: 0, height: 0),
                                           source: .file(name: payload.name))
                self.showToast(ok ? .ok : .fail, ok ? L("Saved as image note") : L("Could not save the image."))
            }
        }
    }

    // MARK: 书签 / 草稿纸 / 链接

    func addBookmarkAtCursor() {
        guard let p = cursorDoc, let n = pageNorm(atDoc: p) else { return }
        clearSelection()
        session.beginBookmark(page: n.page, frac: Double(n.ny))
    }

    func newScratchPadAtCursor() {
        guard let p = cursorDoc, let n = pageNorm(atDoc: p) else { return }
        clearSelection()
        app.addScratchPad(in: session, page: n.page, nx: Double(n.nx), ny: Double(n.ny))
    }

    /// `unireader://` 深链写进剪贴板（复用 MCP 那边的 `MCPFacade.link`）。`page` 是内部下标（0 起）。
    func copyLinkToPasteboard(page: Int? = nil, frac: Double? = nil, note: UUID? = nil) {
        guard let docId = session.documentId else { return }
        let url = MCPFacade.shared.link(workspace, doc: docId, page: page.map(PageNo.external), frac: frac, note: note)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url, forType: .string)
    }

    /// 右键处「复制链接」：落在高亮上就链那条高亮，否则链到该处的页内位置。
    func copyLinkAtCursor() {
        guard let p = cursorDoc else { return }
        if let hit = highlightHit(atDoc: p) {
            copyLinkToPasteboard(note: hit.highlight.id)
        } else if let n = pageNorm(atDoc: p) {
            copyLinkToPasteboard(page: n.page, frac: Double(n.ny))
        }
    }

    /// `unireader://open?note=…` 要求展开某条笔记的气泡。
    func revealNoteBubble(_ id: UUID) {
        expandedNotes.insert(id)
    }
}
