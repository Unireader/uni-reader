import SwiftUI

/// 图层色板 key → SwiftUI 颜色（复用 `NoteType.palette`；模型层只存 key，UI 换算集中于此）。
extension InkLayer {
    var uiColor: Color {
        let rgb = NoteType.paletteRGB(colorKey)
        return Color(red: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255)
    }
}

/// 图层管理面板（PenRack 弹出的 popover 内容）：图层相互独立、可各自显示/隐藏（可同时显示，
/// 也可只显示一层）、可拖拽排序、动态新建不设上限。结构仿 `NoteTypeManagerView`（列表 + sheet
/// 改名/改色 + alert 删除确认），额外多一层「当前作画图层」单选态（点行选中，同 `PenRackView.penSlot`
/// 的单选逻辑）。
struct LayerManagerView: View {
    @ObservedObject var session: DocSession

    @State private var draft: InkLayer?      // 非 nil = 改名/改色中（sheet）
    @State private var deleting: InkLayer?   // 非 nil = 删除确认中（alert）

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Layers")).font(.headline)

            List {
                ForEach(session.inkLayers) { layer in
                    row(layer)
                }
                .onMove(perform: move)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)   // List 自带的不透明系统背景会在弹层材质上抠出一块黑，去掉让它跟弹层融为一体
            .background(.clear)
            .frame(height: min(CGFloat(max(session.inkLayers.count, 1)) * 32 + 6, 220))

            Button { addLayer() } label: {
                Label(L("New Layer"), systemImage: "plus.circle.fill")
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 260)
        .sheet(item: $draft) { layer in
            LayerEditView(draft: layer, onDone: { saved in
                if let i = session.inkLayers.firstIndex(where: { $0.id == saved.id }) {
                    session.inkLayers[i] = saved
                }
                draft = nil
            }, onCancel: { draft = nil })
        }
        .alert(item: $deleting) { layer in
            let n = session.strokes.filter { $0.layerId == layer.id }.count
            return Alert(title: Text(String(format: L("Delete layer “%@”?"), layer.name)),
                        message: n > 0 ? Text(String(format: L("%d stroke(s) on this layer will be deleted too."), n)) : nil,
                        primaryButton: .destructive(Text(L("Delete"))) { delete(layer) },
                        secondaryButton: .cancel())
        }
    }

    private func row(_ layer: InkLayer) -> some View {
        let isActive = session.activeLayerID == layer.id
        return HStack(spacing: 8) {
            Button {
                if let i = session.inkLayers.firstIndex(where: { $0.id == layer.id }) {
                    session.inkLayers[i].visible.toggle()
                }
            } label: {
                Image(systemName: layer.visible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.visible ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.secondary))
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .help(layer.visible ? L("Hide Layer") : L("Show Layer"))

            Circle().fill(layer.uiColor).frame(width: 10, height: 10)
            Text(layer.name).lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(isActive ? Color.accentColor.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
        .listRowBackground(Color.clear)   // 圆角高亮画在内容自己的 background 上，避免 List 整行方块背景盖住圆角
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .onTapGesture { session.activeLayerID = layer.id }
        .contextMenu {
            Button { draft = layer } label: { Label(L("Rename"), systemImage: "pencil") }
            Button(role: .destructive) { deleting = layer } label: { Label(L("Delete"), systemImage: "trash") }
                .disabled(session.inkLayers.count <= 1)
        }
    }

    /// 拖拽排序：整体重排 `sortOrder`（等于新位置下标），落库对账走既有值快照对账。
    private func move(from: IndexSet, to: Int) {
        var layers = session.inkLayers
        layers.move(fromOffsets: from, toOffset: to)
        for i in layers.indices { layers[i].sortOrder = i }
        session.inkLayers = layers
    }

    /// 新建图层：不设上限，追加后立即设为当前作画图层（平板 `layerAdd` 请求走 `AppModel` 里同一个
    /// `InkLayer.next(after:)` 助手，命名/配色规则两处保持一致）。
    private func addLayer() {
        let layer = InkLayer.next(after: session.inkLayers)
        session.inkLayers.append(layer)
        session.activeLayerID = layer.id
    }

    /// 删除图层：连同其笔迹一起清除（不同于 `NoteType` 删除后笔记回落「通用」——
    /// 图层删除更贴近「这一整层内容都不要了」的直觉），并保证至少留一层可画。
    private func delete(_ layer: InkLayer) {
        session.strokes.removeAll { $0.layerId == layer.id }
        session.inkLayers.removeAll { $0.id == layer.id }
        if session.activeLayerID == layer.id { session.activeLayerID = session.inkLayers.first?.id }
    }
}

/// 单个图层的改名/改色：结构照抄 `NoteTypeEditView`，去掉图标网格（图层不需要图标）。
struct LayerEditView: View {
    @State var draft: InkLayer
    let onDone: (InkLayer) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Rename Layer")).font(.headline)

            TextField(L("Layer Name"), text: $draft.name)
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
        .frame(width: 300)
    }
}
