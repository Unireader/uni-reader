import SwiftUI
import PDFKit
import QuartzCore
import AppKit

extension ReaderSurface {
    // MARK: 文字选择（T1：原生页走 PDFKit 选择引擎；OCR 页走行级文本层（行内字符级定位，见 OCRTextSelect）；双击选词/行；单击取消；⌘C 复制）

    /// 容器/视口坐标 P（与 pinch/hover 同 `.local` 空间）→ (页, 页内归一化坐标 0~1 左上原点)。
    /// 越界按页边缘 clamp（拖到页外 = 选到页边）。原生选择再由 `pageSpacePoint` 转 PDF 页空间点，OCR 选择直接用归一化点命中行框。
    /// `xRange` 是 x 的合法区间：默认 `0...1`（页内，文字选择/图钉拖拽等一律走这条），
    /// 落墨/擦除/框选在画板模式下传 `inkXRange` 把它放宽到页边（y 永远还是 0...1——页边只横向延伸）。
    func containerPointToPageNorm(_ P: CGPoint,
                                  xRange: ClosedRange<Double> = 0...1) -> (page: Int, nx: CGFloat, ny: CGFloat)? {
        guard let layout else { return nil }
        let ds = max(0.0001, dispScale)
        // ⚠️ 用 `anchorOffset`（刚提交但尚未汇报的 scrollTo 目标优先）而非 `scratch.geo`：
        // 画板模式下落笔中跳一档边界 = 布局与偏移同帧改，`onScrollGeometryChange` 慢半拍，
        // 这中间读旧 offset 配新 `pageX`，笔尖会整整偏出半个页宽（缩放路径同款坑，见 anchorOffset）。
        let o = anchorOffset
        let cx = o.x + P.x, cy = o.y + P.y                        // 内容坐标
        let page = layout.locate(docY: cy / ds).page
        let pageTopDisp = layout.offsets[page] * ds
        let pageHDisp = layout.heights[page] * ds
        guard pageW > 0, pageHDisp > 0 else { return nil }
        let nx = min(max((cx - pageX) / pageW, CGFloat(xRange.lowerBound)), CGFloat(xRange.upperBound))
        let ny = min(max((cy - pageTopDisp) / pageHDisp, 0), 1)
        return (page, nx, ny)
    }

    /// 该页的显示纵横比（页高 / 页宽）。页内归一化坐标 x/y 尺度不同，凡是要「按看上去的角度/距离」
    /// 算的地方（⇧ 尺子吸附）都得先用它把 y 折算成与 x 同尺度。取不到布局时退回 1（正方形）。
    func pageAspect(page: Int) -> Double {
        guard let layout, layout.heights.indices.contains(page), pageW > 0 else { return 1 }
        return Double(layout.heights[page] * max(0.0001, dispScale) / pageW)
    }

    /// 归一化点 → 该页 PDF 页空间点（喂 `selection(from:at:to:at:)`）。
    func pageSpacePoint(_ n: (page: Int, nx: CGFloat, ny: CGFloat)) -> CGPoint? {
        guard let pdf = session.pdf, let pdfPage = pdf.page(at: n.page) else { return nil }
        let mb = pdfPage.bounds(for: PageBitmap.effectiveBox(pdfPage))
        return PageGeometry.pageSpacePoint(normX: n.nx, normY: n.ny, box: mb, rotation: pdfPage.rotation,
                                           align: session.pageAlign(n.page))
    }

    /// 该页可用的 OCR 行文本层（非空才返回）；有它就覆盖不准的原生文本。
    /// ⚠️ 走 `ocrVisibleRuns`：扫描件的平铺水印块已被 `OCRWatermark` 剔除，
    /// 于是拖选正文不会再带出一串「王道计」之类的水印碎片。下标与 `session.ocrGroups(page:)` 对齐。
    func ocrRuns(page: Int) -> [TextRun]? { session.ocrVisibleRuns(page: page) }

    /// 由 PDFKit 原生选区（可跨页）落成 `selection`：空/无字则清空。可视顺序/跨行跨页/CJK 都交给 PDFKit。
    func setSelection(_ sel: PDFSelection?) {
        guard let pdf = session.pdf, let sel, sel.string?.isEmpty == false else {
            if selection != nil { selection = nil }
            return
        }
        let align = session.scanAlign
        selection = TextSelection(rects: PageGeometry.normalizedLineRects(of: sel, in: pdf, align: { align?.page($0) }),
                                  text: sel.string ?? "")
    }

    /// OCR 选区：锚点/焦点各命中一「行」（run），行内再按 x 定位到字符级（`OCRTextSelect`）。
    /// **同页**走「分组感知」约束（见 `ocrGroupSelection`）——只在锚点所在列/块分组内连选，
    /// 与「可选分组」调试视图完全一致（所见即所选）；**跨页**（罕见）仍走原阅读顺序线性切片。
    func setOCRSelection(anchor a: (page: Int, nx: CGFloat, ny: CGFloat),
                                 focus f: (page: Int, nx: CGFloat, ny: CGFloat)) {
        guard let ai = ocrLineHit(page: a.page, nx: a.nx, ny: a.ny),
              let fi = ocrLineHit(page: f.page, nx: f.nx, ny: f.ny) else { return }
        selection = a.page == f.page
            ? ocrGroupSelection(page: a.page, ai: ai, fi: fi, ax: a.nx, fx: f.nx)
            : ocrLinearSelection(a: (a.page, ai, a.nx), f: (f.page, fi, f.nx))
    }

    /// 同页 OCR 选区（分组感知，所见即所选）：
    ///  · **纵向带** = 锚点行∪焦点行的竖直范围；
    ///  · 只选**锚点所在分组**（`DocSession.ocrGroups` = `OCRFlow.columnGroups`）内、midY 落在带内的行。
    /// 于是「左列拖右列」「思维导图黄块拖远处蓝节点」都只落在锚点那一列/块——与调试视图同色块严格一致。
    ///  · **单行横拖**（带高 ≤1.8 行高）例外：走阅读顺序线性切片，含右对齐页码等同行元素（分组会把页码单列成组，
    ///    横拖时不该被分组挡掉）。
    ///  · **首末行字符级裁剪**：带内首行裁掉端点左侧、末行裁掉端点右侧（`OCRTextSelect` 行内 x → 字符），
    ///    中间行整行——多行拖选同样能「从某行中间选到某行中间」。
    /// 正常单列连续文本：整列是一个分组 → 带内所有行全选（首末行仍按端点 x 裁剪）。
    func ocrGroupSelection(page: Int, ai: Int, fi: Int, ax: CGFloat, fx: CGFloat) -> TextSelection? {
        guard let runs = ocrRuns(page: page), runs.indices.contains(ai), runs.indices.contains(fi) else { return nil }
        let a = runs[ai].rect, f = runs[fi].rect
        let bandMin = min(a.minY, f.minY), bandMax = max(a.maxY, f.maxY)
        if bandMax - bandMin <= 1.8 * max(a.height, f.height) {
            return ocrLinearSelection(a: (page, ai, ax), f: (page, fi, fx))
        }
        let groups = session.ocrGroups(page: page)
        let ga = groups.indices.contains(ai) ? groups[ai] : -1
        var picked: [Int] = []
        for (i, r) in runs.enumerated() {
            guard groups.indices.contains(i), groups[i] == ga else { continue }
            let midY = r.rect.midY
            if midY >= bandMin, midY <= bandMax { picked.append(i) }
        }
        if picked.isEmpty { picked = [ai] }
        picked.sort {
            let r0 = runs[$0].rect, r1 = runs[$1].rect
            return r0.midY != r1.midY ? r0.midY < r1.midY : r0.minX < r1.minX
        }
        // 字符级裁剪：端点在带的哪头就裁哪头（顶行裁端点左侧、底行裁端点右侧）。
        let topIsAnchor = runs[ai].rect.midY <= runs[fi].rect.midY
        let (topIdx, topX) = topIsAnchor ? (ai, ax) : (fi, fx)
        let (botIdx, botX) = topIsAnchor ? (fi, fx) : (ai, ax)
        var items = picked.map { (idx: $0, run: runs[$0]) }
        if let i = items.firstIndex(where: { $0.idx == topIdx }) {
            let off = OCRTextSelect.charOffset(in: items[i].run, atNX: topX)
            if let c = OCRTextSelect.clip(run: items[i].run, from: off, to: items[i].run.text.count) {
                items[i].run = c
            } else { items.remove(at: i) }
        }
        if botIdx != topIdx, let i = items.lastIndex(where: { $0.idx == botIdx }) {
            let off = OCRTextSelect.charOffset(in: items[i].run, atNX: botX)
            if let c = OCRTextSelect.clip(run: items[i].run, from: 0, to: off) {
                items[i].run = c
            } else { items.remove(at: i) }
        }
        let text = items.map { $0.run.text }.joined(separator: "\n")
        return text.isEmpty ? nil : TextSelection(rects: [page: items.map { $0.run.rect }], text: text)
    }

    /// 线性切片选区（单行横拖 / 跨页）：按阅读顺序（页号→行序）切片，
    /// 首行裁掉端点左侧、末行裁掉端点右侧（字符级），中间行整行；同一行 = 两端点间的字符区间。
    func ocrLinearSelection(a: (page: Int, idx: Int, nx: CGFloat), f: (page: Int, idx: Int, nx: CGFloat)) -> TextSelection? {
        // 同页同行：两端点 x 之间的字符区间（拖反了也一样，取 min/max）
        if a.page == f.page, a.idx == f.idx {
            guard let runs = ocrRuns(page: a.page), runs.indices.contains(a.idx) else { return nil }
            let lo = OCRTextSelect.charOffset(in: runs[a.idx], atNX: Double(min(a.nx, f.nx)))
            let hi = OCRTextSelect.charOffset(in: runs[a.idx], atNX: Double(max(a.nx, f.nx)))
            guard let sub = OCRTextSelect.clip(run: runs[a.idx], from: lo, to: hi) else { return nil }
            return TextSelection(rects: [a.page: [sub.rect]], text: sub.text)
        }
        let aFirst = a.page < f.page || (a.page == f.page && a.idx <= f.idx)
        let (sp, si, sx) = aFirst ? a : f
        let (ep, ei, ex) = aFirst ? f : a
        var rects: [Int: [CGRect]] = [:]
        var parts: [String] = []
        for p in sp...ep {
            guard let runs = ocrRuns(page: p) else { continue }
            let lo = p == sp ? si : 0
            let hi = p == ep ? ei : runs.count - 1
            guard lo <= hi, lo >= 0, hi < runs.count else { continue }
            var slice = Array(runs[lo...hi])
            if p == sp {   // 首行：裁掉起点左侧（起点在行尾 → 整行不选）
                let off = OCRTextSelect.charOffset(in: slice[0], atNX: Double(sx))
                if let c = OCRTextSelect.clip(run: slice[0], from: off, to: slice[0].text.count) {
                    slice[0] = c
                } else { slice.removeFirst() }
            }
            if p == ep, !slice.isEmpty {   // 末行：裁掉终点右侧（终点在行首 → 整行不选）
                let li = slice.count - 1
                let off = OCRTextSelect.charOffset(in: slice[li], atNX: Double(ex))
                if let c = OCRTextSelect.clip(run: slice[li], from: 0, to: off) {
                    slice[li] = c
                } else { slice.removeLast() }
            }
            guard !slice.isEmpty else { continue }
            rects[p] = slice.map(\.rect)
            parts.append(slice.map(\.text).joined(separator: "\n"))
        }
        let text = parts.joined(separator: "\n")
        return text.isEmpty ? nil : TextSelection(rects: rects, text: text)
    }

    /// OCR 行命中：先比行(y)、同高度内再比列(x)——落在行框内 dx=0，最近行优先。
    func ocrLineHit(page: Int, nx: CGFloat, ny: CGFloat) -> Int? {
        guard let runs = ocrRuns(page: page) else { return nil }
        var best: Int?
        var bestD = CGFloat.greatestFiniteMagnitude
        for (i, r) in runs.enumerated() {
            let dy = abs((r.y + r.h / 2) - ny)
            let dx = (nx >= r.x && nx <= r.x + r.w) ? 0 : min(abs(nx - r.x), abs(nx - (r.x + r.w)))
            let d = dy * 1000 + dx
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    func clearSelection() { if selection != nil { selection = nil } }

    /// 全选（Edit → Select All / ⌘A）：**当前页**全部文字。有 OCR 文本层选该页全部 OCR 行
    /// （与拖选同规则——OCR 层覆盖不准的原生文本），否则 PDFKit 整页选区（mediaBox 范围）。
    func selectAllText() {
        guard let pdf = session.pdf, pdf.pageCount > 0 else { return }
        let page = min(max(session.currentPageIndex, 0), pdf.pageCount - 1)
        if let runs = ocrRuns(page: page) {
            let text = runs.map(\.text).joined(separator: "\n")
            selection = text.isEmpty ? nil : TextSelection(rects: [page: runs.map(\.rect)], text: text)
        } else if let pdfPage = pdf.page(at: page) {
            setSelection(pdfPage.selection(for: pdfPage.bounds(for: PageBitmap.effectiveBox(pdfPage))))
        }
    }

    // MARK: 文字注解（kind=0）——右键选区添加批注

    @ViewBuilder var readerContextMenu: some View {
        inkClipMenuItems   // 框选选中集的剪切/复制/粘贴/删除（见 `ReaderSurface+InkClip`）
        if selection?.text.isEmpty == false {
            Button(L("Add Note")) { beginAddNote() }          // 注解选中文字（锚到选区）
            // 铺色 / 画线 / 画框各一个子菜单，里面是调色板四色（同一套颜色，只是画法不同）
            ForEach(HighlightStyle.allCases, id: \.self) { style in
                Menu(style.title) {
                    ForEach(Array(Highlight.palette.enumerated()), id: \.offset) { _, item in
                        Button(L(item.name)) { addHighlight(color: item.color, style: style) }
                    }
                }
            }
            Button(L("Copy")) { copySelectionToPasteboard() }
            Button(String(format: L("Ask %@ About This"), aiProviderName)) { askAIAboutSelection() }
                .disabled(session.documentId == nil)
        } else {
            Button(L("Add Note Here")) { beginAddNoteAtCursor() }   // 点注解（锚到右键处页面坐标）
            Button(L("Copy Link")) { copyLinkAtCursor() }
        }
        imageNoteMenuItems   // 导入图片…（点锚在右键处；见 `ReaderSurface+ImageNote`）
        Divider()
        Button(L("Add Bookmark Here")) { addBookmarkAtCursor() }
        Button(L("New Scratchpad Here")) { newScratchPadAtCursor() }
        Divider()
        Button(String(format: L("Discuss This Page with %@"), aiProviderName)) { discussPageWithAI() }
            .disabled(session.documentId == nil)
    }

    /// 当前 AI 平台显示名（菜单文案用）。平台表为空时退回通用「AI」。
    var aiProviderName: String { AIPanelModel.shared.currentProvider?.name ?? L("AI") }

    /// 「用 … 讨论本页」：开 AI 面板 → 新对话 → 把这次对话绑到右键处那一页。
    ///
    /// 此刻**还没有会话 URL**（各家都是发出第一条消息才 `replaceState` 出唯一链接），所以这里只
    /// 落一个 pending 上下文，等面板捕到匹配 `threadPattern` 的 URL 再 commit 落库
    /// （两段式绑定，见 `AIPanelModel.syncFromPage`）。
    func discussPageWithAI() {
        guard let docId = session.documentId else { return }
        let page = scratch.cursorP.flatMap { containerPointToPageNorm($0)?.page } ?? session.currentPageIndex
        clearSelection()
        AIPanelModel.shared.present(window: session.windowID)   // 内置模式展开侧面板，浮窗模式开窗口
        AIPanelModel.shared.beginBind(AIBindContext(sessionID: session.id, documentId: docId,
                                                    docTitle: session.title, page: page))
    }

    /// **划字发送**（用户 2026-09-06）：把选中的原文 + 一行上下文（书名·页码·章节）填进 AI 输入框。
    ///
    /// 与框选截图是同一条投递链路的两半，只是这半边发的是**文字**：页面有文本层（含 OCR 层）时
    /// 直接发字比发图强一个档次——省 token、模型识别率高（`AI-PLAN.md §4` 的「文本优先」）。
    /// 同样**不自动按发送**：填好让用户自己补一句要问什么再发。
    ///
    /// 锚点取选区所在的**最小页**及其行框并集：与「多张图用第一张」同一条规则——
    /// 这条上下文若是本次对话的第一条，它就决定这次绑定钉在哪一页哪一处（`AIThread.addContext`）。
    func askAIAboutSelection() {
        guard let docId = session.documentId, let sel = selection else { return }
        let text = sel.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let page = sel.rects.keys.min() ?? session.currentPageIndex
        let union = (sel.rects[page] ?? []).reduce(CGRect.null) { $0.union($1) }
        let rect = union.isNull ? CGRect.zero : union
        let prompt = aiContextPrefix(page: page) + "\n" + text
        let provider = AIPanelModel.shared.currentProvider?.name ?? L("AI")

        clearSelection()
        AIPanelModel.shared.present(window: session.windowID)   // 内置模式展开侧面板，浮窗模式开窗口
        // **不强制新对话**（同框选发送）：连着划第二段多半是想接着刚才那个对话问。
        AIPanelModel.shared.prepareForSend(
            AIBindContext(sessionID: session.id, documentId: docId, docTitle: session.title,
                          page: page, anchor: rect))
        showSnipToast(SnipToast(kind: .working, text: L("Capturing…")))

        Task { @MainActor in
            let out = await AIPanelModel.shared.attachText(prompt)
            if out.ok {
                AIPanelModel.shared.noteSentContext(
                    AIContext(kind: .quote, page: page, rect: rect == .zero ? nil : rect, text: text))
                showSnipToast(SnipToast(kind: .ok, text: String(format: L("Added to %@"), provider)))
            } else {
                wsLog("[ASK] 划字发送失败 tried=\(out.tried) notReady=\(out.notReady)")
                showSnipToast(SnipToast(
                    kind: .fail,
                    text: out.notReady
                        ? String(format: L("%@ isn't ready yet (still loading, or not signed in)."), provider)
                        : L("Couldn't put it in the chat box.")))
            }
        }
    }

    // MARK: 复制链接（`unireader://` 深链，书签/图钉/高亮/空白处右键共用）

    /// 生成 `unireader://` 深链接并写入剪贴板。复用 MCP 那边现成的 `MCPFacade.link`（`MCP-PLAN.md`
    /// 「文档/批注/位置 DTO 都带现成 link」同一套逻辑，不自己重新拼 URL）。`page` 传内部下标（0 起），
    /// 这里转外部页码；本项目没有公共剪贴板 util，同 `copySelectionToPasteboard` 那套写法就地写。
    func copyLinkToPasteboard(page: Int? = nil, frac: Double? = nil, note: UUID? = nil) {
        guard let docId = session.documentId else { return }
        let url = MCPFacade.shared.link(workspace, doc: docId, page: page.map(PageNo.external), frac: frac, note: note)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url, forType: .string)
    }

    /// 右键处「复制链接」：落点精确在某条高亮上就链到那条高亮（`note:`，跟 MCP 给高亮生成 link 同一套
    /// 参数），否则链到当前页/该处的页内位置——取光标位置的写法同 `addBookmarkAtCursor`。
    func copyLinkAtCursor() {
        guard let p = scratch.cursorP else { return }
        if let hit = highlightHit(p) {
            copyLinkToPasteboard(note: hit.highlight.id)
        } else if let n = containerPointToPageNorm(p) {
            copyLinkToPasteboard(page: n.page, frac: Double(n.ny))
        }
    }

    /// 在右键处加一枚书签：落点取 `.onContinuousHover` 维护的光标位（与「在此添加批注」同源），
    /// 随后弹命名框——名字必填，输完确认才真的落库（`REQUIREMENTS.md §1.9`）。
    func addBookmarkAtCursor() {
        guard let p = scratch.cursorP, let n = containerPointToPageNorm(p) else { return }
        clearSelection()
        session.beginBookmark(page: n.page, frac: Double(n.ny))
    }

    /// 在右键处新建一张草稿纸并立即打开：锚点取 `.onContinuousHover` 维护的光标位
    /// （与「在此添加批注」同源），页面上从此留一枚图钉指着这张纸。
    func newScratchPadAtCursor() {
        guard let p = scratch.cursorP, let n = containerPointToPageNorm(p) else { return }
        clearSelection()
        app.addScratchPad(in: session, page: n.page, nx: Double(n.nx), ny: Double(n.ny))
    }

    /// 高亮当前选区：逐页各落一条高亮（每页自己的行框），跨页选区各页都铺色。无正文、无图钉、无编辑器。
    /// `style` = 铺色 / 画线 / 画框（同一套颜色，只是画法不同）。
    /// 用过的颜色记成下次 `h` / `⇧H` / `⌥H` 快速高亮的颜色（`AppModel.quickHighlightColor`，三种样式共用一份）。
    func addHighlight(color: InkColor, style: HighlightStyle = .fill) {
        guard let sel = selection, !sel.text.isEmpty else { return }
        for (page, rects) in sel.rects where !rects.isEmpty {
            let bbox = rects.reduce(CGRect.null) { $0.union($1) }
            session.highlights.append(Highlight(page: page, anchor: bbox.isNull ? .zero : bbox,
                                                quote: sel.text, rects: rects, color: color, style: style))
        }
        rememberHighlightColor(color)
        clearSelection()
    }

    /// 选中文字后按 `h`（铺色）/ `⇧H`（画线）/ `⌥H`（画框）：用最近一次选过的颜色直接落，不弹菜单
    /// （`installToolKeyMonitor` 分派）。
    func quickHighlight(style: HighlightStyle = .fill) { addHighlight(color: app.quickHighlightColor, style: style) }

    /// 给一条已有高亮换色（气泡里的色点 / Inspector 列表）：就地改色 + bump updatedAt →
    /// `DocTabModel.persistHighlights` 对账识别为「变更」并 upsert。换过的颜色同样记成下次 `h` 的颜色。
    func recolorHighlight(_ h: Highlight, color: InkColor) {
        guard let i = session.highlights.firstIndex(where: { $0.id == h.id }),
              session.highlights[i].color != color else { return }
        session.highlights[i].color = color
        session.highlights[i].updatedAt = .now
        rememberHighlightColor(color)
    }

    /// 给一条已有高亮换画法（气泡里的样式切换 / Inspector 右键）：同 `recolorHighlight` 的落库路径。
    func restyleHighlight(_ h: Highlight, style: HighlightStyle) {
        guard let i = session.highlights.firstIndex(where: { $0.id == h.id }),
              session.highlights[i].style != style else { return }
        session.highlights[i].style = style
        session.highlights[i].updatedAt = .now
    }

    func rememberHighlightColor(_ color: InkColor) {
        if app.quickHighlightColor != color { app.quickHighlightColor = color }
    }

    /// 「高亮补充为文字笔记」（用户 2026-09-16，拍板为**转换**而非并存）：由这条高亮起一份笔记草稿——
    /// 页 / 锚点 / 行框 / 引文 / 颜色 / 画法原样带过去，编辑器里填正文，保存时落成 `TextNote` 并删掉原高亮
    /// （`commitNote` 按 `replacesHighlight` 处理）；取消则什么都不动。
    func beginNoteFromHighlight(_ h: Highlight) {
        activeHighlight = nil
        editorTarget = .new(PendingNote(page: h.page, anchor: h.anchor, rects: h.rects, quote: h.quote,
                                        color: h.color, style: h.style, replacesHighlight: h.id))
    }

    /// 阅读区的**单击**（按下→抬起位移 ≤3pt），抬手即响应、不等系统双击间隔那一拍：
    ///  · **按下那一刻把键盘焦点收回来**（`takeKeyboardFocus`，任何工具、草稿纸开着也一样）；
    ///  · 单击 = **收起文字选择与框选**（点空白取消选择，用户 2026-09-12 要的「点击空白则取消」）；
    ///  · 文字工具下**命中一条文字高亮就把它的操作气泡打开**（删除/换色入口，用户 2026-09-03 要的
    ///    「点高亮要能删」），没命中则收起气泡。
    ///
    /// 挂成 `minimumDistance: 0` 的拖拽手势而不是 `.onTapGesture(count: 1)`：tap 要等系统双击间隔确认
    /// 「不是双击」才回调，气泡/取消于是总慢半秒（2026-09-12 先为气泡改的，取消选择这次跟上）。
    /// 真拖动（拖选/拖图钉/框选）位移大于阈值，不会误判成单击；一次抖动 2~3pt 的「假拖选」留下的
    /// 一两个字的选区也顺手被这里清掉。
    /// **双击的第二下不算单击**（`isMultiClick`）：否则它会把 `.onTapGesture(count: 2)` 刚选好的词
    /// 又清掉——两者谁先回调没有保证，不能赌顺序。
    ///
    /// 高亮命中判定放在容器这一层（而不是给铺色层加 Button）：铺色的 Canvas 一旦吃命中，
    /// 高亮盖住的那块文字就选不了、框选不到了——高亮是**铺在正文上的**，不能挡住正文的交互。
    /// 起点落在点注解图钉上的让位给图钉（同拖选的让位规则），免得点图钉时顺带弹出底下高亮的气泡。
    var readerClickGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { _ in takeKeyboardFocus() }   // 首个回调 = 鼠标按下
            .onEnded { v in
                takeKeyboardFocus()   // 按下那次没跑到（手势被别的抢先）也兜住
                guard scratch.pinch == nil, session.openPadID == nil,
                      abs(v.translation.width) <= 3, abs(v.translation.height) <= 3,
                      !isMultiClick else { return }
                clearSelection()
                clearLassoSelection()
                guard app.pointerTool == .textSelect, draggablePinHit(v.startLocation) == nil,
                      cardHit(v.startLocation) == nil else { return }   // 点卡片不弹底下高亮的气泡
                let mark = highlightHit(v.startLocation).map { HighlightTap(id: $0.highlight.id, rect: $0.rect) }
                if activeHighlight != mark { activeHighlight = mark }
            }
    }

    /// 这次鼠标事件是不是连击的第二下及以后。SwiftUI 手势回调跑在 AppKit 派发那个鼠标事件的同一
    /// 调用栈里，`NSApp.currentEvent` 就是它。`clickCount` 对非鼠标事件会抛异常，先验类型。
    var isMultiClick: Bool {
        guard let e = NSApp.currentEvent,
              [.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(e.type) else { return false }
        return e.clickCount >= 2
    }

    /// 点阅读区 = 把第一响应者交还给窗口本身。
    ///
    /// 阅读区是纯 SwiftUI、没有任何可聚焦的东西，AppKit 不会因为点了它就挪第一响应者——于是
    /// 工具栏搜索框一旦激活就一直攥着键盘（单键工具快捷键全被它吃掉），内置 AI 面板的网页也一样：
    /// `WKWebView` 认领 `copy:`，Edit 菜单先走响应者链（`MenuActions.route`），⌘C 被它接走，
    /// 选中的 PDF 文字永远复制不到（用户 2026-09-12 报的两条）。窗口本身与 `NSHostingView`
    /// 都不认领剪贴板那五个动作（spike 实测），交还给窗口后菜单命令就会落到阅读区。
    /// 只碰事件所在的那扇窗（不是 `keyWindow`——AI 浮窗是子窗口时两者可能不同）；已经是窗口本身就不动。
    func takeKeyboardFocus() {
        guard let w = NSApp.currentEvent?.window ?? NSApp.keyWindow, w.firstResponder !== w else { return }
        w.makeFirstResponder(nil)
    }

    /// 文字高亮命中测试（容器/视口坐标 P，与双击选词同 `.local` 空间）→ 命中的高亮**与被点中的那一行**。
    /// 逐行框判定（不是整块包围盒——跨行选区的包围盒会把行间空白也算进去），
    /// 上下各放宽 2pt 便于点中细行；重叠时取**最后铺的那条**（＝画在最上面的那条）。
    func highlightHit(_ P: CGPoint) -> (highlight: Highlight, rect: CGRect)? {
        guard let n = containerPointToPageNorm(P), let layout,
              layout.heights.indices.contains(n.page), pageW > 0 else { return nil }
        let pageHDisp = layout.heights[n.page] * max(0.0001, dispScale)
        guard pageHDisp > 0 else { return nil }
        let tx = 2 / pageW, ty = 2 / pageHDisp     // 2pt 容差换算成归一化单位（x/y 尺度不同）
        let p = CGPoint(x: n.nx, y: n.ny)
        for h in session.highlights.reversed() where h.page == n.page {
            if let r = h.rects.first(where: { $0.insetBy(dx: -tx, dy: -ty).contains(p) }) {
                return (h, r)
            }
        }
        return nil
    }

    /// 删除一条高亮：从内存移除 → `DocTabModel` 的增量对账把对应 note 行删库
    /// （与 `InspectorView.deleteHighlight` 同一条路径；高亮不进笔迹撤销栈，两处一致）。
    func deleteHighlight(_ h: Highlight) {
        activeHighlight = nil
        session.highlights.removeAll { $0.id == h.id }
    }

    /// 由当前选区起一条批注草稿：锚到选区起始页，取该页逐行框归一化 + 包围盒；原文完整保留（可能跨页）。
    func beginAddNote() {
        guard let sel = selection, !sel.text.isEmpty, let page = sel.rects.keys.min() else { return }
        let rects = sel.rects[page] ?? []
        let bbox = rects.reduce(CGRect.null) { $0.union($1) }
        editorTarget = .new(PendingNote(page: page, anchor: bbox.isNull ? .zero : bbox,
                                        rects: rects, quote: sel.text))
    }

    /// 点注解草稿：不选文字，锚到右键处的页面归一化坐标（零尺寸 anchor、无行框、无引文）。
    /// 位置取 `.onContinuousHover` 维护的光标位（与双击选词同源），换算为 (页, nx, ny)。
    func beginAddNoteAtCursor() {
        guard let p = scratch.cursorP, let n = containerPointToPageNorm(p) else { return }
        let anchor = CGRect(x: n.nx, y: n.ny, width: 0, height: 0)
        editorTarget = .new(PendingNote(page: n.page, anchor: anchor, rects: [], quote: ""))
    }

    /// 编辑器保存分派：新建 → 追加；编辑 → 就地改文本与类型。
    func saveEditor(_ target: NoteEditorTarget, _ out: NoteEditorOutput) {
        switch target {
        case .new(let draft): commitNote(draft: draft, out)
        case .edit(let note): updateNote(note, out)
        }
        editorTarget = nil
    }

    /// 新建批注：落成 `TextNote` 追加到 `session.textNotes`（ContentView 的 onChange 增量落库）。
    /// 点注解（无引文）必须有文字，否则是个空图钉——直接丢弃不落库。选区注解允许空文字（=纯高亮标记）。
    /// 草稿是由高亮转来的（`replacesHighlight`）→ 同一步里把原高亮删掉（高亮不进撤销栈，与删除高亮同口径）。
    func commitNote(draft: PendingNote, _ out: NoteEditorOutput) {
        if draft.quote.isEmpty, out.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clearSelection(); return
        }
        session.inkEdit("Note", kind: .note) {
            session.textNotes.append(TextNote(page: draft.page, anchor: draft.anchor, quote: draft.quote,
                                              text: out.text, rects: draft.rects,
                                              color: out.color, style: out.style, typeId: out.typeId,
                                              display: out.display))
        }
        if let hid = draft.replacesHighlight {
            session.highlights.removeAll { $0.id == hid }
        }
        clearSelection()
    }

    /// 编辑批注：就地改文本 + 类型 + 展开方式 + 铺色/画法 + bump updatedAt → 数组变更触发 onChange，对账识别为“变更”并 upsert。
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

    /// 编辑器「删除」（仅 .edit 入口有按钮）：从内存移除 → ContentView 的 onChange 对账删库
    /// （与 InspectorView.deleteTextNote 同一条路径）。
    func deleteEditorNote(_ target: NoteEditorTarget) {
        guard let note = target.editedNote else { return }
        session.inkEdit("Delete", kind: .delete) { session.textNotes.removeAll { $0.id == note.id } }
        editorTarget = nil
    }

    /// 类型增删改回写（编辑器管理面板 → onChangeTypes）：更新内存 + 整体落库（meta JSON）；
    /// 被删类型的引用笔记回落通用（typeId=nil，走 textNotes 对账落库，无需逐条手动 upsert）。
    func saveNoteTypes(_ types: [NoteType]) {
        let removed = Set(session.noteTypes.map(\.id)).subtracting(types.map(\.id))
        session.noteTypes = types
        workspace.saveNoteTypes(types)
        guard !removed.isEmpty else { return }
        if case .only(let id?) = session.noteTypeFilter, removed.contains(id) {
            session.noteTypeFilter = .all
        }
        for i in session.textNotes.indices where session.textNotes[i].typeId.map({ removed.contains($0) }) ?? false {
            session.textNotes[i].typeId = nil
            session.textNotes[i].updatedAt = .now
        }
    }

    /// 上下文菜单/Edit 菜单「复制」：直写剪贴板（纯 ScrollView 容器 `.onCopyCommand` 不可靠）。
    func copySelectionToPasteboard() {
        guard let text = selection?.text, !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// 双击：OCR 页选整行、原生页选整词。
    /// OCR 分支不走 `setOCRSelection`（同点锚定在字符级逻辑下是空选区），直接选命中行整行。
    func selectWord(atContainer P: CGPoint) {
        guard let n = containerPointToPageNorm(P) else { return }
        if let runs = ocrRuns(page: n.page), let i = ocrLineHit(page: n.page, nx: n.nx, ny: n.ny) {
            let r = runs[i]
            selection = r.text.isEmpty ? nil : TextSelection(rects: [n.page: [r.rect]], text: r.text)
        } else if let pdf = session.pdf, let page = pdf.page(at: n.page), let pt = pageSpacePoint(n) {
            setSelection(page.selectionForWord(at: pt))
        }
    }

    /// 拖选：起点定锚（一次），移动实时扩选。锚点所在页有 OCR 层 → 走 OCR 行选择；否则 PDFKit 原生选择。
    /// minimumDistance 2 → 纯单击不触发拖选（交给 `readerClickGesture` 取消），2px 内抖动不误选。
    /// `pointerTool == .ink` 时反向门控：拖选让位给本机落墨手势。
    /// 起点命中点注解图钉时让位图钉拖拽（容器手势是 simultaneous，不让位会边拖图钉边扩选）。
    var dragSelectGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { v in
                guard app.pointerTool == .textSelect, scratch.pinch == nil,
                      session.openPadID == nil else { return }   // 草稿纸盖着时阅读区一概不响应
                // ⌥ 按下 = 用户要框选截图 → **尚未起手**的才让位（已经在拖选的不打断）
                guard !(snipModifierDown && scratch.selDragAnchor == nil) else { return }
                if scratch.selDragAnchor == nil {
                    // 起点在图钉 / 笔记卡片上：让位，selDragAnchor 保持 nil → 整段拖选不启动
                    if draggablePinHit(v.startLocation) != nil || cardHit(v.startLocation) != nil { return }
                    scratch.selDragAnchor = containerPointToPageNorm(v.startLocation)
                }
                guard let a = scratch.selDragAnchor, let f = containerPointToPageNorm(v.location) else { return }
                if ocrRuns(page: a.page) != nil {
                    setOCRSelection(anchor: a, focus: f)
                } else if let pdf = session.pdf, let pa = pdf.page(at: a.page), let pf = pdf.page(at: f.page),
                          let ptA = pageSpacePoint(a), let ptF = pageSpacePoint(f) {
                    setSelection(pdf.selection(from: pa, at: ptA, to: pf, at: ptF))
                }
            }
            .onEnded { _ in scratch.selDragAnchor = nil }
    }

    /// 点注解图钉命中测试（容器/视口坐标 P，与 dragSelect 同 `.local` 空间）→ 命中的 note。
    /// 与 `PageCellView.markerPos` 同规则（点注解落锚点、页内 12/10 边距钳制），热区半径 14pt。
    func pointNotePinHit(_ P: CGPoint) -> TextNote? {
        guard let layout else { return nil }
        let g = scratch.geo
        let ds = max(0.0001, dispScale)
        let cx = g.offsetX + P.x, cy = g.offsetY + P.y
        let page = layout.locate(docY: cy / ds).page
        let pageHDisp = layout.heights[page] * ds
        guard pageW > 0, pageHDisp > 0 else { return nil }
        let lx = cx - pageX, ly = cy - layout.offsets[page] * ds   // 页内显示坐标
        for n in session.textNotes where n.page == page && n.rects.isEmpty {
            let px = min(max(n.anchor.minX * pageW, 12), pageW - 12)
            let py = min(max(n.anchor.minY * pageHDisp, 10), pageHDisp - 10)
            if hypot(lx - px, ly - py) <= 14 { return n }
        }
        return nil
    }

    /// 可拖的图钉命中（点注解 **或** 图片笔记）：返回 id。三处共用——单击手势让位、拖选让位、图钉拖拽定锚。
    func draggablePinHit(_ P: CGPoint) -> UUID? {
        pointNotePinHit(P)?.id ?? imagePinHit(P)?.id
    }

    /// 展开着的笔记卡片命中（容器/视口坐标 P）→ 卡片所属笔记 id。卡片位置由卡片视图自己报（`Scratch.cardFrames`），
    /// 画在哪就算在哪，不在这边重算一遍排版。
    ///
    /// 容器上的手势全是 simultaneous：按在卡片上，卡片自己的拖动手势和这边的拖选 / 单击 / 双击选词 / 落墨 / 框选 /
    /// 图钉拖拽**同时**收到，所以这几处起手时都先问它，命中就让位（卡片在最上面，按在它上面就是冲它去的）。
    func cardHit(_ P: CGPoint) -> UUID? {
        guard !scratch.cardFrames.isEmpty, let layout else { return nil }
        let g = scratch.geo
        let ds = max(0.0001, dispScale)
        let cx = g.offsetX + P.x, cy = g.offsetY + P.y
        let page = layout.locate(docY: cy / ds).page
        guard layout.offsets.indices.contains(page) else { return nil }
        let p = CGPoint(x: cx - pageX, y: cy - layout.offsets[page] * ds)   // 页内显示坐标
        return scratch.cardFrames.first { $0.value.page == page && $0.value.rect.contains(p) }?.key
    }

    /// 卡片松手提交（拖动 / 改大小）或右键「恢复自动」（`card == nil`）：就地改那条笔记（文字 / 图片按 id 找），
    /// bump `updatedAt` → 增量对账落库。进撤销栈（与拖图钉一样是一步「移动」，改大小记成「调整大小」）。
    /// 不广播平板：线上 `notes` 不带卡片（网页 / 安卓暂按自动规则画）。
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

    /// 某枚可拖图钉此刻的锚点（页 + 归一化锚矩形），两种笔记都认。
    func pinAnchor(id: UUID) -> (page: Int, anchor: CGRect)? {
        if let n = session.textNotes.first(where: { $0.id == id }) { return (n.page, n.anchor) }
        if let n = session.imageNotes.first(where: { $0.id == id }) { return (n.page, n.anchor) }
        return nil
    }

    /// 点注解图钉拖拽手势（同挂 ScrollView 容器，与 lasso 同款模式）：起点命中图钉才激活
    /// （`pointNotePinHit` 定锚一次存 `scratch.noteDragID`），拖动只动 ghost（`notePinDrag` 瞬态，
    /// 位移 clamp 到锚点不出本页），松手 `commitNoteDrag` 一次性提交。仅 textSelect 模式；
    /// 拖选手势靠同一起点命中测试反向让位。
    var notePinDragGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { v in
                guard app.pointerTool == .textSelect, scratch.pinch == nil,
                      session.openPadID == nil else { return }
                if scratch.noteDragID == nil {
                    guard cardHit(v.startLocation) == nil,   // 卡片盖住的图钉：卡片在上面，按下是冲卡片去的
                          let hit = draggablePinHit(v.startLocation) else { return }
                    scratch.noteDragID = hit
                }
                guard let id = scratch.noteDragID,
                      let n = pinAnchor(id: id),
                      let layout, layout.heights.indices.contains(n.page), pageW > 0 else { return }
                // 容器像素位移 == 页内像素位移（delta 与平移无关）；clamp 到锚点不出本页
                let pageHDisp = layout.heights[n.page] * max(0.0001, dispScale)
                let ax = n.anchor.minX * pageW, ay = n.anchor.minY * pageHDisp
                notePinDrag = (id, CGSize(width: min(max(v.translation.width, -ax), pageW - ax),
                                          height: min(max(v.translation.height, -ay), pageHDisp - ay)))
            }
            .onEnded { _ in
                guard let id = scratch.noteDragID else { return }
                scratch.noteDragID = nil
                let off = notePinDrag?.off ?? .zero
                notePinDrag = nil
                if let n = session.textNotes.first(where: { $0.id == id }) { commitNoteDrag(n, translation: off) }
                else if let n = session.imageNotes.first(where: { $0.id == id }) { commitImageNoteDrag(n, translation: off) }
            }
    }

    /// 点注解图钉拖拽提交（`notePinDragGesture` 松手）：页内像素位移 → 归一化平移，
    /// 页内 clamp 由 `InkEdit.translated` 保证（图钉拖不出本页）。数组变更触发 onChange 增量落库。
    func commitNoteDrag(_ note: TextNote, translation t: CGSize) {
        guard let layout, layout.heights.indices.contains(note.page), pageW > 0 else { return }
        let pageHDisp = layout.heights[note.page] * max(0.0001, dispScale)
        let dx = Double(t.width / pageW), dy = Double(t.height / pageHDisp)
        guard dx != 0 || dy != 0,
              let i = session.textNotes.firstIndex(where: { $0.id == note.id }) else { return }
        session.inkEdit("Move", kind: .move) {
            session.textNotes[i] = InkEdit.translated(session.textNotes[i], dx: dx, dy: dy)
        }
        // 镜像平板：仅当本窗口恰是 padSession（同 commitLassoMove 语义；否则 broadcast 的是 padSession 的旧数据）
        if session.id == app.padSession?.id { app.broadcastNotes() }
    }

    // MARK: 本机落墨（pointerTool == .ink：Mac 鼠标/触控板直接画）

    /// 本机落墨/擦除拖拽：仅 `pointerTool == .ink` 生效（与 dragSelectGesture 互斥门控）。
    /// 容器 .local 坐标 → `containerPointToPageNorm` 得页内归一化点，压感恒 0.5（对齐 PROTOCOL.md erase 缺省惯例）。
    /// 当前笔 = 笔架选中笔（`app.pens[app.padPenIndex]`，用户已定共用）；`app.padMode == "erase"` 走局部擦除
    /// （`eraserRadius`），否则落墨。⇧ 尺子：拖动中按住 Shift → 整笔替换为「起点 → 45° 吸附终点」两点直线
    /// （`InkEdit.rulerSnap`；修饰键读 `NSEvent.modifierFlags`，纯事件读取不引 AppKit 视图）。
    /// 全部写进**本窗口自己的 session**：ContentView 对账自动落库；恰是 padSession 时广播自动镜像到平板。
    var localInkDragGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { v in
                guard app.pointerTool == .ink, scratch.pinch == nil,
                      session.openPadID == nil else { return }   // 笔迹只落草稿纸（覆盖层自己收）
                guard !(snipModifierDown && scratch.localInkStart == nil) else { return }   // ⌥ 让位截图
                let isErase = app.padMode == "erase"
                // 起笔（本手势首个回调）：定锚 + inkBegin / 首点擦除
                if scratch.localInkStart == nil {
                    guard cardHit(v.startLocation) == nil,   // 按在笔记卡片上不落笔（画在卡片底下也看不见）
                          let n0 = containerPointToPageNorm(v.startLocation, xRange: inkXRange) else { return }
                    growCanvasMargin(towardX: Double(n0.nx))   // 起笔就在页边深处（滚过去写）也要先长够
                    let p0 = InkPoint(Double(n0.nx), Double(n0.ny), 0.5)
                    if isErase {
                        app.inkErase([p0], page: n0.page, in: session)
                    } else {
                        guard let pen = app.pens.indices.contains(app.padPenIndex)
                                ? app.pens[app.padPenIndex] : app.pens.first else { return }
                        app.inkBegin(in: session, page: n0.page, color: pen.color,
                                     width: pen.width, type: pen.type, points: [p0])
                    }
                    scratch.localInkStart = (n0.page, Double(n0.nx), Double(n0.ny))
                    return
                }
                guard let start = scratch.localInkStart,
                      let n = containerPointToPageNorm(v.location, xRange: inkXRange) else { return }
                // 写到离页边不足 slack 就把边界往外跳一档（同 runloop 补偿横向偏移，页面在笔下不动）
                if !isErase { growCanvasMargin(towardX: Double(n.nx)) }
                let pt = InkPoint(Double(n.nx), Double(n.ny), 0.5)
                if isErase {
                    app.inkErase([pt], page: n.page, in: session)   // 擦除可跨页（按点所在页逐批）
                    return
                }
                guard n.page == start.page else { return }   // 落墨不跨页：拖出页边即停笔
                if NSEvent.modifierFlags.contains(.shift) {
                    // ⇧ 尺子：整笔替换为两点直线（松开 Shift 后继续追加 = 从直线端点接着画）。
                    // aspect 传本页显示纵横比，吸附的才是**看上去**的 0/45/90°（见 InkEdit.rulerSnap）。
                    let snapped = InkEdit.rulerSnap(start: SIMD2(start.nx, start.ny),
                                                    current: SIMD2(pt.dx, pt.dy),
                                                    aspect: pageAspect(page: start.page))
                    if var st = session.liveStroke {
                        st.points = [InkPoint(start.nx, start.ny, 0.5), InkPoint(snapped.x, snapped.y, 0.5)]
                        session.liveStroke = st
                    }
                } else {
                    app.inkAppend([pt], in: session)
                }
            }
            .onEnded { _ in
                guard scratch.localInkStart != nil else { return }
                if app.padMode != "erase" { app.inkEnd(in: session) }   // 擦除每批已即时生效，无需收尾
                session.inkUndo.seal()   // 抬笔 = 这一组擦除封口（一次拖动 = 一步撤销）
                scratch.localInkStart = nil
            }
    }

}
