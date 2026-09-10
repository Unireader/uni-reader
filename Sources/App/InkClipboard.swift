import AppKit
import CoreGraphics
import Foundation

/// 笔迹剪贴板：框选选中的**页内笔迹 + 文字注解** ⇄ 系统剪贴板。
///
/// 走系统 `NSPasteboard` 而不是 App 内部的一个变量，图的正是它自带的三件事：跨窗口、跨文档、
/// 跨工作区都通；⌘X/⌘C/⌘V 就是系统那三个键；用户拷了别的东西进来我们自然就失效。
///
/// **条目编码直接复用落库那套 payload**（`InkStroke.toNote` / `init?(note:)`）——模型加字段时
/// 剪贴板自动跟着走，不必两处维护；跨版本粘贴也照 `note.payload` 的既有兜底规则解码。
///
/// **两个坐标空间**：页内笔迹是页内归一化（x 相对页宽、y 相对页高），草稿纸笔迹是画布点（可负无界）。
/// 剪贴板记下自己是哪一种（`space`）+ 源页的纵横比（`aspect`），粘贴方按需换算（`scaled`），
/// 于是纸 ↔ 页可以互相粘。
enum InkClipboard {

    /// 剪贴板内容所处的坐标空间。
    enum Space: String, Codable { case page, canvas }

    /// 自有剪贴板类型。别的 app 认不得它，粘不进去也粘不坏（另附一份纯文本兜底，见 `write`）。
    static let pbType = NSPasteboard.PasteboardType("tech.xvanturing.unireader.ink")

    /// 一条被复制的条目（`kind` 与 `LibNote.kind` 同义：0 文字注解 / 2 页内笔迹）。
    struct Row: Codable {
        var kind: Int
        var page: Int
        var x: Double, y: Double, w: Double, h: Double
        var payload: Data
    }

    struct Payload: Codable {
        var v = 1
        /// 坐标空间（"page" / "canvas"）。**旧 payload 没有这个键 → page**：手写 `init(from:)`
        /// 而不是靠默认值——合成的解码器遇到缺键会直接抛，那样一份旧内容留在剪贴板里就永远粘不出来
        /// （静默：`read()` 返回 nil，⌘V 一点反应没有）。同 note payload 「新键一律兜底」的既有惯例。
        var space: String = Space.page.rawValue
        /// 源页的纵横比（页高/页宽）。只有 `space == .page` 时有意义，跨空间粘贴按它折算 y。
        var aspect: Double = 0
        var rows: [Row]

        init(space: Space, aspect: Double, rows: [Row]) {
            self.space = space.rawValue; self.aspect = aspect; self.rows = rows
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
            space = try c.decodeIfPresent(String.self, forKey: .space) ?? Space.page.rawValue
            aspect = try c.decodeIfPresent(Double.self, forKey: .aspect) ?? 0
            rows = try c.decode([Row].self, forKey: .rows)
        }
    }

    /// 剪贴板里现在有没有本 app 的笔迹（菜单/右键项的可用性）。
    /// `pb` 只为 spike 留的注入口（默认就是系统剪贴板），别在 App 代码里传别的。
    static func hasInk(in pb: NSPasteboard = .general) -> Bool {
        pb.data(forType: pbType) != nil
    }

    /// `space`/`aspect` 由调用方按自己所在的空间填（阅读区 = page + 该页纵横比；草稿纸 = canvas）。
    static func write(strokes: [InkStroke], notes: [TextNote] = [], space: Space = .page,
                      aspect: Double = 0, to pb: NSPasteboard = .general) {
        var rows: [Row] = []
        // `padId` 一律抹掉再序列化：剪贴板里只有「一团笔迹」，落到纸上还是页上由粘贴方决定
        // （留着它会让草稿纸笔迹以 kind=4 进剪贴板，粘到页里就成了看不见的孤儿）。
        for st in strokes {
            var t = st; t.padId = nil
            if let n = t.toNote(documentId: "clip") { rows.append(row(n)) }
        }
        for tn in notes { if let n = tn.toNote(documentId: "clip") { rows.append(row(n)) } }
        guard !rows.isEmpty,
              let data = try? JSONEncoder().encode(Payload(space: space, aspect: aspect, rows: rows))
        else { return }
        pb.clearContents()
        pb.setData(data, forType: pbType)
        // 纯文本兜底：选中集里有注解正文时一并放上，粘到别的 app 里至少还有内容（笔迹没有文本形态）。
        let text = notes.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
        if !text.isEmpty { pb.setString(text, forType: .string) }
    }

    /// 读回剪贴板里的笔迹/注解。**每条都换新 id**——粘贴出来的是新条目，与源共用 id 的话
    /// 同一篇文档里粘一次就把源覆盖掉了（`persistInk` 按 id 对账）。
    static func read(from pb: NSPasteboard = .general)
    -> (strokes: [InkStroke], notes: [TextNote], space: Space, aspect: Double)? {
        guard let data = pb.data(forType: pbType),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        var strokes: [InkStroke] = []
        var notes: [TextNote] = []
        for r in payload.rows {
            let note = LibNote(id: UUID().uuidString, documentId: "", kind: r.kind, page: r.page,
                               anchor: CGRect(x: r.x, y: r.y, width: r.w, height: r.h),
                               payload: r.payload, createdAt: .now, updatedAt: .now)
            switch r.kind {
            case InkStroke.noteKind:
                if var st = InkStroke(note: note) { st.padId = nil; strokes.append(st) }
            case TextNote.noteKind:
                if let tn = TextNote(note: note) { notes.append(tn) }
            default:
                break
            }
        }
        guard !strokes.isEmpty || !notes.isEmpty else { return nil }
        return (strokes, notes, Space(rawValue: payload.space) ?? .page, payload.aspect)
    }

    /// 页内归一化 ⇄ 画布点。基准是**三端契约** `ScratchPad.pageRefWidth`：**1 个页宽 = 800 画布点**
    /// （草稿纸上垫着的那一页就是按它铺的，见 `ScratchPad.pageRect`），于是从纸上抄一段公式粘到页边，
    /// 大小与在纸上看到的一致。y 另乘页的纵横比——归一化 y 相对的是页高，不是页宽。
    ///
    /// **线宽不换算**：页内笔迹的 `width` 本来就是「显示点」这个绝对量、与页面大小无关，
    /// 画布点也是绝对量，两边同一个数就是同一个粗细（同橡皮 `eraserRefWidth` 那条换算的口径）。
    static func scaled(_ strokes: [InkStroke], toCanvas: Bool, aspect: Double) -> [InkStroke] {
        let a = aspect > 0 ? aspect : 1.4142            // 拿不到页面尺寸时按 A4 兜底（同 pageRect）
        let w = ScratchPad.pageRefWidth
        let sx = toCanvas ? w : 1 / w
        let sy = toCanvas ? w * a : 1 / (w * a)
        return strokes.map { st in
            var t = st
            t.points = st.points.map { InkPoint($0.dx * sx, $0.dy * sy, $0.dz) }
            return t
        }
    }

    private static func row(_ n: LibNote) -> Row {
        Row(kind: n.kind, page: n.page,
            x: n.anchor.minX, y: n.anchor.minY, w: n.anchor.width, h: n.anchor.height,
            payload: n.payload)
    }
}
