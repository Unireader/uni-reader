import SwiftUI

/// 类型色板 key → SwiftUI 颜色（模型层只存 RGB，UI 换算集中于此；图钉/侧边栏同用）。
extension NoteType {
    var uiColor: Color {
        let rgb = NoteType.paletteRGB(colorKey)
        return Color(red: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255)
    }
}

/// 笔记类型管理面板（编辑器内「管理类型…」弹出）：列表 + 新建/编辑/删除。
/// 「通用」内置兜底不在列、不可改。改动经 onChange 整体回写（调用方负责落库 + 被删类型的笔记回落）。
struct NoteTypeManagerView: View {
    let noteTypes: [NoteType]
    let usageCount: (UUID) -> Int
    let onChange: ([NoteType]) -> Void
    let onClose: () -> Void

    @State private var draft: NoteType?      // 非 nil = 新建/编辑中（sheet）
    @State private var deleting: NoteType?   // 非 nil = 删除确认中（alert）

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Manage Types")).font(.headline)

            if noteTypes.isEmpty {
                Text(L("No custom types yet.")).foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(noteTypes) { t in
                    HStack(spacing: 8) {
                        Circle().fill(t.uiColor).frame(width: 10, height: 10)
                        Image(systemName: t.icon).frame(width: 16)
                        Text(t.name).lineLimit(1)
                        Spacer()
                        Button { draft = t } label: { Image(systemName: "pencil") }
                            .buttonStyle(.plain).help(L("Edit Type"))
                        Button { deleting = t } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).help(L("Delete"))
                    }
                }
            }

            HStack {
                Button(L("New Type")) {
                    draft = NoteType(name: "", colorKey: NoteType.palette[0].key,
                                     iconName: NoteType.iconCandidates[0])
                }
                Spacer()
                Button(L("Done")) { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340)
        .sheet(item: $draft) { t in
            NoteTypeEditView(draft: t, isNew: !noteTypes.contains(t),
                             onDone: { saved in
                                 var types = noteTypes
                                 if let i = types.firstIndex(where: { $0.id == saved.id }) {
                                     types[i] = saved
                                 } else {
                                     types.append(saved)
                                 }
                                 onChange(types)
                                 draft = nil
                             },
                             onCancel: { draft = nil })
        }
        .alert(item: $deleting) { t in
            let n = usageCount(t.id)
            return Alert(title: Text(String(format: L("Delete type “%@”?"), t.name)),
                         message: n > 0 ? Text(String(format: L("%d note(s) will revert to General."), n)) : nil,
                         primaryButton: .destructive(Text(L("Delete"))) {
                             onChange(noteTypes.filter { $0.id != t.id })
                         },
                         secondaryButton: .cancel())
        }
    }
}

/// 单个类型的新建/编辑：名称 + 固定色板 + 图标网格。名称为空禁存。
struct NoteTypeEditView: View {
    @State var draft: NoteType
    let isNew: Bool
    let onDone: (NoteType) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? L("New Type") : L("Edit Type")).font(.headline)

            TextField(L("Type Name"), text: $draft.name)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                ForEach(NoteType.palette, id: \.key) { sw in
                    Circle()
                        .fill(Color(red: sw.r / 255, green: sw.g / 255, blue: sw.b / 255))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.primary.opacity(0.6),
                                                 lineWidth: draft.colorKey == sw.key ? 2 : 0))
                        .onTapGesture { draft.colorKey = sw.key }
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28)), count: 8), spacing: 8) {
                ForEach(NoteType.iconCandidates, id: \.self) { name in
                    Image(systemName: name)
                        .frame(width: 28, height: 28)
                        .background(draft.iconName == name ? Color.accentColor.opacity(0.25) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .onTapGesture { draft.iconName = name }
                }
            }

            HStack {
                Spacer()
                Button(L("Cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Save")) { onDone(draft) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
