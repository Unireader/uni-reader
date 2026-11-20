// 离屏验证 2026-11-20「Agent 面板 / 习题正文里表格中的链接能点」：引擎 `0.15.0-xvan.11` 起表格图上记着每个链接的位置
// （`MarkdownDisplayRenderer.tableLinks` / `tableLink(in:at:)`），`AgentPictureView` 据此给手形指针、处理点击。
// 编的是**真代码**（`AgentMarkdownView` / `AgentMarkdownBlocksView`）。依赖已编好的包模块（先按 AGENTS.md 编一次 Debug 包）。运行：
//
//   D=build/dev/Build/Products/Debug; AD=$(cd $D && pwd); O=/tmp/agent-table-link; mkdir -p $O && cp -R $D/Highlighter_Highlighter.bundle $D/SwiftMath_SwiftMath.bundle $O/ \
//   && cp spike/agent-table-link-test.swift $O/main.swift && swiftc -O -I $D -F $D -framework GrapherEmbed -framework GrapherKit -framework GrapherRender \
//      -Xlinker -rpath -Xlinker $AD $D/MarkdownEngine.o $D/MarkdownEngineLatex.o $D/SwiftMath.o $D/Highlighter.o \
//      Sources/Support/L.swift Sources/Markdown/MarkdownNoteEditor.swift Sources/Markdown/LatexCompat.swift Sources/Markdown/GrapherBlocks.swift \
//      Sources/Markdown/TableEditMenu.swift Sources/Markdown/FencedBlocks.swift Sources/Markdown/AnimBlocks.swift Sources/Anim/*.swift \
//      Sources/Window/AI/AgentMarkdownView.swift Sources/Window/AI/AgentMarkdownBlocksView.swift \
//      Sources/Window/AI/AgentRowView.swift $O/main.swift -o $O/t && $O/t
//
// 盯这几件事：
//  1. 表格段的图上列得出两个链接（`[#42](unireader://…)` 与 `[[书名#page=262]]`），只有表格的图能点（块公式的不能）；
//  2. 真走一遍 `mouseDown`（投一个松开事件进队列）：松开在同一个链接上 → 交给 `openLink`，网址原样、`[[…]]` 是 wikiLinkScheme 网址；
//     松开在别处 → 不打开；按在链接外 → 不拦（往上传）；
//  3. 宽表格横向滚动之后，点的位置照样对得上链接。
// 🔴 `openLink` 一律返回 true（接手），不让 `AgentBlockContext.follow` 真去 `NSWorkspace.open`。
import AppKit
import MarkdownEngine
import SwiftUI

// MARK: - 桩（与本题无关的类型）

final class WorkspaceWikiIndex: WikiLinkResolver, EmbeddedImageProvider, @unchecked Sendable {
    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? { nil }
    func image(for reference: EmbeddedImageRequest) -> NSImage? { nil }
    func fingerprint() -> AnyHashable { 0 }
}

final class NoteLinkCompleter {
    var pending: InlineReplacementRequest?
    var wikiActive = false
    func selectionChanged(_ state: InlineSelectionState?) {}
    func caretRectChanged(_ r: CGRect) {}
    func key(_ k: InlinePreviewKey) -> Bool { false }
}

/// 习题高亮的定位（真身在 `Sources/App/Exercise.swift`，那个文件牵出整个库）；本题不用高亮。
enum ExerciseMark {
    static func locate(_ text: String, nth: Int, in plain: String) -> NSRange? { nil }
}

enum NoteBubble {
    static let editorFontSizeKey = "spike.editorFontSize"
    static let defaultEditorFont: CGFloat = 13
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

// MARK: - 断言与工具

setvbuf(stdout, nil, _IONBF, 0)
var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: String) {
    checks += 1
    print(ok ? "  ✓ \(what)" : "  ✗ \(what)")
    if !ok { failures += 1 }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

func pump(_ seconds: TimeInterval = 0.3) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}

@MainActor
func pictures(in v: NSView) -> [AgentPictureView] {
    var out: [AgentPictureView] = []
    if let p = v as? AgentPictureView { out.append(p) }
    for s in v.subviews { out += pictures(in: s) }
    return out
}

@MainActor
func mouse(_ type: NSEvent.EventType, at windowPoint: NSPoint, in window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [], timestamp: 0,
                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}

/// 一段 Markdown 装进宽 `width` 的窗口排好，`opened` 收 `openLink` 拿到的链接。
@MainActor
func render(_ markdown: String, width: CGFloat, opened: @escaping (Any) -> Void) -> (NSWindow, AgentMarkdownView) {
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800), styleMask: [.titled],
                       backing: .buffered, defer: false)
    let c = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
    win.contentView = c
    let md = AgentMarkdownView(text: markdown, fontSize: 13, documentId: "table-link-spike-\(width)")
    md.openLink = { link in opened(link); return true }
    md.translatesAutoresizingMaskIntoConstraints = false
    c.addSubview(md)
    NSLayoutConstraint.activate([md.leadingAnchor.constraint(equalTo: c.leadingAnchor),
                                 md.topAnchor.constraint(equalTo: c.topAnchor),
                                 md.widthAnchor.constraint(equalTo: c.widthAnchor)])
    c.layoutSubtreeIfNeeded()
    pump()
    c.layoutSubtreeIfNeeded()
    return (win, md)
}

/// 链接在图上的中心点 → 窗口坐标。
@MainActor
func windowPoint(of link: MarkdownDisplayRenderer.TableLink, in picture: AgentPictureView) -> NSPoint {
    picture.convert(NSPoint(x: link.rect.midX, y: link.rect.midY), to: nil)
}

// MARK: 1 + 2. 窄表格

@MainActor
func testNarrow() {
    print("1. 表格图上的链接 / 2. 点击")
    var opened: [Any] = []
    let markdown = """
    前面一段。

    | 题 | 出处 |
    |---|---|
    | [#42](unireader://open?ws=%2FUsers%2Fa&doc=1) | [[书名#page=262]]【2009】 |

    $$x^2$$
    """
    let (win, md) = render(markdown, width: 600) { opened.append($0) }
    withExtendedLifetime(md) {}
    let all = pictures(in: win.contentView!)
    let tables = all.filter { $0.openLink != nil }
    check(all.count == 2, "两张图（表格 + 公式），实得 \(all.count)")
    check(tables.count == 1, "只有表格的图能点，实得 \(tables.count)")
    guard let picture = tables.first, let image = picture.image else { return }
    check(abs(picture.bounds.width - image.size.width) < 0.5, "表格图按原尺寸画（比例 1）")
    let links = MarkdownDisplayRenderer.tableLinks(in: image)
    check(links.count == 2, "列出两个链接，实得 \(links.count)")
    guard links.count == 2 else { return }
    let url = links[0], wiki = links[1]
    check(url.url == URL(string: "unireader://open?ws=%2FUsers%2Fa&doc=1"), "第一个是 unireader 网址原样")
    check(MarkdownDisplayRenderer.wikiLinkTarget(wiki.url) == "书名#page=262", "第二个是 [[…]]，解得出名字")
    check(picture.link(atWindowPoint: windowPoint(of: url, in: picture)) == url.url, "链接中心点得到这个链接")
    check(picture.link(atWindowPoint: picture.convert(NSPoint(x: 2, y: 2), to: nil)) == nil, "表格角上不是链接")

    // 真走 mouseDown：先投一个松开事件，跟踪循环收到它
    let on = windowPoint(of: url, in: picture)
    NSApp.postEvent(mouse(.leftMouseUp, at: on, in: win), atStart: false)
    picture.mouseDown(with: mouse(.leftMouseDown, at: on, in: win))
    check(opened.count == 1 && (opened.first as? URL) == url.url, "按下松开都在链接上 → 交给 openLink：\(opened)")

    let wikiOn = windowPoint(of: wiki, in: picture)
    NSApp.postEvent(mouse(.leftMouseUp, at: wikiOn, in: win), atStart: false)
    picture.mouseDown(with: mouse(.leftMouseDown, at: wikiOn, in: win))
    check(opened.count == 2 && MarkdownDisplayRenderer.wikiLinkTarget(opened.last as Any) == "书名#page=262",
          "[[…]] → wikiLinkScheme 网址交给 openLink")

    NSApp.postEvent(mouse(.leftMouseUp, at: picture.convert(NSPoint(x: 2, y: 2), to: nil), in: win), atStart: false)
    picture.mouseDown(with: mouse(.leftMouseDown, at: on, in: win))
    check(opened.count == 2, "松开在别处 → 不打开")
    // 投进去的松开事件被吃掉了没有（按在链接外时 mouseDown 不进跟踪循环，下面单独验）
    let leftover = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true)
    check(leftover == nil, "没有剩下没被收走的事件")

    check(!picture.finishPress(on: url.url, releasedAt: picture.convert(NSPoint(x: 2, y: 2), to: nil)),
          "finishPress：松开点不在链接上 → 不打开")
}

// MARK: 3. 宽表格横向滚动之后

@MainActor
func testWide() {
    print("3. 宽表格横向滚动之后")
    var opened: [Any] = []
    let cols = (1...12).map { "列\($0)" }
    let header = "| " + cols.joined(separator: " | ") + " |"
    let rule = "|" + String(repeating: "---|", count: cols.count)
    let row = "| " + (1...11).map { "第\($0)格内容比较长" }.joined(separator: " | ") + " | [最后](https://example.com/last) |"
    let (win, md) = render([header, rule, row].joined(separator: "\n"), width: 360) { opened.append($0) }
    withExtendedLifetime(md) {}
    guard let picture = pictures(in: win.contentView!).first(where: { $0.openLink != nil }), let image = picture.image,
          let scroll = picture.enclosingScrollView else {
        check(false, "宽表格放进了横向滚动")
        return
    }
    check(image.size.width > 360, "表格比版面宽（\(Int(image.size.width))pt），在横向滚动里")
    guard let link = MarkdownDisplayRenderer.tableLinks(in: image).last else { check(false, "列出链接"); return }
    scroll.contentView.scroll(to: NSPoint(x: image.size.width - scroll.contentView.bounds.width, y: 0))
    scroll.reflectScrolledClipView(scroll.contentView)
    let on = windowPoint(of: link, in: picture)
    check(win.contentView!.bounds.contains(win.contentView!.convert(on, from: nil)), "滚到最右，最后一列的链接露在窗口里")
    NSApp.postEvent(mouse(.leftMouseUp, at: on, in: win), atStart: false)
    picture.mouseDown(with: mouse(.leftMouseDown, at: on, in: win))
    check((opened.first as? URL) == URL(string: "https://example.com/last"), "滚动后点最后一列的链接 → 打开它：\(opened)")
}

_ = NSApplication.shared
MainActor.assumeIsolated {
    testNarrow()
    testWide()
}
print(failures == 0 ? "全部通过（\(checks) 项）" : "失败 \(failures) / \(checks) 项")
exit(failures == 0 ? 0 : 1)
