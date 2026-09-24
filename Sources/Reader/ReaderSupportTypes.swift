import AppKit
import WebKit

// 阅读区的几样纯数据类型与菜单命令通知（从原 SwiftUI `PageStreamSupport` / `ReaderSurface+BoxSelect` /
// `NoteEditorSheet` / `AIWebArea` 里搬出来，内容未改）。

extension Notification.Name {
    static let readerZoomIn = Notification.Name("com.xvan.UniReader.readerZoomIn")
    static let readerZoomOut = Notification.Name("com.xvan.UniReader.readerZoomOut")
    static let readerZoomFit = Notification.Name("com.xvan.UniReader.readerZoomFit")
    static let readerZoomActual = Notification.Name("com.xvan.UniReader.readerZoomActual")
    static let readerCopy = Notification.Name("com.xvan.UniReader.readerCopy")
    static let readerSelectAll = Notification.Name("com.xvan.UniReader.readerSelectAll")
    // 编辑（Edit 菜单里没人接时路由给阅读区 / 草稿纸；对象都是**框选选中集**）
    static let readerCut = Notification.Name("com.xvan.UniReader.readerCut")
    static let readerPaste = Notification.Name("com.xvan.UniReader.readerPaste")
    static let readerDelete = Notification.Name("com.xvan.UniReader.readerDelete")
    static let readerUndo = Notification.Name("com.xvan.UniReader.readerUndo")
    static let readerRedo = Notification.Name("com.xvan.UniReader.readerRedo")
    // 笔记：Inspector 那边点「编辑 / 查看」→ 阅读区弹 sheet。`object` = `NoteRequest`，非本会话的窗口不认领。
    static let imageNoteEdit = Notification.Name("com.xvan.UniReader.imageNoteEdit")
    static let imageNoteView = Notification.Name("com.xvan.UniReader.imageNoteView")
    static let textNoteEdit = Notification.Name("com.xvan.UniReader.textNoteEdit")
}

/// `imageNoteEdit` / `imageNoteView` / `textNoteEdit` 通知的载荷。
struct NoteRequest {
    var sessionID: UUID
    var noteID: UUID
}

/// 被点开的那条文字高亮 + **被点中的那一行**（页内归一化框）。
/// 存行框而不是整条高亮的包围盒：跨行高亮的包围盒可能有半页高，从它底下弹删除气泡离手指老远。
struct HighlightTap: Equatable {
    let id: UUID
    let rect: CGRect
}

/// 高倍清晰贴片：normRect = 页内归一化区域（0~1，左上原点）→ 显示时 × 页尺寸，随缩放拉伸。
struct PageTile: Equatable {
    var normRect: CGRect
    var image: CGImage
}

/// 一次文字选择的结果：逐页归一化行框 / 行内片段框（画高亮）+ 选中纯文本（⌘C 复制）。
/// 归一化 0~1 左上原点；原生页由 PDFKit 选择引擎产出，OCR 页由 `OCRTextSelect` 行内字符级裁剪产出。
struct TextSelection: Equatable {
    var rects: [Int: [CGRect]]   // page → 该页归一化行框
    var text: String
}

/// 一个可选中的最小单位：OCR 一行裁剪出的字符片段，或 PDF 原生页 `selectionsByLine()` 的一行。
/// rect + text 成对存放，是框选能做「再框一遍就取消」的关键：删哪项就精确少哪项文本。
struct BoxSelectItem: Equatable {
    var rect: CGRect
    var text: String
}

/// 「添加批注」草稿：捕获选区起始页 + 归一化锚点 / 行框 + 原文，待编辑器填批注后落成 `TextNote`。
/// 由高亮转来的草稿额外带上颜色 / 画法与原高亮 id——保存时删掉那条高亮。
struct PendingNote: Identifiable {
    let id = UUID()
    var page: Int
    var anchor: CGRect       // 归一化包围盒 0~1（页局部）
    var rects: [CGRect]      // 选区逐行归一化框（页局部）
    var quote: String        // 选中原文
    var color: InkColor? = nil            // 显式铺色（高亮转来的带上高亮色；选区新建为 nil = 按类型色）
    var style: HighlightStyle = .fill     // 画法（高亮转来的带上原画法）
    var replacesHighlight: UUID? = nil    // 非空 = 这份草稿是由这条高亮转来的，保存即删它
}

/// 批注编辑器目标：新建（选区草稿）或编辑（已存在注解）。
enum NoteEditorTarget: Identifiable {
    case new(PendingNote)
    case edit(TextNote)

    var id: UUID {
        switch self {
        case .new(let p): return p.id
        case .edit(let n): return n.id
        }
    }
    var quote: String {
        switch self {
        case .new(let p): return p.quote
        case .edit(let n): return n.quote
        }
    }
    var initialText: String {
        switch self {
        case .new: return ""
        case .edit(let n): return n.text
        }
    }
    var initialTypeId: UUID? {
        switch self {
        case .new: return nil
        case .edit(let n): return n.typeId
        }
    }
    /// 展开方式：新建按默认（tap），编辑取这条笔记自己的。
    var initialDisplay: NoteDisplay {
        switch self {
        case .new: return .tap
        case .edit(let n): return n.display
        }
    }
    /// 显式铺色：新建取草稿的（高亮转来的带高亮色，否则 nil），编辑取这条笔记自己的。
    var initialColor: InkColor? {
        switch self {
        case .new(let p): return p.color
        case .edit(let n): return n.color
        }
    }
    /// 画法（铺色 / 画线 / 画框）：同上。
    var initialStyle: HighlightStyle {
        switch self {
        case .new(let p): return p.style
        case .edit(let n): return n.style
        }
    }
    /// 有没有行框：点注解（无行框）没有可画的东西，编辑器里不给颜色 / 画法那一行。
    var hasRects: Bool {
        switch self {
        case .new(let p): return !p.rects.isEmpty
        case .edit(let n): return !n.rects.isEmpty
        }
    }
    /// 编辑已存在注解时才给「删除」入口（新建草稿没有可删的东西）。
    var editedNote: TextNote? {
        if case .edit(let n) = self { return n }
        return nil
    }
}

/// 编辑器保存时交出去的整包：正文 + 类型（nil=通用）+ 展开方式 + 显式铺色（nil=按类型色）+ 画法。
struct NoteEditorOutput {
    var text: String
    var typeId: UUID?
    var display: NoteDisplay
    var color: InkColor?
    var style: HighlightStyle
}

/// 框选移动（仅页内）的选中集：同页笔迹 id + 文字注解 id + 联合包围盒（页内归一化 0~1）。瞬态，不持久化。
struct LassoSelection: Equatable {
    var page: Int
    var strokeIDs: Set<UUID>
    var noteIDs: Set<UUID>
    var bounds: CGRect
}

/// 进行中的框选手势形态：拖空白 = 重新框选（自由路径虚线）；拖选中高亮框内 = 移动选中项（ghost 预览）；
/// 拖手柄 = 缩放（**角手柄 = 等比**（⇧ 临时自由两轴）、**边中点手柄 = 单轴**；anchor = 对角 / 对边中点）。
enum LassoDragMode: Equatable {
    case select, move, scale(LassoHandle)
}

/// 高亮框缩放手柄：四角（等比缩放）+ 四边中点（单轴缩放）。
enum LassoHandle: Equatable, CaseIterable {
    case tl, tr, bl, br, t, b, l, r

    var isCorner: Bool {
        switch self {
        case .tl, .tr, .bl, .br: return true
        case .t, .b, .l, .r: return false
        }
    }

    /// 手柄在 rect 上的点（角 / 边中点）。
    func point(in r: CGRect) -> CGPoint {
        switch self {
        case .tl: return CGPoint(x: r.minX, y: r.minY)
        case .tr: return CGPoint(x: r.maxX, y: r.minY)
        case .bl: return CGPoint(x: r.minX, y: r.maxY)
        case .br: return CGPoint(x: r.maxX, y: r.maxY)
        case .t:  return CGPoint(x: r.midX, y: r.minY)
        case .b:  return CGPoint(x: r.midX, y: r.maxY)
        case .l:  return CGPoint(x: r.minX, y: r.midY)
        case .r:  return CGPoint(x: r.maxX, y: r.midY)
        }
    }

    /// 对侧手柄（缩放 anchor：角的对角 / 边的对边中点）。
    var opposite: LassoHandle {
        switch self {
        case .tl: return .br
        case .tr: return .bl
        case .bl: return .tr
        case .br: return .tl
        case .t:  return .b
        case .b:  return .t
        case .l:  return .r
        case .r:  return .l
        }
    }
}

/// 框选截图松手后做什么：问 Agent / 问网页 AI / 复制图片 / 存为图片笔记（同一个菜单里选，2026-09-24 用户定）。
enum SnipTarget: String { case agent, consult, copy, imageNote }

/// 「发给谁」那个弹出菜单的动作接收者：菜单项点下去记住是哪一项（`popUp` 返回后读 `picked`）。
final class SnipTargetPicker: NSObject {
    var picked: SnipTarget?
    @objc func pick(_ sender: NSMenuItem) {
        picked = (sender.representedObject as? String).flatMap(SnipTarget.init(rawValue:))
    }
}

/// Inspector 顶部分段的各页。`agent` = Agent 对话（2026-09-19 起 Agent 面板只住在这里，不再有浮层 / 独立窗口）。
enum InspectorTab: Hashable { case info, thumbnails, contents, notes, agent }

/// 「笔记」页的二级分区（文字 / 高亮 / 图片 / 书签 / 笔迹 / 草稿纸 / AI 全堆一页太多，一次只显示一类）。
enum NotesSection: String, CaseIterable, Identifiable {
    case text, highlight, image, bookmark, ink, scratch, ai

    var id: String { rawValue }

    /// 二级分区栏是图标分段（面板窄，七个字标签排不下）。文字标签仍给辅助功能与块标题用。
    var icon: String {
        switch self {
        case .text: return "note.text"
        case .highlight: return "highlighter"
        case .image: return "photo"
        case .bookmark: return "bookmark"
        case .ink: return "scribble"
        case .scratch: return "square.and.pencil"
        case .ai: return "bubble.left.and.bubble.right"
        }
    }

    var title: String {
        switch self {
        case .text: return L("Text Notes")
        case .highlight: return L("Highlights")
        case .image: return L("Image Notes")
        case .bookmark: return L("Bookmarks")
        case .ink: return L("Ink")
        case .scratch: return L("Scratchpads")
        case .ai: return L("AI Chats")
        }
    }
}

/// 第一响应者是不是落在一个 `WKWebView` 里。
///
/// 阅读区那套**单键**工具快捷键（`e` 橡皮 / `1`~`9` 选笔 / `n b v l i t`）原来只判 `firstResponder is NSText`
/// 就放行——**WKWebView 不是 NSText**，于是在内置 AI 面板里打字会被抢走（用户 2026-08-26 报）。
/// 凡是「阅读区要不要吃掉这个键」的判断，都得把 webview 这条算进去。
func aiWebInputHasFocus() -> Bool {
    var view = NSApp.keyWindow?.firstResponder as? NSView
    while let current = view {
        if current is WKWebView { return true }
        view = current.superview
    }
    return false
}
