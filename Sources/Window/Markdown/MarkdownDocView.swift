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
    let workspace: WorkspaceManager
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

    /// 各篇笔记上次看到哪儿（键 = 引擎的 documentId，App 活着期间有效）。
    ///
    /// 切标签时窗格把整个 `MarkdownDocView` 拆掉、切回来再新建一份（`ReaderPaneController.refresh`），
    /// 引擎记在协调器里的滚动偏移随之消失，于是每次切回来都在最上面（2026-09-24 用户报）。
    /// 引擎为这种「拆掉再装回」留了两个口子（`onPersistScrollOffset` / `restoreScrollOffset`），存在这里。
    final class ScrollMemory {
        static let shared = ScrollMemory()
        var offsets: [String: CGFloat] = [:]
    }

    struct Root: View {
        @ObservedObject var box: TextBox
        let documentId: String
        let wiki: WorkspaceWikiIndex?
        let onOpenNote: (String) -> Void
        var body: some View {
            MarkdownDocEditor(text: $box.text, documentId: documentId, wiki: wiki, onOpenNote: onOpenNote,
                              onPersistScrollOffset: { ScrollMemory.shared.offsets[$0] = $1 },
                              restoreScrollOffset: { ScrollMemory.shared.offsets[$0] })
        }
    }

    /// 交给引擎的文档身份（撤销栈、滚动记忆都按它分）。
    private let documentId: String
    /// 顶上那行标题 + 路径。笔记小窗（`NoteWindowController`）不要——窗口标题栏已经写着了。
    private let showsHeader: Bool

    init(ref: NoteRef, workspace: WorkspaceManager, showsHeader: Bool = true) {
        self.ref = ref
        self.workspace = workspace
        self.showsHeader = showsHeader
        let text = workspace.noteBody(ref) ?? ""
        savedText = text
        box = TextBox(text)
        let relay = LinkRelay()
        self.relay = relay
        documentId = "md-\(ref.key)"
        host = NSHostingView(rootView: Root(box: box, documentId: documentId, wiki: workspace.wiki,
                                            onOpenNote: { [relay] in relay.onOpen($0) }))
        host.sizingOptions = []
        super.init(frame: .zero)
        Self.all.add(self)
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
        for v in [header, titleLabel, pathLabel, separator] as [NSView] { v.isHidden = !showsHeader }
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
        // 文件被外部编辑器改了 → 跟着换成新内容（不用切走再切回来）
        observers.append(NotificationCenter.default.addObserver(
            forName: .markdownNotesChangedOnDisk, object: workspace, queue: .main) { [weak self] note in
                let paths = note.userInfo?["paths"] as? Set<String> ?? []
                MainActor.assumeIsolated { self?.reloadFromDisk(ifAmong: paths) }
            })
        // 同一篇在别处（另一个标签 / 笔记小窗 / MCP）存了 → 跟着换成那一版。
        // 外部改动那条通知认不出 App 自己写的（`selfWrittenNotes` 会把它当成自己的滤掉），所以另走这一条。
        observers.append(NotificationCenter.default.addObserver(
            forName: .markdownNoteSavedInApp, object: workspace, queue: .main) { [weak self] note in
                guard let key = note.userInfo?["key"] as? String,
                      let text = note.userInfo?["text"] as? String else { return }
                MainActor.assumeIsolated { self?.applySavedElsewhere(key: key, text: text) }
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

    /// 活着的编辑区（弱引用）。MCP 读写笔记时要找「这篇此刻开在哪些编辑器里」——标签页和笔记小窗都算，
    /// 而小窗不挂在阅读窗格上，只问 `ReaderPaneController` 会漏掉它。
    private static let all = NSHashTable<MarkdownDocView>.weakObjects()

    /// 正显示在窗口里的、编辑这一篇的编辑区（拆下来还没释放的不算）。
    static func editors(showing ref: NoteRef, in workspace: WorkspaceManager) -> [MarkdownDocView] {
        all.allObjects.filter { $0.window != nil && $0.ref == ref && $0.workspace === workspace }
    }

    /// 在 key 窗口里的那个编辑区（笔记小窗是 key 时就是它）。
    static var keyEditor: MarkdownDocView? {
        all.allObjects.first { $0.window?.isKeyWindow == true }
    }

    /// 屏幕上这份编辑器的实时正文。可能比文件里领先不到自动保存的 0.8 秒；Agent/MCP 读当前视图用它。
    var currentText: String { box.text }

    /// MCP 已经把正文原子写入文件后，同步正在显示的编辑器，防止它稍后的自动保存把 Agent 改动盖回去。
    func applySavedText(_ text: String) {
        savedText = text
        if box.text != text { box.text = text }
    }

    /// 外部改了这篇的文件：读回来换上。
    ///
    /// 本地还有没存下去的改动（停手不到 0.8 秒）时**以本地为准**：不换，稍后自动保存照常写盘。
    /// 反过来换成外部那份的话，用户正在打的字会当着他的面消失。
    private func reloadFromDisk(ifAmong paths: Set<String>) {
        guard let url = workspace.noteURL(ref), paths.contains(NoteFileWatcher.canonicalPath(url)) else { return }
        guard let disk = workspace.noteBody(ref), disk != savedText else { return }
        guard box.text == savedText else {
            wsLog("[MD] \(ref.key) 外部有改动，但本地还有未保存的输入，保留本地")
            return
        }
        applySavedText(disk)
    }

    /// 同一篇在 App 里别的编辑器存了一版。规则同外部改动：本地有没存的输入就以本地为准。
    /// 自己存的那一次也会收到（`savedText` 还是旧的、正文就是这一版）——走下面那行只是把 `savedText` 对齐，无害。
    private func applySavedElsewhere(key: String, text: String) {
        guard key == ref.key, text != savedText else { return }
        guard box.text == savedText || box.text == text else { return }
        applySavedText(text)
    }

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
        // 文件已经不在了（被删 / 在 App 外改了名）：别自动存——那会把它在旧路径上凭空建回来。
        guard let url = workspace.noteURL(ref), FileManager.default.fileExists(atPath: url.path) else {
            wsLog("[MD] \(ref.key) 文件已不在，不自动保存")
            return
        }
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

    /// 离开窗口前记下滚到哪儿了。引擎的 `dismantleNSView` 也会记，但它要等托管视图真正释放才跑，
    /// 时机不归我们管；这里在拆之前先记一次，切回来时 `restoreScrollOffset` 一定拿得到。
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, window != nil,
           let scroll = descendantTextView(in: host)?.enclosingScrollView,
           scroll.contentView.bounds.height > 0 {
            ScrollMemory.shared.offsets[documentId] = scroll.contentView.bounds.origin.y
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { save() }   // 切标签 / 关窗
    }

    override func layout() {
        super.layout()
        let b = bounds
        guard showsHeader else {
            host.frame = NSRect(x: 0, y: topInset, width: b.width, height: max(0, b.height - topInset))
            return
        }
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
