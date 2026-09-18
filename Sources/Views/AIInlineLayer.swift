import SwiftUI
import WebKit
import AppKit

/// 内置面板拆成的两半（咨询 AI 与 Agent 两块内置面板共用这个说法）。
enum InlinePanelPart {
    /// 收起时的气泡按钮：浮在阅读区右下角（`.overlay`）。
    case bubble
    /// 展开的侧栏：与阅读区并排，展开时把阅读区往左挤（2026-09-18 起，之前是盖在阅读区上）。
    case panel
}

/// **内置模式**：AI 面板不另开窗口，而是贴在阅读窗口右侧、与阅读区并排（展开时把 PDF 往左推）；
/// 收起时缩成右下角一枚气泡按钮（像网页上那种客服按钮），点一下展开。
///
/// 气泡那一半挂在 `PageStreamView` 这一层而**不是** `ReaderSurface` 里，是为了让它天然挡住阅读区的手势：
/// 阅读区那四个拖拽手势（拖选 / 落墨 / 框选移动 / 框选截图）都挂在 `ScrollView` 容器上，
/// 用 `.overlay` 加在**同一个视图**上的覆盖层（如草稿纸）挡不住它们——所以草稿纸才要在每个
/// gesture 里显式写 `session.openPadID == nil`。挂到上一层就成了普通的遮挡关系，一行门控都不用加。
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
    /// `.bubble` 浮在阅读区右下角（收起时那枚按钮，外加本宿主的生命周期钩子）；
    /// `.panel` 与阅读区**并排**放在 `ReaderPane.readerColumn` 的 HStack 里，展开时把阅读区往左挤。
    var part: InlinePanelPart
    @StateObject private var panel = AIPanelModel.shared

    @State private var dragStartWidth: Double?

    /// 内置模式下每扇阅读窗口都是宿主 —— 不再看是不是活跃窗口。
    private var hosts: Bool { panel.mode == .inline }

    /// 本窗口的面板是展开的还是收成气泡。
    private var isOpen: Bool { panel.isInlineOpen(session.windowID) }

    /// 该不该挂 webview：展开时才挂（收成气泡就不占着）。
    private var wantsHost: Bool { hosts && isOpen }

    private var host: AIHost { .inline(session.windowID) }

    /// 🔴 **body 里直接从模型查，不用 `@State` 缓存**：视图一被重建 `@State` 就归 nil，
    /// 会先渲一帧占位再切回网页 —— 那一下必然闪。创建仍只在 `onAppear`/`onChange` 里做。
    private var box: AIPageBox? { panel.existingPage(for: host) }

    var body: some View {
        if hosts {
            switch part {
            case .bubble:
                // 生命周期钩子挂在这一半：它在内置模式下始终在（面板那一半收起时整个不存在）
                ZStack {
                    if !isOpen {
                        bubble.transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .animation(.easeOut(duration: 0.18), value: isOpen)
                .onAppear {
                    panel.seedInlineOpen(session.windowID)   // 新窗口沿用「上次是展开还是收着」
                    if wantsHost { takePage() }
                }
                .onChange(of: wantsHost) { _, want in if want { takePage() } }
                .onChange(of: panel.currentID) { _, _ in if wantsHost { takePage() } }
                // 🔴 **刻意不在 onDisappear 放页面**：切到另一扇阅读窗口、或收成气泡，都不算这个宿主消失，
                // 放了就等于清掉那扇窗口正在进行的对话状态。真正的回收在 `ContentView.onDisappear`
                // （窗口关闭）里做。
            case .panel:
                // 🔴 不加展开动画：面板变宽的每一帧阅读区都要按新宽度重排（fit-width 缩放跟着变），逐帧动画会卡
                if isOpen { sidePanel }
            }
        }
    }

    /// 确保本窗口那一份页面已建好（body 靠 `existingPage` 读它）。
    /// ⚠️ **不在这里抢 `activeHost`**：多扇窗口的面板同时出现时，谁最后 `onAppear` 谁就赢，
    /// 那是错的。`activeHost` 由「哪扇窗口是 key」决定（`ContentView` 的 `onKeyChange`）。
    private func takePage() { _ = panel.page(for: host) }

    // MARK: - 气泡

    private var bubble: some View {
        Button { panel.setInlineOpen(true, for: session.windowID) } label: {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 46, height: 46)
                .background(.regularMaterial, in: Circle())
                .overlay { Circle().strokeBorder(.separator, lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(18)
        .help(L("Open AI Panel"))
    }

    // MARK: - 侧面板

    private var sidePanel: some View {
        VStack(spacing: 0) {
            header
            Divider()
            webArea
        }
        .frame(width: panel.inlineWidth)
        .frame(maxHeight: .infinity)
        // 与阅读区并排（不再盖在上面）：标准窗口底色 + 左侧分隔线，像系统的检查器栏那样
        .background(.background)
        .overlay(alignment: .leading) { Divider() }
        .overlay(alignment: .leading) { resizeHandle }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: panel.currentProvider?.icon ?? "bubble.left.and.text.bubble.right")
                .foregroundStyle(.secondary)
            // 🔴 挤压优先级要写明，否则窄面板下先被挤没的正是最该看见的那两样
            // （2026-09-01 用户报「内置模式下标题栏看不清链接的 pdf 和页」）：
            // 平台名可以缩（图标已经说明是哪家），**文档名与页码优先保住**——它们回答的是
            // 「这段对话绑在哪一页上」，是这条 header 存在的理由。
            Text(panel.currentProvider?.name ?? L("AI"))
                .font(.callout.weight(.medium))
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(0)
            if let ctx = panel.bindContext {
                // 🔴 **在 material 底上别用 `.secondary`**：会被画得极淡、几乎看不见
                // （2026-09-01 用户截图实测；与 2026-08-07 草稿纸工具条「非激活按钮几乎看不见」
                // 同一笔账）。层级差异靠**字号**表达就够了——这两样是「这段对话绑在哪一页」的答案，
                // 是整条 header 存在的理由，不该比背景亮不了多少。
                Text(ctx.docTitle)
                    .font(.caption).foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
                Text(String(format: L("p.%d"), ctx.page + 1))
                    .font(.caption.monospacedDigit()).foregroundStyle(.primary)
                    .fixedSize()          // 页码断不得，一断整条都白看
            }
            Spacer(minLength: 4)
            modeMenu
            headerButton("house", L("New Chat")) { panel.goHome() }
            headerButton("macwindow", L("Open as Separate Window")) {
                panel.setMode(.window)
                AIPanelWindowController.show()   // 迁移后浮窗归 AppKit，不再走 SwiftUI 的 openWindow
            }
            headerButton("chevron.right", L("Collapse")) { panel.setInlineOpen(false, for: session.windowID) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
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
                // material 底上一律显式 `.primary`（红线：`.secondary` 会被画得几乎看不见）
                Image(systemName: "slider.horizontal.3")
                    .imageScale(.medium)
                    .foregroundStyle(.primary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Mode for new chats"))
        }
    }

    /// `.plain` 在 material 底上会把图标画得极淡（2026-08-07 草稿纸工具条踩过一次），
    /// 所以显式染 `.primary` 并给足命中区。
    private func headerButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .imageScale(.medium)
                .foregroundStyle(.primary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
