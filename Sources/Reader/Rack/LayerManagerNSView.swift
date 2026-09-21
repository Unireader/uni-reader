import AppKit
import Combine

extension InkLayer {
    /// 图层色板 key → 颜色（复用 `NoteType.palette`；模型层只存 key，界面换算集中于此）。
    var nsColor: NSColor {
        let rgb = NoteType.paletteRGB(colorKey)
        return NSColor(srgbRed: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255, alpha: 1)
    }
}

/// 图层管理面板（笔架「图层」按钮弹出的 popover 内容，AppKit 版，替代 SwiftUI `LayerManagerView`）：
/// 图层各自显示 / 隐藏、点行设为当前作画图层、拖动排序、右键改名 / 改色 / 删除、新建不设上限。
@MainActor
final class LayerManagerNSView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let session: DocSession
    /// 列表行数变了，弹窗要跟着改高度。
    var onSizeChange: (NSSize) -> Void = { _ in }

    private let title = NSTextField(labelWithString: L("Layers"))
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let addButton = NSButton()
    private var layers: [InkLayer] = []
    private var activeID: UUID?
    private var bag = Set<AnyCancellable>()
    private static let dragType = NSPasteboard.PasteboardType("tech.xvanturing.unireader.layer-row")
    private static let rowH: CGFloat = 32

    init(session: DocSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 120))
        title.font = .preferredFont(forTextStyle: .headline)
        let col = NSTableColumn(identifier: .init("layer"))
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = Self.rowH
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.registerForDraggedTypes([Self.dragType])
        table.draggingDestinationFeedbackStyle = .gap
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        addButton.title = L("New Layer")
        addButton.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.isBordered = false
        addButton.contentTintColor = .labelColor
        addButton.target = self
        addButton.action = #selector(addLayer)
        for v in [title, scroll, addButton] as [NSView] { addSubview(v) }
        session.$inkLayers.combineLatest(session.$activeLayerID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &bag)
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }

    var preferredSize: NSSize {
        let listH = min(CGFloat(max(layers.count, 1)) * Self.rowH + 6, 220)
        return NSSize(width: 260, height: 14 + 20 + 10 + listH + 10 + 22 + 14)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let listH = min(CGFloat(max(layers.count, 1)) * Self.rowH + 6, 220)
        title.frame = NSRect(x: 14, y: 14, width: w - 28, height: 20)
        scroll.frame = NSRect(x: 6, y: 44, width: w - 12, height: listH)
        addButton.sizeToFit()
        addButton.frame.origin = NSPoint(x: 14, y: 44 + listH + 10)
    }

    private func reload() {
        let newLayers = session.inkLayers
        let newActive = session.activeLayerID
        let countChanged = newLayers.count != layers.count
        guard newLayers != layers || newActive != activeID else { return }
        layers = newLayers
        activeID = newActive
        table.reloadData()
        if countChanged {
            needsLayout = true
            onSizeChange(preferredSize)
        }
    }

    // MARK: 动作

    @objc private func rowClicked() {
        let r = table.clickedRow
        guard layers.indices.contains(r) else { return }
        session.activeLayerID = layers[r].id
    }

    fileprivate func toggleVisible(_ id: UUID) {
        guard let i = session.inkLayers.firstIndex(where: { $0.id == id }) else { return }
        session.inkLayers[i].visible.toggle()
    }

    /// 新建图层：追加后立即设为当前作画图层（命名 / 配色规则与平板 `layerAdd` 共用 `InkLayer.next(after:)`）。
    @objc private func addLayer() {
        let layer = InkLayer.next(after: session.inkLayers)
        session.inkLayers.append(layer)
        session.activeLayerID = layer.id
    }

    /// 改名 / 改色：系统提示框 + 输入框 + 色板一排。
    private func edit(_ layer: InkLayer) {
        var draft = layer
        let a = NSAlert()
        a.messageText = L("Rename Layer")
        a.addButton(withTitle: L("Save"))
        a.addButton(withTitle: L("Cancel"))
        let field = NSTextField(string: layer.name)
        field.placeholderString = L("Layer Name")
        field.frame = NSRect(x: 0, y: 30, width: 260, height: 24)
        let swatchRow = NSStackView()
        swatchRow.spacing = 8
        var swatches: [SwatchButton] = []
        let actions = ButtonActions()
        for sw in NoteType.palette {
            let b = SwatchButton(color: NSColor(srgbRed: sw.r / 255, green: sw.g / 255, blue: sw.b / 255, alpha: 1))
            b.selectedRing = sw.key == draft.colorKey
            let key = sw.key
            actions.bind(b) { [weak b] in
                draft.colorKey = key
                for s in swatches { s.selectedRing = false }
                b?.selectedRing = true
            }
            swatches.append(b)
            swatchRow.addArrangedSubview(b)
        }
        objc_setAssociatedObject(a, &ButtonActions.key, actions, .OBJC_ASSOCIATION_RETAIN)
        swatchRow.frame = NSRect(x: 0, y: 0, width: 260, height: 20)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        box.addSubview(field)
        box.addSubview(swatchRow)
        a.accessoryView = box
        a.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let i = self.session.inkLayers.firstIndex(where: { $0.id == layer.id }) else { return }
            draft.name = name
            self.session.inkLayers[i] = draft
        }
        if let win = window { a.beginSheetModal(for: win, completionHandler: finish) } else { finish(a.runModal()) }
    }

    /// 删除图层：连同其笔迹一起清除，并保证至少留一层可画。全篇笔数问库（内存里只有窗口内那几页）。
    private func confirmDelete(_ layer: InkLayer) {
        let n = session.inkStrokeCount(layerId: layer.id)
        let a = NSAlert()
        a.messageText = String(format: L("Delete layer “%@”?"), layer.name)
        var info: [String] = []
        if n > 0 { info.append(String(format: L("%d stroke(s) on this layer will be deleted too."), n)) }
        info.append(L("They go to Recently Deleted and can be put back from File ▸ Recently Deleted."))
        a.informativeText = info.joined(separator: "\n")
        let del = a.addButton(withTitle: L("Delete"))
        del.hasDestructiveAction = true
        a.addButton(withTitle: L("Cancel"))
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            // 🔴 **先归档、再删**（`BACKUP-PLAN.md §2.4`）。归档失败就整个放弃——
            // 反过来做，中间任何一步出错都等于这一层的笔迹已经没了。
            if n > 0, let store = self.session.store, let docId = self.session.documentId,
               Trash.archiveInkLayer(store: store, documentId: docId, documentTitle: self.session.title,
                                     layerId: layer.id, layerName: layer.name,
                                     isDefaultLayer: layer.id == InkLayer.defaultID) == nil {
                NSAlert(error: NSError(domain: "UniReader", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: L("Could not archive this layer, so nothing was deleted.")
                ])).runModal()
                return
            }
            self.session.deleteInkStrokes(layerId: layer.id)
            self.session.inkLayers.removeAll { $0.id == layer.id }
            if self.session.activeLayerID == layer.id { self.session.activeLayerID = self.session.inkLayers.first?.id }
        }
        if let win = window { a.beginSheetModal(for: win, completionHandler: finish) } else { finish(a.runModal()) }
    }

    // MARK: 右键菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let r = table.clickedRow
        guard layers.indices.contains(r) else { return }
        let layer = layers[r]
        let rename = ClosureMenuItem(L("Rename"), action: { [weak self] in self?.edit(layer) })
        rename.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        menu.addItem(rename)
        let del = ClosureMenuItem(L("Delete"), action: { [weak self] in self?.confirmDelete(layer) })
        del.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        if layers.count <= 1 { del.action = nil }
        menu.addItem(del)
    }

    // MARK: 表格 + 拖动排序

    func numberOfRows(in tableView: NSTableView) -> Int { layers.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("layerRow")
        let v = (tableView.makeView(withIdentifier: id, owner: nil) as? LayerRowView) ?? {
            let r = LayerRowView()
            r.identifier = id
            return r
        }()
        let l = layers[row]
        v.set(l, active: l.id == activeID)
        v.onToggle = { [weak self] in self?.toggleVisible(l.id) }
        return v
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        if op == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    /// 整体重排 `sortOrder`（等于新位置下标），落库对账走既有值快照对账。
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let s = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.dragType),
              let from = Int(s), layers.indices.contains(from) else { return false }
        var list = session.inkLayers
        list.move(fromOffsets: IndexSet(integer: from), toOffset: row)
        for i in list.indices { list[i].sortOrder = i }
        session.inkLayers = list
        return true
    }
}

/// 图层一行：眼睛（显示 / 隐藏）+ 色点 + 名字；当前作画图层用强调色浅底。
private final class LayerRowView: NSTableCellView {
    var onToggle: () -> Void = {}
    private let eye = NSButton()
    private let dot = NSView()
    private let name = NSTextField(labelWithString: "")
    private let bg = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        eye.isBordered = false
        eye.imagePosition = .imageOnly
        eye.target = self
        eye.action = #selector(toggle)
        name.lineBreakMode = .byTruncatingTail
        name.textColor = .labelColor
        for v in [bg, eye, dot, name] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bg.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            eye.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 8),
            eye.centerYAnchor.constraint(equalTo: centerYAnchor),
            eye.widthAnchor.constraint(equalToConstant: 20),
            dot.leadingAnchor.constraint(equalTo: eye.trailingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            name.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            name.trailingAnchor.constraint(lessThanOrEqualTo: bg.trailingAnchor, constant: -8),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    func set(_ l: InkLayer, active: Bool) {
        eye.image = NSImage(systemSymbolName: l.visible ? "eye" : "eye.slash", accessibilityDescription: nil)
        eye.contentTintColor = l.visible ? .labelColor : .secondaryLabelColor
        eye.toolTip = l.visible ? L("Hide Layer") : L("Show Layer")
        dot.layer?.backgroundColor = l.nsColor.cgColor
        name.stringValue = l.name
        bg.layer?.backgroundColor = active ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : nil
    }

    @objc private func toggle() { onToggle() }
}
