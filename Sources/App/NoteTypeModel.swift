import Foundation

/// 文字笔记类型（工作区级自定义）：名称 + 固定色板 key + SF Symbol 图标。
/// 落工作区 `meta(key='note_types')` 的 JSON 数组（snake_case 键，跨平台可读）；
/// 笔记侧 payload 存 `type_id`（见 TextNoteModel）。「通用」是内置兜底（generalID），
/// 不落库、不可编辑/删除；笔记 typeId 为 nil 或指向不存在类型时一律按通用渲染。
struct NoteType: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var name: String
    var colorKey: String    // 色板 key，如 "red"
    var iconName: String    // SF Symbol 名，如 "exclamationmark.triangle"

    enum CodingKeys: String, CodingKey {
        case id, name
        case colorKey = "color_key"
        case iconName = "icon_name"
    }
}

extension NoteType {
    /// 内置「通用」类型的固定 id（全 0）。显示名不走模型，UI 层用 `L("General")`。
    static let generalID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static let general = NoteType(id: generalID, name: "", colorKey: "gray", iconName: "note.text")

    /// 固定色板（0~255 RGB）。新建类型默认取第一个（red）。
    static let palette: [(key: String, r: Double, g: Double, b: Double)] = [
        ("red",    255,  59,  48),
        ("orange", 255, 149,   0),
        ("yellow", 255, 204,   0),
        ("green",   52, 199,  89),
        ("blue",     0, 122, 255),
        ("purple", 175,  82, 222),
        ("pink",   255,  45,  85),
        ("gray",   142, 142, 147),
    ]
    /// 色板查色：未知 key（手改坏/跨端未同步）回落 gray。
    static func paletteRGB(_ key: String) -> (r: Double, g: Double, b: Double) {
        palette.first { $0.key == key }.map { ($0.r, $0.g, $0.b) } ?? (142, 142, 147)
    }

    /// 图标候选（SF Symbol）。新建类型默认取第一个。
    static let iconCandidates: [String] = [
        "note.text", "exclamationmark.triangle", "questionmark.circle", "bookmark",
        "flag", "star", "play.rectangle", "lightbulb",
        "flame", "checkmark.circle", "xmark.octagon", "quote.bubble",
        "book", "tag", "pencil.line", "eye",
    ]
    /// 合法化图标名：候选集外一律回落通用图标（SF Symbol 名非法会渲染空白）。
    static func icon(_ raw: String) -> String { iconCandidates.contains(raw) ? raw : "note.text" }

    /// 笔记类型解析：nil / 未知 id / 通用 id → 通用；否则取工作区类型。
    static func resolve(_ typeId: UUID?, in types: [NoteType]) -> NoteType {
        guard let typeId, typeId != generalID,
              let t = types.first(where: { $0.id == typeId }) else { return general }
        return t
    }

    /// 合法化后的实例图标（模型的 iconName 可能被手改坏）。
    var icon: String { NoteType.icon(iconName) }
}

/// 侧边栏笔记筛选（仅内存，不落库）：全部 / 仅某类型（nil = 通用）。
enum NoteTypeFilter: Equatable {
    case all
    case only(UUID?)
}
