import SwiftUI

/// 画布悬浮「笔架」：收藏笔插槽（可拖拽定位、点开即可实时改颜色/粗细/类型）+ 橡皮/翻页。
/// 取代旧的工具栏笔状态徽章 + 长按呼出面板——笔的一切交互都挪进阅读区本身，调整入口永远在画布现场，
/// 不在操作栏、也不在系统设置页。
///
/// **作用域**：`app.pens`/`padPenIndex`/`padMode` 是设备级全局状态（不挂在某个 `DocSession` 上），
/// 笔架只是个控制面板，跟哪个窗口在跟 pad 通信无关。故每个开着 PDF 的窗口都显示（含非激活窗口）——
/// 位置/收起态走全局 `@AppStorage`，多窗口保持一致。`isActiveWindow` 暂留作将来「仅激活窗口响应」用。
///
/// **位置限制**：整个胶囊（含拖拽手柄）始终完整落在阅读区内容内，上沿不进工具栏玻璃区
/// （`topInset`）——拖拽过程实时夹取，初始/视口变化也校正一次：否则旧存储值可能把胶囊留在
/// 可视区外或贴死边缘，手柄够不到就再也拖不回来。
struct PenRackView: View {
    @EnvironmentObject private var app: AppModel
    let viewportSize: CGSize
    let topInset: CGFloat          // 工具栏（玻璃）高度：笔架上沿不许进入该区域
    let isActiveWindow: Bool

    /// 位置存视口宽高的 0~1 比例（不存绝对像素）——跟这个代码库一贯「阅读区状态用比例不用绝对值」的
    /// 偏好一致，窗口缩放后面板位置仍然合理。默认落在左下角附近。
    /// （key 沿用旧的 penToolbar* 名字，不动，保住用户已存的位置/收起态。）
    @AppStorage("penToolbarFracX") private var fracX: Double = 0.03
    @AppStorage("penToolbarFracY") private var fracY: Double = 0.92
    @AppStorage("penToolbarCollapsed") private var collapsed = false
    @GestureState private var dragOffset: CGSize = .zero
    @State private var editingIndex: Int?
    @State private var eraserEditorOpen = false
    /// 胶囊实测尺寸（夹取范围要用）；首帧未测量时用保守估计，避免闪一下越界位置。
    @State private var barSize: CGSize = CGSize(width: 240, height: 44)

    private let edgeMargin: CGFloat = 6

    var body: some View {
        if viewportSize.width > 0, viewportSize.height > 0 {
            bar
                .onGeometryChange(for: CGSize.self) { $0.size } action: { barSize = $0 }
                .position(clampedCenter(drag: dragOffset))
                .gesture(dragGesture)
                .transaction { $0.animation = nil }
                .onAppear { reclampStored() }
                .onChange(of: viewportSize) { _, _ in reclampStored() }
        }
    }

    /// 展开=完整笔架；收起=靠边小药丸（只留当前笔尖 + 展开箭头）。收起态持久（全局）。
    @ViewBuilder private var bar: some View {
        if collapsed { collapsedPill } else { content }
    }

    // MARK: 位置夹取

    /// 夹取后的胶囊中心：`position` 锚的是视图中心，故按实测半宽半高留边；上边界额外加 `topInset`
    /// （不进工具栏）。视口比胶囊还窄/矮的极端情况退化为固定在上/左合法点（minX/minY）。
    private func clampedCenter(drag: CGSize) -> CGPoint {
        let w = viewportSize.width, h = viewportSize.height
        let halfW = barSize.width / 2, halfH = barSize.height / 2
        let minX = halfW + edgeMargin, maxX = max(minX, w - halfW - edgeMargin)
        let minY = topInset + halfH + edgeMargin, maxY = max(minY, h - halfH - edgeMargin)
        let raw = CGPoint(x: fracX * w + drag.width, y: fracY * h + drag.height)
        return CGPoint(x: min(max(raw.x, minX), maxX),
                       y: min(max(raw.y, minY), maxY))
    }

    /// 初始/视口变化校正：存储位置若已越界（窗口变矮变窄、旧版本无限制留下的值）拉回可见区。
    private func reclampStored() {
        let p = clampedCenter(drag: .zero)
        fracX = Double(p.x / viewportSize.width)
        fracY = Double(p.y / viewportSize.height)
    }

    private var content: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.primary.opacity(0.55))
                .imageScale(.small)
                .accessibilityHidden(true)
            ForEach(app.pens.indices, id: \.self) { i in penSlot(i) }
            addButton
            Divider().frame(height: 20)
            eraserButton
            modeButton(mode: "page", icon: "hand.draw", label: L("Page Turn"))
            localInkButton
            lassoButton
            Divider().frame(height: 20)
            collapseButton
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
        .shadow(radius: 6, y: 2)
    }

    // MARK: 笔插槽

    private func penSlot(_ i: Int) -> some View {
        let pen = app.pens[i]
        let active = app.padMode == "note" && app.padPenIndex == i
        return Button {
            if active { editingIndex = i } else { app.applyPenSelection(index: i) }
        } label: {
            penTip(pen, active: active)
        }
        .buttonStyle(.plain)
        .help(pen.name)
        .contextMenu {
            Button(role: .destructive) { app.removePen(id: pen.id) } label: {
                Label(L("Delete"), systemImage: "trash")
            }
            .disabled(app.pens.count <= 1)
        }
        .popover(isPresented: Binding(get: { editingIndex == i }, set: { if !$0 { editingIndex = nil } }),
                 arrowEdge: .bottom) { penEditor(i) }
    }

    /// 实时调整面板：颜色/粗细/类型任何一项改动都直接写回 `app.pens[i]`，靠数组的 `didSet`
    /// 自动落盘 + 广播给 pad——没有「保存」按钮，这就是「记笔记时随时切换」的核心。
    private func penEditor(_ i: Int) -> some View {
        let type = app.pens.indices.contains(i) ? app.pens[i].type : .ballpoint
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Pen")).font(.headline)
                Spacer()
                ColorPicker("", selection: Binding(
                    get: { app.pens.indices.contains(i) ? app.pens[i].color.swiftUIColor : .black },
                    set: { if app.pens.indices.contains(i) { app.pens[i].color = InkColor(color: $0) } }),
                    supportsOpacity: true)
                    .labelsHidden()
            }
            HStack {
                Text(L("Width"))
                // 粗细收敛到两位小数：裸 Slider 会产出 8.379999… 超长小数，
                // 既落盘又广播到 pad（网页端状态胶囊会直接显示这串数字）。
                Slider(value: Binding(
                    get: { app.pens.indices.contains(i) ? app.pens[i].width : 8 },
                    set: { if app.pens.indices.contains(i) { app.pens[i].width = ($0 * 100).rounded() / 100 } }), in: 2...40)
                Text("\(Int(app.pens.indices.contains(i) ? app.pens[i].width : 8))")
                    .monospacedDigit().frame(width: 24, alignment: .trailing)
            }
            // 笔头类型：四种笔标签（圆珠/钢笔/马克/铅笔）文字铺开会撑爆 260 宽的浮层被两侧截断，
            // 改用「纯图标 segmented + 当前类型名 caption」——一眼可点、不截断，名字仍在下方可读。
            VStack(alignment: .leading, spacing: 6) {
                Picker(L("Pen Type"), selection: Binding(
                    get: { app.pens.indices.contains(i) ? app.pens[i].type : .ballpoint },
                    set: { if app.pens.indices.contains(i) { app.pens[i].type = $0 } })) {
                    ForEach(PenBrushType.allCases, id: \.self) { t in
                        Image(systemName: t.systemImage).help(t.label).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(type.label)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    // MARK: 笔尖展示 / 收起

    /// 笔插槽/收起药丸共用的「笔尖」视觉：白底垫真彩（含半透明墨如荧光笔 a=0.4 也显真色）+ 该笔类型的
    /// 笔尖字形，一眼看出「什么颜色 + 什么笔」——取代原来只有颜色圆点、分不清笔型。
    private func penTip(_ pen: PenPreset, active: Bool) -> some View {
        ZStack {
            Circle().fill(.white)
            Circle().fill(pen.color.swiftUIColor)
            Image(systemName: pen.type.systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(contrastText(pen.color))
        }
        .frame(width: 28, height: 28)
        .overlay(Circle().stroke(active ? Color.accentColor : .white.opacity(0.55),
                                 lineWidth: active ? 2.5 : 1))
    }

    /// 笔尖字形黑/白：白底之上按笔色感知亮度选，保证对比。
    private func contrastText(_ c: InkColor) -> Color {
        let lum = (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) / 255
        return lum > 0.62 ? .black : .white
    }

    private var collapseButton: some View {
        Button { collapsed = true } label: {
            Image(systemName: "chevron.left")
                .imageScale(.medium)
                .foregroundStyle(.primary.opacity(0.7))
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Collapse"))
    }

    /// 收起态：靠边小药丸，只显示当前笔的笔尖 + 展开箭头；整体可拖拽、点一下展开。
    private var collapsedPill: some View {
        let pen = app.pens.indices.contains(app.padPenIndex) ? app.pens[app.padPenIndex] : app.pens.first
        return HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .imageScale(.small).foregroundStyle(.primary.opacity(0.7))
            if let pen { penTip(pen, active: app.padMode == "note") }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
        .shadow(radius: 6, y: 2)
        .contentShape(Capsule())
        .onTapGesture { collapsed = false }
        .help(L("Expand Pen Toolbar"))
    }

    private var addButton: some View {
        Button {
            editingIndex = app.addPen()
        } label: {
            Image(systemName: "plus.circle.fill")
                .imageScale(.large)
                .foregroundStyle(.primary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Add Pen"))
    }

    private func modeButton(mode: String, icon: String, label: String) -> some View {
        let active = app.padMode == mode
        return Button { app.setPadMode(mode) } label: {
            Image(systemName: icon)
                .imageScale(.medium)
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
    }

    /// 本机笔：切换 Mac 鼠标/触控板在阅读区是「文字选择」还是「临时落墨/擦除」（共用笔架当前选中笔
    /// 与橡皮；⇧ 拖动 = 尺子直线）。样式仿 modeButton，只是切换的是 `pointerTool` 而非 pad 模式。
    private var localInkButton: some View {
        let active = app.pointerTool == .ink
        return Button { app.pointerTool = active ? .textSelect : .ink } label: {
            Image(systemName: "cursorarrow.motionlines")
                .imageScale(.medium)
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Local Pen"))
    }

    /// 框选移动：切换 Mac 鼠标/触控板为「框选」模式——拖空白画虚线框选中同页笔迹+文字注解，
    /// 再拖选中高亮框整体平移（仅页内；点空白/Esc 取消选中）。样式仿 localInkButton。
    private var lassoButton: some View {
        let active = app.pointerTool == .lasso
        return Button { app.pointerTool = active ? .textSelect : .lasso } label: {
            Image(systemName: "lasso")
                .imageScale(.medium)
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Lasso Select"))
    }

    /// 橡皮：点一下进擦除模式；**已在擦除模式时再点**弹尺寸 slider（同 penEditor 的实时写回模式——
    /// 改动直接写 `app.eraserRadius`，didSet 自动落盘 + 广播给 pad，没有「保存」按钮）。
    private var eraserButton: some View {
        let active = app.padMode == "erase"
        return Button {
            if active { eraserEditorOpen = true } else { app.setPadMode("erase") }
        } label: {
            Image(systemName: "eraser")
                .imageScale(.medium)
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Eraser"))
        .popover(isPresented: $eraserEditorOpen, arrowEdge: .bottom) { eraserEditor }
    }

    /// 橡皮设置：整笔/局部模式（系统 segmented，与 penEditor 的笔头类型同款）+ 尺寸 slider
    /// （归一化半径 0.005...0.06，读数 = 直径占页宽 %）+ 尺寸圆环开关。全部实时写 app 状态，
    /// didSet 自动落盘 + 广播 eraser 给 pad——没有「保存」按钮。
    private var eraserEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Eraser")).font(.headline)
            Picker(L("Eraser Mode"), selection: Binding(
                get: { app.eraserMode },
                set: { app.eraserMode = $0 })) {
                ForEach(EraserMode.allCases, id: \.self) { m in Text(m.label).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Text(L("Width"))
                Slider(value: Binding(
                    get: { app.eraserRadius },
                    set: { app.eraserRadius = ($0 * 1000).rounded() / 1000 }), in: 0.005...0.06)
                Text("\(Int((app.eraserRadius * 200).rounded()))%")
                    .monospacedDigit().frame(width: 36, alignment: .trailing)
            }
            Toggle(L("Size Ring"), isOn: Binding(
                get: { app.eraserRing },
                set: { app.eraserRing = $0 }))
        }
        .padding(14)
        .frame(width: 260)
    }

    // MARK: 拖拽定位

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($dragOffset) { value, state, _ in state = value.translation }
            .onEnded { value in
                // 落点同样过夹取（与拖拽中的实时显示一致），再折算回 0~1 比例存盘
                let p = clampedCenter(drag: value.translation)
                fracX = Double(p.x / viewportSize.width)
                fracY = Double(p.y / viewportSize.height)
            }
    }
}
