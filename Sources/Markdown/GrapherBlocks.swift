import AppKit
import GrapherEmbed
import GrapherKit
import GrapherRender
import MarkdownEngine

// 笔记里的 ```grapher 图形块（方案见 `GRAPHER-BLOCK-PLAN.md`）。三件事：
//  ① `GrapherFencedRenderer`：告诉引擎「grapher 语言的围栏块画成这张图」，光标不在块里时引擎把源码折起来、
//     占一块图的位置；光标进去就是普通代码块，能直接改文字。这张图是静态的（`GraphSnapshot`），也是气泡、批注框里看到的样子。
//  ② `GrapherBlockScan`：在笔记正文里找出所有 ```grapher 块（编辑区里叠视图、存回改动都按它定位）。
//  ③ `GrapherBlockOverlay`：整篇笔记编辑区里，在每张图上叠一个可操作的实时视图（`GrapherBlockView`）：
//     点一下进入操作状态，拖动旋转、滚轮缩放、改参数滑块，「保存视角」把改动写回块里的文字。

/// 引擎的围栏块渲染接口（`FencedBlockRenderer`）：grapher 块 → 静态图。
struct GrapherFencedRenderer: FencedBlockRenderer {
    static let language = "grapher"
    /// 一块图最宽多少点：再宽就是一整个屏幕，3D 图拉那么大没有意义。
    static let maxBlockWidth: CGFloat = 640
    static let minBlockWidth: CGFloat = 200

    /// 文本容器宽（点）；0 = 还没量到。
    let containerWidth: CGFloat

    var languages: Set<String> { [Self.language] }

    func render(_ request: FencedBlockRequest, theme: MarkdownEditorTheme) -> FencedBlockRendering? {
        let width = min(max(containerWidth, Self.minBlockWidth), Self.maxBlockWidth).rounded(.down)
        let dark = Self.isDark(theme)
        guard let picture = GrapherImageCache.shared.picture(text: request.content, width: width, dark: dark) else { return nil }
        let size = CGSize(width: width, height: picture.height)
        // 引擎在翻转的坐标里直接 `draw(in:)`，位图图片会上下颠倒；包成「翻转」图片，画出来才是正的。
        let bitmap = NSImage(cgImage: picture.image, size: size)
        let upright = NSImage(size: size, flipped: true) { rect in
            bitmap.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
        return FencedBlockRendering(image: upright, size: size)
    }

    func fingerprint() -> AnyHashable {
        AnyHashable("\(Int(containerWidth.rounded(.down)))|\(NSApp.effectiveAppearance.name.rawValue)")
    }

    /// 主题的正文字色亮 = 深色背景。气泡永远是纸白底（正文深色），不跟系统外观走。
    static func isDark(_ theme: MarkdownEditorTheme) -> Bool {
        guard let c = theme.bodyText.usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.55
    }
}

/// 静态图缓存：引擎每次重排都会再要一遍，3D 图出一张几十毫秒，不能每次都画。
final class GrapherImageCache: @unchecked Sendable {
    static let shared = GrapherImageCache()

    struct Picture {
        let image: CGImage
        let height: CGFloat
    }

    private struct Key: Hashable {
        let text: String
        let width: Int
        let dark: Bool
        let scale: Int
    }

    private var pictures: [Key: Picture] = [:]
    private let lock = NSLock()
    /// 张数上限：每张几 MB，超了整个清掉重新攒（屏上这几块下次排版时会重画）。
    private static let limit = 24

    func picture(text: String, width: CGFloat, dark: Bool) -> Picture? {
        let scale = Int(NSScreen.main?.backingScaleFactor ?? 2)
        let key = Key(text: text, width: Int(width), dark: dark, scale: scale)
        lock.lock()
        if let hit = pictures[key] { lock.unlock(); return hit }
        lock.unlock()

        let rendering = GraphSnapshot.image(text: text, pixelWidth: Int(width) * scale, theme: dark ? .dark : .light,
                                            pointScale: Double(scale), quality: .full)
        guard let image = rendering.image else { return nil }
        let picture = Picture(image: image, height: (width / CGFloat(rendering.aspect)).rounded())
        lock.lock()
        if pictures.count >= Self.limit { pictures.removeAll() }
        pictures[key] = picture
        lock.unlock()
        return picture
    }
}

// MARK: - 找块

/// 笔记正文里的 ```grapher 块。配对规则同引擎：一行以 ``` 开头 = 开，之后第一行以 ``` 开头 = 关；没有关闭的不算。
enum GrapherBlockScan {
    struct Block: Equatable {
        /// 整个块：开头那行到关闭围栏的三个反引号。
        let range: NSRange
        /// 两道围栏之间的文字（含换行）。
        let content: NSRange
        /// 去掉首尾空白的文字，就是交给 `GrapherBlockView` 的源。
        let text: String
    }

    static func blocks(in source: String) -> [Block] {
        guard source.contains("```") else { return [] }
        let ns = source as NSString
        var found: [Block] = []
        var open: (start: Int, contentStart: Int, isGrapher: Bool)?
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let text = ns.substring(with: line)
            if text.hasPrefix("```") {
                if let current = open {
                    if current.isGrapher {
                        let content = NSRange(location: current.contentStart, length: line.location - current.contentStart)
                        found.append(Block(
                            range: NSRange(location: current.start, length: line.location + 3 - current.start),
                            content: content,
                            text: ns.substring(with: content).trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                    open = nil
                } else {
                    let word = text.drop { $0 == "`" }.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    open = (line.location, NSMaxRange(line), word == GrapherFencedRenderer.language)
                }
            }
            if NSMaxRange(line) <= location { break }
            location = NSMaxRange(line)
        }
        return found
    }
}

// MARK: - 编辑区里的实时视图

/// 整篇笔记编辑区里盖在每张图上的实时视图。
///
/// 引擎把光标不在里面的 ```grapher 块画成一张静态图（`GrapherFencedRenderer`），图的位置用引擎的
/// `renderedBlockFrames` 查；这里在那个位置盖一个 `GrapherBlockView`：平时看上去就是那张图，点一下才进入操作状态。
/// 视图是编辑区 `NSTextView` 的子视图，跟着文字一起滚。
///
/// 只给「视口里」的块建视图（一篇笔记几十个 3D 图，每个一个 Metal 视图太重）；滚出去的拆掉，滚回来再建。
/// 光标进了块（改文字）→ 引擎把源码露出来 → 这块不在查询结果里 → 视图拆掉；光标出来再盖上。
/// 视图的改动（「保存视角」）经文字视图的标准改动流程写回（可撤销，绑定与自动存盘照常走）。
@MainActor
final class GrapherBlockOverlay {
    private weak var host: NSView?
    private weak var textView: NSTextView?
    private var views: [Int: GrapherBlockView] = [:]
    private var observers: [NSObjectProtocol] = []
    private var refreshScheduled = false
    private var attachAttempts = 0

    init(host: NSView) {
        self.host = host
    }

    /// 找到编辑区的文字视图并开始跟随。视图树是 SwiftUI 异步建出来的，找不到就隔一会再找。
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
        for view in views.values { view.removeFromSuperview() }
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
        if let tv = view as? NSTextView, tv.isEditable { return tv }
        for sub in view.subviews {
            if let hit = editableTextView(in: sub) { return hit }
        }
        return nil
    }

    // MARK: 对一遍

    private func refresh() {
        guard let tv = textView, tv.window != nil else { return }
        let blocks = GrapherBlockScan.blocks(in: tv.string)
        guard !blocks.isEmpty else {
            for view in views.values { view.removeFromSuperview() }
            views.removeAll()
            return
        }

        var used = Set<Int>()
        for item in tv.renderedBlockFrames(in: viewportRange(of: tv)) {
            guard let index = blocks.firstIndex(where: { NSLocationInRange(item.anchor.location, $0.content) }) else { continue }
            let view: GrapherBlockView
            if let existing = views[index] {
                view = existing
            } else {
                guard let made = GrapherBlockView(source: blocks[index].text) else { continue }
                made.onSourceChange = { [weak self, weak made] text in
                    guard let self, let made else { return }
                    self.write(text, from: made)
                }
                made.onEditSource = { [weak self, weak made] in
                    guard let self, let made else { return }
                    self.revealSource(of: made)
                }
                views[index] = made
                view = made
            }
            view.setSource(blocks[index].text)
            if view.superview !== tv { tv.addSubview(view) }
            if view.frame != item.frame { view.frame = item.frame }
            used.insert(index)
        }
        for (index, view) in views where !used.contains(index) {
            view.removeFromSuperview()
            views[index] = nil
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

    private func index(of view: GrapherBlockView) -> Int? {
        views.first { $0.value === view }?.key
    }

    /// 「保存视角」：把这块的文字换成新的（视角、参数值已经由 `GrapherText.patch` 改好，其余一个字不动）。
    private func write(_ text: String, from view: GrapherBlockView) {
        guard let tv = textView, let index = index(of: view) else { return }
        let blocks = GrapherBlockScan.blocks(in: tv.string)
        guard blocks.indices.contains(index) else { return }
        let range = blocks[index].content
        let replacement = text + "\n"
        guard tv.shouldChangeText(in: range, replacementString: replacement) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: replacement)
        tv.didChangeText()
    }

    /// 「编辑文字」：光标放进块里，引擎就把源码露出来。
    private func revealSource(of view: GrapherBlockView) {
        guard let tv = textView, let index = index(of: view) else { return }
        let blocks = GrapherBlockScan.blocks(in: tv.string)
        guard blocks.indices.contains(index) else { return }
        view.setActive(false)
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: blocks[index].content.location, length: 0))
        tv.scrollRangeToVisible(blocks[index].range)
    }
}
