import SwiftUI

/// 新建标签时的选文档弹窗（标签栏「+」与 ⌘T 共用，挂在 `.popover` 里）。
/// 只列本工作区书库里的文档，不导入新文件；选中交给 `TabsModel.open`（已开着的就切过去）。
///
/// 样张：`spike/doc-picker-look.swift`（真 `NSPopover` 里渲染出图）。
/// 🔴 弹窗底是系统材质：文字一律 `Color.primary`（次要信息靠字号 + 不透明度区分），列表必须
/// `scrollContentBackground(.hidden)`，否则整块不透明底色盖在材质上（2026-09-17 用户嫌丑的第一条）。
struct DocPickerView: View {
    /// 两个挂载点（「+」按钮 / 标签栏不显示时的阅读区底部）共用的装配。
    @MainActor
    static func forTabs(_ tabs: TabsModel, workspace: WorkspaceManager) -> DocPickerView {
        DocPickerView(documents: workspace.documents,
                      openIDs: Set(tabs.tabs.compactMap(\.docID))) { id in
            tabs.docPickerPresented = false
            tabs.open(id)
        }
    }

    let documents: [LibDocument]
    let openIDs: Set<String>
    let onPick: (String) -> Void

    @State private var query = ""
    @State private var selection: String?
    @FocusState private var fieldFocused: Bool

    private static let width: CGFloat = 420
    private static let rowHeight: CGFloat = 44
    private static let maxVisibleRows = 7

    private var filtered: [LibDocument] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let sorted = documents.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
        guard !q.isEmpty else { return sorted }
        return sorted.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.group.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            results
        }
        .frame(width: Self.width)
        .onAppear {
            selection = filtered.first?.id
            fieldFocused = true
        }
        .onChange(of: query) { _, _ in selection = filtered.first?.id }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
            TextField(L("Search Documents"), text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .onSubmit(pickSelection)
                // 焦点留在搜索框里也能用方向键挑，不必先点列表
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var results: some View {
        let list = filtered
        if list.isEmpty {
            Text(documents.isEmpty ? L("No documents in this workspace.") : L("No matching documents."))
                .font(.callout)
                .foregroundStyle(Color.primary.opacity(0.7))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            ScrollViewReader { proxy in
                List(list, selection: $selection) { doc in
                    row(doc)
                        .tag(doc.id)
                        .id(doc.id)
                        .listRowSeparator(.hidden)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(doc.id) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                // 接鼠标时占位式滚动条会在右侧预留一条槽，选中条右边距比左边宽一截（样张实测）；
                // 滚轮与方向键照样能滚
                .scrollIndicators(.never)
                .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
            }
            // 高度随条数走：两三篇时不留一大截空白，多了封顶滚动
            .frame(height: CGFloat(min(list.count, Self.maxVisibleRows)) * Self.rowHeight + 16)
        }
    }

    private func row(_ doc: LibDocument) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .font(.title2)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail(doc))
                    .font(.caption)
                    .opacity(0.7)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.primary)
        .frame(height: Self.rowHeight - 8)
    }

    /// 第二行固定有内容（页数总在），行高才一致：分组 · 页数 · 已打开。
    private func detail(_ doc: LibDocument) -> String {
        var parts: [String] = []
        if !doc.group.isEmpty { parts.append(doc.group) }
        parts.append(String(format: L("%d pages"), doc.pageCount))
        if openIDs.contains(doc.id) { parts.append(L("Already Open")) }
        return parts.joined(separator: " · ")
    }

    private func move(_ step: Int) {
        let ids = filtered.map(\.id)
        guard !ids.isEmpty else { return }
        let i = selection.flatMap { ids.firstIndex(of: $0) } ?? -step
        selection = ids[min(max(i + step, 0), ids.count - 1)]
    }

    private func pickSelection() {
        if let id = selection ?? filtered.first?.id { onPick(id) }
    }
}
