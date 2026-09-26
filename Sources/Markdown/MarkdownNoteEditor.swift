import AppKit
import MarkdownEngine
import MarkdownEngineLatex
import SwiftUI

/// 笔记里的 LaTeX 公式（`$…$` 行内、单独成段的 `$$…$$` 块）：引擎自带的 `SwiftMathBridge` 外面套一层，管两件事。
///
/// **① 块公式按块排版**（用户 2026-09-16：「`$$` 应该是块吧，为啥是 inline」）。bridge 对所有公式一律用行内样式
/// （`labelMode = .text`：分式缩小、∑ 的上下限挤在旁边），而引擎调 `render` 时块和行内**传的参数一模一样**
/// （同一个字号、同一个主题），渲染接口里分不出来。所以这里自己记一张「块公式内容」表：
///  · 气泡 / 编辑器的 `body` 先把整段源码里的 `$$…$$` 登记进来（`registerBlocks`，扫法同引擎分词器：一个 `$$` 到下一个 `$$`）；
///  · 编辑器里新敲 / 粘贴进来的块：引擎是先重排、后**异步**回写 binding，等 `body` 就晚了——
///    查不到时再从正在编辑的那个 `NSTextView`（key 窗口的第一响应者）当场扫一遍。
///  · 查到是块 → 前面加 `\displaystyle` 再交给 bridge（样张实测对 `aligned` / `pmatrix` 等环境也有效，重复加也无害）。
///  · 比对时去掉全部空白（引擎传进来的块内容剪过首尾空白，与源码里的原样不完全一致）。
///  · 代价：某条行内公式若与某个块公式**内容完全相同**，它也会按块样式排——只有含分式 / 求和 / 积分这类才看得出差别，接受。
///
/// **② 缓存封顶**。bridge 的缓存按（公式, 字号, 外观, 颜色）存图、**从不淘汰**。气泡开了「跟页缩放」时字号随缩放连续变
/// （`MarkdownNoteReader` 按 0.5pt 取整），缩放一个来回每条公式就多出几十张不同字号的图，一直攒着不放。
/// 这里只记（公式, 字号）出现过多少种，超过上限就整个清掉重新攒——清完屏上正显示的那几张会在下次排版时重画，代价很小。
///
/// 编辑器与气泡共用一份（`shared`），同一条公式在两边字号相同时能复用。
/// 语法写不对 / SwiftMath 不支持的命令 → bridge 返回 nil → 引擎原样显示源码，不会出空白。
/// 只认 `$` 定界：`\(…\)` / `\[…\]` 不渲染（引擎解析器不认）。
/// 线程：引擎在主线程排版时调 `render`（bridge 自己也读 `NSApp.keyWindow`，同一前提）。
final class NoteLatexRenderer: LatexRenderer, @unchecked Sendable {
    static let shared = NoteLatexRenderer()

    private struct Key: Hashable { let latex: String; let fontSize: CGFloat }
    private let bridge = SwiftMathBridge()
    private var seen = Set<Key>()
    private var blockBodies = Set<String>()
    private let lock = NSLock()
    /// （公式, 字号）种数上限。一张 12pt 的行内公式位图几十 KB、跟着页放大到 30pt 上下也就几百 KB，
    /// 160 种封顶在几十 MB 以内；平常固定字号的气泡一篇笔记十几条公式，远到不了。
    private static let limit = 160
    /// 块公式表上限（存的只是去掉空白的公式串，几千条也就几百 KB）；超了清空，正在显示的下次 `body` 会再登记回来。
    private static let blockLimit = 4096

    /// 把一段笔记源码里的 `$$…$$` 登记为块公式。在 `body` 里调：它先于 AppKit 视图的创建 / 更新（也就先于引擎排版）。
    func registerBlocks(in source: String) {
        guard source.contains("$$") else { return }
        let found = Self.blockBodies(in: source)
        guard !found.isEmpty else { return }
        lock.lock()
        if !found.isSubset(of: blockBodies) {
            if blockBodies.count + found.count > Self.blockLimit { blockBodies.removeAll() }
            blockBodies.formUnion(found)
        }
        lock.unlock()
    }

    func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
        let body = Self.normalized(latex)
        var isBlock = isKnownBlock(body)
        if !isBlock, let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.string.contains("$$") {
            registerBlocks(in: tv.string)   // 编辑器里刚敲 / 粘贴的块（见类注释①）
            isBlock = isKnownBlock(body)
        }
        let source = isBlock ? "\\displaystyle " + latex : latex

        lock.lock()
        seen.insert(Key(latex: source, fontSize: fontSize))
        if seen.count > Self.limit {
            seen.removeAll()
            bridge.clearCache()
        }
        lock.unlock()
        return bridge.render(latex: source, fontSize: fontSize, theme: theme)
    }

    private func isKnownBlock(_ body: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return blockBodies.contains(body)
    }

    private static func normalized(_ s: String) -> String { s.filter { !$0.isWhitespace } }

    /// 源码里每一对 `$$…$$` 的内容（去空白）。扫法照抄引擎 `BlockLevelTokenizer.blockLatex`：
    /// 前一个字符是 `$` 的 `$$` 不算开头；从开头往后找下一个 `$$`，内容至少一个字符。
    private static func blockBodies(in source: String) -> Set<String> {
        let u = Array(source.utf16)
        let n = u.count
        let dollar: UInt16 = 0x24
        var out = Set<String>()
        var i = 0
        while i + 1 < n {
            if u[i] == dollar, u[i + 1] == dollar, !(i > 0 && u[i - 1] == dollar) {
                var j = i + 2
                while j + 1 < n, !(u[j] == dollar && u[j + 1] == dollar && j > i + 2) { j += 1 }
                if j + 1 < n {
                    let body = normalized(String(decoding: u[(i + 2)..<j], as: UTF16.self))
                    if !body.isEmpty { out.insert(body) }
                    i = j + 2
                    continue
                }
            }
            i += 1
        }
        return out
    }
}

/// 某一个引擎视图自己的公式渲染：走共享的 `NoteLatexRenderer`，再把**比可用宽度还宽**的公式按比例缩到正好放下。
///
/// 🔴 为什么非缩不可（用户 2026-09-16 报「悬浮渲染有问题」，离屏复现实测）：块公式是一行居中的图，图宽过文本容器时
/// TextKit 2 的 `usageBoundsForTextContainer` 左边变成负数，它就把**整篇**往右挪这么多——正文整体右移、右边被裁，
/// 公式本身左右都露出去。缩到容器宽之后 usage 回到 0，排版正常。行内公式同理一起缩。
/// 渲染接口里拿不到视图宽度，所以宽度跟着配置走，每个视图一份（`MarkdownNoteReader` / `MarkdownNoteEditor` 各自算）。
struct FittedLatexRenderer: LatexRenderer {
    let maxWidth: CGFloat   // ≤ 0 = 还不知道宽度，不缩

    func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
        guard let r = NoteLatexRenderer.shared.render(latex: latex, fontSize: fontSize, theme: theme) else { return nil }
        guard maxWidth > 0, r.size.width > maxWidth else { return r }
        let k = maxWidth / r.size.width
        return LatexRenderResult(image: r.image,
                                 size: CGSize(width: maxWidth, height: r.size.height * k),
                                 baselineOffset: r.baselineOffset * k)
    }
}

/// 不提供任何图片，只用来**让引擎在宽度变了时整篇重排**：引擎只在 `images.fingerprint()` 变了时才换上新的
/// services 并重排（`NativeTextViewWrapper.updateNSView`），没有别的公开开关。指纹 = 取整后的可用宽度，
/// 于是宽度没变时照旧什么都不做（气泡跟页缩放时逐帧重建配置也不会逐帧重排）。
struct WidthKeyedImageProvider: EmbeddedImageProvider {
    let width: Int
    func image(for reference: EmbeddedImageRequest) -> NSImage? { nil }
    func fingerprint() -> AnyHashable { width }
}

extension MarkdownEditorConfiguration {
    /// 这份配置按「文本容器宽 `containerWidth`」装上公式缩放与宽度指纹（见 `FittedLatexRenderer`）。
    func fittingLatex(to containerWidth: CGFloat) -> MarkdownEditorConfiguration {
        var c = self
        let w = containerWidth.rounded(.down)
        c.services.latex = FittedLatexRenderer(maxWidth: w)
        c.services.images = WidthKeyedImageProvider(width: Int(w))
        return c
    }
}

/// 点气泡卡片时打开正文里的链接。
///
/// 卡片正文不吃鼠标（`MarkdownNoteReader` 里 `.allowsHitTesting(false)`：用户 2026-09-16 选了「关闭文字选择」，
/// 按住卡片任意处拖 = 移动卡片），引擎自己的点链接也就收不到了。卡片的手势认出「单击」后调这里：
/// 按鼠标事件在窗口里的位置找到那块只读正文（非可编辑的 `NSTextView`），看点中的字上有没有 `.link`。
enum NoteLinkClick {
    /// 点中了什么。
    enum Hit: Equatable {
        /// 普通链接（http / unireader…）。
        case url(URL)
        /// 气泡里的 `[[…]]`：引擎把目标笔记 id 放在 `.link` 里（v15）。
        case note(String)
    }

    /// - Returns: 真的打开了一个链接。
    /// - Parameter openNote: 点中 `[[…]]` 时调；不给就当没点中（如参考窗那种只读场景）。
    @discardableResult
    static func open(at event: NSEvent?, openNote: ((String) -> Void)? = nil) -> Bool {
        switch hit(at: event) {
        case .url(let u):
            NSWorkspace.shared.open(u)
            return true
        case .note(let id):
            guard let openNote else { return false }
            openNote(id)
            return true
        case nil:
            return false
        }
    }

    /// 这个鼠标事件落在什么上（没有 = nil）。
    ///
    /// 🔴 引擎给 `[[…]]` 写的 `.link` **是一串裸 id，不是 URL**（见
    /// `MarkdownASTStyler.styleWikiLink`）。`URL(string:)` 对裸 UUID 也能造出一个相对 URL，
    /// 交给 `NSWorkspace.open` 就是一次静默失败——所以这里先按「有没有 scheme」分开。
    static func hit(at event: NSEvent?) -> Hit? {
        guard let raw = rawLink(at: event) else { return nil }
        if let u = raw as? URL { return .url(u) }
        guard let s = raw as? String else { return nil }
        if let u = URL(string: s), u.scheme != nil { return .url(u) }
        return .note(s)
    }

    /// 兼容旧叫法：只要 URL 形态的那一种。
    static func url(at event: NSEvent?) -> URL? {
        if case .url(let u) = hit(at: event) { return u }
        return nil
    }

    /// `.link` 属性的原值（URL 或 String）。
    private static func rawLink(at event: NSEvent?) -> Any? {
        guard let e = event, let window = e.window, let root = window.contentView,
              let tv = readerTextView(in: root, at: e.locationInWindow),
              let storage = tv.textStorage, storage.length > 0 else { return nil }
        // 以下与从前一致，只是不再强行拆成 URL
        let p = tv.convert(e.locationInWindow, from: nil)
        let screenP = window.convertPoint(toScreen: e.locationInWindow)
        // 插入点下标：点在字的右半边会给出后一个位置，所以前后两个字都核对——字形框真的罩住鼠标才算点中
        //（点在行尾空白处，插入点也会落在最近的字上）。
        let i = tv.characterIndexForInsertion(at: p)
        for idx in [i, i - 1] where idx >= 0 && idx < storage.length {
            let r = tv.firstRect(forCharacterRange: NSRange(location: idx, length: 1), actualRange: nil)
            guard r.insetBy(dx: -1, dy: -1).contains(screenP),
                  let link = storage.attribute(.link, at: idx, effectiveRange: nil) else { continue }
            return link
        }
        return nil
    }

    /// 窗口里罩住这一点的只读正文；多个叠着取最上面那个（子视图顺序靠后的画在上面）。
    private static func readerTextView(in view: NSView, at pWindow: CGPoint) -> NSTextView? {
        var hit: NSTextView?
        func walk(_ v: NSView) {
            if v.isHidden { return }
            if let tv = v as? NSTextView, !tv.isEditable,
               tv.convert(tv.visibleRect, to: nil).contains(pWindow) {
                hit = tv
            }
            for s in v.subviews { walk(s) }
        }
        walk(view)
        return hit
    }
}

/// 笔记正文 / 图片说明的编辑框：`swift-markdown-engine` 的 `NativeTextViewWrapper`（TextKit 2 + AppKit，
/// 用户 2026-09-13 定：Perch 里用过、好用）。**只用在编辑器 sheet 里**——阅读区纯 SwiftUI 的红线不受影响，
/// 页面气泡由 `NoteMarkdown` 把同一份源折成 `Text` 画。
///
/// 存的就是 Markdown 源（`TextNote.text` / `ImageNote.caption` 照旧是 String），编辑器只是所见即所得地画它。
/// 一个 sheet 里一个编辑器，`documentId` 传笔记 id：引擎按它分撤销栈，换一条笔记不会撤到上一条的内容。
struct MarkdownNoteEditor: View {
    @Binding var text: String
    let documentId: String
    var placeholder: String = ""
    /// 本工作区的 `[[…]]` 索引与图片服务（`WorkspaceWikiIndex`）。nil = 不认 wiki 链接（引擎的无操作默认）。
    var wiki: WorkspaceWikiIndex?
    /// 正文字号：设置 → 阅读 →「编辑框字号」（默认 13；气泡默认 12，编辑时略大一点看得清）。
    @AppStorage(NoteBubble.editorFontSizeKey) private var fontSizeSetting = Int(NoteBubble.defaultEditorFont)
    private var fontSize: CGFloat { CGFloat(fontSizeSetting) }
    /// 编辑框实际宽度（量出来的；0 = 还没量到）。公式宽过文本容器就缩（`FittedLatexRenderer`）。
    @State private var boxWidth: CGFloat = 0
    /// 文本容器宽 = 框宽 − 两侧 6pt 内边距 − 16pt 余量（系统设成「始终显示滚动条」时竖滚动条要占掉这一条）。
    private var containerWidth: CGFloat { boxWidth > 0 ? boxWidth - 12 - 16 : 0 }

    /// 引擎配置：小编辑框，不要「舒适的底部留白」（那是给整页长文档设计的，160pt 高的框里会空出一半），
    /// 只留竖滚动条；文字与边框之间留 6pt。
    static let baseConfiguration: MarkdownEditorConfiguration = {
        var c = MarkdownEditorConfiguration.default
        c.overscroll = OverscrollPolicy(percent: 0, maxPoints: 8, minPoints: 8)
        c.scrollers = .vertical
        c.textInsets = TextInsets(horizontal: 6, vertical: 6)
        // 写的是 Markdown / LaTeX 源码：`'` `"` 必须原样，不能被系统智能引号换成 ’ ”（自家 fork 加的开关）
        c.spellChecking.automaticQuoteSubstitution = false
        Self.applyNoteTypography(&c)
        return c
    }()

    /// 接上本工作区的 `[[…]]` 服务。`services` 里装的是存在类型，换一个只是改两个字段，不必缓存。
    static func configuration(wiki: WorkspaceWikiIndex?) -> MarkdownEditorConfiguration {
        var c = baseConfiguration
        if let wiki { c.services.wikiLinks = wiki; c.services.images = wiki }
        return c
    }

    /// 笔记的排版尺度与公式渲染（编辑器与气泡共用）：引擎默认是给整页文档定的——一级标题 2 倍字号、
    /// 列表每级缩进 27.5pt，放进几行字的笔记里太夸张。标题只比正文大一点、缩进收到 16pt。
    /// 公式：编辑器里光标不在公式里时显示渲染结果、光标进去显示源码（引擎行为）；气泡里始终显示渲染结果。
    static func applyNoteTypography(_ c: inout MarkdownEditorConfiguration) {
        c.headings.fontMultipliers = [1.4, 1.25, 1.12, 1.05, 1.0, 1.0]
        c.headings.topSpacingEm = [0.3, 0.25, 0.2, 0.15, 0.1, 0.1]
        c.lists.indentPerLevel = 16
        c.services.latex = NoteLatexRenderer.shared
    }

    var body: some View {
        NoteLatexRenderer.shared.registerBlocks(in: text)   // 打开时已有的块公式；之后新敲的由渲染器现查（见 `NoteLatexRenderer`）
        return NativeTextViewWrapper(text: $text,
                                     configuration: Self.configuration(wiki: wiki).fittingLatex(to: containerWidth),
                                     fontSize: fontSize,
                                     documentId: documentId,
                                     placeholder: placeholder.isEmpty ? nil : NSAttributedString(
                                         string: placeholder,
                                         attributes: [.foregroundColor: NSColor.placeholderTextColor,
                                                      .font: NSFont.systemFont(ofSize: fontSize)]))
            // 引擎自己不画底（drawsBackground = false），底色与边框按系统文本框的样子补上
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .onAppear { Self.focusEditor() }
    }

    /// 气泡里的正文（`MarkdownNoteReader`）用的固定浅色主题：气泡永远是纸白底（夜间也是），字色得钉死，
    /// 不能跟系统外观走——`.labelColor` 在深色外观下是白字，压在纸白上就没了。
    static let readerTheme: MarkdownEditorTheme = {
        var t = MarkdownEditorTheme.default
        t.bodyText = NSColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1)      // = NoteBubble.ink
        t.mutedText = NSColor(white: 0.42, alpha: 1)
        t.disabledText = NSColor(white: 0.6, alpha: 1)
        t.headingMarker = NSColor(white: 0.55, alpha: 1)
        t.strikethroughColor = t.bodyText
        t.link = NSColor.systemBlue
        t.incompleteLink = NSColor.systemBlue
        // 公式颜色两种外观都钉成正文色：`SwiftMathBridge` 判深浅色看的是 **key 窗口**的外观，
        // 不是这个视图被钉成的浅色——系统深色时它会挑 `latexDarkModeText`（默认白），压在纸白气泡上就看不见了。
        t.latexLightModeText = t.bodyText
        t.latexDarkModeText = t.bodyText
        return t
    }()

    /// 打开编辑器就把光标放进去（原来 `TextEditor` 走 `@FocusState`；AppKit 视图得自己找第一响应者）。
    /// sheet 一出来它就是 key 窗口；在里面找那个可编辑的 `NSTextView`。延一拍：`onAppear` 时视图树还没挂到窗口上。
    static func focusEditor() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow, let root = window.contentView,
                  let tv = firstEditableTextView(in: root) else { return }
            window.makeFirstResponder(tv)
        }
    }

    private static func firstEditableTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView, tv.isEditable { return tv }
        for sub in view.subviews {
            if let hit = firstEditableTextView(in: sub) { return hit }
        }
        return nil
    }
}

// MARK: - 只读渲染（气泡里的正文）

/// 笔记正文 / 图片说明在**页面气泡**里的渲染：同一个引擎、`isEditable: false`（用户 2026-09-13 定：
/// 「气泡渲染最好也用这个，关闭编辑即可」——纯 SwiftUI `Text` 的近似渲染效果不好）。
///
/// 🔴 这是阅读区里**唯一的 AppKit 视图**（红线「阅读区纯 SwiftUI」的例外，用户拍板）。限定在气泡正文这一块；
/// 滚动/缩放面本身仍是 SwiftUI。几条要守住：
///  · `heightBehavior = .fitsContent`：高度由内容定、不内滚；引擎在这个模式下把滚轮事件交给下一响应者，
///    鼠标停在气泡上照样能滚阅读区；
///  · 外观钉死浅色（`.environment(\.colorScheme, .light)` → 引擎视图的 `NSAppearance` 跟着变）：气泡永远是纸白底；
///  · 字号跟页缩放那种口径下每帧都在变，引擎每次都要重排——按 0.5pt 取整，少触发几次。
struct MarkdownNoteReader: View {
    let text: String
    let fontSize: CGFloat
    /// 正文排版宽度（= 外面给它的 `.frame(width:)`）。显式传进来而不是自己量：公式要按它缩（`FittedLatexRenderer`），
    /// 自己量的话第一帧拿不到宽度、公式没缩，整篇会先歪一帧再归位——阅读区零闪烁纪律不允许。
    let width: CGFloat
    /// 引擎按它分状态（撤销栈/待替换）；同一条笔记在编辑器里是笔记 id，气泡里用 `<id>-bubble` 错开。
    let documentId: String
    /// 同 `MarkdownNoteEditor.wiki`。气泡里 `[[…]]` 要显示成当前标题、点得动，就得给它。
    var wiki: WorkspaceWikiIndex?

    static let baseConfiguration: MarkdownEditorConfiguration = {
        var c = MarkdownEditorConfiguration.default
        c.theme = MarkdownNoteEditor.readerTheme
        c.heightBehavior = .fitsContent
        c.overscroll = OverscrollPolicy(percent: 0, maxPoints: 0, minPoints: 0)
        c.scrollers = .hidden
        c.textInsets = TextInsets(horizontal: 0, vertical: 0)
        c.spellChecking = SpellCheckingPolicy(continuousSpellChecking: false, grammarChecking: false,
                                              automaticSpellingCorrection: false)
        MarkdownNoteEditor.applyNoteTypography(&c)
        return c
    }()

    static func configuration(wiki: WorkspaceWikiIndex?) -> MarkdownEditorConfiguration {
        var c = baseConfiguration
        if let wiki { c.services.wikiLinks = wiki; c.services.images = wiki }
        return c
    }

    var body: some View {
        NoteLatexRenderer.shared.registerBlocks(in: text)   // 块公式按块排版：须先于引擎排版登记（见 `NoteLatexRenderer`）
        return NativeTextViewWrapper(text: .constant(text),
                                     configuration: Self.configuration(wiki: wiki).fittingLatex(to: width),
                                     fontSize: (fontSize * 2).rounded() / 2,
                                     documentId: documentId,
                                     isEditable: false)
            .environment(\.colorScheme, .light)
            // 不吃鼠标（用户 2026-09-16：「关闭文字选择」）：按住卡片任意处拖都是移动卡片（`NoteCardInteraction`），
            // 链接改由卡片的单击去开（`NoteLinkClick`）。
            .allowsHitTesting(false)
    }
}
