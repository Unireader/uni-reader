import SwiftUI

/// Agent 面板的**内置形态**：与阅读区并排贴在阅读窗口右侧（展开时把 PDF 往左推）。
/// 展开 / 收起用阅读窗口工具栏上的「Agent 面板」开关（`ReaderWindowController.toggleAgentPanel`）。
///
/// 与咨询 AI 的 `AIInlineLayer` 同一套拆法（`InlinePanelPart`）：
/// `.lifecycle` 挂在阅读区的覆盖层上（只挂钩子，不显示东西）；`.panel` 放在 `ReaderPane.readerColumn` 的 HStack 里。
/// 两块面板可以同时开：从左到右是「阅读区 | Agent | 咨询 AI」。
struct AgentInlineLayer: View {
    /// 本阅读窗口（`TabsModel.windowID`）。
    let windowID: UUID
    /// 本窗口的工作区包；nil = 还没开工作区。
    let workspaceFolder: URL?
    let workspaceName: String
    var part: InlinePanelPart

    @ObservedObject private var panel = AgentPanelModel.shared

    @State private var chat: AgentChat?
    @State private var dragStartWidth: Double?

    private var isOpen: Bool { panel.isInlineOpen(windowID) }
    private var cwd: URL? { workspaceFolder?.deletingLastPathComponent() }

    var body: some View {
        if panel.mode == .inline, panel.enabled {
            switch part {
            case .lifecycle:
                Color.clear
                    .allowsHitTesting(false)
                    .onAppear { panel.seedInlineOpen(windowID) }
            case .panel:
                // 从右边滑入 / 滑出（动画挂在外壳 `InlinePanelsColumn` 上，阅读区不逐帧重排）
                if isOpen {
                    sidePanel
                        .transition(.move(edge: .trailing))
                        // 对话只在展开且有工作区时建；换了工作目录（本窗口切了工作区）换一份
                        .task(id: cwd) {
                            guard let cwd else { chat = nil; return }
                            chat = panel.chat(for: .inline(windowID), cwd: cwd)
                        }
                }
            }
        }
    }

    private var sidePanel: some View {
        Group {
            if let chat, workspaceFolder != nil {
                // 面板里不放收起按钮（用户 2026-09-19）：开合只走工具栏开关
                AgentChatView(chat: chat, workspaceName: workspaceName)
                .id(ObjectIdentifier(chat))   // 换了一份对话（切了工作区）→ 视图重建，onAppear 重新建会话
            } else if workspaceFolder == nil {
                ContentUnavailableView(L("No Workspace"), systemImage: "folder",
                                       description: Text(L("Open a workspace to talk to the agent about it.")))
            } else {
                ProgressView()
            }
        }
        .frame(width: panel.inlineWidth)
        .frame(maxHeight: .infinity)
        // 系统 Liquid Glass（与左侧边栏同一种材质，用户 2026-09-19：透明度对齐左侧边栏）+ 左侧分隔线；
        // PDF 放大后伸到面板底下的部分透得出来。铺进安全区（工具栏底下也是它）。
        // 🔴 玻璃底：文字 / 按钮一律显式 `.primary`，别用 `.secondary` / `.borderless`（红线）
        .background { Color.clear.glassEffect(.regular, in: Rectangle()).ignoresSafeArea() }
        .overlay(alignment: .leading) { Divider() }
        .overlay(alignment: .leading) { resizeHandle }
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 6)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        let base = dragStartWidth ?? panel.inlineWidth
                        if dragStartWidth == nil { dragStartWidth = base }
                        panel.setInlineWidth(base - Double(v.translation.width))
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }
}
