import AppKit

/// 问 AI 与框选截图（逻辑同 SwiftUI 版 `ReaderSurface+Snip` 与划字发送，逐条移植）：
///  · ⌥ 拖（或常驻截图工具）框一块 → 松手在指针处弹一个菜单：问 Agent / 问网页 AI / 复制图片 / 存为图片笔记
///    （2026-09-24 用户要求三件事并到一个菜单里，不用再记修饰键）→ 按页重渲成图；
///  · ⌥⇧ 拖（或拖到一半按上 ⇧）→ 直接存为图片笔记，不问（老快捷方式，留着）；
///  · 划字「问 AI」、右键「和 AI 讨论本页」。
extension ReaderView {

    var aiProviderName: String { AIPanelModel.shared.currentProvider?.name ?? L("AI") }

    // MARK: 截图框（覆盖层）

    /// 框选中的视觉：区域外压暗 + 1px 强调色边 + 页码角标（⇧ 时缀上「· 图片笔记」）。
    func updateSnipOverlay(toNote: Bool? = nil) {
        guard let s = snipRect else {
            for l in [overlay.snipDim, overlay.snipBorder] { ReaderOverlayView.set(l, nil) }
            overlay.snipBadge.isHidden = true
            return
        }
        let a = displayPoint(ofDoc: s.start), b = displayPoint(ofDoc: s.end)
        let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        let dim = CGMutablePath()
        dim.addRect(overlay.bounds)
        dim.addRect(box)
        ReaderOverlayView.set(overlay.snipDim, dim)
        ReaderOverlayView.set(overlay.snipBorder, CGPath(rect: box.insetBy(dx: 0.5, dy: 0.5), transform: nil))
        let note = toNote ?? mouseTrack?.snipToNote ?? false
        if let label = snipPageLabel(s.start, s.end, toNote: note) {
            let badge = overlay.snipBadge
            badge.string = " \(label) "
            let w = (label as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]).width + 16
            let y = box.minY > 26 ? box.minY - 21 : box.minY + 3
            badge.frame = CGRect(x: box.minX, y: y, width: w, height: 17)
            badge.isHidden = false
        } else {
            overlay.snipBadge.isHidden = true
        }
    }

    private func snipPageLabel(_ p0: CGPoint, _ p1: CGPoint, toNote: Bool) -> String? {
        guard let a = pageNorm(atDoc: CGPoint(x: (p0.x + p1.x) / 2, y: min(p0.y, p1.y))),
              let b = pageNorm(atDoc: CGPoint(x: (p0.x + p1.x) / 2, y: max(p0.y, p1.y))) else { return nil }
        let lo = min(a.page, b.page) + 1, hi = max(a.page, b.page) + 1
        let pages = lo == hi ? String(format: L("p.%d"), lo) : "\(String(format: L("p.%d"), lo))–\(hi)"
        return toNote ? "\(pages) · \(L("Image Note"))" : pages
    }

    // MARK: 松手

    func finishSnipDrag(toNote: Bool) {
        guard let s = snipRect else { return }
        // 框太小多半是误拖：静默丢弃（阈值按屏幕点）
        let a = displayPoint(ofDoc: s.start), b = displayPoint(ofDoc: s.end)
        guard PageSnip.isMeaningful(CGSize(width: b.x - a.x, height: b.y - a.y)) else {
            snipRect = nil; updateSnipOverlay(); return
        }
        if toNote {
            snipRect = nil
            updateSnipOverlay()
            finishSnipAsImageNote(start: s.start, end: s.end)
            return
        }
        // 松手先问做什么（用户 2026-09-19 起问发给谁，2026-09-24 把复制 / 图片笔记也并进来）。
        // 问的时候框留着；菜单放到下一拍弹（它会占着主线程直到选完）
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let target = self.chooseSnipTarget()
            self.snipRect = nil
            self.updateSnipOverlay()
            switch target {
            case .agent: self.finishSnipToAgent(start: s.start, end: s.end)
            case .consult: self.finishSnipToConsult(start: s.start, end: s.end)
            case .copy: self.finishSnipCopy(start: s.start, end: s.end)
            case .imageNote: self.finishSnipAsImageNote(start: s.start, end: s.end)
            case nil: break
            }
        }
    }

    /// 在指针处弹系统菜单：上一组是问 AI（Agent / 网页 AI，哪个可用列哪个），下一组是复制图片、存为图片笔记。
    /// 「复制图片」永远在，所以菜单永远弹（不再有「只有一个选项就不问」）。
    func chooseSnipTarget() -> SnipTarget? {
        let web = AIPanelModel.shared.currentProvider
        var ask: [(SnipTarget, String, String?, String)] = []
        if AgentPanelModel.shared.canAttach(from: session.windowID) {
            ask.append((.agent, String(format: L("Ask %@"), AgentConfig.displayName), L("Agent"), "sparkles"))
        }
        if AIPanelModel.shared.enabled {
            ask.append((.consult, String(format: L("Ask %@"), web?.name ?? L("AI")), L("Web AI"),
                        web?.icon ?? "bubble.left.and.text.bubble.right"))
        }
        var keep: [(SnipTarget, String, String?, String)] = [(.copy, L("Copy Image"), nil, "doc.on.doc")]
        if session.documentId != nil {
            keep.append((.imageNote, L("Save as Image Note"), nil, "photo.badge.plus"))
        }
        let picker = SnipTargetPicker()
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (n, group) in [ask, keep].enumerated() where !group.isEmpty {
            if n > 0, menu.numberOfItems > 0 { menu.addItem(.separator()) }
            for (target, title, subtitle, icon) in group {
                let item = NSMenuItem(title: title, action: #selector(SnipTargetPicker.pick(_:)), keyEquivalent: "")
                item.target = picker
                item.representedObject = target.rawValue
                item.subtitle = subtitle
                item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return picker.picked
    }

    /// 复制图片：与图片笔记同一条渲染路径（原清晰度），PNG + TIFF 两种都放上剪贴板，粘到哪儿都认。
    func finishSnipCopy(start: CGPoint, end: CGPoint) {
        guard let pdf = session.pdf, let (region, _) = snipRegion(start: start, end: end) else { return }
        showToast(.working, L("Capturing…"))
        let align = session.scanAlign
        PageRenderEngine.shared.renderOffMain {
            PageSnip.renderImage(pdf: pdf, region: region, align: align).flatMap { out -> (Data, Data?)? in
                let rep = NSBitmapImageRep(cgImage: out.image)
                guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
                return (png, rep.tiffRepresentation)
            }
        } completion: { [weak self] result in
            guard let self else { return }
            guard let (png, tiff) = result else { self.showToast(.fail, L("Could not capture that area.")); return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(png, forType: .png)
            if let tiff { pb.setData(tiff, forType: .tiff) }
            self.showToast(.ok, L("Image copied"))
        }
    }

    private func snipRegion(start: CGPoint, end: CGPoint) -> (PageSnip.Region, PageSnip.Slice)? {
        guard let a = pageNorm(atDoc: start), let b = pageNorm(atDoc: end) else { return nil }
        let region = PageSnip.region(from: (a.page, Double(a.nx), Double(a.ny)), to: (b.page, Double(b.nx), Double(b.ny)))
        guard let first = PageSnip.slices(region).first else { return nil }
        return (region, first)
    }

    /// 发给 Agent：渲图后挂到这扇窗对应的 Agent 对话的输入框上，面板亮出来。
    func finishSnipToAgent(start: CGPoint, end: CGPoint) {
        guard let pdf = session.pdf, let (region, first) = snipRegion(start: start, end: end) else { return }
        showToast(.working, L("Capturing…"))
        let caption = aiContextPrefix(page: first.page)
        let note = snipAgentNote(region)
        let windowID = session.windowID
        let align = session.scanAlign
        PageRenderEngine.shared.renderOffMain {
            PageSnip.render(pdf: pdf, region: region, align: align)
        } completion: { [weak self] shot in
            guard let self else { return }
            guard let shot else { self.showToast(.fail, L("Could not capture that area.")); return }
            let img = AgentImage(data: shot.data, mimeType: "image/jpeg", caption: caption, note: note)
            if AgentPanelModel.shared.attach(img, from: windowID) {
                self.showToast(.ok, String(format: L("Added to %@"), AgentConfig.displayName))
            } else {
                self.showToast(.fail, String(format: L("%@ does not accept images."), AgentConfig.displayName))
            }
        }
    }

    /// 给 Agent 看的截图来源（英文，放进隐藏的上下文块）。
    private func snipAgentNote(_ r: PageSnip.Region) -> String {
        let pages = r.startPage == r.endPage ? "page \(r.startPage + 1)" : "pages \(r.startPage + 1)–\(r.endPage + 1)"
        var s = "a region the user cropped from \(pages)"
        if !session.title.isEmpty { s += " of \"\(session.title)\"" }
        if let id = session.documentId { s += " (document_id \(id))" }
        s += String(format: ", x %.2f–%.2f, from y %.2f on the first page to y %.2f on the last (0–1, top-left origin).",
                    r.x0, r.x1, r.y0, r.y1)
        return s
    }

    /// 发给网页 AI：面板开起来、绑定对齐到这一页，图塞进当前对话的输入框。
    func finishSnipToConsult(start: CGPoint, end: CGPoint) {
        guard let pdf = session.pdf, let docId = session.documentId,
              let (region, first) = snipRegion(start: start, end: end) else { return }
        AIPanelModel.shared.present(window: session.windowID)
        AIPanelModel.shared.prepareForSend(AIBindContext(sessionID: session.id, documentId: docId, docTitle: session.title,
                                                         page: first.page, anchor: first.rect))
        showToast(.working, L("Capturing…"))
        let prompt = aiContextPrefix(page: first.page)
        let name = "unireader-p\(first.page + 1)-\(UUID().uuidString.prefix(6)).jpg"
        let provider = aiProviderName
        let align = session.scanAlign
        PageRenderEngine.shared.renderOffMain {
            PageSnip.render(pdf: pdf, region: region, align: align)
        } completion: { [weak self] shot in
            guard let self else { return }
            guard let shot else { self.showToast(.fail, L("Could not capture that area.")); return }
            Task { @MainActor in
                let out = await AIPanelModel.shared.attach(imageJPEG: shot.data, fileName: name, prompt: prompt)
                if out.ok {
                    AIPanelModel.shared.noteSentContext(AIContext(kind: .region, page: first.page, rect: first.rect))
                    self.showToast(.ok, String(format: L("Added to %@"), provider))
                } else {
                    wsLog("[SNIP] 投递失败 tried=\(out.tried) text=\(out.textOK) notReady=\(out.notReady)")
                    self.showToast(.fail, out.notReady
                        ? String(format: L("%@ isn't ready yet (still loading, or not signed in)."), provider)
                        : L("Couldn't put it in the chat box."))
                }
            }
        }
    }

    /// ⌥⇧ 框选：同一条渲染路径出 PNG 存进工作区，锚 = 框在起始页上的那一段。
    func finishSnipAsImageNote(start: CGPoint, end: CGPoint) {
        guard let pdf = session.pdf, session.documentId != nil,
              let (region, first) = snipRegion(start: start, end: end) else { return }
        showToast(.working, L("Saving image note…"))
        let align = session.scanAlign
        PageRenderEngine.shared.renderOffMain {
            PageSnip.renderImage(pdf: pdf, region: region, align: align).flatMap { out in
                ImageAssets.prepare(out.image).map { ($0, out.pageCount) }
            }
        } completion: { [weak self] result in
            guard let self else { return }
            guard let (prepared, pages) = result else { self.showToast(.fail, L("Could not capture that area.")); return }
            let ok = self.addImageNote(prepared, page: first.page, anchor: first.rect,
                                       source: .pdf(page: first.page, rect: first.rect, pages: pages))
            self.showToast(ok ? .ok : .fail, ok ? L("Saved as image note") : L("Could not save the image."))
        }
    }

    // MARK: 划字发送 / 讨论本页

    /// 上下文前缀：书名 + 页码 + 章节（没有书名页码的裸截图，模型答得明显差）。
    func aiContextPrefix(page: Int) -> String {
        var parts: [String] = []
        if !session.title.isEmpty { parts.append("《\(session.title)》") }
        parts.append(String(format: L("p.%d"), page + 1))
        if let ch = chapterTitle(page: page) { parts.append(ch) }
        return parts.joined(separator: " · ")
    }

    /// 该页所属章节：目录先序拍平后取最后一个「页码 ≤ 本页」的条目。
    private func chapterTitle(page: Int) -> String? {
        var best: (page: Int, label: String)?
        func walk(_ es: [TOCEntry]) {
            for e in es {
                if let p = e.pageIndex, p <= page, (best.map { p >= $0.page } ?? true) { best = (p, e.label) }
                walk(e.children)
            }
        }
        walk(session.toc)
        let label = best?.label.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? nil : label
    }

    /// 划字「问 AI」：选中原文 + 一行上下文填进网页 AI 的输入框（不自动发送）。
    func askAIAboutSelection() {
        guard let docId = session.documentId, let sel = selection else { return }
        let text = sel.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let page = sel.rects.keys.min() ?? session.currentPageIndex
        let union = (sel.rects[page] ?? []).reduce(CGRect.null) { $0.union($1) }
        let rect = union.isNull ? CGRect.zero : union
        let prompt = aiContextPrefix(page: page) + "\n" + text
        let provider = aiProviderName
        clearSelection()
        AIPanelModel.shared.present(window: session.windowID)
        AIPanelModel.shared.prepareForSend(AIBindContext(sessionID: session.id, documentId: docId, docTitle: session.title,
                                                         page: page, anchor: rect))
        showToast(.working, L("Capturing…"))
        Task { @MainActor in
            let out = await AIPanelModel.shared.attachText(prompt)
            if out.ok {
                AIPanelModel.shared.noteSentContext(AIContext(kind: .quote, page: page, rect: rect == .zero ? nil : rect, text: text))
                self.showToast(.ok, String(format: L("Added to %@"), provider))
            } else {
                wsLog("[ASK] 划字发送失败 tried=\(out.tried) notReady=\(out.notReady)")
                self.showToast(.fail, out.notReady
                    ? String(format: L("%@ isn't ready yet (still loading, or not signed in)."), provider)
                    : L("Couldn't put it in the chat box."))
            }
        }
    }

    /// 「和 AI 讨论本页」：开面板 → 新对话 → 绑到右键处那一页（等捕到会话 URL 再落库）。
    func discussPageWithAI() {
        guard let docId = session.documentId else { return }
        let page = cursorDoc.flatMap { pageNorm(atDoc: $0)?.page } ?? session.currentPageIndex
        clearSelection()
        AIPanelModel.shared.present(window: session.windowID)
        AIPanelModel.shared.beginBind(AIBindContext(sessionID: session.id, documentId: docId,
                                                    docTitle: session.title, page: page))
    }
}
