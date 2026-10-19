// 搜索结果浮窗（`SearchResultsCard`）+ 查找条开关的离屏装配测试：分组行、两行摘要的高度、命中加粗、
// 默认摆在右上角、当前那处高亮并滚进视野、开关显隐、Markdown 下藏开关。运行（CFFIXED_USER_HOME 隔离偏好，免得写进真实 defaults）：
//   cp spike/search-results-card-test.swift /tmp/main.swift && swiftc Sources/Support/L.swift Sources/App/JumpHistoryPanel.swift \
//     Sources/Window/Floating/FloatingCardView.swift Sources/Window/Floating/SearchResultsCard.swift \
//     Sources/Reader/Pane/ReaderPaneWidgets.swift /tmp/main.swift -o /tmp/srct && CFFIXED_USER_HOME=/tmp/srct-home /tmp/srct
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
// `DocSession` / `TextMatch` / `TOCEntry` / `FlippedView` 用最小替身顶上（只留浮窗与查找条碰到的成员）。
import AppKit
import Combine

// ---- 替身 ----
final class FlippedView: NSView { override var isFlipped: Bool { true } }
struct TextMatch: Identifiable, Equatable {
    let id = UUID()
    var page: Int
    var rects: [CGRect] = []
    var frac: Double = 0
    var snippet = ""
    var snippetHit = NSRange(location: 0, length: 0)
}
struct TOCEntry {
    static func chapterLabel(for page: Int, in entries: [TOCEntry]) -> String { page >= 10 ? "第二章 进程管理" : "第一章 概论" }
}
@MainActor final class DocSession: ObservableObject {
    @Published var searchQuery = ""
    @Published var searchMatches: [TextMatch] = []
    @Published var currentMatchIndex: Int?
    @Published var isSearching = false
    var toc: [TOCEntry] = []
    var selected: [Int] = []
    func prevMatch() {}
    func nextMatch() {}
    func selectMatch(_ i: Int) { selected.append(i); currentMatchIndex = i }
}

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }
func spin(_ s: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

func hit(_ page: Int, _ snippet: String, _ word: String) -> TextMatch {
    let r = (snippet as NSString).range(of: word)
    return TextMatch(page: page, snippet: snippet, snippetHit: r)
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let container = FlippedView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let win = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
    win.contentView = container

    let card = SearchResultsCard()
    container.addSubview(card.card)
    card.layout(in: container.bounds.size)
    let s = DocSession()
    s.searchQuery = "操作系统"
    let long = "…我们知道操作系统是计算机系统中最基本的系统软件，它管理硬件资源并为应用程序提供服务，进程线程调度内存管理"
    s.searchMatches = [hit(0, long, "操作系统"), hit(0, "第二处操作系统", "操作系统"), hit(3, "操作系统概论", "操作系统"),
                       hit(10, "进程是操作系统分配资源的单位", "操作系统"), hit(10, "操作系统的五大功能", "操作系统")]
    s.currentMatchIndex = 0

    print("开关与显示")
    check(card.isOpen, "默认开")
    card.bind(s)
    spin()
    check(card.card.isHidden, "没有搜索（active=false）时不显示")
    card.active = true
    spin(0.3)
    check(!card.card.isHidden, "有 PDF 搜索时显示")
    let f = card.card.frame
    check(abs(f.maxX - (800 - FloatingCardView.margin)) < 0.5 && f.minY <= 3,
          "没摆过 → 默认贴右上角（实际 \(f)）")
    card.suppressed = true
    spin(0.3)
    check(card.card.isHidden, "草稿纸盖着时隐去")
    card.suppressed = false
    spin(0.3)
    check(!card.card.isHidden, "草稿纸收起后回来")

    print("列表")
    card.card.layoutSubtreeIfNeeded()
    let table = card.card.body.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTableView }.first
    check(table != nil, "body 里装着表格")
    guard let table else { return }
    check(table.numberOfRows == 8, "3 个页标题 + 5 处命中 = 8 行（实际 \(table.numberOfRows)）")
    let rowH = table.rect(ofRow: 1).height
    check(rowH >= 36, "命中行够放两行字（实际 \(rowH)）")
    table.layoutSubtreeIfNeeded()
    if let v = table.view(atColumn: 0, row: 1, makeIfNecessary: true) {
        v.layoutSubtreeIfNeeded()
        let tf = v.subviews.compactMap { $0 as? NSTextField }.first
        let lineH = NSLayoutManager().defaultLineHeight(for: .preferredFont(forTextStyle: .callout))
        check((tf?.frame.height ?? 0) >= lineH * 2 - 1, "长摘要折成两行（实际高 \(tf?.frame.height ?? 0)，单行 \(lineH)）")
        if let short = table.view(atColumn: 0, row: 2, makeIfNecessary: true) {
            short.layoutSubtreeIfNeeded()
            let st = short.subviews.compactMap { $0 as? NSTextField }.first
            check((st?.frame.height ?? 99) < lineH * 2 - 1 && abs((st?.frame.midY ?? 0) - short.bounds.midY) < 1.5,
                  "短摘要一行、垂直居中（实际 \(st?.frame ?? .zero)）")
        }
        if let a = tf?.attributedStringValue {
            let r = (a.string as NSString).range(of: "操作系统")
            let font = a.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
            let font0 = a.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            check(font?.fontDescriptor.symbolicTraits.contains(.bold) == true, "命中段加粗")
            check(font0?.fontDescriptor.symbolicTraits.contains(.bold) == false, "其余不加粗")
            check(tf?.textColor == .labelColor || a.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .labelColor,
                  "材质底上用主色")
        }
    } else { check(false, "取到命中行视图") }
    if let v = table.view(atColumn: 0, row: 5, makeIfNecessary: true) {
        let labels = v.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        check(labels.contains("第二章 进程管理") && labels.contains("2"), "页标题带章节与本页处数（实际 \(labels)）")
    }
    let current = table.view(atColumn: 0, row: 1, makeIfNecessary: true)?.subviews.first?.layer?.backgroundColor
    check(current != nil, "当前那处（第 0 处）铺了底色")

    print("跟着当前那处走")
    s.currentMatchIndex = 4
    spin()
    let row7 = table.view(atColumn: 0, row: 7, makeIfNecessary: true)?.subviews.first?.layer?.backgroundColor
    let row1 = table.view(atColumn: 0, row: 1, makeIfNecessary: true)?.subviews.first?.layer?.backgroundColor
    check(row7 != nil && row1 == nil, "高亮换到第 4 处（第 7 行），旧的那行撤掉")
    check(table.visibleRect.intersects(table.rect(ofRow: 7)), "第 7 行滚进视野")

    print("重新搜索 / 清空")
    s.searchMatches = [hit(20, "唯一一处", "唯一")]
    s.currentMatchIndex = 0
    spin()
    check(table.numberOfRows == 2, "换一轮结果：1 页标题 + 1 处（实际 \(table.numberOfRows)）")
    s.searchMatches = []
    s.currentMatchIndex = nil
    spin()
    check(table.enclosingScrollView?.isHidden == true, "无命中：列表收起，显示空状态")

    print("关掉")
    card.setOpen(false)
    spin(0.3)
    check(card.card.isHidden && !card.isOpen, "关掉后隐去")
    check(UserDefaults.standard.object(forKey: "searchPanelOpen") as? Bool == false, "开关记进偏好")
    card.setOpen(true)

    print("查找条开关")
    let banner = FindBannerView()
    banner.setListToggle(available: true, on: true)
    let wOn = banner.fittingSize.width
    check(!banner.list.isHidden && banner.list.contentTintColor == .controlAccentColor, "PDF：开关可见，开着用强调色")
    banner.setListToggle(available: false, on: true)
    check(banner.list.isHidden && banner.fittingSize.width < wOn, "Markdown：开关藏起来、查找条变窄")
}

print("\n\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
