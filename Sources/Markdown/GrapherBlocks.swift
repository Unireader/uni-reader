import AppKit
import GrapherKit
import GrapherRender
import MarkdownEngine

// 笔记里的 ```grapher 图形块（方案见 `GRAPHER-BLOCK-PLAN.md`）：
//  `GrapherFencedRenderer`：告诉引擎「grapher 语言的围栏块画成这张图」，光标不在块里时引擎把源码折起来、
//  占一块图的位置；光标进去就是普通代码块，能直接改文字。这张图是静态的（`GraphSnapshot`），也是气泡、批注框里看到的样子。
//  找块（`FencedBlockScan`）与编辑区里叠的实时视图（`FencedBlockOverlay` 盖 `GrapherBlockView`：点一下进入操作状态，
//  拖动旋转、滚轮缩放、改参数滑块，「保存视角」写回块里的文字）与 ```anim 块共用，在 `FencedBlocks.swift`。

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

// 找块、编辑区里的实时视图：与 ```anim 块共用，见 `FencedBlocks.swift`（`FencedBlockScan` / `FencedBlockOverlay`）。
