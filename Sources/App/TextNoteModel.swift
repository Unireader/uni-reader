import CoreGraphics
import Foundation

/// 一条文字注解（便签）。锚定到某页的一段选区：
///  · `anchor` = 选区行框的归一化包围盒（0~1，页局部，左上原点）——与手写笔迹同约定，渲染高亮/图钉直接用。
///  · `rects`  = 逐行归一化框（页局部），用于在页面上精确高亮被注解的文字（feat 2）。
///  · `quote`  = 被选中的原文（可能跨页；注解锚到选区起始页，原文完整保留）。
///  · `text`   = 用户写的批注内容。
/// 落 `note` 表 kind=0（挂逻辑文档，全版本共用；payload=JSON 跨平台可读）。
/// 一条笔记的来源。目前只有一种：从 AI 面板里选中一段回答回填过来的。
///
/// 有了它，笔记能**点回原对话**，也能筛出「哪些笔记是 AI 来的」。
/// 旧 payload 没有这个键 → nil，**零迁移**（与 `type_id` 完全同一个先例）。
struct NoteSource: Equatable {
    static let aiKind = "ai"
    /// 外部 Agent 经 MCP 写进来的（`MCP-PLAN.md §9.2`）：`provider` = 客户端名（如 claude-code），`url` 空串。
    static let agentKind = "agent"

    var kind: String            // "ai"（AI 面板回填）/ "agent"（MCP 写入）
    var provider: String        // AIProvider.id / MCP 客户端名
    var url: String             // 那次对话的唯一链接；agent 来源为空串
    var threadId: UUID?         // 对应的 AIThread（note kind=1）；解绑过就可能为 nil
    var at: Date

    var isAI: Bool { kind == Self.aiKind }
    var isAgent: Bool { kind == Self.agentKind }
}

/// 一条文字笔记在页面上**怎么展开正文**（每条笔记自己的属性，三端同款语义）。
///
/// 线上是 u8（`notes`/`textNote`，见 `PROTOCOL.md`）、payload 里是同名小写串；
/// 旧 payload 无 `display` 键 → `.tap`，**零迁移**（与 `type_id`/`source` 同一个先例）。
/// 🔴 只许尾部追加新态：安卓/网页按数值解码，中间插一个会把老数据整体错位。
enum NoteDisplay: String, Codable, CaseIterable {
    case tap        // 点图钉展开/收起气泡（默认；气泡右上角铅笔进编辑器）
    case hover      // 指针（Mac）/ 笔（平板）悬停在图钉上才展开；手指没有悬停 → 当 tap 用
    case always     // 始终展开

    var wire: UInt8 {
        switch self {
        case .tap: return 0
        case .hover: return 1
        case .always: return 2
        }
    }

    /// 线上 u8 → 模式；未知值（跨端版本错位/手改坏）一律回落 `.tap`（与解析不出 payload 同口径）。
    static func fromWire(_ v: UInt8) -> NoteDisplay {
        switch v {
        case 1: return .hover
        case 2: return .always
        default: return .tap
        }
    }
}

/// 用户手动摆过的笔记卡片（页面上展开的气泡；文字笔记与图片笔记共用，2026-09-16）。定义放这里同 `HighlightStyle`：spike 都编这个文件。
///
///  · `dx` / `dy` = 卡片**左上角**相对**图钉中心**的偏移。摆过就一定有（任何一次拖动 / 改大小都会把位置钉住，
///    否则改宽时自动规则会把卡片从图钉右边翻到左边）。
///  · `w` = 宽；`h` = **高度上限**（内容比它短就收到内容高，比它长就在卡片里滚动——用户 2026-09-16 定的语义）。
///    nil = 这一维没动过，照旧按自动规则（宽按内容收窄、高按行数上限）。
///  · 单位 = **固定尺寸口径下的点**；跟页缩放口径按 `NoteBubble.Metrics.unit`（页宽 ÷ 参考页宽）换算，
///    两种口径切换时卡片与页面的相对大小不跳。
/// payload 键 `card: {dx, dy, w?, h?}`；旧 payload 无此键 → nil（没摆过），零迁移。网页 / 安卓暂不认，按自动规则画。
struct NoteCard: Equatable, Codable {
    var dx: Double
    var dy: Double
    var w: Double?
    var h: Double?
}

/// 按下卡片的哪儿决定拖动做什么：四边 / 四角改大小，其余地方移动。
enum NoteCardZone: Equatable {
    case move, top, bottom, leading, trailing, topLeading, topTrailing, bottomLeading, bottomTrailing

    /// 边的命中宽度 / 角的命中边长（屏幕点，不随缩放变——手要瞄得准的是屏幕上的那几个点）。
    static let edge: CGFloat = 5
    static let corner: CGFloat = 12

    /// `p` = 卡片内坐标（左上原点），`size` = 卡片尺寸。
    static func at(_ p: CGPoint, size: CGSize) -> NoteCardZone {
        let nearL = p.x <= corner, nearR = p.x >= size.width - corner
        let nearT = p.y <= corner, nearB = p.y >= size.height - corner
        if nearT && nearL { return .topLeading }
        if nearT && nearR { return .topTrailing }
        if nearB && nearL { return .bottomLeading }
        if nearB && nearR { return .bottomTrailing }
        if p.x <= edge { return .leading }
        if p.x >= size.width - edge { return .trailing }
        if p.y <= edge { return .top }
        if p.y >= size.height - edge { return .bottom }
        return .move
    }

    /// 横向：-1 拖左边、+1 拖右边、0 不改宽。
    var horizontal: Int {
        switch self {
        case .leading, .topLeading, .bottomLeading: return -1
        case .trailing, .topTrailing, .bottomTrailing: return 1
        default: return 0
        }
    }

    /// 纵向：-1 拖上边、+1 拖下边、0 不改高。
    var vertical: Int {
        switch self {
        case .top, .topLeading, .topTrailing: return -1
        case .bottom, .bottomLeading, .bottomTrailing: return 1
        default: return 0
        }
    }
}

/// 卡片**不许盖住自己的图钉**（用户 2026-09-16）。图钉周围留一块禁区（图钉半径 + 间隙的方块），卡片压进去就挪开。
/// 纯函数，spike `note-type-test` 测它。全部是页内像素。
enum NoteCardPin {
    /// 图钉禁区：以图钉中心为心、边长 2×`clearance` 的方块。
    static func keepOut(pin: CGPoint, clearance: CGFloat) -> CGRect {
        CGRect(x: pin.x - clearance, y: pin.y - clearance, width: clearance * 2, height: clearance * 2)
    }

    /// 严格相交（只贴着边不算压住）。`CGRect.intersects` 对贴边的判定不好说，自己比。
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && a.maxX > b.minX && a.minY < b.maxY && a.maxY > b.minY
    }

    /// 卡片压住禁区时把它**整块挪开**（大小不变）：试图钉右 / 左 / 下 / 上四个贴边位置，各自钳进页内后仍不压住的里面，
    /// 取离原位最近的。四个都放不下（页比卡片还窄小）就原样返回。没压住直接原样返回。
    static func pushOut(_ rect: CGRect, keepOut k: CGRect, page: CGSize) -> CGRect {
        guard overlaps(rect, k) else { return rect }
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, 0), max(0, page.width - rect.width)) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, 0), max(0, page.height - rect.height)) }
        let candidates = [
            CGPoint(x: clampX(k.maxX), y: clampY(rect.minY)),                // 图钉右边
            CGPoint(x: clampX(k.minX - rect.width), y: clampY(rect.minY)),   // 图钉左边
            CGPoint(x: clampX(rect.minX), y: clampY(k.maxY)),                // 图钉下面
            CGPoint(x: clampX(rect.minX), y: clampY(k.minY - rect.height)),  // 图钉上面
        ]
        var best: CGRect?
        var bestCost = CGFloat.greatestFiniteMagnitude
        for o in candidates {
            let r = CGRect(origin: o, size: rect.size)
            guard !overlaps(r, k) else { continue }
            let cost = abs(o.x - rect.minX) + abs(o.y - rect.minY)
            if cost < bestCost { bestCost = cost; best = r }
        }
        return best ?? rect
    }
}

/// 一次拖动卡片的起点快照 + 由位移算出新卡片（纯函数，spike `note-type-test` 测它）。全部是页内像素。
struct NoteCardDrag {
    let zone: NoteCardZone
    /// 按下时卡片在页上的样子（已按内容与上限算好的可见大小）。
    let frame: CGRect
    /// 按下时内容**全部露出**要多高（含内边距）：高度是「上限」，可见高 = min(内容高, 上限)。
    let contentHeight: CGFloat
    /// 按下时存着的卡片（nil = 还没摆过）。
    let card: NoteCard?

    /// - Parameters:
    ///   - unit: 存的数 × unit = 页内像素（固定口径 1，跟页缩放口径见 `NoteBubble.Metrics.unit`）。
    ///   - pin: 图钉中心；`minSize`: 卡片最小宽 / 最小可见高；`page`: 页尺寸（卡片钳在页内）。
    ///   - pinClearance: 图钉禁区半边长（见 `NoteCardPin`）：移动时压进禁区就整块挪开；改大小时拖的那条边停在禁区边上。
    func card(translation t: CGSize, unit: CGFloat, pin: CGPoint, minSize: CGSize, page: CGSize,
              pinClearance: CGFloat = 0) -> NoteCard {
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), max(lo, hi)) }
        let u = max(unit, 0.0001)
        var x = frame.minX, y = frame.minY, w = frame.width, visible = frame.height
        var cap: CGFloat?   // 这次拖出来的高度上限（只拖了横向时为 nil，保留原值）

        switch zone.horizontal {
        case 1:
            w = clamp(frame.width + t.width, minSize.width, page.width - frame.minX)
        case -1:
            w = clamp(frame.width - t.width, minSize.width, frame.maxX)
            x = frame.maxX - w
        default: break
        }
        switch zone.vertical {
        case 1:
            let c = clamp(frame.height + t.height, minSize.height, page.height - frame.minY)
            cap = c
            visible = min(contentHeight, c)
        case -1:
            // 拖上边：下边不动。上限从「按下时的可见高」起算（存着的上限可能比内容高得多，从它起算手感会发空）。
            let c = clamp(frame.height - t.height, minSize.height, frame.maxY)
            cap = c
            visible = min(contentHeight, c)
            y = frame.maxY - visible
        default: break
        }
        if zone == .move {
            x = clamp(frame.minX + t.width, 0, page.width - w)
            y = clamp(frame.minY + t.height, 0, page.height - visible)
        }

        if pinClearance > 0 {
            let k = NoteCardPin.keepOut(pin: pin, clearance: pinClearance)
            if zone != .move {
                // 改大小：拖的那条边碰到禁区就停在禁区边上（对边不动）。停不住（最小尺寸都放不下）交给下面整块挪开。
                let rowOverlap = y < k.maxY && y + visible > k.minY
                if zone.horizontal == 1, rowOverlap, x < k.minX, x + w > k.minX, k.minX - x >= minSize.width {
                    w = k.minX - x
                } else if zone.horizontal == -1, rowOverlap, frame.maxX > k.maxX, x < k.maxX,
                          frame.maxX - k.maxX >= minSize.width {
                    x = k.maxX
                    w = frame.maxX - x
                }
                let colOverlap = x < k.maxX && x + w > k.minX
                if zone.vertical == 1, colOverlap, y < k.minY, y + visible > k.minY, k.minY - y >= minSize.height {
                    cap = k.minY - y
                    visible = min(contentHeight, k.minY - y)
                } else if zone.vertical == -1, colOverlap, frame.maxY > k.maxY, y < k.maxY,
                          frame.maxY - k.maxY >= minSize.height {
                    cap = frame.maxY - k.maxY
                    visible = min(contentHeight, frame.maxY - k.maxY)
                    y = frame.maxY - visible
                }
            }
            let r = NoteCardPin.pushOut(CGRect(x: x, y: y, width: w, height: visible), keepOut: k, page: page)
            x = r.minX
            y = r.minY
        }

        return NoteCard(dx: Double((x - pin.x) / u), dy: Double((y - pin.y) / u),
                        w: zone.horizontal != 0 ? Double(w / u) : card?.w,
                        h: cap.map { Double($0 / u) } ?? card?.h)
    }
}

/// 高亮 / 文字笔记在选中文字上**怎么画**（2026-09-16 起两者共用一套；定义放这里是因为 spike 都编 `TextNoteModel.swift`）。
///
/// payload 里是同名小写串（键 `style`）；旧 payload 无此键 → `.fill`，**零迁移**（与 `display`/`type_id` 同先例）。
/// 三种都按**逐行框**画（用户 2026-09-16 拍板：画框也是每行一个框，与铺色同口径）。
/// 🔴 安卓模式1 直接读 payload，目前只认铺色（`LibraryStore.textFills`）——画线/画框在那边暂按铺色画，见 `TODO.md` 已知欠账。
enum HighlightStyle: String, Codable, CaseIterable {
    case fill        // 铺色（荧光笔，默认）
    case underline   // 画线：行框底边一条线
    case box         // 画框：只描边不填充

    /// 菜单 / 设置页里的显示名。
    var title: String {
        switch self {
        case .fill: return L("Highlight")
        case .underline: return L("Underline")
        case .box: return L("Box")
        }
    }

    /// SF Symbol（Inspector 条目 / 气泡里的样式切换）。
    var iconName: String {
        switch self {
        case .fill: return "highlighter"
        case .underline: return "underline"
        case .box: return "rectangle"
        }
    }
}

struct TextNote: Identifiable, Equatable {
    var id: UUID = UUID()
    var page: Int
    var anchor: CGRect          // 归一化包围盒 0~1（页局部，左上原点）
    var quote: String           // 选中的原文
    var text: String            // 用户批注
    var rects: [CGRect]         // 选区逐行归一化框（页局部）——渲染精确高亮用
    var color: InkColor?        // 显式铺色（`Highlight.palette` 那几色）；nil = 按类型色 / 通用暖黄（2026-09-16 起启用，图钉仍按类型色）
    var style: HighlightStyle = .fill   // 选区上怎么画（铺色/画线/画框）；点注解无行框，此字段无意义
    var typeId: UUID? = nil     // 笔记类型（工作区 NoteType.id）；nil/未知 = 通用
    var source: NoteSource? = nil   // 来源（AI 回填）；nil = 用户自己写的
    var display: NoteDisplay = .tap // 页面上怎么展开正文（每条自己的属性）
    var card: NoteCard? = nil       // 气泡卡片手动摆过的位置 / 大小；nil = 自动规则
    var createdAt: Date = .now
    var updatedAt: Date = .now
}

// MARK: - 持久化（note 表，kind=0）

/// 落库到 `note.payload` 的 JSON 形态（页/锚点走 note 列，这里只存其余字段）。
/// rects 用显式 `[x, y, w, h]` 数组，保证 Windows/Android 端易读。
private struct TextNotePayload: Codable {
    var quote: String
    var text: String
    var rects: [[Double]]
    var color: InkColor?
    var style: String?      // JSON 键 style（fill/underline/box）；旧 payload 无此键 → fill，零迁移
    var typeId: String?     // JSON 键 type_id；旧 payload 无此键 → nil（通用），零迁移
    var source: Src?        // JSON 键 source；旧 payload 无此键 → nil，同样零迁移
    var display: String?    // JSON 键 display（tap/hover/always）；旧 payload 无此键 → tap，零迁移
    var card: NoteCard?     // JSON 键 card（{dx, dy, w?, h?}）；旧 payload 无此键 → nil，零迁移

    struct Src: Codable {
        var kind: String
        var provider: String
        var url: String
        var threadId: String?
        var at: String      // ISO-8601，跨平台可读（同 AIThread 的 contexts）

        enum CodingKeys: String, CodingKey {
            case kind, provider, url, at
            case threadId = "thread_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case quote, text, rects, color, style, source, display, card
        case typeId = "type_id"
    }
}

extension TextNote {
    /// 文字注解的笔记类型（对齐 `LibNote.kind`：0 text / 1 chat / 2 ink）。
    static let noteKind = 0

    /// 序列化为一条 text 笔记（挂逻辑文档，全版本共用）。
    func toNote(documentId: String) -> LibNote? {
        let payload = TextNotePayload(quote: quote, text: text,
                                      rects: rects.map { [$0.minX, $0.minY, $0.width, $0.height] },
                                      color: color, style: style.rawValue, typeId: typeId?.uuidString,
                                      source: source.map {
                                          TextNotePayload.Src(kind: $0.kind, provider: $0.provider,
                                                              url: $0.url,
                                                              threadId: $0.threadId?.uuidString,
                                                              at: ISO.string($0.at))
                                      },
                                      display: display.rawValue, card: card)
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return LibNote(id: id.uuidString, documentId: documentId, kind: Self.noteKind,
                       page: page, anchor: anchor, payload: data,
                       createdAt: createdAt, updatedAt: updatedAt)
    }

    /// 从一条 text 笔记复原（id/page/anchor 取 note 列，其余取 payload）。类型不符或损坏返回 nil。
    init?(note: LibNote) {
        guard note.kind == TextNote.noteKind,
              let uuid = UUID(uuidString: note.id),
              let p = try? JSONDecoder().decode(TextNotePayload.self, from: note.payload)
        else { return nil }
        let rects: [CGRect] = p.rects.map { (a: [Double]) -> CGRect in
            let x: Double = a.count > 0 ? a[0] : 0
            let y: Double = a.count > 1 ? a[1] : 0
            let w: Double = a.count > 2 ? a[2] : 0
            let h: Double = a.count > 3 ? a[3] : 0
            return CGRect(x: x, y: y, width: w, height: h)
        }
        let src = p.source.map {
            NoteSource(kind: $0.kind, provider: $0.provider, url: $0.url,
                       threadId: $0.threadId.flatMap { UUID(uuidString: $0) },
                       at: ISO.date($0.at) ?? note.createdAt)
        }
        self.init(id: uuid, page: note.page, anchor: note.anchor, quote: p.quote, text: p.text,
                  rects: rects, color: p.color,
                  style: p.style.flatMap { HighlightStyle(rawValue: $0) } ?? .fill,
                  typeId: p.typeId.flatMap { UUID(uuidString: $0) },
                  source: src, display: p.display.flatMap { NoteDisplay(rawValue: $0) } ?? .tap, card: p.card,
                  createdAt: note.createdAt, updatedAt: note.updatedAt)
    }
}
