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
    /// **锚的是胶囊左上缘（不是中心）**：收起/展开时左缘固定、右侧收进/放出，即「靠左对齐」。
    /// （key 沿用旧的 penToolbar* 名字，不动；旧值按中心锚解释，一次性右移半个胶囊宽，
    /// 越界会被夹取拉回，用户拖一下即可。）
    @AppStorage("penToolbarFracX") private var fracX: Double = 0.03
    @AppStorage("penToolbarFracY") private var fracY: Double = 0.92
    @AppStorage("penToolbarCollapsed") private var collapsed = false
    /// 布局实际读的收起态：`@AppStorage` 写入经 UserDefaults 通知异步回投，`withAnimation`
    /// 包不住它触发的更新（实测就是没动画），故动画由这个本地 @State 驱动，上面的存储值
    /// 只做持久化 + 多窗口同步（onChange 镜像回来）。
    @State private var collapsedUI = false
    @GestureState private var dragOffset: CGSize = .zero
    @State private var editingIndex: Int?
    @State private var eraserEditorOpen = false
    /// 胶囊实测尺寸（夹取范围要用）；首帧未测量时用保守估计，避免闪一下越界位置。
    @State private var barSize: CGSize = CGSize(width: 240, height: 44)
    /// 首次实测落位前不做尺寸动画——否则启动时胶囊会从估计值滑向实测值。
    @State private var barMeasured = false

    private let edgeMargin: CGFloat = 6

    var body: some View {
        if viewportSize.width > 0, viewportSize.height > 0 {
            bar
                .onGeometryChange(for: CGSize.self) { $0.size } action: { new in
                    // 收起/展开时尺寸变化也要走动画：夹取范围依赖 barSize，无动画会在结尾跳一下位置
                    // （贴边默认位必然触发）。首次实测例外，避免启动时从估计值滑向真实值。
                    if barMeasured {
                        withAnimation(Self.collapseAnim) { barSize = new }
                    } else {
                        barSize = new
                        barMeasured = true
                    }
                }
                .position(clampedCenter(drag: dragOffset))
                // 高优先级：起点落在笔插槽等 Button 上时，普通 .gesture 会被 Button 吃掉按下事件
                // （全程不跟手、松手瞬移）；minimumDistance=6 保证单击按钮不受影响。
                .highPriorityGesture(dragGesture)
                .onAppear { collapsedUI = collapsed; reclampStored() }
                .onChange(of: collapsed) { _, v in
                    // 另一窗口改的收起态：镜像进本地驱动值（同走弹簧动画）
                    if v != collapsedUI { withAnimation(Self.collapseAnim) { collapsedUI = v } }
                }
                .onChange(of: viewportSize) { _, _ in reclampStored() }
        }
    }

    /// 收起/展开共用的弹性曲线：胶囊缩放 + 贴边位置跟随同一条，保证同步。
    private static let collapseAnim: Animation = .spring(duration: 0.32, bounce: 0.15)

    private func setCollapsed(_ value: Bool) {
        withAnimation(Self.collapseAnim) { collapsedUI = value }
        collapsed = value   // 持久化（onChange 里 v == collapsedUI，不会二次触发动画）
    }

    /// 展开=完整笔架；收起=靠边小药丸（只留当前笔尖 + 展开箭头）。收起态持久（全局）。
    /// 两态共用一个外壳（padding/背景/描边/阴影挂在这里），切换时胶囊整体弹性缩放，
    /// 而不是两个自带背景的视图生硬互换。
    @ViewBuilder private var bar: some View {
        HStack(spacing: 10) {
            if collapsedUI { collapsedContent } else { expandedContent }
        }
        .padding(.horizontal, collapsedUI ? 10 : 12)
        .padding(.vertical, collapsedUI ? 6 : 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
        .shadow(radius: 6, y: 2)
    }

    // MARK: 位置夹取

    /// 夹取后的胶囊左上缘：存储锚的就是左上缘，按实测宽高留边；上边界额外加 `topInset`
    /// （不进工具栏）。视口比胶囊还窄/矮的极端情况退化为固定在上/左合法点。
    private func clampedOrigin(drag: CGSize) -> CGPoint {
        let w = viewportSize.width, h = viewportSize.height
        let maxX = max(edgeMargin, w - barSize.width - edgeMargin)
        let minY = topInset + edgeMargin, maxY = max(minY, h - barSize.height - edgeMargin)
        let raw = CGPoint(x: fracX * w + drag.width, y: fracY * h + drag.height)
        return CGPoint(x: min(max(raw.x, edgeMargin), maxX),
                       y: min(max(raw.y, minY), maxY))
    }

    /// `position` 锚的是视图中心：由左上缘换算。动画期间 barSize 也在动，左缘不动、
    /// 中心随宽度收缩左移——视觉上就是胶囊靠左收拢/展开。
    private func clampedCenter(drag: CGSize) -> CGPoint {
        let o = clampedOrigin(drag: drag)
        return CGPoint(x: o.x + barSize.width / 2, y: o.y + barSize.height / 2)
    }

    /// 初始/视口变化校正：存储位置若已越界（窗口变矮变窄、旧版本无限制留下的值）拉回可见区。
    private func reclampStored() {
        let p = clampedOrigin(drag: .zero)
        fracX = Double(p.x / viewportSize.width)
        fracY = Double(p.y / viewportSize.height)
    }

    /// 展开态内容：背景/描边/阴影在外层 `bar` 上，这里只摆按钮。
    private var expandedContent: some View {
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
        .transition(.opacity)
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
        Button { setCollapsed(true) } label: {
            Image(systemName: "chevron.left")
                .imageScale(.medium)
                .foregroundStyle(.primary.opacity(0.7))
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Collapse"))
    }

    /// 收起态内容：只显示当前笔的笔尖 + 展开箭头；整体可拖拽、点一下展开。
    /// 背景/描边/阴影在外层 `bar` 上。
    private var collapsedContent: some View {
        let pen = app.pens.indices.contains(app.padPenIndex) ? app.pens[app.padPenIndex] : app.pens.first
        return HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .imageScale(.small).foregroundStyle(.primary.opacity(0.7))
            if let pen { penTip(pen, active: app.padMode == "note") }
        }
        .contentShape(Rectangle())
        .onTapGesture { setCollapsed(false) }
        .help(L("Expand Pen Toolbar"))
        .transition(.opacity)
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
            // 拖拽位移禁动画走 updating 的 transaction（精准到本手势），不要在视图上挂
            // `.animation(nil, value:)`——它会误伤收起/展开的弹簧动画。
            .updating($dragOffset) { value, state, transaction in
                transaction.animation = nil
                state = value.translation
            }
            .onEnded { value in
                // 落点同样过夹取（与拖拽中的实时显示一致），再折算回 0~1 比例存盘
                let p = clampedOrigin(drag: value.translation)
                fracX = Double(p.x / viewportSize.width)
                fracY = Double(p.y / viewportSize.height)
            }
    }
}
