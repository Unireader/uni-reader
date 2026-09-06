import SwiftUI

/// 参考窗：浮在阅读区上的**只读** PDF 小窗（方案 `REF-WINDOW-PLAN.md`）。
///
/// 🔴 **挂载点必须是 `ContentView.readerColumn`**（与 `tabBar`、`AIInlineLayer` 同层），
/// 与那两位完全同样的两条理由：
///  ① **身份要稳定**——不能落进 `PageStreamView` 内部 `.id(docKey)` 的下游，否则每换一次标签
///     整个小窗跟着重建（闪一下，且滚动位置丢失）；
///  ② **要挡得住阅读区手势**——那四个拖拽手势（拖选/落墨/框选移动/框选截图）挂在 `ScrollView`
///     容器上，用 `.overlay` 加在**同一个视图**上的覆盖层挡不住它们（草稿纸就是为此才要在每个
///     gesture 里写 `openPadID == nil` 门控）。挂到上一层就是普通遮挡关系，一行门控都不用加。
struct RefWindowView: View {
    @ObservedObject var model: RefWindowModel
    @ObservedObject var workspace: WorkspaceManager
    let nightMode: Bool
    /// 当前标签在读的那本（用于「在主视图显示这一页」的可用性判定）。
    let currentDocID: String?
    let onGotoMain: (Int) -> Void

    @State private var currentPage = 0
    /// 🔴 拖动 / 改尺寸**期间**只动这两个本地量，松手才写回 model。
    /// 每帧写 `@Published` 的话，页流（`@ObservedObject model`）会跟着每帧整体重算——
    /// 用户 2026-08-30 报的「拖拽小窗时内容上下抖动」就是这么来的。
    ///
    /// 🔴 **松手后不清它们**（`nil` 只表示「还没动过」）：清空与 `model.size` 写入是
    /// `@State` 与 `@Published` 两条更新路径，SwiftUI 不保证合并成同一帧——真机日志里逮到过
    /// 松手瞬间视口闪回旧值一帧（`497×476 → 576×526 → 497×476`），那一帧会连带触发两次
    /// 「保持文档位置」的补偿滚动，看起来就是又跳了一下。让本地值一直当权威即可，
    /// 它与 `model` 此刻本来就相等。
    @State private var localSize: CGSize?
    @State private var localOffset: CGSize?
    /// 目录弹窗开着没有。
    @State private var tocOpen = false

    private static let corner: CGFloat = 12
    /// 拖动手柄的热区厚度。**比 header 的 8pt 内边距窄**，所以压不到里面那枚书本图标
    /// （用户 2026-08-30 报「缩放指示图标和书本图标有点重叠」——原来那枚左上角图标已删）。
    private static let edge: CGFloat = 5
    /// 工具栏条高。写死 = 任何内容都撑不高它。
    private static let headerHeight: CGFloat = 30
    /// 窄于此就不显示页码（先让文档名和那几枚按钮活下来）。
    private static let pageNumMinWidth: CGFloat = 330

    private var liveOffset: CGSize { localOffset ?? model.offset }
    private var liveSize: CGSize { localSize ?? model.size }

    /// 🔴 **摆位与尺寸每次布局都按当前容器夹一遍**（用户 2026-09-06 报「小窗标题栏跑到窗口
    /// 标题栏底下，拖不动了」）。
    ///
    /// 摆位/尺寸是本端记忆（`UserDefaults`），而容器随时会**变小**：缩窗口、开侧栏/Inspector、
    /// 退出全屏、换一块小屏、甚至上次那扇窗本来就更大。夹取从前**只在拖动/改尺寸的手势里**做，
    /// 容器一变就再没人夹——那份为大容器存下的偏移把小窗顶到容器上沿之外。
    /// 而 `.offset` **不裁剪**：跑出去的那截正好画在工具栏玻璃底下，小窗的标题栏落在系统标题栏
    /// 那一片里，鼠标点不到（事件被工具栏吃掉）＝「拖不动了」。
    ///
    /// 夹取是纯函数、在 body 里算（不写 `@Published`，写状态的事交给 `fitIntoContainer`）——
    /// 这样**第一帧**就已经是夹过的，不必等 `onChange` 补一拍。
    private func fitSize(_ container: CGSize) -> CGSize {
        RefWindowModel.clampSize(liveSize, in: container)
    }
    private func fitOffset(_ container: CGSize) -> CGSize {
        RefWindowModel.clampOffset(liveOffset, size: fitSize(container), in: container)
    }

    /// 容器变了 → 把夹取结果写回状态与记忆，否则下次容器变大时又会从那份越界的旧值起算。
    private func fitIntoContainer(_ container: CGSize) {
        guard container.width > 0, container.height > 0 else { return }
        let s = fitSize(container), o = fitOffset(container)
        guard s != liveSize || o != liveOffset else { return }
        localSize = s
        localOffset = o
        model.size = s
        model.offset = o
        model.persistGeometry()
    }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottomTrailing) {
                if model.isOpen {
                    if model.collapsed {
                        bubble(container: g.size).transition(.scale.combined(with: .opacity))
                    } else {
                        panel(container: g.size).transition(.opacity)
                    }
                }
            }
            // 铺满才谈得上「贴右下角」；ZStack 自身没有背景，所以空白处照旧不吃手势。
            .frame(width: g.size.width, height: g.size.height, alignment: .bottomTrailing)
            .animation(.easeOut(duration: 0.16), value: model.isOpen)
            .animation(.easeOut(duration: 0.16), value: model.collapsed)
            .onAppear { fitIntoContainer(g.size) }
            .onChange(of: g.size) { _, s in fitIntoContainer(s) }
            // 打开那一刻也夹一遍：关着的时候容器变过（开侧栏/缩窗口），再打开就是越界的旧值。
            .onChange(of: model.isOpen) { _, open in if open { fitIntoContainer(g.size) } }
        }
    }

    // MARK: - 面板

    private func panel(container: CGSize) -> some View {
        let size = fitSize(container)
        return VStack(spacing: 0) {
            header(container: container, size: size)
            Divider()
            RefPageStream(model: model, nightMode: nightMode, currentPage: $currentPage)
        }
        .frame(width: size.width, height: size.height)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner))
        .overlay { RoundedRectangle(cornerRadius: Self.corner).strokeBorder(.separator, lineWidth: 0.5) }
        .overlay { resizeEdges(container: container) }
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        .padding(14)
        .offset(fitOffset(container))
    }

    /// 🔴 **高度锁死 + 按宽度分档降级**：HStack 里只要有一个 `Text` 没被限成单行，窄到放不下时
    /// 它就会换行、把整条工具栏撑高（用户 2026-08-30 报「宽度太小的时候会被挤得很高」）。
    /// 页码那条当时漏了 `lineLimit`，而文档名又带着 `.fixedSize()` 不许压缩，两头顶着。
    /// 现在：条高固定，文档名可截断（优先让它缩），页码在窄窗下整条隐去。
    ///
    /// 🔴 **文档名是拖拽区，不是控件**（用户 2026-09-02）：它原先整块是「换书」菜单的 label，
    /// 于是标题栏最顺手的那一片全被菜单吃掉、拖不动窗口（系统窗口的标题从来都是拖拽把手）。
    /// 现在换书收进左边那枚书本图标，标题退回纯 `Text` —— 不吃点击 = 落到下面的 `moveGesture`。
    private func header(container: CGSize, size: CGSize) -> some View {
        HStack(spacing: 4) {
            docPicker
            if !model.toc.isEmpty { tocButton }
            title
            Spacer(minLength: 2)
            if size.width >= Self.pageNumMinWidth, let n = model.pdf?.pageCount, n > 0 {
                Text("\(currentPage + 1) / \(n)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
                    .padding(.trailing, 2)
            }
            btn("arrow.uturn.backward", L("Back to Progress")) {
                model.rewindToProgress(workspace: workspace)
            }
            if model.docID != nil, model.docID == currentDocID {
                btn("arrow.up.forward.app", L("Show This Page in Main View")) { onGotoMain(currentPage) }
            }
            btn("minus", L("Collapse")) { model.collapsed = true }
            btn("xmark", L("Close")) { model.close() }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.headerHeight)
        .contentShape(Rectangle())
        .gesture(moveGesture(container: container))
    }

    /// 文档名。**纯文本、不吃点击**——这块是标题栏的拖拽把手（见 `header` 的红线）。
    /// 🔴 不要 `.fixedSize()`：那会让它拒绝被压缩，窄窗下整条 HStack 的理想宽度超出可用宽度，
    /// 挤压就落到别的元素上（文本换行 → 条被撑高）。让文档名当那个「可以缩的」。
    private var title: some View {
        Text(model.title.isEmpty ? L("Reference") : model.title)
            .font(.callout).lineLimit(1).truncationMode(.middle)
            .foregroundStyle(.primary)
            .layoutPriority(0)
            .help(model.title)
    }

    /// 换一本书看。列的是**当前工作区的全部文档**（不只已打开的那几篇）。
    /// 只留一枚图标：标题让位给拖拽（用户 2026-09-02）。
    private var docPicker: some View {
        Menu {
            ForEach(workspace.documents) { d in
                Button { model.load(documentId: d.id, workspace: workspace) } label: {
                    if d.id == model.docID { Label(d.title, systemImage: "checkmark") }
                    else { Text(d.title) }
                }
            }
        } label: {
            // material 底上一律显式 `.primary`：`.secondary` 会被画得几乎看不见（红线）。
            Image(systemName: "book")
                .imageScale(.small)
                .foregroundStyle(.primary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .layoutPriority(1)   // 图标不参与压缩：要缩就缩文档名
        .help(L("Pick a document to reference"))
    }

    /// 目录跳转。用 SwiftUI 的 `.popover` 而不是工具栏那套 `NSPopover`——这枚按钮本来就活在
    /// SwiftUI 覆盖层里，锚点是视图自己，不存在工具栏那次「翻转坐标系把 popover 弹到标题栏上方」
    /// 的问题（那笔账记在 `APPKIT-WINDOW-PLAN.md §5.1`）。
    ///
    /// 条目复用主阅读区那份 `TOCListView`（它只吃 entries / currentPage / onSelect，
    /// 与 `DocSession` 零耦合），连「当前章节自动展开并高亮」都是现成的。
    private var tocButton: some View {
        Button { tocOpen.toggle() } label: {
            Image(systemName: "list.bullet")
                .imageScale(.small)
                .foregroundStyle(.primary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
        .help(L("Contents"))
        .popover(isPresented: $tocOpen, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                Text(L("Contents"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                TOCListView(entries: model.toc, currentPage: currentPage) { e in
                    guard let page = e.pageIndex else { return }   // 坏书签：跳不过去
                    model.goto(page: page, frac: e.frac)
                    tocOpen = false
                }
                .frame(width: 300, height: 380)
            }
        }
    }

    /// `.plain` + 显式 `.primary`：`.borderless` 在 material 底上会把图标画得极淡
    /// （2026-08-07 草稿纸工具条踩过一次）。
    private func btn(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(.primary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .layoutPriority(1)   // 按钮不参与压缩：要缩就缩文档名
        .help(help)
    }

    // MARK: - 摆位与改尺寸

    /// 拖标题栏移动。基准要在起手时定死：`translation` 是相对起点的累计量，每帧拿当前值去加会指数放大
    /// （同 `AIInlineLayer` 的宽度手柄）。
    private func moveGesture(container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { v in
                // 基准取 `model.offset`（手势期间不变）；夹取的尺寸用**夹过的**那份，
                // 否则容器刚变小、`fitIntoContainer` 还没写回时会按旧尺寸放宽边界。
                let want = CGSize(width: model.offset.width + v.translation.width,
                                  height: model.offset.height + v.translation.height)
                localOffset = RefWindowModel.clampOffset(want, size: fitSize(container), in: container)
            }
            .onEnded { _ in
                model.setOffset(liveOffset, in: container)
                localOffset = model.offset      // 与 model 对齐（clamp 后），不置 nil
                model.persistGeometry()
            }
    }

    /// 尺寸手柄：左边缘 / 上边缘 / 左上角三条**透明热区**，靠 `pointerStyle` 提示，不画任何图标。
    ///
    /// `offset` 是相对**右下角**的偏移，所以改尺寸时右下角天然不动、只有左上两条边伸缩——
    /// 手柄放这两条边最顺手，也不必同时改 offset。
    /// 原来那枚画在左上角的图标与 header 里的书本图标撞在一起（用户 2026-08-30 报），
    /// 而系统窗口本来就是「边缘可拖、不画东西」，照它办。
    @ViewBuilder
    private func resizeEdges(container: CGSize) -> some View {
        let e = Self.edge
        ZStack(alignment: .topLeading) {
            Color.clear
            // 左边缘：改宽
            handle(width: e, height: nil, cursor: .frameResize(position: .leading),
                   container: container, horizontal: true, vertical: false)
                .frame(maxHeight: .infinity)
            // 上边缘：改高
            handle(width: nil, height: e, cursor: .frameResize(position: .top),
                   container: container, horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            // 左上角：两轴同时
            handle(width: e * 3, height: e * 3, cursor: .frameResize(position: .topLeading),
                   container: container, horizontal: true, vertical: true)
        }
        .allowsHitTesting(true)
    }

    private func handle(width: CGFloat?, height: CGFloat?, cursor: PointerStyle,
                        container: CGSize, horizontal: Bool, vertical: Bool) -> some View {
        Color.clear
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .pointerStyle(cursor)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        // 往左上拖 = 变大，所以取负；右下角固定不动。
                        let want = CGSize(width: model.size.width - (horizontal ? v.translation.width : 0),
                                          height: model.size.height - (vertical ? v.translation.height : 0))
                        localSize = RefWindowModel.clampSize(want, in: container)
                    }
                    .onEnded { _ in
                        model.setSize(liveSize, in: container)
                        localSize = model.size   // 与 model 对齐（clamp 后），不置 nil
                        model.persistGeometry()
                    }
            )
    }

    // MARK: - 折叠气泡

    private func bubble(container: CGSize) -> some View {
        Button { model.collapsed = false } label: {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .overlay { Circle().strokeBorder(.separator, lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(16)
        .offset(fitOffset(container))   // 气泡与面板同一份摆位（同样夹在容器内）
        .help(L("Reference Window"))
    }
}
