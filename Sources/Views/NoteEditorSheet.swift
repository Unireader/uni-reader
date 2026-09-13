import SwiftUI

/// 文字注解编辑器（新建 / 编辑复用）。上方展示被注解的原文（只读引文），下方是 Markdown 编辑器
/// （`MarkdownNoteEditor`，2026-09-13 起；正文存的就是 Markdown 源）。
/// 标题行右侧挂类型选择（Menu：通用 + 工作区自定义类型，底部「管理类型…」弹管理面板）。
/// 走标准 `.sheet` 呈现（原生模态，无浮层 hack）；⌘回车保存、Esc 取消。
struct NoteEditorSheet: View {
    let quote: String
    let saveTitle: String
    /// 编辑器的文档 id（引擎按它分撤销栈）：编辑传笔记 id，新建传草稿 id。
    let documentId: String
    let noteTypes: [NoteType]                 // 工作区自定义类型（不含通用）
    let usageCount: (UUID) -> Int             // 某类型被多少条笔记引用（删除确认用）
    let onSave: (String, UUID?, NoteDisplay) -> Void   // 批注文本 + 类型（nil=通用）+ 展开方式
    let onDelete: (() -> Void)?               // 编辑已存在注解时给「删除」入口（新建草稿为 nil）
    let onChangeTypes: ([NoteType]) -> Void   // 管理面板增删改后整体回写
    let onCancel: () -> Void

    @State private var text: String
    @State private var typeId: UUID?
    @State private var display: NoteDisplay
    @State private var managing = false

    init(quote: String, initialText: String, initialTypeId: UUID?,
         initialDisplay: NoteDisplay = .tap,
         documentId: String = "note-draft",
         noteTypes: [NoteType], usageCount: @escaping (UUID) -> Int,
         saveTitle: String = L("Save"),
         onSave: @escaping (String, UUID?, NoteDisplay) -> Void,
         onDelete: (() -> Void)? = nil,
         onChangeTypes: @escaping ([NoteType]) -> Void,
         onCancel: @escaping () -> Void) {
        self.quote = quote
        self.saveTitle = saveTitle
        self.documentId = documentId
        self.noteTypes = noteTypes
        self.usageCount = usageCount
        self.onSave = onSave
        self.onDelete = onDelete
        self.onChangeTypes = onChangeTypes
        self.onCancel = onCancel
        _text = State(initialValue: initialText)
        _typeId = State(initialValue: initialTypeId)
        _display = State(initialValue: initialDisplay)
    }

    /// 当前选中类型（nil/未知 id → 通用）。
    private var current: NoteType { NoteType.resolve(typeId, in: noteTypes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Note")).font(.headline)
                Spacer()
                typePicker
            }

            if !quote.isEmpty {
                Text(quote)
                    .font(.callout).italic().foregroundStyle(.secondary)
                    .lineLimit(4).multilineTextAlignment(.leading)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }

            MarkdownNoteEditor(text: $text, documentId: documentId, placeholder: L("Write a note… (Markdown)"))
                .frame(width: 380, height: 170)

            // 展开方式（每条笔记自己的属性，三端同步）：这条笔记的正文在页面上怎么露出来。
            HStack(spacing: 8) {
                Text(L("Show note")).font(.callout).foregroundStyle(.secondary)
                Picker(L("Show note"), selection: $display) {
                    Text(L("On tap")).tag(NoteDisplay.tap)
                    Text(L("On hover")).tag(NoteDisplay.hover)
                    Text(L("Always")).tag(NoteDisplay.always)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack {
                if let onDelete {
                    Button(L("Delete"), role: .destructive) { onDelete() }
                }
                Spacer()
                Button(L("Cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                // ⌘↩ 保存（不是裸回车：编辑框里回车是换行）
                Button(saveTitle) { onSave(text, typeId, display) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 420)
        .sheet(isPresented: $managing) {
            NoteTypeManagerView(noteTypes: noteTypes, usageCount: usageCount,
                                onChange: { types in
                                    onChangeTypes(types)
                                    if let id = typeId, !types.contains(where: { $0.id == id }) { typeId = nil }
                                },
                                onClose: { managing = false })
        }
    }

    /// 类型选择：通用恒为第一项；label 显示当前类型色点 + 名称。
    private var typePicker: some View {
        Menu {
            Button { typeId = nil } label: {
                Label(L("General"), systemImage: NoteType.general.iconName)
            }
            ForEach(noteTypes) { t in
                Button { typeId = t.id } label: {
                    Label(t.name, systemImage: t.icon)
                }
            }
            Divider()
            Button(L("Manage Types…")) { managing = true }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(current.uiColor).frame(width: 10, height: 10)
                Text(current.id == NoteType.generalID ? L("General") : current.name).font(.callout)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }
}
