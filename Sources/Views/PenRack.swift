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
    @AppStorage(PenRackView.collapsedKey) private var collapsed = false
    static let collapsedKey = "penToolbarCollapsed"
    /// 布局实际读的收起态：`@AppStorage` 写入经 UserDefaults 通知异步回投，`withAnimation`
    /// 包不住它触发的更新（实测就是没动画），故动画由这个本地 @State 驱动，上面的存储值
    /// 只做持久化 + 多窗口同步（onChange 镜像回来）。
    @State private var collapsedUI: Bool
    @GestureState private var dragOffset: CGSize = .zero
    @State private var editingIndex: Int?
    @State private var eraserEditorOpen = false
    /// 胶囊渲染中的实测尺寸，**只喂位置夹取**（不参与决定胶囊自身尺寸，故不构成环）。
    /// 动画期间它逐帧插值，贴边时位置连续跟随收缩，不会在结尾跳一下。
    @State private var barSize: CGSize = CGSize(width: 420, height: 44)
    /// 整排内容的自然宽度 = 展开时的取景窗宽度（内容 `fixedSize`，故这个值不受窗口反向影响，无环）。
    @State private var fullW: CGFloat = 380
    /// 「保留格」左缘在整排内容里的横向位置（实测值）。
    @State private var keepX: CGFloat = 0
    /// 实际驱动推移的量：收起那一刻从 `keepX` 拍下的快照。
    /// 动画期间必须是**常量**——直接用 `keepX` 的话，一旦测量在动画中被重报（哪怕只抖动零点几 pt），
    /// offset 的目标值就变了，SwiftUI 会以新目标重启插值，表现就是收放走一半顿一下。
    @State private var shift: CGFloat = 0

    /// 内容排的局部坐标系：`keepX` 在这里量，`offset` 加在它外面，故测量值不被推移干扰。
    private static let contentSpace = "penRackContent"
    /// 收起后取景窗宽度 = 一格宽（笔尖与工具图标都是 28）。
    private static let keepW: CGFloat = 28
    private static let cellGap: CGFloat = 10

    private let edgeMargin: CGFloat = 6

    init(viewportSize: CGSize, topInset: CGFloat, isActiveWindow: Bool) {
        self.viewportSize = viewportSize
        self.topInset = topInset
        self.isActiveWindow = isActiveWindow
        // 首帧就落在正确的收起态。留给 onAppear 赋值不行：内容淡化用的 `.animation(_:value:)`
        // 是无条件的，会连这次「初始化赋值」也配上动画——启动时若是收起态，就会看见
        // 展开态内容凭空淡出一次。（State(initialValue:) 只在视图首次建立时生效，
        // 后续因 viewportSize 变化重建 struct 不会覆盖运行中的值。）
        _collapsedUI = State(initialValue: UserDefaults.standard.bool(forKey: Self.collapsedKey))
    }

    var body: some View {
        if viewportSize.width > 0, viewportSize.height > 0 {
            bar
                // 纯记录实测尺寸喂夹取，**不加 withAnimation**：这里本就是动画的逐帧插值结果，
                // 再包一层动画只会让它滞后于真实宽度，左缘在收放过程中漂移。
                .onGeometryChange(for: CGSize.self) { $0.size } action: { barSize = $0 }
                // 锚左上缘而不是中心：宽度怎么变，左缘都由 fracX/fracY 唯一决定，
                // 位置与 barSize 彻底解耦（旧的 .position(中心) 每帧要拿宽度反算，宽度一抖位置就抖）。
                .offset(x: origin.x, y: origin.y)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // 高优先级：起点落在笔插槽等 Button 上时，普通 .gesture 会被 Button 吃掉按下事件
                // （全程不跟手、松手瞬移）；minimumDistance=6 保证单击按钮不受影响。
                .highPriorityGesture(dragGesture)
                .onAppear { reclampStored() }   // 收起态已在 init 里落好，这里只校位置
                .onChange(of: collapsed) { _, v in
                    // 另一窗口改的收起态：镜像进本地驱动值（同走弹簧动画）
                    if v != collapsedUI { withAnimation(Self.collapseAnim) { collapsedUI = v } }
                }
                .onChange(of: viewportSize) { _, _ in reclampStored() }
        }
    }

    /// 收起/展开共用曲线：推移量、取景窗宽度、箭头翻转全走这一条。
    /// **不带 bounce**：内容是「推」到窗口边界外的，过冲会让当前工具那格先被顶出左边界再弹回来，闪一下。
    private static let collapseAnim: Animation = .smooth(duration: 0.3)

    private func setCollapsed(_ value: Bool) {
        if value {
            // 收起前先收掉挂在窗口外按钮上的浮层：它们马上会被裁掉 + 禁命中，
            // 浮层留着就会指向一个看不见的锚点。
            editingIndex = nil
            eraserEditorOpen = false
            shift = keepX   // 拍快照，动画全程用它，不受测量回报干扰
        }
        withAnimation(Self.collapseAnim) { collapsedUI = value }
        collapsed = value   // 持久化（onChange 里 v == collapsedUI，不会二次触发动画）
    }

    /// 展开=完整笔架；收起=靠边小药丸（只留当前工具 + 展开箭头）。收起态持久（全局）。
    ///
    /// **只有一排内容，没有「两态互换」**：当前工具那一格自始至终是同一个视图，不淡化、不重建，
    /// 收起时只是左边的格子把自己收成 0 宽，把它平移到最前面。曾经试过「展开态 / 收起态两套内容
    /// 交叉或错峰淡化」，两种都会闪：交叉淡化中期双方都停在 opacity≈0.5，叠加后总不透明度只有
    /// 0.75；错峰淡化则是所有笔先整体消失、宽度收完、当前笔再重新冒出来。根子在于当前笔压根
    /// 没被「保留」，而是消失后又画了一个。
    ///
    /// 最左拖拽手柄、最右收/展箭头同样两态共享，跟着宽度平移。padding 与内容高度两态统一
    /// （恒定 44 高），只有宽度在动。
    @ViewBuilder private var bar: some View {
        HStack(spacing: 0) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.primary.opacity(0.55))
                .imageScale(.small)
                .frame(width: 14)
                .accessibilityHidden(true)

            contentWindow.padding(.leading, Self.cellGap)
            toggleButton.padding(.leading, 8)
        }
        // 切工具/切笔时，选中环与 accent 色的变化也走同一条曲线，不瞬跳。
        .animation(Self.collapseAnim, value: app.padMode)
        .animation(Self.collapseAnim, value: app.padPenIndex)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        // 这里不再套 .clipShape(Capsule())：那是又一层离屏合成，胶囊宽度每帧变就每帧重算。
        // 内容排自己已经 .clipped() 到取景窗内，手柄/箭头都在 padding 里，没有会溢出的东西。
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
        .shadow(radius: 6, y: 2)
    }

    /// 中间内容：**一整排格子，谁都不改宽度、谁都不单独裁剪**。收起 = 整排往左推 `keepX`，
    /// 把当前工具那格顶到窗口最左，它左边的推出左边界、右边的被收窄的右边界吃掉。
    ///
    /// 上一版是每格各自把宽度收到 0 再各自 `mask`：十来个笔尖同时被切成一排竖条，很难看。
    /// **裁剪边界只能有一条**（就是这个取景窗），内容整体平移——格子本身从头到尾保持原样。
    private var contentWindow: some View {
        HStack(spacing: Self.cellGap) {
            ForEach(app.pens.indices, id: \.self) { i in
                cell(keep: collapsedKeepIndex == i) { penSlot(i) }
            }
            cell(keep: false) { addButton }
            cell(keep: false) { Divider().frame(width: 1, height: 20) }
            cell(keep: app.padMode == "erase") { eraserButton }
            cell(keep: app.padMode == "page") {
                modeButton(mode: "page", icon: "hand.draw", label: L("Page Turn"))
            }
            cell(keep: false) { localInkButton }
            cell(keep: false) { lassoButton }
        }
        // 内容永远按自然宽度布局：外面那层 frame 是取景窗，不许反过来把按钮挤扁。
        .fixedSize(horizontal: true, vertical: false)
        .coordinateSpace(.named(Self.contentSpace))
        // 阈值去抖：布局回报的零点几 pt 浮点抖动不该写回 State——它是动画目标值的来源，
        // 每写一次就重启一次插值。
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { v in
            if abs(v - fullW) > 0.5 { fullW = v }
        }
        // offset 加在坐标系外面：内部 keepX 的测量值不受推移影响，不构成环。
        .offset(x: collapsedUI ? -shift : 0)
        .frame(width: collapsedUI ? Self.keepW : fullW, alignment: .leading)
        // 唯一的裁剪边界。这里必须是 `.clipped()` 而不是 `.mask()`：mask 是离屏 alpha 合成，
        // 内容排一平移就得每帧把整排（十几个按钮 + 每个笔尖三层 + 材质）重渲染进离屏缓冲，
        // 于是「选中的不是第一支笔」（keepX≠0，内容真的在动）才卡、第一支笔（只有裁剪框在变）不卡。
        // 笔尖描边已改 strokeBorder 不外溢，内容高度正好等于格高，矩形硬裁不会切到任何东西。
        .clipped()
    }

    /// 一格内容。布局上永远是自然宽（收起靠整排平移，不靠它自己缩），这里只管两件事：
    /// 收起后窗口外的格子不许被点到、不进无障碍树；以及把「保留格」的横向位置报上来。
    private func cell<V: View>(keep: Bool, @ViewBuilder content: () -> V) -> some View {
        content()
            .background {
                // 只给保留格挂探针：keep 换人时这个视图被插入/移除，onGeometryChange 在插入时
                // 就报一次，于是 keepX 立刻是新值。（挂在所有格上反而不会重报——几何压根没变。）
                if keep {
                    Color.clear.onGeometryChange(for: CGFloat.self) {
                        $0.frame(in: .named(Self.contentSpace)).minX
                    } action: { v in
                        guard abs(v - keepX) > 0.5 else { return }
                        keepX = v
                        // 已经收起时换了保留格（切笔/切工具）：推移量当场跟上，否则窗口里显示的还是旧那格。
                        if collapsedUI { shift = v }
                    }
                }
            }
            // mask 不挡命中：窗口外的按钮仍在布局里，必须显式禁掉，否则收起后还能点到看不见的笔。
            .allowsHitTesting(!collapsedUI || keep)
            .accessibilityHidden(collapsedUI && !keep)
    }

    /// 收起后保留哪一支笔。橡皮/翻页模式下一支都不留（由对应的工具格自己留下）——
    /// 收起后显示的必须是「现在在用什么」，无条件画笔尖会在橡皮模式下读成「在用这支笔」。
    /// 索引越界兜底到第一支，避免一格都不剩的空药丸。
    private var collapsedKeepIndex: Int? {
        guard app.padMode == "note" else { return nil }
        return app.pens.indices.contains(app.padPenIndex) ? app.padPenIndex : app.pens.indices.first
    }

    // MARK: 位置夹取

    /// 当前帧的胶囊左上缘（含拖拽位移）。
    private var origin: CGPoint { clampedOrigin(drag: dragOffset) }

    /// 夹取后的胶囊左上缘：存储锚的就是左上缘，按实测宽高留边；上边界额外加 `topInset`
    /// （不进工具栏）。视口比胶囊还窄/矮的极端情况退化为固定在上/左合法点。
    ///
    /// 收起时宽度只会变小 → 右边界更宽松 → 左缘算出来原地不动；展开时若会捅出右边缘，
    /// 左缘随实测宽度连续左移把胶囊拉回可视区，同样是平滑的。
    private func clampedOrigin(drag: CGSize) -> CGPoint {
        let w = viewportSize.width, h = viewportSize.height
        let maxX = max(edgeMargin, w - barSize.width - edgeMargin)
        let minY = topInset + edgeMargin, maxY = max(minY, h - barSize.height - edgeMargin)
        let raw = CGPoint(x: fracX * w + drag.width, y: fracY * h + drag.height)
        return CGPoint(x: min(max(raw.x, edgeMargin), maxX),
                       y: min(max(raw.y, minY), maxY))
    }

    /// 初始/视口变化校正：存储位置若已越界（窗口变矮变窄、旧版本无限制留下的值）拉回可见区。
    private func reclampStored() {
        let p = clampedOrigin(drag: .zero)
        fracX = Double(p.x / viewportSize.width)
        fracY = Double(p.y / viewportSize.height)
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
        // `strokeBorder` 而非 `stroke`：后者线宽居中于路径，会往 28pt 外溢半个线宽
        // （选中态 2.5 → 外溢 1.25pt），一旦外面有任何裁剪就被削掉一圈。
        // 画在内侧后笔尖的占位尺寸 = 视觉尺寸，怎么裁都不会缺角。
        .overlay(Circle().strokeBorder(active ? Color.accentColor : .white.opacity(0.55),
                                       lineWidth: active ? 2.5 : 1))
    }

    /// 笔尖字形黑/白：白底之上按笔色感知亮度选，保证对比。
    private func contrastText(_ c: InkColor) -> Color {
        let lum = (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) / 255
        return lum > 0.62 ? .black : .white
    }

    /// 收/展箭头：**始终是同一个 chevron，靠旋转 180° 换向**。
    /// 不能用 `chevron.left`/`chevron.right` 两个符号互换——哪怕加 `.symbolEffect(.replace)`，
    /// 换符动画本身就是「旧的缩出、新的缩入」，中途画面上真的有两个箭头。
    /// 方向语义跟「左缘锚定」一致：`‹` 往左收拢，转过来的 `›` 往右放出。
    private var toggleButton: some View {
        Button { setCollapsed(!collapsedUI) } label: {
            Image(systemName: "chevron.left")
                .imageScale(.small)
                .fontWeight(.semibold)
                .foregroundStyle(.primary.opacity(0.7))
                .rotationEffect(.degrees(collapsedUI ? 180 : 0))
                .frame(width: 20, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsedUI ? L("Expand Pen Toolbar") : L("Collapse"))
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
