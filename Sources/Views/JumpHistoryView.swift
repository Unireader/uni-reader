import SwiftUI

/// 跳转历史浮窗：浮在阅读区上的一条轨迹列表，点哪条去哪儿。
///
/// 🔴 **挂载点必须是 `ContentView.readerColumn`**（与 `tabBar`、`AIInlineLayer`、参考窗同层），
/// 与那几位完全同样的两条理由：① 身份要稳（不能落进 `PageStreamView` 那个 `.id(docKey)` 的下游，
/// 否则切标签整块重建）；② 要挡得住阅读区那四个挂在 `ScrollView` 上的拖拽手势——`.overlay` 加在
/// **同一个视图**上是挡不住的（草稿纸就是为此才在每个 gesture 里写门控）。
///
/// 摆位/尺寸在 `panel`（窗口级），列表数据在 `session.jumps`（文档级）——切标签时窗不动、内容换。
struct JumpHistoryView: View {
    @ObservedObject var panel: JumpHistoryPanel
    @ObservedObject var session: DocSession

    /// 🔴 拖动 / 改尺寸**期间**只动这两个本地量，松手才写回 `panel`：每帧写 `@Published` 会让整个
    /// 浮窗跟着每帧重算（参考窗 2026-08-30 报过的「拖拽时内容抖动」）。松手后**不清**它们
    /// （`nil` 只表示「还没动过」），避免 `@State` 与 `@Published` 两条更新路径不同帧落地闪一下。
    @State private var localSize: CGSize?
    @State private var localOffset: CGSize?

    private static let corner: CGFloat = 12
    private static let edge: CGFloat = 5
    private static let headerHeight: CGFloat = 30
    private static let footerHeight: CGFloat = 24

    private var liveOffset: CGSize { localOffset ?? panel.offset }
    private var liveSize: CGSize { localSize ?? panel.size }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottomTrailing) {
                if panel.isOpen { card(container: g.size).transition(.opacity) }
            }
            // 铺满才谈得上「贴角」；ZStack 自身没有背景，空白处照旧不吃手势。
            .frame(width: g.size.width, height: g.size.height, alignment: .bottomTrailing)
            .animation(.easeOut(duration: 0.16), value: panel.isOpen)
            .onAppear { if panel.isOpen { panel.placeDefault(in: g.size) } }
            .onChange(of: panel.isOpen) { _, open in if open { panel.placeDefault(in: g.size) } }
        }
    }

    // MARK: - 面板

    private func card(container: CGSize) -> some View {
        VStack(spacing: 0) {
            header(container: container)
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: liveSize.width, height: liveSize.height)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner))
        .overlay { RoundedRectangle(cornerRadius: Self.corner).strokeBorder(.separator, lineWidth: 0.5) }
        .overlay { resizeEdges(container: container) }
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        .padding(14)
        .offset(liveOffset)
    }

    /// 条高锁死 + 标题可截断：窄窗下只要有一个 `Text` 没被限成单行，它换行就会把整条撑高
    /// （参考窗 2026-08-30 踩过）。
    private func header(container: CGSize) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "clock.arrow.circlepath")
                .imageScale(.small).foregroundStyle(.secondary)
            Text(L("Jump History"))
                .font(.callout).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 2)
            btn("chevron.left", L("Back to Previous Position")) { session.jumpBack() }
                .disabled(!session.jumps.canGoBack)
            btn("chevron.right", L("Forward to Next Position")) { session.jumpForward() }
                .disabled(!session.jumps.canGoForward)
            btn("xmark", L("Close")) { panel.close() }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.headerHeight)
        .contentShape(Rectangle())
        .gesture(moveGesture(container: container))
    }

    @ViewBuilder
    private var content: some View {
        if session.jumps.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "arrow.trianglehead.turn.up.right.diamond")
                    .font(.title2).foregroundStyle(.tertiary)
                Text(L("No jumps yet")).font(.callout).foregroundStyle(.secondary)
                Text(L("Contents, search and list jumps show up here."))
                    .font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(session.jumps.marks) { row($0) }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 6)
                }
                .onAppear { reveal(proxy) }
                .onChange(of: session.jumps.current?.id) { _, _ in reveal(proxy) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(String(format: L("%d marks"), session.jumps.marks.count))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Button(L("Clear History")) { session.clearJumps() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(session.jumps.isEmpty)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.footerHeight)
    }

    private func row(_ m: JumpMark) -> some View {
        let isCurrent = m.id == session.jumps.current?.id
        return Button { session.jumpToMark(id: m.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: m.kind.symbol)
                    .imageScale(.small).frame(width: 16)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                Text(m.displayTitle(toc: session.toc)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Text("\(m.page + 1)")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(isCurrent ? Color.accentColor.opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(isCurrent ? Color.accentColor : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(m.id)
    }

    /// 当前这条滚进视野（后退/前进时列表跟着走）。等布局落定再滚，同 `TOCListView.reveal`。
    private func reveal(_ proxy: ScrollViewProxy) {
        guard let id = session.jumps.current?.id else { return }
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
    }

    /// `.plain` + 显式 `.primary`：`.borderless` 在 material 底上会把图标画得极淡
    /// （2026-08-07 草稿纸工具条踩过一次）。禁用态交给系统压暗。
    private func btn(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(.primary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .layoutPriority(1)   // 按钮不参与压缩：要缩就缩标题
        .help(help)
    }

    // MARK: - 摆位与改尺寸（与参考窗同一套：基准起手定死，offset 相对右下角）

    private func moveGesture(container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { v in
                let want = CGSize(width: panel.offset.width + v.translation.width,
                                  height: panel.offset.height + v.translation.height)
                localOffset = JumpHistoryPanel.clampOffset(want, size: liveSize, in: container)
            }
            .onEnded { _ in
                panel.setOffset(liveOffset, in: container)
                localOffset = panel.offset      // 与 panel 对齐（clamp 后），不置 nil
                panel.persistGeometry()
            }
    }

    /// 尺寸手柄：左边缘 / 上边缘 / 左上角三条透明热区，靠 `pointerStyle` 提示，不画任何图标
    /// （`offset` 相对右下角 → 改尺寸时右下角天然不动）。
    @ViewBuilder
    private func resizeEdges(container: CGSize) -> some View {
        let e = Self.edge
        ZStack(alignment: .topLeading) {
            Color.clear
            handle(width: e, height: nil, cursor: .frameResize(position: .leading),
                   container: container, horizontal: true, vertical: false)
                .frame(maxHeight: .infinity)
            handle(width: nil, height: e, cursor: .frameResize(position: .top),
                   container: container, horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
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
                        let want = CGSize(width: panel.size.width - (horizontal ? v.translation.width : 0),
                                          height: panel.size.height - (vertical ? v.translation.height : 0))
                        localSize = JumpHistoryPanel.clampSize(want, in: container)
                    }
                    .onEnded { _ in
                        panel.setSize(liveSize, in: container)
                        localSize = panel.size   // 与 panel 对齐（clamp 后），不置 nil
                        panel.persistGeometry()
                    }
            )
    }
}

extension JumpMark {
    /// 一条历史在 UI 上叫什么。
    ///
    /// 有现成名字（目录条目名 / 搜索词）就用它；没有的（缩略图、笔记列表跳转、离开点）显示它
    /// 落在哪一章——比干巴巴一个页码有用；连目录都没有才退回「第 N 页」。
    func displayTitle(toc: [TOCEntry]) -> String {
        if !label.isEmpty {
            return kind == .search ? "\u{201C}\(label)\u{201D}" : label
        }
        let chapter = TOCEntry.chapterLabel(for: page, in: toc)
        return chapter.isEmpty ? String(format: L("Page %d"), page + 1) : chapter
    }
}
