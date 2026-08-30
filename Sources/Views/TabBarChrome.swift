import SwiftUI

/// 标签栏的两种形态（用户 2026-08-29：「两个模式都要支持，浮动可以固定，固定可以浮动」）。
/// 存 app 级 `@AppStorage`，不逐窗口记——它是一条外观偏好，不是某扇窗口的状态。
enum TabBarStyle: String {
    case floating   // 浮动胶囊：与笔架 / 查找条 / 截图 toast / 草稿纸工具条完全同一套浮层语言
    case docked     // 贴底整条：满宽 + 顶部分隔线
    static let key = "tabBarStyle"
}

enum TabBarMetrics {
    static let rowHeight: CGFloat = 26      // 单个标签的高度（不含容器内边距）
    static let pad: CGFloat = 4             // 容器内边距
    static let floatBottom: CGFloat = 12    // 浮动形态离阅读区底边的距离

    /// **阅读区底部要给标签栏让出多少**：笔架的拖拽夹取、滚动条的 `contentMargins` 都读它。
    /// 只有一个标签时标签栏不显示（用户拍板），故为 0 —— 那时阅读区一寸都不让，与从前一模一样。
    static func inset(style: TabBarStyle, tabCount: Int) -> CGFloat {
        guard tabCount > 1 else { return 0 }
        let bar = rowHeight + pad * 2
        return style == .floating ? bar + floatBottom : bar
    }
}

/// 标签栏上的一个标签（**纯值**）。
struct TabBarItem: Identifiable, Equatable {
    let id: UUID
    var title: String
    var padFollowing: Bool      // 平板正跟随这个标签
    var hasDocument: Bool       // 空标签没有「在新窗口打开」
}

/// 标签栏的**纯呈现层**：只吃值与回调，不认识 `TabsModel` / `DocTabModel` / `AppModel`。
///
/// 这么切的唯一目的是让 `spike/tabbar-look.swift` **只编这一个文件**就能出样张——
/// 同 `ScratchCanvasLayers` 的先例。写一份 mock 复刻是不行的：草稿纸那轮的教训是
/// **少复刻一件，那件就是下一个漏网的**（缩放读数太浅就是这么漏过去的）。
///
/// 🔴 UI 红线：**严禁自绘仿系统样式**（用户 2026-07-25 否决）。这里只用系统材质与标准形状
/// （`.regularMaterial` / `.bar` / `.quaternary` / `.quinary` / `Capsule` / `RoundedRectangle`），
/// 系统渲染成什么样就什么样。
struct TabStrip: View {
    let items: [TabBarItem]
    let activeID: UUID
    let style: TabBarStyle
    var onSelect: (UUID) -> Void = { _ in }
    var onClose: (UUID) -> Void = { _ in }
    var onCloseOthers: (UUID) -> Void = { _ in }
    var onOpenInNewWindow: (UUID) -> Void = { _ in }
    var onNewTab: () -> Void = {}
    var onToggleStyle: () -> Void = {}

    var body: some View {
        switch style {
        case .floating:
            strip
                .padding(TabBarMetrics.pad)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
                .shadow(radius: 6, y: 2)
                .padding(.bottom, TabBarMetrics.floatBottom)
                .padding(.horizontal, 24)
                .contextMenu { styleMenu }
        case .docked:
            strip
                .padding(.vertical, TabBarMetrics.pad)
                .padding(.horizontal, 8)   // 4pt 时第一个标签的圆角片直接贴着窗口左边，太挤
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
                .contextMenu { styleMenu }
        }
    }

    @ViewBuilder
    private var styleMenu: some View {
        Button(style == .floating ? L("Pin to Bottom") : L("Float"), action: onToggleStyle)
    }

    /// 标签排。
    ///
    /// 🔴 **不能无条件套 `ScrollView`**（2026-08-29 样张当场抓到）：横向 ScrollView 是贪心的，
    /// 会把浮动胶囊撑成**整条阅读区宽**——那就不是「浮在纸上的胶囊」而是个圆角横杠了。
    /// `ViewThatFits` 才对：放得下就整排铺开、胶囊贴着内容宽；放不下才退到横向滚动
    /// （不做「越开越窄挤成一条」）。附带好处是 `ImageRenderer` 画得出第一个分支——
    /// ScrollView 在样张里是**整块空白**，那一版等于没法目检。
    private var strip: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal) { row }.scrollIndicators(.never)
        }
        .frame(height: TabBarMetrics.rowHeight)
    }

    /// 🔴 `fixedSize(horizontal:)` 不能省（2026-08-29 样张当场抓到）：标签用了
    /// `.frame(minWidth:maxWidth:)`，那是**弹性**尺寸，HStack 会把整条可用宽平摊给它们——
    /// 两三个标签的胶囊也会被撑到满宽、标题之间隔着大片空白。`fixedSize` 让这一排按**理想宽**
    /// 落位（弹性 frame 在 nil 提案下取 `min(内容理想宽, maxWidth)`），于是胶囊贴着内容走，
    /// 长标题仍在 220pt 处截断。
    private var row: some View {
        HStack(spacing: style == .floating ? 2 : 1) {
            ForEach(items) { item in
                TabChip(item: item, isActive: item.id == activeID, shape: chipShape,
                        onSelect: { onSelect(item.id) }, onClose: { onClose(item.id) })
                    .contextMenu {
                        Button(L("Close Tab")) { onClose(item.id) }
                        Button(L("Close Other Tabs")) { onCloseOthers(item.id) }
                        if item.hasDocument {
                            Divider()
                            Button(L("Open in New Window")) { onOpenInNewWindow(item.id) }
                        }
                    }
            }
            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .frame(width: TabBarMetrics.rowHeight, height: TabBarMetrics.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("New Tab"))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var chipShape: AnyShape {
        style == .floating ? AnyShape(Capsule())
                           : AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// 一个标签。**关闭按钮在左**（用户 2026-08-29 明确要求，也是 macOS 惯例：Safari / Xcode 同款）。
private struct TabChip: View {
    let item: TabBarItem
    let isActive: Bool
    let shape: AnyShape
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    /// 关闭按钮只在「活动标签」或「鼠标悬停」时露出——一排常驻的 × 会把标题挤没、也太抢戏。
    /// 藏起来时**同时关掉命中**：只改 opacity 的话看不见却点得到，那正是误关的来源。
    private var showsClose: Bool { isActive || hovering }

    var body: some View {
        HStack(spacing: 5) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 15, height: 15)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(showsClose ? 1 : 0)
            .allowsHitTesting(showsClose)
            .accessibilityLabel(L("Close Tab"))

            // 不加 `.frame(maxWidth: .infinity)`：那会让每个标签都贪到封顶宽，
            // 两三个标签时胶囊就白白撑得老长。让它按标题的自然宽度走，由外层封顶截断。
            //
            // 🔴 活动标签**加粗**（2026-08-29 样张当场抓到）：只靠 `.primary` / `.secondary` 分主次时，
            // 浅色外观下活动标签反而比非活动的更浅——它那层 `.quaternary` 底片会把文字一起提亮。
            // 字重是唯一不受底色影响的区分手段，浅深两套外观都稳。
            Text(item.title)
                .font(isActive ? .callout.weight(.semibold) : .callout)
                .lineLimit(1)
                .truncationMode(.tail)

            if item.padFollowing {
                Image(systemName: "ipad")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help(L("The tablet is following this tab"))
            }
        }
        // 用具体的 `Color.primary/.secondary`，不用层级样式 `.primary/.secondary`——后者是相对
        // **当前前景**解析的，套在 material + `.quaternary` 底片上时会被一路稀释掉。
        //
        // 🔴 非活动标签**不能用 `Color.secondary`**（用户 2026-08-30：「几乎看不清」）：
        // `secondaryLabelColor` 本身就只有五成不透明度，再叠在浮动胶囊那层半透明 material 上、
        // 底下还透着 PDF 的白纸，实际对比度掉到勉强能认字。主次已经由**字重**分开了
        // （活动 semibold / 非活动 regular，见上），颜色这一路只留一点点差就够，
        // 于是非活动也走 `Color.primary`，只压一档不透明度。
        .foregroundStyle(isActive ? Color.primary : Color.primary.opacity(0.78))
        .padding(.horizontal, 8)
        .frame(height: TabBarMetrics.rowHeight)
        .frame(minWidth: 96, maxWidth: 220)
        .background(background, in: shape)
        .contentShape(shape)
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(item.title)
    }

    private var background: AnyShapeStyle {
        if isActive { return AnyShapeStyle(.quaternary) }
        if hovering { return AnyShapeStyle(.quinary) }
        return AnyShapeStyle(.clear)
    }
}
