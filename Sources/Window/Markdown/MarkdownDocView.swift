import AppKit
import Combine
import SwiftUI

/// 一篇 Markdown 笔记在阅读窗格里的样子（`MARKDOWN-NOTES-PLAN.md §5` 第二批）：
/// 顶上一行标题，下面是整篇编辑区（`MarkdownDocEditor`，引擎的 SwiftUI 包装经 `NSHostingView` 托管）。
///
/// 🔴 **正文以文件为真源**（方案红线 §6）：打开时从文件读，改完**自动存**——
///  · 停手 0.8 秒存一次（不是每敲一个字存一次：每次都是一次原子写 + 一次 SQL）；
///  · 视图离开窗口（切标签 / 关窗）、App 退出，立刻补存一次。
/// 这三条缺一不可：只靠防抖，切标签就会丢掉最后不到一秒的输入。
final class MarkdownDocView: NSView {

    /// 正在编辑的是哪一篇（源 + 源内相对路径）。
    private(set) var ref: NoteRef
    private let workspace: WorkspaceManager
    private let box: TextBox
    private let relay: LinkRelay
    private let host: NSHostingView<Root>
    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let header = NSVisualEffectView()
    private let separator = NSBox()
    private var bag = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    /// 已经落盘的那一版。与 `box.text` 相同 = 没有待存的改动。
    private var savedText: String
    /// 顶部让开工具栏的高度（由窗格设）。
    var topInset: CGFloat = 0 { didSet { if topInset != oldValue { needsLayout = true } } }
    /// 点了正文里的 `[[…]]`：参数是目标笔记的 `NoteRef.key`。
    var onOpenNote: (String) -> Void = { _ in }
    /// 工具栏搜索的命中数 / 当前项变了，让阅读窗格刷新查找状态条。
    var onSearchStateChange: () -> Void = {}

    private(set) var searchQuery = ""
    private(set) var searchRanges: [NSRange] = []
    private(set) var currentSearchIndex: Int?

    final class TextBox: ObservableObject {
        @Published var text: String
        init(_ t: String) { text = t }
    }

    /// 点链接的中转。
    ///
    /// 🔴 **引擎的 `onLinkClick` 只在 `makeCoordinator()` 里捕获一次**——`updateNSView` 刷新了
    /// `onCaretRectChange` / `onBuildContextMenu` / `onInlineSelectionChange` / `onInlinePreviewKey` /
    /// `onCodeBlockSelectionChange` 五个回调，唯独**不刷新它**。所以绝不能「先传个空闭包占位、
    /// 建完再换 `rootView`」：首次渲染只要发生在换之前，协调器就永久攥着那个空闭包，
    /// 点链接静悄悄什么都不发生（2026-09-20 用户报「点了还是跳转不了」，根因就是这个）。
    /// 这里传一个身份固定的中转闭包进去，目标随后再填。
    final class LinkRelay {
        var onOpen: (String) -> Void = { _ in }
    }

    struct Root: View {
        @ObservedObject var box: TextBox
        let documentId: String
        let wiki: WorkspaceWikiIndex?
        let onOpenNote: (String) -> Void
        var body: some View {
            MarkdownDocEditor(text: $box.text, documentId: documentId, wiki: wiki, onOpenNote: onOpenNote)
        }
    }

    init(ref: NoteRef, workspace: WorkspaceManager) {
        self.ref = ref
        self.workspace = workspace
        let text = workspace.noteBody(ref) ?? ""
        savedText = text
        box = TextBox(text)
        let relay = LinkRelay()
        self.relay = relay
        host = NSHostingView(rootView: Root(box: box, documentId: "md-\(ref.key)", wiki: workspace.wiki,
                                            onOpenNote: { [relay] in relay.onOpen($0) }))
        host.sizingOptions = []
        super.init(frame: .zero)
        relay.onOpen = { [weak self] id in self?.openNote(id) }

        header.material = .headerView
        header.blendingMode = .withinWindow
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.lineBreakMode = .byTruncatingTail
        pathLabel.font = .preferredFont(forTextStyle: .caption1)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        separator.boxType = .separator
        for v in [header, titleLabel, pathLabel, separator, host] as [NSView] { addSubview(v) }
        syncHeader()

        box.$text
            .dropFirst()
            .debounce(for: .milliseconds(800), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &bag)
        // 正文编辑后，仍开着查找就按新文本重算。推到下一拍，等引擎先把最新 storage text
        // 同步成编辑器里的 display text（wiki link 两者长度可能不同）。
        box.$text
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.searchQuery.isEmpty else { return }
                    self.rebuildSearch()
                }
            }
            .store(in: &bag)
        // 退出 App 时补存（关窗走 `viewDidMoveToWindow`，退出不保证走到那里）
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.save() }
            })
        // 笔记改名 / 被删 → 顶上那行跟着变
        workspace.$noteTrees
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncHeader() }
            .store(in: &bag)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

    /// 立刻把待存的改动写下去（切标签 / 关窗 / 退出 / 导出前都要叫一次）。
    func flush() { save() }

    // MARK: - 正文查找

    /// 顶部 `NSSearchToolbarItem` 共用的搜索入口。只读编辑器的 display text，绝不改正文。
    func setSearchQuery(_ value: String) {
        let q = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q != searchQuery else { return }
        searchQuery = q
        rebuildSearch()
    }

    func nextSearchMatch() { advanceSearch(by: 1) }
    func previousSearchMatch() { advanceSearch(by: -1) }

    private func rebuildSearch() {
        let oldLocation = currentSearchIndex.flatMap { searchRanges.indices.contains($0) ? searchRanges[$0].location : nil }
        let editor = descendantTextView(in: host)
        // 引擎会把 wiki link 的 storage text 换成 display text；屏幕上看到什么就搜什么。
        let source = editor?.string ?? box.text
        let full = source as NSString
        let q = searchQuery
        var ranges: [NSRange] = []
        if !q.isEmpty, full.length > 0 {
            var cursor = 0
            while cursor < full.length {
                let found = full.range(of: q, options: [.caseInsensitive, .diacriticInsensitive],
                                       range: NSRange(location: cursor, length: full.length - cursor))
                guard found.location != NSNotFound else { break }
                ranges.append(found)
                cursor = found.location + max(found.length, 1)
            }
        }
        searchRanges = ranges
        guard !ranges.isEmpty else {
            currentSearchIndex = nil
            onSearchStateChange()
            return
        }

        let caret = oldLocation ?? editor?.selectedRange().location ?? 0
        currentSearchIndex = ranges.enumerated().min {
            abs($0.element.location - caret) < abs($1.element.location - caret)
        }?.offset ?? 0
        revealCurrentSearchMatch(in: editor)
        onSearchStateChange()
    }

    private func advanceSearch(by delta: Int) {
        guard !searchRanges.isEmpty else { return }
        let count = searchRanges.count
        let current = currentSearchIndex ?? (delta > 0 ? -1 : 0)
        currentSearchIndex = ((current + delta) % count + count) % count
        revealCurrentSearchMatch(in: descendantTextView(in: host))
        onSearchStateChange()
    }

    private func revealCurrentSearchMatch(in editor: NSTextView?) {
        guard let editor, let index = currentSearchIndex, searchRanges.indices.contains(index) else { return }
        let range = searchRanges[index]
        guard NSMaxRange(range) <= (editor.string as NSString).length else { return }
        editor.setSelectedRange(range)
        editor.scrollRangeToVisible(range)
        editor.showFindIndicator(for: range)
    }

    private func descendantTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for child in view.subviews {
            if let found = descendantTextView(in: child) { return found }
        }
        return nil
    }

    private func save() {
        let text = box.text
        guard text != savedText else { return }
        guard workspace.saveNoteBody(ref, text: text) else { return }
        savedText = text
    }

    private func openNote(_ id: String) {
        save()                       // 跳走之前先落盘，别把这一篇最后几个字留在内存里
        onOpenNote(id)
    }

    private func syncHeader() {
        let title = ref.title
        // 引用源在路径前面标上它叫什么，一眼能看出这篇是外部目录里的
        let sourceName = workspace.noteSource(id: ref.sourceID)?.name ?? ""
        let path = sourceName.isEmpty ? ref.relPath : "\(sourceName)/\(ref.relPath)"
        if titleLabel.stringValue != title { titleLabel.stringValue = title }
        if pathLabel.stringValue != path { pathLabel.stringValue = path }
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { save() }   // 切标签 / 关窗
    }

    override func layout() {
        super.layout()
        let b = bounds
        let headerH: CGFloat = 44
        header.frame = NSRect(x: 0, y: 0, width: b.width, height: topInset + headerH)
        let titleY = topInset + 5
        let pad: CGFloat = 16
        titleLabel.frame = NSRect(x: pad, y: titleY, width: max(0, b.width - pad * 2), height: 19)
        pathLabel.frame = NSRect(x: pad, y: titleY + 19, width: max(0, b.width - pad * 2), height: 14)
        separator.frame = NSRect(x: 0, y: header.frame.maxY, width: b.width, height: 1)
        host.frame = NSRect(x: 0, y: separator.frame.maxY,
                            width: b.width, height: max(0, b.height - separator.frame.maxY))
    }

    override var isFlipped: Bool { true }
}
