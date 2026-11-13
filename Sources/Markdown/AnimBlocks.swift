import AppKit
import MarkdownEngine

// 笔记里的 ```anim 分步演示块（`ANIM-BLOCK-PLAN.md`）：引擎这一侧只要一张静态图（第 0 步 + 控制条的位置），
// 编辑区里再由 `FencedBlockOverlay` 盖上能播放的 `AnimBlockView`。

/// 引擎的围栏块渲染接口：anim 块 → 第 0 步的静态图。
struct AnimFencedRenderer: FencedBlockRenderer {
    static let language = AnimText.language

    let containerWidth: CGFloat
    /// 整篇笔记编辑区：只占位、不画内容。上面盖的 `AnimBlockView` 是透明底（编辑区本身是透明底，取不到一个能盖住的颜色），
    /// 下面要是还有一张第 0 步的图，播到别的步时两张会叠着看见（用户 2026-11-13 截图：两个窗口框）。
    var placeholder = false

    var languages: Set<String> { [Self.language] }

    func render(_ request: FencedBlockRequest, theme: MarkdownEditorTheme) -> FencedBlockRendering? {
        let width = AnimBlockMetrics.clampedWidth(containerWidth)
        guard let picture = AnimImageCache.shared.picture(text: request.content, width: width,
                                                          dark: GrapherFencedRenderer.isDark(theme), controls: true,
                                                          blank: placeholder) else { return nil }
        let size = CGSize(width: width, height: picture.height)
        // 引擎在翻转的坐标里直接 `draw(in:)`：同 grapher，包成「翻转」图片画出来才是正的。
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
}

/// 静态图缓存：引擎每次重排都会再要一遍。
final class AnimImageCache: @unchecked Sendable {
    static let shared = AnimImageCache()

    struct Picture {
        let image: CGImage
        let height: CGFloat
    }

    private struct Key: Hashable {
        let text: String
        let width: Int
        let dark: Bool
        let controls: Bool
        let blank: Bool
        let scale: Int
    }

    private var pictures: [Key: Picture] = [:]
    private let lock = NSLock()
    private static let limit = 32

    func picture(text: String, width: CGFloat, dark: Bool, controls: Bool, blank: Bool = false) -> Picture? {
        let scale = Int(NSScreen.main?.backingScaleFactor ?? 2)
        let key = Key(text: text, width: Int(width), dark: dark, controls: controls, blank: blank, scale: scale)
        lock.lock()
        if let hit = pictures[key] { lock.unlock(); return hit }
        lock.unlock()

        let run = AnimEngine.run(text)
        let rendered: CGImage?
        if blank {
            let height = AnimBlockMetrics(run: run, width: width).height(withControls: controls)
            rendered = AnimSnapshot.render(size: CGSize(width: width, height: height), scale: CGFloat(scale), background: nil) {}
        } else {
            rendered = AnimSnapshot.image(run: run, width: width, step: 0, dark: dark, scale: CGFloat(scale), controls: controls)
        }
        guard let image = rendered else { return nil }
        let picture = Picture(image: image, height: CGFloat(image.height) / CGFloat(scale))
        lock.lock()
        if pictures.count >= Self.limit { pictures.removeAll() }
        pictures[key] = picture
        lock.unlock()
        return picture
    }
}
