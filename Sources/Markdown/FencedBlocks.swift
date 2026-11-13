import AppKit
import GrapherEmbed
import MarkdownEngine

// 笔记里「画成图、还能操作」的围栏块的公共部分（```grapher `GRAPHER-BLOCK-PLAN.md`、```anim `ANIM-BLOCK-PLAN.md`）：
//  ① `NoteFencedRenderer`：引擎只能挂一个围栏块渲染器，这里按语言分派。
//  ② `FencedBlockScan`：在正文里找这些块（叠视图、写回改动都按它定位）。
//  ③ `FencedBlockOverlay`：整篇笔记编辑区里，在每张静态图上叠一个实时视图（只给视口里的建，光标进块就拆）。

/// 按语言分派的围栏块渲染器（`fittingLatex(to:)` 装它）。
struct NoteFencedRenderer: FencedBlockRenderer {
    let containerWidth: CGFloat
    /// 整篇笔记编辑区：上面会盖实时视图（见 `AnimFencedRenderer.placeholder`）。
    var liveBlocks = false

    var languages: Set<String> { [GrapherFencedRenderer.language, AnimFencedRenderer.language] }

    func render(_ request: FencedBlockRequest, theme: MarkdownEditorTheme) -> FencedBlockRendering? {
        switch request.language.lowercased() {
        case GrapherFencedRenderer.language: return GrapherFencedRenderer(containerWidth: containerWidth).render(request, theme: theme)
        case AnimFencedRenderer.language:
            return AnimFencedRenderer(containerWidth: containerWidth, placeholder: liveBlocks).render(request, theme: theme)
        default: return nil
        }
    }

    /// 两种图都只依赖宽度与外观。
    func fingerprint() -> AnyHashable { GrapherFencedRenderer(containerWidth: containerWidth).fingerprint() }
}

// MARK: - 找块

/// 正文里指定语言的围栏块。配对规则同引擎：一行以 ``` 开头 = 开，之后第一行以 ``` 开头 = 关；没有关闭的不算。
enum FencedBlockScan {
    struct Block: Equatable {
        /// 围栏后的语言（小写）。
        let language: String
        /// 整个块：开头那行到关闭围栏的三个反引号。
        let range: NSRange
        /// 两道围栏之间的文字（含换行）。
        let content: NSRange
        /// 去掉首尾空白的文字。
        let text: String
    }

    static func blocks(in source: String, languages: Set<String>) -> [Block] {
        guard source.contains("```") else { return [] }
        let ns = source as NSString
        var found: [Block] = []
        var open: (start: Int, contentStart: Int, language: String)?
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let text = ns.substring(with: line)
            if text.hasPrefix("```") {
                if let current = open {
                    if languages.contains(current.language) {
                        let content = NSRange(location: current.contentStart, length: line.location - current.contentStart)
                        found.append(Block(
                            language: current.language,
                            range: NSRange(location: current.start, length: line.location + 3 - current.start),
                            content: content,
                            text: ns.substring(with: content).trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                    open = nil
                } else {
                    let word = text.drop { $0 == "`" }.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    open = (line.location, NSMaxRange(line), word)
                }
            }
            if NSMaxRange(line) <= location { break }
            location = NSMaxRange(line)
        }
        return found
    }
}

// MARK: - 编辑区里的实时视图

/// 能盖在围栏块静态图上的实时视图。
@MainActor
protocol FencedLiveBlock: NSView {
    func setSource(_ text: String)
    /// 拆掉 / 光标进块前：退出操作状态、停播放。
    func deactivate()
}

extension GrapherBlockView: FencedLiveBlock {
    func deactivate() { setActive(false) }
}

extension AnimBlockView: FencedLiveBlock {}

/// 整篇笔记编辑区里盖在每张图上的实时视图。
///
/// 引擎把光标不在里面的块画成一张静态图，图的位置用引擎的 `renderedBlockFrames` 查；这里在那个位置盖一个实时视图。
/// 视图是编辑区 `NSTextView` 的子视图，跟着文字一起滚。
///
/// 只给「视口里」的块建视图（一篇笔记几十个 3D 图，每个一个 Metal 视图太重）；滚出去的拆掉，滚回来再建。
/// 光标进了块（改文字）→ 引擎把源码露出来 → 这块不在查询结果里 → 视图拆掉；光标出来再盖上。
/// 视图的改动（grapher「保存视角」）经文字视图的标准改动流程写回（可撤销，绑定与自动存盘照常走）。
@MainActor
final class FencedBlockOverlay {
    struct Kind {
        let language: String
        /// 给一块的文字建视图；回调里用 `overlay.write` / `overlay.revealSource` 接上「存回」「编辑文字」。
        let make: (_ source: String, _ overlay: FencedBlockOverlay) -> (NSView & FencedLiveBlock)?
    }

    private weak var host: NSView?
    private weak var textView: NSTextView?
    private let kinds: [String: Kind]
    /// 键：语言 + 这种语言里的第几块。
    private var views: [String: NSView & FencedLiveBlock] = [:]
    private var observers: [NSObjectProtocol] = []
    private var refreshScheduled = false
    private var attachAttempts = 0

    init(host: NSView, kinds: [Kind]) {
        self.host = host
        self.kinds = Dictionary(kinds.map { ($0.language, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// 笔记编辑区用的两种：grapher 图形块、anim 分步演示块。
    static func noteEditor(host: NSView) -> FencedBlockOverlay {
        FencedBlockOverlay(host: host, kinds: [
            Kind(language: GrapherFencedRenderer.language) { source, overlay in
                guard let view = GrapherBlockView(source: source) else { return nil }
                view.onSourceChange = { [weak overlay, weak view] text in
                    guard let overlay, let view else { return }
                    overlay.write(text, from: view)
                }
                view.onEditSource = { [weak overlay, weak view] in
                    guard let overlay, let view else { return }
                    overlay.revealSource(of: view)
                }
                return view
            },
            Kind(language: AnimFencedRenderer.language) { source, overlay in
                let view = AnimBlockView(source: source)
                view.onEditSource = { [weak overlay, weak view] in
                    guard let overlay, let view else { return }
                    overlay.revealSource(of: view)
                }
                return view
            },
        ])
    }

    /// 找到编辑区的文字视图并开始跟随（只读的笔记也要盖：anim 块在这里只有占位图）。视图树是 SwiftUI 异步建出来的，找不到就隔一会再找。
    func start() {
        guard textView == nil else { return }
        if let found = host.flatMap(Self.editableTextView(in:)) {
            attach(to: found)
            return
        }
        attachAttempts += 1
        guard attachAttempts < 40 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.start() }
    }

    func tearDown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for view in views.values { view.deactivate(); view.removeFromSuperview() }
        views.removeAll()
    }

    /// 正文、选区、尺寸、滚动位置变了都要重新对一遍；合并成一次，再补一次等引擎排版落定。
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    private func attach(to tv: NSTextView) {
        textView = tv
        let center = NotificationCenter.default
        tv.postsFrameChangedNotifications = true
        observers.append(center.addObserver(forName: NSText.didChangeNotification, object: tv, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        })
        observers.append(center.addObserver(forName: NSTextView.didChangeSelectionNotification, object: tv, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        })
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: tv, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        })
        if let clip = tv.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
        scheduleRefresh()
    }

    private static func editableTextView(in view: NSView) -> NSTextView? {
        firstTextView(in: view, editable: true) ?? firstTextView(in: view, editable: false)
    }

    private static func firstTextView(in view: NSView, editable: Bool) -> NSTextView? {
        if let tv = view as? NSTextView, !editable || tv.isEditable { return tv }
        for sub in view.subviews {
            if let hit = firstTextView(in: sub, editable: editable) { return hit }
        }
        return nil
    }

    // MARK: 对一遍

    private func currentBlocks(_ tv: NSTextView) -> [(key: String, block: FencedBlockScan.Block)] {
        var ordinal: [String: Int] = [:]
        return FencedBlockScan.blocks(in: tv.string, languages: Set(kinds.keys)).map { block in
            let n = ordinal[block.language, default: 0]
            ordinal[block.language] = n + 1
            return ("\(block.language)#\(n)", block)
        }
    }

    private func refresh() {
        guard let tv = textView, tv.window != nil else { return }
        let blocks = currentBlocks(tv)
        guard !blocks.isEmpty else {
            for view in views.values { view.deactivate(); view.removeFromSuperview() }
            views.removeAll()
            return
        }

        var used = Set<String>()
        for item in tv.renderedBlockFrames(in: viewportRange(of: tv)) {
            guard let found = blocks.first(where: { NSLocationInRange(item.anchor.location, $0.block.content) }),
                  let kind = kinds[found.block.language] else { continue }
            let view: NSView & FencedLiveBlock
            if let existing = views[found.key] {
                view = existing
            } else {
                guard let made = kind.make(found.block.text, self) else { continue }
                views[found.key] = made
                view = made
            }
            view.setSource(found.block.text)
            if view.superview !== tv { tv.addSubview(view) }
            if view.frame != item.frame { view.frame = item.frame }
            used.insert(found.key)
        }
        for (key, view) in views where !used.contains(key) {
            view.deactivate()
            view.removeFromSuperview()
            views[key] = nil
        }
    }

    /// 视口（加上引擎给的缓冲）覆盖的字符范围；取不到就整篇。
    private func viewportRange(of tv: NSTextView) -> NSRange? {
        guard let layout = tv.textLayoutManager,
              let content = layout.textContentManager as? NSTextContentStorage,
              let viewport = layout.textViewportLayoutController.viewportRange else { return nil }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
        guard start != NSNotFound, end != NSNotFound, end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private func block(of view: NSView) -> FencedBlockScan.Block? {
        guard let tv = textView, let key = views.first(where: { $0.value === view })?.key else { return nil }
        return currentBlocks(tv).first { $0.key == key }?.block
    }

    /// 把这块的文字换成新的（grapher「保存视角」：视角、参数值已由 `GrapherText.patch` 改好，其余一个字不动）。
    func write(_ text: String, from view: NSView) {
        guard let tv = textView, let block = block(of: view) else { return }
        let range = block.content
        let replacement = text + "\n"
        guard tv.shouldChangeText(in: range, replacementString: replacement) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: replacement)
        tv.didChangeText()
    }

    /// 「编辑文字」：光标放进块里，引擎就把源码露出来。
    func revealSource(of view: NSView & FencedLiveBlock) {
        guard let tv = textView, let block = block(of: view) else { return }
        view.deactivate()
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: block.content.location, length: 0))
        tv.scrollRangeToVisible(block.range)
    }
}
