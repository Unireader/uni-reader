import SwiftUI
import AppKit

/// 框选选中集的**剪切 / 复制 / 粘贴 / 删除**，以及阅读区的撤销/重做入口。
///
/// 三件事值得先说清楚：
///  · **粘贴落在哪一页**由「粘贴那一刻指针在哪一页上」决定（`scratch.cursorP`，与右键
///    「在此添加批注」同一个光标源）——这正是「跨页粘贴」：在第 3 页复制、滚到第 40 页粘贴。
///    指针不在页上（键盘 ⌘V、指针在页间空隙）就落到当前页的原位、并错开一点点，免得与源完全重叠。
///  · 粘出来的每一条都是**新 id**（`InkClipboard.read` 负责），否则同篇文档里粘一次就把源覆盖了。
///  · 粘贴后立刻把新条目设成选中集并切到框选工具：接着就能拖着摆位置，不必再框一次。
extension ReaderSurface {

    // MARK: 撤销 / 重做（菜单 ⌘Z / ⇧⌘Z 路由过来；草稿纸开着时归纸自己接管，见 ScratchPadView）

    func performUndo(redo: Bool) {
        clearLassoSelection()       // 选中集指向的 id 可能整批被撤没了，别留个空框在那儿
        app.undoInk(in: session, redo: redo)
    }

    // MARK: 复制 / 剪切 / 删除

    /// 复制选中集到系统剪贴板。返回是否真的复制了东西——⌘C 的路由据此决定要不要退回「复制选中文字」。
    @discardableResult
    func copyLassoSelection() -> Bool {
        guard session.openPadID == nil, let sel = lassoSelection else { return false }
        let strokes = session.strokes.filter { $0.page == sel.page && sel.strokeIDs.contains($0.id) }
        let notes = session.textNotes.filter { $0.page == sel.page && sel.noteIDs.contains($0.id) }
        guard !strokes.isEmpty || !notes.isEmpty else { return false }
        // 带上「页内归一化 + 这一页的纵横比」：粘到草稿纸上时那边按它折成画布点（见 `InkClipboard.scaled`）
        InkClipboard.write(strokes: strokes, notes: notes, space: .page,
                           aspect: pageAspect(page: sel.page))
        return true
    }

    @discardableResult
    func cutLassoSelection() -> Bool {
        guard copyLassoSelection() else { return false }
        deleteLassoSelection()
        return true
    }

    func deleteLassoSelection() {
        guard session.openPadID == nil, let sel = lassoSelection else { return }
        session.inkEdit("Delete", kind: .delete) {
            session.strokes.removeAll { $0.page == sel.page && sel.strokeIDs.contains($0.id) }
            session.textNotes.removeAll { $0.page == sel.page && sel.noteIDs.contains($0.id) }
        }
        clearLassoSelection()
        refreshCanvasMargin()   // 删掉的可能正是撑着页边的那几笔，软边界该收回来
        if session.id == app.padSession?.id { app.broadcastStrokes(); app.broadcastNotes() }
    }

    // MARK: 粘贴

    func pasteInk() {
        // 打点同 `MenuActions.route`：粘不出东西时先看这一行是不是压根没跑到
        // （默认关，`touch ~/Library/Logs/UniReader-pad.log` 开）。
        PadLog.log("粘贴笔迹：剪贴板有料=\(InkClipboard.hasInk()) 纸开着=\(session.openPadID != nil)")
        guard session.openPadID == nil, session.pdf != nil,
              let clip = InkClipboard.read() else { return }

        // 落点：指针在某页上 → 以指针为中心；否则当前页原位错开一点（同页粘贴不完全压住源）。
        var page = session.currentPageIndex
        if let p = scratch.cursorP, let n = containerPointToPageNorm(p, xRange: lassoEditXRange) {
            page = n.page
        }
        // 从草稿纸抄来的是**画布点**：先按目标页的纵横比折成页内归一化，再照常走下面的定位。
        let srcStrokes = clip.space == .canvas
            ? InkClipboard.scaled(clip.strokes, toCanvas: false, aspect: pageAspect(page: page))
            : clip.strokes
        let box = InkEdit.bounds(srcStrokes)
            .union(clip.notes.reduce(CGRect.null) { $0.union($1.anchor) })
        guard !box.isNull else { return }

        var dx = 0.02, dy = 0.02
        if let p = scratch.cursorP, let n = containerPointToPageNorm(p, xRange: lassoEditXRange) {
            dx = Double(n.nx) - Double(box.midX)
            dy = Double(n.ny) - Double(box.midY)
        }
        // 与框选移动同一条纪律：**先夹位移再整体平移** = 刚性，撞上页边只是停住、不会被逐点摁扁。
        let xr = lassoEditXRange
        (dx, dy) = InkEdit.fitTranslation(
            dx: dx, dy: dy, inkBounds: InkEdit.bounds(srcStrokes), xRange: xr,
            noteBounds: clip.notes.reduce(CGRect.null) { $0.union($1.anchor) })

        let fallbackLayer = session.activeLayerID ?? InkLayer.defaultID
        let knownLayers = Set(session.inkLayers.map(\.id))
        let knownTypes = Set(session.noteTypes.map(\.id))
        var strokeIDs = Set<UUID>(), noteIDs = Set<UUID>()
        session.inkEdit("Paste", kind: .paste) {
            for src in srcStrokes {
                var st = InkEdit.translated(src, dx: dx, dy: dy, xRange: xr)
                st.page = page
                // 跨文档粘贴时源图层多半不存在于这一篇：落到当前作画图层，别造出无处可归的孤儿笔迹。
                if !knownLayers.contains(st.layerId) { st.layerId = fallbackLayer }
                session.strokes.append(st)
                strokeIDs.insert(st.id)
            }
            for src in clip.notes {
                var n = InkEdit.translated(src, dx: dx, dy: dy)
                n.page = page
                if let t = n.typeId, !knownTypes.contains(t) { n.typeId = nil }   // 同上：类型属工作区
                n.createdAt = .now
                session.textNotes.append(n)
                noteIDs.insert(n.id)
            }
        }
        guard !strokeIDs.isEmpty || !noteIDs.isEmpty else { return }

        // 粘完即选中：接着拖就能摆位置。工具切到框选，否则选中框画得出来却拖不动（手势按工具门控）。
        app.pointerTool = .lasso
        var sel = LassoSelection(page: page, strokeIDs: strokeIDs, noteIDs: noteIDs,
                                 bounds: box.offsetBy(dx: dx, dy: dy))
        let real = lassoSelectionBounds(sel)
        if !real.isNull { sel.bounds = real }
        lassoSelection = sel
        refreshCanvasMargin()   // 粘到页边更远处：笔画数变了会触发一次，这里再补一次不多花什么
        if session.id == app.padSession?.id { app.broadcastStrokes(); app.broadcastNotes() }
    }

    // MARK: 右键菜单（有选中集时的四项；无选中集时只在框选工具下给「粘贴」）

    @ViewBuilder var inkClipMenuItems: some View {
        if lassoSelection != nil, session.openPadID == nil {
            Button(L("Cut")) { cutLassoSelection() }
            Button(L("Copy")) { copyLassoSelection() }
            Button(L("Paste")) { pasteInk() }.disabled(!InkClipboard.hasInk())
            Button(L("Delete")) { deleteLassoSelection() }
            Divider()
        } else if app.pointerTool == .lasso, session.openPadID == nil, InkClipboard.hasInk() {
            Button(L("Paste")) { pasteInk() }
            Divider()
        }
    }
}
