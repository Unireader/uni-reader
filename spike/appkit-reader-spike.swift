// AppKit 阅读器骨架 spike：验证「纯 AppKit 三栏(NSSplitViewController)+ NSToolbar + PDFView」
// 是否天然拿到 macOS 26 半透明工具栏 + 内容 scroll-under 虚化，且不抢标题栏交互、侧栏不崩。
// 这正是 Finder/Notes 的做法。若成立 → 主窗口值得从 SwiftUI 迁到 AppKit 骨架（侧栏/Inspector 用 NSHostingController 复用现有 SwiftUI 视图）。
//
// 运行：
//   swiftc spike/appkit-reader-spike.swift -o /tmp/reader-spike && /tmp/reader-spike
// 启动后选一个 PDF，向上/向下滚动，观察：
//   ① 工具栏是否半透明、PDF 内容滚到其下是否虚化透出（而非被实心条挡住）
//   ② 双击标题栏是否是标题栏行为（缩放/最小化），而不是选中 PDF 文字
//   ③ 左侧玻璃侧栏是否正常（不崩、不左移）

import Cocoa
import PDFKit
import UniformTypeIdentifiers

/// 占位侧栏（真实项目里换成 NSHostingController(rootView: SidebarView(...))）。
final class SidebarVC: NSViewController {
    override func loadView() {
        let v = NSView()
        let label = NSTextField(labelWithString: "Sidebar\n(占位·玻璃侧栏)")
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: v.safeAreaLayoutGuide.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
        ])
        view = v
    }
}

/// 占位 Inspector（真实项目里换成 NSHostingController(rootView: InspectorView(...))）。
final class InspectorVC: NSViewController {
    override func loadView() {
        let v = NSView()
        let label = NSTextField(labelWithString: "Inspector\n(占位)")
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: v.safeAreaLayoutGuide.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
        ])
        view = v
    }
}

/// PDF 列：复刻 Preview（连续单页 + 幅优先 + 透明背景）。
/// 真延伸靠 split item 的 automaticallyAdjustsSafeAreaInsets：真内容画到侧栏玻璃后被虚化（Preview 做法）。
final class PDFVC: NSViewController {
    let pdfView = PDFView()
    override func loadView() {
        if CommandLine.arguments.contains("fullwidth") {
            view = pdfView   // 对照：全宽延伸 → 真延伸但水平左偏（复现 bug）
            return
        }
        // 折中方案：容器包裹。左右钉 safeAreaLayoutGuide（PDFView 挤回未遮区 → 绕开水平居中 bug、居中/fit 正确）；
        // 上下钉容器边缘（垂直是滚动、天然尊重 top inset → 顶部 scroll-under 虚化保留）。
        // 代价：PDFView 水平不到侧栏后 → 侧栏玻璃后不再透出 PDF 内容（放弃侧栏真延伸）。
        let container = NSView()
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: container.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .clear
        pdfView.autoScales = true
        pdfView.maxScaleFactor = 6.0
        pdfView.minScaleFactor = 0.25
    }
    func load(_ url: URL) {
        pdfView.document = PDFDocument(url: url)
        pdfView.layoutDocumentView()
        pdfView.autoScales = true
        pdfView.minScaleFactor = min(0.25, pdfView.scaleFactorForSizeToFit)
    }
}

/// 非 PDF 对照内容：彩色网格 + 原生 NSScrollView（天然支持 pinch magnification 且尊重 safe area）。
/// 命令行加 "demo" 启用，用来判断「真延伸时左偏 / 不能缩放」是 PDFView 特有，还是通病。
final class GridView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen,
                                 .systemBlue, .systemPurple, .systemPink, .systemTeal]
        let cell: CGFloat = 90
        var row = 0, y: CGFloat = 0
        while y < bounds.height {
            var col = 0, x: CGFloat = 0
            while x < bounds.width {
                colors[(row + col) % colors.count].setFill()
                NSBezierPath(rect: NSRect(x: x, y: y, width: cell, height: cell)).fill()
                col += 1; x += cell
            }
            row += 1; y += cell
        }
    }
}

final class DemoScrollVC: NSViewController {
    let scroll = NSScrollView()
    override func loadView() {
        scroll.documentView = GridView(frame: NSRect(x: 0, y: 0, width: 1400, height: 2800))
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.25
        scroll.maxMagnification = 6
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll
    }
}

final class MainSplitVC: NSSplitViewController {
    lazy var contentVC: NSViewController = CommandLine.arguments.contains("demo") ? DemoScrollVC() : PDFVC()
    override func viewDidLoad() {
        super.viewDidLoad()
        let side = NSSplitViewItem(sidebarWithViewController: SidebarVC())
        side.minimumThickness = 200
        let content = NSSplitViewItem(viewController: contentVC)
        // 真延伸（Preview 做法）：内容列 frame 延伸到侧栏/Inspector 玻璃后，真内容画在下面被玻璃虚化。
        // 内容需自己尊重 safe area guide 把主体定位在未遮区，否则整体左偏（正是要对照测的点）。
        content.automaticallyAdjustsSafeAreaInsets = true
        let inspector = NSSplitViewItem(inspectorWithViewController: InspectorVC())
        inspector.minimumThickness = 240
        addSplitViewItem(side)
        addSplitViewItem(content)
        addSplitViewItem(inspector)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    var window: NSWindow!
    let splitVC = MainSplitVC()

    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "AppKit Reader Spike"
        window.contentViewController = splitVC

        let tb = NSToolbar(identifier: "spikeTB")
        tb.delegate = self
        tb.displayMode = .iconOnly
        window.toolbar = tb
        window.toolbarStyle = .unified   // 统一工具栏：内容在其下 scroll-under（Finder 风）

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        pick()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    @objc func pick() {
        guard let pdf = splitVC.contentVC as? PDFVC else { return }   // demo 模式无需选 PDF
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.begin { resp in
            if resp == .OK, let url = panel.url { pdf.load(url) }
        }
    }

    // MARK: - NSToolbar（放几个图标验证半透明）
    private let sidebarID = NSToolbarItem.Identifier("toggleSidebar")
    private let openID = NSToolbarItem.Identifier("open")
    private let dumpID = NSToolbarItem.Identifier("dump")
    private let nightID = NSToolbarItem.Identifier("night")
    private let infoID = NSToolbarItem.Identifier("info")

    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case sidebarID:
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
            item.label = "Sidebar"; item.action = #selector(NSSplitViewController.toggleSidebar(_:))
        case openID:
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            item.label = "Open"; item.target = self; item.action = #selector(pick)
        case dumpID:
            item.image = NSImage(systemSymbolName: "ladybug", accessibilityDescription: nil)
            item.label = "Dump"; item.target = self; item.action = #selector(dumpHierarchy)
        case nightID:
            item.image = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: nil)
            item.label = "Night"
        case infoID:
            item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)
            item.label = "Inspector"
        default: break
        }
        return item
    }
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [sidebarID, openID, dumpID, .flexibleSpace, nightID, infoID]
    }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [sidebarID, openID, dumpID, nightID, infoID, .flexibleSpace, .space]
    }

    // MARK: - 诊断：打印 PDFView 内部层级几何（开/关侧栏各点一次 Dump 对比，看哪层没响应 safe area）
    @objc func dumpHierarchy() {
        guard let pdf = splitVC.contentVC as? PDFVC else { NSLog("demo 模式无 PDFView"); return }
        let v = pdf.pdfView
        NSLog("========== PDFView 层级 dump ==========")
        NSLog("page scaleFactor=%.3f  scaleForFit=%.3f", v.scaleFactor, v.scaleFactorForSizeToFit)
        if let page = v.currentPage {
            let r = v.convert(page.bounds(for: .mediaBox), from: page)
            let sa = v.safeAreaInsets
            let unobLeft = sa.left, unobRight = v.bounds.width - sa.right
            let unobCenter = (unobLeft + unobRight) / 2
            NSLog(">>> 页@PDFView: x=%.0f w=%.0f 页心=%.0f | 未遮区[%.0f~%.0f] 未遮中心=%.0f | 偏移=%.0f",
                  r.origin.x, r.size.width, r.midX, unobLeft, unobRight, unobCenter, r.midX - unobCenter)
        }
        dumpView(v, indent: 0)
    }
    private func dumpView(_ v: NSView, indent: Int) {
        let pad = String(repeating: "· ", count: indent)
        let i = v.safeAreaInsets
        var line = "\(pad)\(type(of: v)) frame=\(rc(v.frame)) bounds=\(rc(v.bounds)) safeArea(l:\(sh(i.left)) r:\(sh(i.right)) t:\(sh(i.top)))"
        if let sv = v as? NSScrollView {
            line += " | contentInsets(l:\(sh(sv.contentInsets.left)) r:\(sh(sv.contentInsets.right))) docVisible=\(rc(sv.documentVisibleRect)) mag=\(sh(sv.magnification))"
        }
        if let cv = v as? NSClipView {
            line += " | clip.origin=(\(sh(cv.bounds.origin.x)),\(sh(cv.bounds.origin.y)))"
        }
        NSLog("%@", line)
        for sub in v.subviews { dumpView(sub, indent: indent + 1) }
    }
    private func rc(_ r: NSRect) -> String {
        "(\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.size.width))x\(Int(r.size.height)))"
    }
    private func sh(_ d: CGFloat) -> String { String(format: "%.0f", d) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
