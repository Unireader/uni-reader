import SwiftUI

/// 编辑器保存时交出去的整包：正文 + 类型（nil=通用）+ 展开方式 + 显式铺色（nil=按类型色）+ 画法。
struct NoteEditorOutput {
    var text: String
    var typeId: UUID?
    var display: NoteDisplay
    var color: InkColor?
    var style: HighlightStyle
}

/// 文字注解编辑器（新建 / 编辑复用）。上方展示被注解的原文（只读引文），下方是 Markdown 编辑器
/// （`MarkdownNoteEditor`，2026-09-13 起；正文存的就是 Markdown 源）。
/// 标题行右侧挂类型选择（Menu：通用 + 工作区自定义类型，底部「管理类型…」弹管理面板）。
/// 选区注解多一行「标记」：调色板色点（第一枚 = 跟随类型色）+ 铺色/画线/画框三选一（2026-09-16）。
/// 走标准 `.sheet` 呈现（原生模态，无浮层 hack）；⌘回车保存、Esc 取消。
struct NoteEditorSheet: View {
    let quote: String
    let saveTitle: String
    /// 编辑器的文档 id（引擎按它分撤销栈）：编辑传笔记 id，新建传草稿 id。
    let documentId: String
    let noteTypes: [NoteType]                 // 工作区自定义类型（不含通用）
    let usageCount: (UUID) -> Int             // 某类型被多少条笔记引用（删除确认用）
    let hasRects: Bool                        // 选区注解才有可画的东西；点注解不给「标记」那一行
    let onSave: (NoteEditorOutput) -> Void
    let onDelete: (() -> Void)?               // 编辑已存在注解时给「删除」入口（新建草稿为 nil）
    let onChangeTypes: ([NoteType]) -> Void   // 管理面板增删改后整体回写
    let onCancel: () -> Void

    @State private var text: String
    @State private var typeId: UUID?
    @State private var display: NoteDisplay
    @State private var color: InkColor?
    @State private var style: HighlightStyle
    @State private var managing = false

    init(quote: String, initialText: String, initialTypeId: UUID?,
         initialDisplay: NoteDisplay = .tap,
         initialColor: InkColor? = nil,
         initialStyle: HighlightStyle = .fill,
         hasRects: Bool = true,
         documentId: String = "note-draft",
         noteTypes: [NoteType], usageCount: @escaping (UUID) -> Int,
         saveTitle: String = L("Save"),
         onSave: @escaping (NoteEditorOutput) -> Void,
         onDelete: (() -> Void)? = nil,
         onChangeTypes: @escaping ([NoteType]) -> Void,
         onCancel: @escaping () -> Void) {
        self.quote = quote
        self.saveTitle = saveTitle
        self.documentId = documentId
        self.noteTypes = noteTypes
        self.usageCount = usageCount
        self.hasRects = hasRects
        self.onSave = onSave
        self.onDelete = onDelete
        self.onChangeTypes = onChangeTypes
        self.onCancel = onCancel
        _text = State(initialValue: initialText)
        _typeId = State(initialValue: initialTypeId)
        _display = State(initialValue: initialDisplay)
        _color = State(initialValue: initialColor)
        _style = State(initialValue: initialStyle)
    }

    private var output: NoteEditorOutput {
        NoteEditorOutput(text: text, typeId: typeId, display: display, color: color, style: style)
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

            // 标记（选区注解才有）：选中文字上铺什么颜色、怎么画。色点第一枚 = 跟随类型色（nil），
            // 其余是高亮调色板那四色——与高亮气泡里的换色色点同款扁平色点，当前项描一圈。
            if hasRects {
                HStack(spacing: 8) {
                    Text(L("Mark")).font(.callout).foregroundStyle(.secondary)
                    colorDot(nil, fill: current.uiColor, help: L("Type color"))
                    ForEach(Array(Highlight.palette.enumerated()), id: \.offset) { _, item in
                        colorDot(item.color, fill: Color(nsColor: item.color.nsColor), help: L(item.name))
                    }
                    Spacer()
                    Picker(L("Mark"), selection: $style) {
                        ForEach(HighlightStyle.allCases, id: \.self) { s in
                            Image(systemName: s.iconName).tag(s).help(s.title)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

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
                Button(saveTitle) { onSave(output) }
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

    /// 一枚铺色色点：`value` 是它代表的显式颜色（nil = 跟随类型色）；当前选中的描一圈。
    private func colorDot(_ value: InkColor?, fill: Color, help: String) -> some View {
        Circle()
            .fill(fill)
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(Color.primary.opacity(0.6), lineWidth: color == value ? 2 : 0))
            .contentShape(Circle())
            .onTapGesture { color = value }
            .help(help)
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
