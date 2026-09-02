import SwiftUI

/// 书签命名框（新建 / 改名共用）。名字**必填**（用户 2026-09-02 拍板），所以确定键在空白时是灰的。
///
/// 输入框**不预填**名字，只把「所在章节 · 第 N 页」放进 placeholder 当提示——预填等于替用户
/// 按了确定，与「必须输入」相悖。改名那一路例外：初值就是原名（不然等于逼人重打一遍）。
struct BookmarkNameSheet: View {
    let draft: BookmarkDraft
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var title: String
    @FocusState private var focused: Bool

    init(draft: BookmarkDraft, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.draft = draft
        self.onSave = onSave
        self.onCancel = onCancel
        _title = State(initialValue: draft.currentTitle)
    }

    private var isNew: Bool { draft.editing == nil }
    private var canSave: Bool { Bookmark.validTitle(title) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? L("Add Bookmark") : L("Rename Bookmark"))
                .font(.headline)

            // 落点回显：加在哪一页（页码是 1 基，与目录/工具栏一致）。层级差异用字号表达，颜色仍是 .primary
            // ——material 上的 .secondary 会被系统画得极淡（红线，已踩两次）。
            Text(draft.hint).font(.caption).foregroundStyle(.primary)

            TextField(L("Bookmark name"), text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .focused($focused)
                .onSubmit { if canSave { onSave(title) } }

            HStack {
                Spacer()
                Button(L("Cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? L("Add") : L("Save")) { onSave(title) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { focused = true }
    }
}
