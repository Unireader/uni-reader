import SwiftUI
import PDFKit
import QuartzCore
import AppKit

extension ReaderSurface {
    // MARK: 文字选择（T1：原生页走 PDFKit 选择引擎；OCR 页走行级文本层（行内字符级定位，见 OCRTextSelect）；双击选词/行；单击取消；⌘C 复制）

    /// 容器/视口坐标 P（与 pinch/hover 同 `.local` 空间）→ (页, 页内归一化坐标 0~1 左上原点)。
    /// 越界按页边缘 clamp（拖到页外 = 选到页边）。原生选择再由 `pageSpacePoint` 转 PDF 页空间点，OCR 选择直接用归一化点命中行框。
    func containerPointToPageNorm(_ P: CGPoint) -> (page: Int, nx: CGFloat, ny: CGFloat)? {
        guard let layout else { return nil }
        let g = scratch.geo
        let ds = max(0.0001, dispScale)
        let cx = g.offsetX + P.x, cy = g.offsetY + P.y            // 内容坐标
        let page = layout.locate(docY: cy / ds).page
        let pageTopDisp = layout.offsets[page] * ds
        let pageHDisp = layout.heights[page] * ds
        guard pageW > 0, pageHDisp > 0 else { return nil }
        let nx = min(max((cx - pageX) / pageW, 0), 1)
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
        return PageGeometry.pageSpacePoint(normX: n.nx, normY: n.ny, box: mb, rotation: pdfPage.rotation)
    }

    /// 该页可用的 OCR 行文本层（非空才返回）；有它就覆盖不准的原生文本。
    func ocrRuns(page: Int) -> [TextRun]? {
        let r = session.ocrRuns[page]
        return (r?.isEmpty == false) ? r : nil
    }

    /// 由 PDFKit 原生选区（可跨页）落成 `selection`：空/无字则清空。可视顺序/跨行跨页/CJK 都交给 PDFKit。
    func setSelection(_ sel: PDFSelection?) {
        guard let pdf = session.pdf, let sel, sel.string?.isEmpty == false else {
            if selection != nil { selection = nil }
            return
        }
        selection = TextSelection(rects: PageGeometry.normalizedLineRects(of: sel, in: pdf),
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
        if selection?.text.isEmpty == false {
            Button(L("Add Note")) { beginAddNote() }          // 注解选中文字（锚到选区）
            Menu(L("Highlight")) {                             // 一键高亮（选调色板颜色）
                ForEach(Array(Highlight.palette.enumerated()), id: \.offset) { _, item in
                    Button(L(item.name)) { addHighlight(color: item.color) }
                }
            }
            Button(L("Copy")) { copySelectionToPasteboard() }
        } else {
            Button(L("Add Note Here")) { beginAddNoteAtCursor() }   // 点注解（锚到右键处页面坐标）
        }
        Divider()
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
        AIPanelModel.shared.present(session: session.id) { openWindow(id: $0) }   // 内置模式展开侧面板，浮窗模式开窗口
        AIPanelModel.shared.beginBind(AIBindContext(sessionID: session.id, documentId: docId,
                                                    docTitle: session.title, page: page))
    }

    /// 在右键处新建一张草稿纸并立即打开：锚点取 `.onContinuousHover` 维护的光标位
    /// （与「在此添加批注」同源），页面上从此留一枚图钉指着这张纸。
    func newScratchPadAtCursor() {
        guard let p = scratch.cursorP, let n = containerPointToPageNorm(p) else { return }
        clearSelection()
        app.addScratchPad(in: session, page: n.page, nx: Double(n.nx), ny: Double(n.ny))
    }

    /// 高亮当前选区：逐页各落一条高亮（每页自己的行框），跨页选区各页都铺色。无正文、无图钉、无编辑器。
    func addHighlight(color: InkColor) {
        guard let sel = selection, !sel.text.isEmpty else { return }
        for (page, rects) in sel.rects where !rects.isEmpty {
            let bbox = rects.reduce(CGRect.null) { $0.union($1) }
            session.highlights.append(Highlight(page: page, anchor: bbox.isNull ? .zero : bbox,
                                                quote: sel.text, rects: rects, color: color))
        }
        clearSelection()
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
    func saveEditor(_ target: NoteEditorTarget, text: String, typeId: UUID?) {
        switch target {
        case .new(let draft): commitNote(draft: draft, text: text, typeId: typeId)
        case .edit(let note): updateNote(note, text: text, typeId: typeId)
        }
        editorTarget = nil
    }

    /// 新建批注：落成 `TextNote` 追加到 `session.textNotes`（ContentView 的 onChange 增量落库）。
    /// 点注解（无引文）必须有文字，否则是个空图钉——直接丢弃不落库。选区注解允许空文字（=纯高亮标记）。
    func commitNote(draft: PendingNote, text: String, typeId: UUID?) {
        if draft.quote.isEmpty, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clearSelection(); return
        }
        session.textNotes.append(TextNote(page: draft.page, anchor: draft.anchor, quote: draft.quote,
                                          text: text, rects: draft.rects, typeId: typeId))
        clearSelection()
    }

    /// 编辑批注：就地改文本 + 类型 + bump updatedAt → 数组变更触发 onChange，对账识别为“变更”并 upsert。
    func updateNote(_ note: TextNote, text: String, typeId: UUID?) {
        guard let idx = session.textNotes.firstIndex(where: { $0.id == note.id }) else { return }
        var n = session.textNotes[idx]
        n.text = text
        n.typeId = typeId
        n.updatedAt = .now
        session.textNotes[idx] = n
    }

    /// 编辑器「删除」（仅 .edit 入口有按钮）：从内存移除 → ContentView 的 onChange 对账删库
    /// （与 InspectorView.deleteTextNote 同一条路径）。
    func deleteEditorNote(_ target: NoteEditorTarget) {
        guard let note = target.editedNote else { return }
        session.textNotes.removeAll { $0.id == note.id }
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
    /// minimumDistance 2 → 纯单击不触发拖选（交给 `.onTapGesture` 取消），2px 内抖动不误选。
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
                    if pointNotePinHit(v.startLocation) != nil { return }   // selDragAnchor 保持 nil → 整段拖选不启动
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
                    guard let hit = pointNotePinHit(v.startLocation) else { return }
                    scratch.noteDragID = hit.id
                }
                guard let id = scratch.noteDragID,
                      let n = session.textNotes.first(where: { $0.id == id }),
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
                guard let n = session.textNotes.first(where: { $0.id == id }) else { return }
                commitNoteDrag(n, translation: off)
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
        session.textNotes[i] = InkEdit.translated(session.textNotes[i], dx: dx, dy: dy)
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
                    guard let n0 = containerPointToPageNorm(v.startLocation) else { return }
                    let p0 = SIMD3(Double(n0.nx), Double(n0.ny), 0.5)
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
                      let n = containerPointToPageNorm(v.location) else { return }
                let pt = SIMD3(Double(n.nx), Double(n.ny), 0.5)
                if isErase {
                    app.inkErase([pt], page: n.page, in: session)   // 擦除可跨页（按点所在页逐批）
                    return
                }
                guard n.page == start.page else { return }   // 落墨不跨页：拖出页边即停笔
                if NSEvent.modifierFlags.contains(.shift) {
                    // ⇧ 尺子：整笔替换为两点直线（松开 Shift 后继续追加 = 从直线端点接着画）。
                    // aspect 传本页显示纵横比，吸附的才是**看上去**的 0/45/90°（见 InkEdit.rulerSnap）。
                    let snapped = InkEdit.rulerSnap(start: SIMD2(start.nx, start.ny),
                                                    current: SIMD2(pt.x, pt.y),
                                                    aspect: pageAspect(page: start.page))
                    if var st = session.liveStroke {
                        st.points = [SIMD3(start.nx, start.ny, 0.5), SIMD3(snapped.x, snapped.y, 0.5)]
                        session.liveStroke = st
                    }
                } else {
                    app.inkAppend([pt], in: session)
                }
            }
            .onEnded { _ in
                guard scratch.localInkStart != nil else { return }
                if app.padMode != "erase" { app.inkEnd(in: session) }   // 擦除每批已即时生效，无需收尾
                scratch.localInkStart = nil
            }
    }

}
