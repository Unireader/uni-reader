import SwiftUI

/// Agent 面板的**内置形态**：与阅读区并排贴在阅读窗口右侧（展开时把 PDF 往左推），收起时是一枚气泡按钮。
///
/// 与咨询 AI 的 `AIInlineLayer` 同一套拆法（`InlinePanelPart`）：
/// `.bubble` 浮在阅读区右下角；`.panel` 放在 `ReaderPane.readerColumn` 的 HStack 里。
/// 两块面板可以同时开：从左到右是「阅读区 | Agent | 咨询 AI」；两枚气泡上下错开。
struct AgentInlineLayer: View {
    /// 本阅读窗口（`TabsModel.windowID`）。
    let windowID: UUID
    /// 本窗口的工作区包；nil = 还没开工作区。
    let workspaceFolder: URL?
    let workspaceName: String
    var part: InlinePanelPart

    @ObservedObject private var panel = AgentPanelModel.shared
    @ObservedObject private var consult = AIPanelModel.shared

    @State private var chat: AgentChat?
    @State private var dragStartWidth: Double?

    private var isOpen: Bool { panel.isInlineOpen(windowID) }
    private var cwd: URL? { workspaceFolder?.deletingLastPathComponent() }

    /// 咨询面板的气泡也在右下角 → Agent 的气泡摞在它上面。
    private var bubbleLift: CGFloat {
        consult.mode == .inline && !consult.isInlineOpen(windowID) ? 46 + 12 : 0
    }

    var body: some View {
        if panel.mode == .inline {
            switch part {
            case .bubble:
                ZStack {
                    if !isOpen {
                        bubble.padding(.bottom, bubbleLift)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .animation(.easeOut(duration: 0.18), value: isOpen)
                .onAppear { panel.seedInlineOpen(windowID) }
            case .panel:
                // 🔴 不加展开动画：面板变宽的每一帧阅读区都要按新宽度重排，逐帧动画会卡
                if isOpen {
                    sidePanel
                        // 对话只在展开且有工作区时建；换了工作目录（本窗口切了工作区）换一份
                        .task(id: cwd) {
                            guard let cwd else { chat = nil; return }
                            chat = panel.chat(for: .inline(windowID), cwd: cwd)
                        }
                }
            }
        }
    }

    private var bubble: some View {
        Button { panel.setInlineOpen(true, for: windowID) } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 46, height: 46)
                .background(.regularMaterial, in: Circle())
                .overlay { Circle().strokeBorder(.separator, lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(18)
        .help(L("Open Agent Panel"))
    }

    private var sidePanel: some View {
        Group {
            if let chat, workspaceFolder != nil {
                AgentChatView(chat: chat, workspaceName: workspaceName) {
                    Button { panel.setInlineOpen(false, for: windowID) } label: {
                        Label(L("Collapse"), systemImage: "sidebar.trailing")
                    }
                    .help(L("Collapse"))
                }
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
        // 与阅读区并排：标准窗口底色 + 左侧分隔线（像系统的检查器栏）
        .background(.background)
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
