import SwiftUI
import WebKit
import AppKit

/// **内置模式**：AI 面板不另开窗口，而是贴在阅读窗口右侧；收起时缩成右下角一枚气泡按钮
/// （像网页上那种客服按钮），点一下展开。
///
/// 挂在 `PageStreamView` 这一层而**不是** `ReaderSurface` 里，是为了让它天然挡住阅读区的手势：
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
    @StateObject private var panel = AIPanelModel.shared
    @Environment(\.openWindow) private var openWindow

    @State private var dragStartWidth: Double?

    /// 内置模式下每扇阅读窗口都是宿主 —— 不再看是不是活跃窗口。
    private var hosts: Bool { panel.mode == .inline }

    /// 本窗口的面板是展开的还是收成气泡。
    private var isOpen: Bool { panel.isInlineOpen(session.id) }

    /// 该不该挂 webview：展开时才挂（收成气泡就不占着）。
    private var wantsHost: Bool { hosts && isOpen }

    private var host: AIHost { .inline(session.id) }

    /// 🔴 **body 里直接从模型查，不用 `@State` 缓存**：视图一被重建 `@State` 就归 nil，
    /// 会先渲一帧占位再切回网页 —— 那一下必然闪。创建仍只在 `onAppear`/`onChange` 里做。
    private var box: AIPageBox? { panel.existingPage(for: host) }

    var body: some View {
        if hosts {
            ZStack(alignment: .bottomTrailing) {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if isOpen {
                        sidePanel.transition(.move(edge: .trailing))
                    }
                }
                if !isOpen {
                    bubble.transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: isOpen)
            .onAppear {
                panel.seedInlineOpen(session.id)   // 新窗口沿用「上次是展开还是收着」
                if wantsHost { takePage() }
            }
            .onChange(of: wantsHost) { _, want in if want { takePage() } }
            .onChange(of: panel.currentID) { _, _ in if wantsHost { takePage() } }
            // 🔴 **刻意不在 onDisappear 放页面**：切到另一扇阅读窗口、或收成气泡，都不算这个宿主消失，
            // 放了就等于清掉那扇窗口正在进行的对话状态。真正的回收在 `ContentView.onDisappear`
            // （窗口关闭）里做。
        }
    }

    /// 确保本窗口那一份页面已建好（body 靠 `existingPage` 读它）。
    /// ⚠️ **不在这里抢 `activeHost`**：多扇窗口的面板同时出现时，谁最后 `onAppear` 谁就赢，
    /// 那是错的。`activeHost` 由「哪扇窗口是 key」决定（`ContentView` 的 `onKeyChange`）。
    private func takePage() { _ = panel.page(for: host) }

    // MARK: - 气泡

    private var bubble: some View {
        Button { panel.setInlineOpen(true, for: session.id) } label: {
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
        .background(.regularMaterial)
        .overlay(alignment: .leading) { resizeHandle }
        .shadow(color: .black.opacity(0.18), radius: 10, x: -3)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: panel.currentProvider?.icon ?? "bubble.left.and.text.bubble.right")
                .foregroundStyle(.secondary)
            Text(panel.currentProvider?.name ?? L("AI"))
                .font(.callout.weight(.medium)).lineLimit(1)
            if let ctx = panel.bindContext {
                Text(ctx.docTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(String(format: L("p.%d"), ctx.page + 1))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            headerButton("house", L("New Chat")) { panel.goHome() }
            headerButton("macwindow", L("Open as Separate Window")) {
                panel.setMode(.window)
                openWindow(id: AIPanelModel.windowID)
            }
            headerButton("chevron.right", L("Collapse")) { panel.setInlineOpen(false, for: session.id) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
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
