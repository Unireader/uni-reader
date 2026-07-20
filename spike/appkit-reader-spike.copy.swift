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

/// PDF 列容器：水平方向退出 safe-area 延伸，竖直方向保留。
///
/// 结论（几何日志实测，macOS 26）：PDFView 的水平 contentInsets 支持是坏的——
/// ① 算 fit 缩放时会减掉左右 insets（对），但摆文档位置时「在可用宽里居中」却从 0 起算、
///    漏加 insets.left 平移 → 侧栏越宽内容越向左偏（正是本 bug）；
/// ② 内部 PDFClipView 的滚动夹取（constrainBoundsRect）无视 contentInsets，程序化滚动
///    补偿会被同步打回；直接挪 documentView frame 也会被 PDFKit 同步抢回。
///    → 喂数据/抢布局/补滚动三条路都赢不了它，只能不给它非对称水平 insets。
/// 竖直方向 PDFKit 处理正确（工具栏 scroll-under 虚化一直正常），保留。
/// 视觉上无损：fit-width 阅读时页面恰好占满未遮区，侧栏玻璃下本来就只有背景；
/// 仅放大平移时少了「页面延伸到侧栏玻璃下」这一层（PDFKit 修好前做不到）。
final class SafeAreaPDFContainer: NSView {
    let pdfView = PDFView()

    init() {
        super.init(frame: .zero)
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: topAnchor),      // 竖直贴容器边：保持工具栏下 scroll-under
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // 侧栏动画中 autoScales 的逐帧 refit 会停在中间值，收尾后异步补一次
        pdfView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(pdfFrameChanged),
            name: NSView.frameDidChangeNotification, object: pdfView)
    }
    required init?(coder: NSCoder) { fatalError("unsupported") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func pdfFrameChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let pdfView = self?.pdfView, pdfView.document != nil else { return }
            if pdfView.autoScales {
                let fit = pdfView.scaleFactorForSizeToFit
                if fit > 0.01, abs(pdfView.scaleFactor - fit) > 0.001 {
                    pdfView.scaleFactor = fit
                    pdfView.autoScales = true
                }
            }
            // legacy 滚动条（接鼠标时系统默认）预留 16pt，折叠/展开循环后滚动原点会
            // 残留在这段滑动余量里导致偏心 → 强制 overlay 风格，余量归零
            if let sv = pdfView.documentView?.enclosingScrollView, sv.scrollerStyle != .overlay {
                sv.scrollerStyle = .overlay
            }
        }
    }
}

/// PDF 列：复刻 Preview（连续单页 + 幅优先 + 透明背景）。
final class PDFVC: NSViewController {
    let container = SafeAreaPDFContainer()
    var pdfView: PDFView { container.pdfView }
    override func loadView() { view = container }
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
        // 内容需自己尊重 safe area guide 把主体定位在未遮区。原生 NSScrollView（demo 模式）做得到；
        // PDFView 的水平 insets 支持是坏的（详见 SafeAreaPDFContainer 注释），PDF 列用容器约束落实。
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
    private let openID = NSToolbarItem.Identifier("open")
    private let nightID = NSToolbarItem.Identifier("night")
    private let infoID = NSToolbarItem.Identifier("info")

    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case openID:
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            item.label = "Open"; item.target = self; item.action = #selector(pick)
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
        [openID, .flexibleSpace, nightID, infoID]
    }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [openID, nightID, infoID, .flexibleSpace, .space]
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
