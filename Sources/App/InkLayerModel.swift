import Foundation

/// 一个笔迹图层：作用域=整篇文档（横跨所有页），相互独立、可各自显示/隐藏。
/// 落库 `ink_layer` 表（挂逻辑文档，schema v7）；`colorKey` 复用 `NoteType.palette` 色板，
/// 仅作图层列表色点标识，与笔画本身的墨色（`InkStroke.color`）无关。
struct InkLayer: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var name: String
    var colorKey: String
    var sortOrder: Int
    var visible: Bool = true
}

extension InkLayer {
    /// 迁移前笔迹的隐式归属层：旧版本落库的 `InkStroke` payload 没有 `layerId` 键，
    /// 解码时兜底到这个固定 id；文档首次在新版本打开时会自动补建一条同 id 的「图层 1」。
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// 新建图层的默认色：按已有图层数量轮换取色板，避免总落在同一色。
    static func rotatingColorKey(existingCount: Int) -> String {
        let palette = NoteType.palette
        guard !palette.isEmpty else { return "gray" }
        return palette[existingCount % palette.count].key
    }

    /// 生成「下一个」新图层（Mac 本机新建 / 平板 `layerAdd` 请求共用）：序号紧接现有最大 sortOrder，
    /// 颜色轮换取色板，命名走 `L("Layer %d")`。默认可见。
    static func next(after existing: [InkLayer]) -> InkLayer {
        let n = existing.count
        return InkLayer(name: String(format: L("Layer %d"), n + 1),
                        colorKey: rotatingColorKey(existingCount: n),
                        sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1, visible: true)
    }
}
