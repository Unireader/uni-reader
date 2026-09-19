import SwiftUI
import WebKit
import AppKit

/// 内置面板拆成的两半（咨询 AI 与 Agent 两块内置面板共用这个说法）。
enum InlinePanelPart {
    /// 不显示任何东西，只挂生命周期钩子（首次出现时按上次的开合状态展开等）：挂在阅读区的 `.overlay` 上，
    /// 内置模式下始终在。展开 / 收起的入口是阅读窗口工具栏上的开关（用户 2026-09-19：像参考窗那样用
    /// 工具栏按钮，不在阅读区里画气泡按钮）。
    case lifecycle
    /// 展开的侧栏：与阅读区并排，展开时把阅读区往左挤（2026-09-18 起，之前是盖在阅读区上）。
    case panel
}

/// 两块内置面板（Agent / 咨询 AI）**共用**的标题行（用户 2026-09-19：两边高度、图标样式要统一）。
/// 左边图标 + 两行文字（标题 / 副标题），右边一组按钮用系统 `ControlGroup` 分组，高度固定——
/// 副标题有没有都一样高，两块面板并排时标题行底边对齐。
/// 🔴 面板底是系统 Liquid Glass（`.glassEffect(.regular)`，与左侧边栏同材质）：文字一律显式 `.primary`
/// （红线：玻璃 / material 上 `.secondary` 几乎看不见）。
struct InlinePanelHeader<Controls: View>: View {
    let icon: String
    let title: String
    var subtitle: String?
    @ViewBuilder var controls: () -> Controls

    static var height: CGFloat { 48 }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .imageScale(.large)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1).truncationMode(.tail)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            ControlGroup { controls() }
                .fixedSize()
        }
        .foregroundStyle(.primary)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 12)
        .frame(height: Self.height)
    }
}

/// **内置模式**：AI 面板不另开窗口，而是贴在阅读窗口右侧、与阅读区并排（展开时把 PDF 往左推）；
/// 展开 / 收起用阅读窗口工具栏上的「AI 面板」开关（`ReaderWindowController.toggleConsultPanel`；
/// 2026-09-19 前是阅读区右下角一枚自绘气泡按钮，用户要求改成和参考窗一样的工具栏按钮）。
///
/// 每扇阅读窗口的内置层是一个独立宿主，各挂自己那一份网页（`AIHost.inline(session.id)`）。
/// webview 归 `AIPageBox` 自己持有，**本视图被重建也不会出事**——2026-08-26 为「SwiftUI 重建视图 →
/// 第二个 WebView 挂同一个 WebPage」崩了四次，详见 `AIWebView.swift` 顶部那段。
///
/// **每扇阅读窗口都显示自己的那一个**（用户 2026-08-26：「我要每个 windows 同时显示聊天」）。
/// 早先限制成「只有活跃窗口显示」纯粹是为了规避那个崩溃，现在页面按宿主分配，这条限制已无必要。
/// 展开/收起也是**按窗口各管各的**（`inlineOpenSessions`）。
struct AIInlineLayer: View {
    @ObservedObject var session: DocSession
    /// 拆成两处挂（用户 2026-09-18：「打开后向左推开 pdf 内容，现在会叠加在 pdf 区域上」）：
    /// `.lifecycle` 挂在阅读区的覆盖层上（不显示东西，只挂本宿主的生命周期钩子）；
    /// `.panel` 与阅读区**并排**放在 `ReaderPane.readerColumn` 的 HStack 里，展开时把阅读区往左挤。
    var part: InlinePanelPart
    @StateObject private var panel = AIPanelModel.shared

    @State private var dragStartWidth: Double?

    /// 内置模式下每扇阅读窗口都是宿主 —— 不再看是不是活跃窗口。
    private var hosts: Bool { panel.mode == .inline && panel.enabled }

    /// 本窗口的面板是展开的还是收起的。
    private var isOpen: Bool { panel.isInlineOpen(session.windowID) }

    /// 该不该挂 webview：展开时才挂（收起就不占着）。
    private var wantsHost: Bool { hosts && isOpen }

    private var host: AIHost { .inline(session.windowID) }

    /// 🔴 **body 里直接从模型查，不用 `@State` 缓存**：视图一被重建 `@State` 就归 nil，
    /// 会先渲一帧占位再切回网页 —— 那一下必然闪。创建仍只在 `onAppear`/`onChange` 里做。
    private var box: AIPageBox? { panel.existingPage(for: host) }

    var body: some View {
        if hosts {
            switch part {
            case .lifecycle:
                // 生命周期钩子挂在这一半：它在内置模式下始终在（面板那一半收起时整个不存在）
                Color.clear
                .allowsHitTesting(false)
                .onAppear {
                    panel.seedInlineOpen(session.windowID)   // 新窗口沿用「上次是展开还是收着」
                    if wantsHost { takePage() }
                }
                .onChange(of: wantsHost) { _, want in if want { takePage() } }
                .onChange(of: panel.currentID) { _, _ in if wantsHost { takePage() } }
                // 🔴 **刻意不在 onDisappear 放页面**：切到另一扇阅读窗口、或收起面板，都不算这个宿主消失，
                // 放了就等于清掉那扇窗口正在进行的对话状态。真正的回收在 `ContentView.onDisappear`
                // （窗口关闭）里做。
            case .panel:
                // 从右边滑入 / 滑出（动画挂在外壳 `InlinePanelsColumn` 上，阅读区不逐帧重排）
                if isOpen { sidePanel.transition(.move(edge: .trailing)) }
            }
        }
    }

    /// 确保本窗口那一份页面已建好（body 靠 `existingPage` 读它）。
    /// ⚠️ **不在这里抢 `activeHost`**：多扇窗口的面板同时出现时，谁最后 `onAppear` 谁就赢，
    /// 那是错的。`activeHost` 由「哪扇窗口是 key」决定（`ContentView` 的 `onKeyChange`）。
    private func takePage() { _ = panel.page(for: host) }

    // MARK: - 侧面板

    private var sidePanel: some View {
        VStack(spacing: 0) {
            header
            Divider()
            webArea
        }
        .frame(width: panel.inlineWidth)
        .frame(maxHeight: .infinity)
        // 系统 Liquid Glass（与左侧边栏同一种材质，与 Agent 面板一致，用户 2026-09-19）+ 左侧分隔线
        .background { Color.clear.glassEffect(.regular, in: Rectangle()).ignoresSafeArea() }
        .overlay(alignment: .leading) { Divider() }
        .overlay(alignment: .leading) { resizeHandle }
    }

    /// 与 Agent 面板共用 `InlinePanelHeader`（用户 2026-09-19：两边高度、图标样式统一）。
    /// 副标题 =「这段对话绑在哪一页」（文档名 · 页码）：从中间省略，窄面板下页码也保得住
    /// （2026-09-01 用户报「内置模式下标题栏看不清链接的 pdf 和页」）。
    /// 按钮与 Agent 那组一一对应：模式 / 更多（面板本身的设置）/ 新对话；面板里不放收起按钮，开合只走工具栏开关。
    private var header: some View {
        InlinePanelHeader(icon: panel.currentProvider?.icon ?? "bubble.left.and.text.bubble.right",
                          title: panel.currentProvider?.name ?? L("AI"),
                          subtitle: panel.bindContext.map { "\($0.docTitle) · \(String(format: L("p.%d"), $0.page + 1))" }) {
            modeMenu
            Menu {
                Button(L("Open as Separate Window")) {
                    panel.setMode(.window)
                    AIPanelWindowController.show()   // 迁移后浮窗归 AppKit，不再走 SwiftUI 的 openWindow
                }
            } label: {
                Label(L("More"), systemImage: "ellipsis")
            }
            .help(L("More"))
            Button { panel.goHome() } label: {
                Label(L("New Chat"), systemImage: "square.and.pencil")
            }
            .help(L("New Chat"))
        }
    }

    /// 发送时用哪档模式（DeepSeek 的「快速 / 专家 / 识图」）。默认「跟内容走」＝
    /// 有图 → 识图、无图 → 专家（用户 2026-09-06 定）；钉住某一档就一直用那档。
    /// **只在新对话页切得动**——那条分段控件聊起来之后站点自己就收走了（见 `AIPanelModel.applyMode`）。
    @ViewBuilder private var modeMenu: some View {
        if let modes = panel.currentProvider?.modes, !modes.isEmpty {
            Menu {
                Button { panel.setChatMode("auto") } label: {
                    if panel.chatMode == "auto" { Label(L("Follow Content"), systemImage: "checkmark") }
                    else { Text(L("Follow Content")) }
                }
                Divider()
                ForEach(modes) { m in
                    Button { panel.setChatMode(m.id) } label: {
                        if panel.chatMode == m.id { Label(m.name, systemImage: "checkmark") }
                        else { Text(m.name) }
                    }
                }
            } label: {
                Label(L("Mode for new chats"), systemImage: "slider.horizontal.3")
            }
            .help(L("Mode for new chats"))
        }
    }

    @ViewBuilder
    private var webArea: some View {
        if let box {
            AIWebArea(panel: panel, box: box, host: host)
        } else {
            ContentUnavailableView(L("No AI Platform"),
                                   systemImage: "bubble.left.and.bubble.right",
                                   description: Text(L("Pick a platform from the toolbar to get started.")))
        }
    }

    /// 左缘拖动改宽度。宽度对聊天面板影响很大，值得给一条。
    private var resizeHandle: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 6)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        // 基准要在起手时定死：`translation` 是相对起点的累计量，
                        // 每帧拿当前宽度去减会指数放大。
                        let base = dragStartWidth ?? panel.inlineWidth
                        if dragStartWidth == nil { dragStartWidth = base }
                        panel.setInlineWidth(base - Double(v.translation.width))
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }
}
