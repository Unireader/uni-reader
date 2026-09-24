import AppKit

/// Agent 面板里点缩略图看原图：一扇普通的可调大小窗口，全 App 只留一扇（再点别的图就换内容）。
///
/// 窗口大小 = 原图的点尺寸（像素 ÷ 屏幕倍率），超过屏幕可用区域的 80% 就等比缩到放得下；
/// 图小于窗口时按原尺寸显示、不拉大。右键可「复制图片」，Esc / ⌘W 关。
@MainActor
final class AgentImageViewer: NSObject, NSWindowDelegate {
    static let shared = AgentImageViewer()

    private var window: NSWindow?

    func show(_ image: AgentImage, near parent: NSWindow?) {
        guard let img = NSImage(data: image.data) else { return }
        let screen = parent?.screen ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        if let rep = img.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            img.size = NSSize(width: CGFloat(rep.pixelsWide) / scale, height: CGFloat(rep.pixelsHigh) / scale)
        }
        let limit = (screen?.visibleFrame.size ?? NSSize(width: 1200, height: 800))
        let fit = min(1, limit.width * 0.8 / max(img.size.width, 1), limit.height * 0.8 / max(img.size.height, 1))
        let size = NSSize(width: max(240, img.size.width * fit), height: max(160, img.size.height * fit))

        let view = NSImageView()
        view.image = img
        view.imageScaling = .scaleProportionallyDown
        view.menu = copyMenu(img)

        let win = window ?? makeWindow()
        win.title = image.caption ?? L("Image")
        win.contentView = view
        win.setContentSize(size)
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let w = Window(contentRect: .zero, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                       backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.colorSpace = .sRGB           // 截图是 sRGB，与页图窗口同一规矩（见 AGENTS.md 红线）
        w.minSize = NSSize(width: 200, height: 140)
        w.delegate = self
        return w
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil      // 关了就放掉图片
    }

    private func copyMenu(_ img: NSImage) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(L("Copy Image")) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([img])
        })
        return menu
    }

    /// Esc 关窗（普通窗口默认不认 Esc）。
    private final class Window: NSWindow {
        override func cancelOperation(_ sender: Any?) { performClose(sender) }
    }
}
