import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 图片笔记（`IMAGE-NOTE-PLAN.md`）在阅读区的全部入口与交互：
///  · **⌥⇧ 拖**（或 snip 工具 + ⇧）框一块 → 按页重渲成 PNG → 存进工作区 → 建一条笔记（`finishSnipAsImageNote`，
///    手势本身在 `ReaderSurface+Snip`，那边只多了一个 ⇧ 的分流）；
///  · **拖图片文件进阅读区** / 右键「导入图片…」/ **⌘V**（剪贴板是图片且不是笔迹）→ 点锚在落点；
///  · 编辑器（说明 + 展开方式）、看大图、图钉拖拽提交、命中测试。
///
/// 新建**不弹编辑器**：存了就是一条（用户要的是「方便」），说明文字点图钉进气泡再补。
/// 🔴 **只画覆盖层 / 只挂 sheet，不碰 `contentBody`**（零闪烁纪律）。
extension ReaderSurface {

    /// 拖放 + 两个 sheet，单独包一层挂在 `body` 最外面（理由见 `ReaderSurface.body` 注释：修饰符链到顶了）。
    func imageRoutes<V: View>(_ base: V) -> some View {
        base
            // 落点在 ScrollView 视口坐标（与各 DragGesture 的 `.local` 同一空间）。
            // 图片自己收；其余（PDF）交给窗口层入库——外层 `ReaderPanes` 那条同类型的拖放
            // 被这条挡在里面，不转交的话拖 PDF 进阅读区就没反应了。
            .dropDestination(for: URL.self) { urls, location in
                let (images, others) = urls.reduce(into: ([URL](), [URL]())) { acc, u in
                    if Self.isImageFile(u) { acc.0.append(u) } else { acc.1.append(u) }
                }
                if !others.isEmpty { onDropFiles(others) }
                guard !images.isEmpty, session.openPadID == nil, session.pdf != nil else { return !others.isEmpty }
                importImageFiles(images, at: location)
                return true
            }
            .sheet(item: $imageEditor) { n in
                ImageNoteEditorSheet(note: n, info: workspace.imageInfo(sha256: n.image),
                                     onSave: { caption, display in
                                         updateImageNote(n, caption: caption, display: display)
                                         imageEditor = nil
                                     },
                                     onDelete: { deleteImageNote(n); imageEditor = nil },
                                     onView: { imageEditor = nil; imageViewer = n },
                                     onCancel: { imageEditor = nil })
            }
            // Inspector 列表里的「编辑 / 查看」（那边不持有这两个 @State）
            .onReceive(NotificationCenter.default.publisher(for: .imageNoteEdit)) { note in
                guard let req = note.object as? ImageNoteRequest, req.sessionID == session.id,
                      let n = session.imageNotes.first(where: { $0.id == req.noteID }) else { return }
                imageEditor = n
            }
            .onReceive(NotificationCenter.default.publisher(for: .imageNoteView)) { note in
                guard let req = note.object as? ImageNoteRequest, req.sessionID == session.id,
                      let n = session.imageNotes.first(where: { $0.id == req.noteID }) else { return }
                imageViewer = n
            }
            .sheet(item: $imageViewer) { n in
                if let info = workspace.imageInfo(sha256: n.image) {
                    ImageViewerSheet(note: n, url: info.url, onClose: { imageViewer = nil })
                } else {
                    // 图不在（镜像没带 / 已清理）：说一句，别弹个空窗
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.exclamationmark").font(.largeTitle)
                        Text(L("Image file is missing (not in this copy, or already cleaned up).")).font(.callout)
                        Button(L("Close")) { imageViewer = nil }.keyboardShortcut(.cancelAction)
                    }
                    .padding(24)
                }
            }
    }

    /// 右键菜单里的那一项（挂在 `readerContextMenu`）。
    @ViewBuilder var imageNoteMenuItems: some View {
        Button(L("Import Image Here…")) { importImagesViaPanel() }
            .disabled(session.documentId == nil)
    }

    // MARK: - 建笔记（三条入口共用的末段）

    /// 把整理好的图存进工作区 + 追加一条笔记（撤销栈记账、`DocTabModel` 对账落库）。
    /// 返回 false = 存图失败（工作区没开 / 写盘失败，`workspace.lastError` 里有话）。
    @discardableResult
    func addImageNote(_ p: ImageAssets.Prepared, page: Int, anchor: CGRect, source: ImageNote.Source) -> Bool {
        guard workspace.storeImage(p) != nil else { return false }
        session.inkEdit("Image Note", kind: .note) {
            session.imageNotes.append(ImageNote(page: page, anchor: anchor, image: p.sha256, source: source))
        }
        return true
    }

    /// ⌥⇧ 框选松手：与 `finishSnip` 同一条渲染路径（按页重渲、渲染队列上做），只是出 PNG 存进工作区。
    /// 锚 = 框在**起始页**上的那一段（跨页时后面几页只进图、不另落锚）。
    func finishSnipAsImageNote(start: CGPoint, end: CGPoint) {
        let r = SnipRect(start: start, end: end)
        guard PageSnip.isMeaningful(r.size) else { return }
        guard let pdf = session.pdf, session.documentId != nil,
              let a = containerPointToPageNorm(start), let b = containerPointToPageNorm(end) else { return }
        let region = PageSnip.region(from: (a.page, Double(a.nx), Double(a.ny)),
                                     to: (b.page, Double(b.nx), Double(b.ny)))
        let slices = PageSnip.slices(region)
        guard let first = slices.first else { return }

        showSnipToast(SnipToast(kind: .working, text: L("Saving image note…")))
        // 🔴 渲染走 `PageRenderEngine` 那条队列：同一份 `PDFDocument` 不能被并发使用（同 finishSnip）。
        // PNG 编码 + hash 也顺手在那边做完，主线程只收一个整理好的包。
        PageRenderEngine.shared.renderOffMain {
            PageSnip.renderImage(pdf: pdf, region: region).flatMap { out in
                ImageAssets.prepare(out.image).map { ($0, out.pageCount) }
            }
        } completion: { result in
            guard let (prepared, pages) = result else {
                showSnipToast(SnipToast(kind: .fail, text: L("Could not capture that area.")))
                return
            }
            let ok = addImageNote(prepared, page: first.page, anchor: first.rect,
                                  source: .pdf(page: first.page, rect: first.rect, pages: pages))
            showSnipToast(ok ? SnipToast(kind: .ok, text: L("Saved as image note"))
                             : SnipToast(kind: .fail, text: L("Could not save the image.")))
        }
    }

    // MARK: - 导入（拖放 / 面板 / 粘贴）

    static func isImageFile(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
        return t.conforms(to: .image)
    }

    /// 拖进来的图片文件：每个文件一条笔记，点锚在落点（多个文件依次往下错开一点，别叠成一枚图钉）。
    func importImageFiles(_ urls: [URL], at location: CGPoint) {
        guard let n = containerPointToPageNorm(location) else { return }
        importImageFiles(urls, page: n.page, nx: Double(n.nx), ny: Double(n.ny))
    }

    func importImageFiles(_ urls: [URL], page: Int, nx: Double, ny: Double) {
        guard session.documentId != nil else { return }
        showSnipToast(SnipToast(kind: .working, text: L("Importing image…")))
        // 读文件 + 解码/转码在后台；存图与建笔记回主线程（`WorkspaceManager` 是 @MainActor）
        DispatchQueue.global(qos: .userInitiated).async {
            let prepared: [(ImageAssets.Prepared, String)] = urls.compactMap { u in
                guard let data = try? Data(contentsOf: u), let p = ImageAssets.prepare(data) else { return nil }
                return (p, u.lastPathComponent)
            }
            DispatchQueue.main.async {
                var ok = 0
                for (i, (p, name)) in prepared.enumerated() {
                    let y = min(1, ny + Double(i) * 0.03)
                    if addImageNote(p, page: page, anchor: CGRect(x: nx, y: y, width: 0, height: 0),
                                    source: .file(name: name)) { ok += 1 }
                }
                if ok == urls.count {
                    showSnipToast(SnipToast(kind: .ok, text: ok == 1 ? L("Saved as image note")
                                                                     : String(format: L("Saved %d image notes"), ok)))
                } else if ok == 0 {
                    showSnipToast(SnipToast(kind: .fail, text: L("That file isn't an image we can read.")))
                } else {
                    showSnipToast(SnipToast(kind: .fail, text: String(format: L("Saved %d of %d images."), ok, urls.count)))
                }
            }
        }
    }

    /// 右键「导入图片…」：`NSOpenPanel` 多选，点锚在右键处（光标位，同「在此添加批注」）。
    func importImagesViaPanel() {
        guard session.documentId != nil else { return }
        let anchor = scratch.cursorP.flatMap { containerPointToPageNorm($0) }
        let page = anchor?.page ?? session.currentPageIndex
        let nx = anchor.map { Double($0.nx) } ?? 0.5
        let ny = anchor.map { Double($0.ny) } ?? 0.5
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = L("Choose images to add as notes on this page")
        panel.begin { resp in
            guard resp == .OK, !panel.urls.isEmpty else { return }
            importImageFiles(panel.urls, page: page, nx: nx, ny: ny)
        }
    }

    /// ⌘V：剪贴板里是图片（且不是笔迹剪贴板——那条先判）→ 粘成图片笔记。
    /// 落点：指针在某页上 → 那一点；否则当前页正中。剪贴板里什么图都没有就静默。
    func pasteImageNote() {
        guard session.openPadID == nil, session.pdf != nil, session.documentId != nil else { return }
        let pb = NSPasteboard.general
        var payload: (data: Data, name: String)?
        // 文件形态（Finder 里 ⌘C 的图片）优先——原字节能原样存；再是位图形态（截图/网页复制，一般是 TIFF/PNG）
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let u = urls.first(where: Self.isImageFile), let data = try? Data(contentsOf: u) {
            payload = (data, u.lastPathComponent)
        } else if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            payload = (data, "")
        }
        guard let payload else { return }
        var page = session.currentPageIndex
        var nx = 0.5, ny = 0.5
        if let p = scratch.cursorP, let n = containerPointToPageNorm(p) {
            page = n.page; nx = Double(n.nx); ny = Double(n.ny)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = ImageAssets.prepare(payload.data)
            DispatchQueue.main.async {
                guard let p else {
                    showSnipToast(SnipToast(kind: .fail, text: L("That file isn't an image we can read.")))
                    return
                }
                let ok = addImageNote(p, page: page, anchor: CGRect(x: nx, y: ny, width: 0, height: 0),
                                      source: .file(name: payload.name))
                showSnipToast(ok ? SnipToast(kind: .ok, text: L("Saved as image note"))
                                 : SnipToast(kind: .fail, text: L("Could not save the image.")))
            }
        }
    }

    // MARK: - 编辑 / 删除 / 挪图钉

    func updateImageNote(_ n: ImageNote, caption: String, display: NoteDisplay) {
        guard let i = session.imageNotes.firstIndex(where: { $0.id == n.id }) else { return }
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.imageNotes[i].caption != trimmed || session.imageNotes[i].display != display else { return }
        session.inkEdit("Edit Image Note", kind: .note) {
            session.imageNotes[i].caption = trimmed
            session.imageNotes[i].display = display
            session.imageNotes[i].updatedAt = .now
        }
    }

    /// 删一条：从内存移除 → 对账删库 + 那张图若没了引用就进待删除（30 天内 ⌘Z 加回来即恢复）。
    func deleteImageNote(_ n: ImageNote) {
        session.inkEdit("Delete Image Note", kind: .delete) {
            session.imageNotes.removeAll { $0.id == n.id }
        }
        expandedNotes.remove(n.id)
    }

    /// 图片笔记图钉的命中测试（与 `PageCellView.imageMarkerPos` 同一份落位数）。
    func imagePinHit(_ P: CGPoint) -> ImageNote? {
        guard let layout else { return nil }
        let g = scratch.geo
        let ds = max(0.0001, dispScale)
        let cx = g.offsetX + P.x, cy = g.offsetY + P.y
        let page = layout.locate(docY: cy / ds).page
        let pageHDisp = layout.heights[page] * ds
        guard pageW > 0, pageHDisp > 0 else { return nil }
        let lx = cx - pageX, ly = cy - layout.offsets[page] * ds
        let size = CGSize(width: pageW, height: pageHDisp)
        for n in session.imageNotes where n.page == page {
            let m = PageCellView.imageMarkerPos(n, size: size)
            if hypot(lx - m.x, ly - m.y) <= 14 { return n }
        }
        return nil
    }

    /// 图钉拖拽提交（`notePinDragGesture` 松手）：页内像素位移 → 归一化平移，锚矩形整体钳在页内。
    func commitImageNoteDrag(_ n: ImageNote, translation t: CGSize) {
        guard let layout, layout.heights.indices.contains(n.page), pageW > 0,
              let i = session.imageNotes.firstIndex(where: { $0.id == n.id }) else { return }
        let pageHDisp = layout.heights[n.page] * max(0.0001, dispScale)
        let dx = Double(t.width / pageW), dy = Double(t.height / pageHDisp)
        guard dx != 0 || dy != 0 else { return }
        var r = n.anchor
        r.origin.x = min(max(r.origin.x + dx, 0), max(0, 1 - r.width))
        r.origin.y = min(max(r.origin.y + dy, 0), max(0, 1 - r.height))
        guard r != n.anchor else { return }
        session.inkEdit("Move", kind: .move) {
            session.imageNotes[i].anchor = r
            session.imageNotes[i].updatedAt = .now
        }
    }
}
