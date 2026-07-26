import SwiftUI
import PDFKit
import QuartzCore
import AppKit

extension ReaderSurface {
    // MARK: 文字选择（T1：原生页走 PDFKit 选择引擎；OCR 页走行级文本层；双击选词/行；单击取消；⌘C 复制）

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

    /// 归一化点 → 该页 PDF 页空间点（喂 `selection(from:at:to:at:)`）。
    func pageSpacePoint(_ n: (page: Int, nx: CGFloat, ny: CGFloat)) -> CGPoint? {
        guard let pdf = session.pdf, let pdfPage = pdf.page(at: n.page) else { return nil }
        let mb = pdfPage.bounds(for: .mediaBox)
        return PageGeometry.pageSpacePoint(normX: n.nx, normY: n.ny, mediaBox: mb, rotation: pdfPage.rotation)
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

    /// OCR 行级选区：锚点/焦点各命中一「行」（run）。
    /// **同页**走「分组感知」约束（见 `ocrGroupSelection`）——只在锚点所在列/块分组内连选，
    /// 与「可选分组」调试视图完全一致（所见即所选）；**跨页**（罕见）仍走原阅读顺序线性切片。
    func setOCRSelection(anchor a: (page: Int, nx: CGFloat, ny: CGFloat),
                                 focus f: (page: Int, nx: CGFloat, ny: CGFloat)) {
        guard let ai = ocrLineHit(page: a.page, nx: a.nx, ny: a.ny),
              let fi = ocrLineHit(page: f.page, nx: f.nx, ny: f.ny) else { return }
        selection = a.page == f.page
            ? ocrGroupSelection(page: a.page, ai: ai, fi: fi)
            : ocrLinearSelection(a: (a.page, ai), f: (f.page, fi))
    }

    /// 同页 OCR 选区（分组感知，所见即所选）：
    ///  · **纵向带** = 锚点行∪焦点行的竖直范围；
    ///  · 只选**锚点所在分组**（`DocSession.ocrGroups` = `OCRFlow.columnGroups`）内、midY 落在带内的行。
    /// 于是「左列拖右列」「思维导图黄块拖远处蓝节点」都只落在锚点那一列/块——与调试视图同色块严格一致。
    ///  · **单行横拖**（带高 ≤1.8 行高）例外：走阅读顺序线性切片，含右对齐页码等同行元素（分组会把页码单列成组，
    ///    横拖时不该被分组挡掉）。
    /// 正常单列连续文本：整列是一个分组 → 带内所有行全选（与旧行为一致）。
    func ocrGroupSelection(page: Int, ai: Int, fi: Int) -> TextSelection? {
        guard let runs = ocrRuns(page: page), runs.indices.contains(ai), runs.indices.contains(fi) else { return nil }
        let a = runs[ai].rect, f = runs[fi].rect
        let bandMin = min(a.minY, f.minY), bandMax = max(a.maxY, f.maxY)
        if bandMax - bandMin <= 1.8 * max(a.height, f.height) {
            return ocrLinearSelection(a: (page, ai), f: (page, fi))
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
        let text = picked.map { runs[$0].text }.joined(separator: "\n")
        return text.isEmpty ? nil : TextSelection(rects: [page: picked.map { runs[$0].rect }], text: text)
    }

    /// 跨页 OCR 选区：按阅读顺序（页号→行序）线性切片（保留旧逻辑，跨页场景罕见）。
    func ocrLinearSelection(a: (page: Int, idx: Int), f: (page: Int, idx: Int)) -> TextSelection? {
        let aFirst = a.page < f.page || (a.page == f.page && a.idx <= f.idx)
        let (sp, si) = aFirst ? a : f
        let (ep, ei) = aFirst ? f : a
        var rects: [Int: [CGRect]] = [:]
        var parts: [String] = []
        for p in sp...ep {
            guard let runs = ocrRuns(page: p) else { continue }
            let lo = p == sp ? si : 0
            let hi = p == ep ? ei : runs.count - 1
            guard lo <= hi, lo >= 0, hi < runs.count else { continue }
            let slice = Array(runs[lo...hi])
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

    /// 上下文菜单「复制」：与 ⌘C 监视器同直写剪贴板（纯 ScrollView 容器 `.onCopyCommand` 不可靠）。
    func copySelectionToPasteboard() {
        guard let text = selection?.text, !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// 双击：OCR 页选整行、原生页选整词。
    func selectWord(atContainer P: CGPoint) {
        guard let n = containerPointToPageNorm(P) else { return }
        if ocrRuns(page: n.page) != nil {
            setOCRSelection(anchor: n, focus: n)
        } else if let pdf = session.pdf, let page = pdf.page(at: n.page), let pt = pageSpacePoint(n) {
            setSelection(page.selectionForWord(at: pt))
        }
    }

    /// 拖选：起点定锚（一次），移动实时扩选。锚点所在页有 OCR 层 → 走 OCR 行选择；否则 PDFKit 原生选择。
    /// minimumDistance 2 → 纯单击不触发拖选（交给 `.onTapGesture` 取消），2px 内抖动不误选。
    /// `pointerTool == .ink` 时反向门控：拖选让位给本机落墨手势。
    var dragSelectGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { v in
                guard app.pointerTool == .textSelect, scratch.pinch == nil else { return }
                if scratch.selDragAnchor == nil {
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
                guard app.pointerTool == .ink, scratch.pinch == nil else { return }
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
                    // ⇧ 尺子：整笔替换为两点直线（松开 Shift 后继续追加 = 从直线端点接着画）
                    let snapped = InkEdit.rulerSnap(start: SIMD2(start.nx, start.ny),
                                                    current: SIMD2(pt.x, pt.y))
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
