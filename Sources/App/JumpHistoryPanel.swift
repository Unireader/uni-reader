import CoreGraphics
import Foundation

/// 跳转历史浮窗的**摆位与开关**（本端记忆：`UserDefaults`，不落库、不上线）。
///
/// 🔴 **一扇窗口一份**（`ContentView` 的 `@StateObject`），与参考窗同样的理由：按会话 id 分的话
/// 「切标签 = 换宿主」，浮窗会被重建、位置丢失；按窗口分才有「切到另一个标签，历史窗还摆在原处」。
///
/// 历史**数据**本身不在这里——它按文档分，挂在 `DocSession.jumps` 上（见 `JumpHistory`），
/// 所以切标签时浮窗内容自然换成那本书的轨迹，位置尺寸不动。
///
/// 刻意**不做折叠气泡**（参考窗有）：那是为了保住小窗里的滚动位置与那份 PDF，而历史窗关掉不丢
/// 任何东西（数据在会话上），再开就是原样，多一枚按钮反而挤。
@MainActor
final class JumpHistoryPanel: ObservableObject {

    private enum K {
        static let w = "jumpPanelW", h = "jumpPanelH"
        static let dx = "jumpPanelDX", dy = "jumpPanelDY"
        static let placed = "jumpPanelPlaced"   // 用户摆过没有（没摆过就用「左下角」这个默认位）
    }

    static let minSize = CGSize(width: 220, height: 180)
    static let defaultSize = CGSize(width: 300, height: 360)

    @Published var isOpen = false
    @Published var size: CGSize
    @Published var offset: CGSize
    /// 用户拖过/改过尺寸没有。没有的话首次打开时按容器宽度摆到左下角，免得和参考窗默认位（右下角）叠一起。
    private(set) var placed: Bool

    init() {
        let d = UserDefaults.standard
        let w = d.double(forKey: K.w), h = d.double(forKey: K.h)
        size = (w >= Self.minSize.width && h >= Self.minSize.height)
            ? CGSize(width: w, height: h) : Self.defaultSize
        offset = CGSize(width: d.double(forKey: K.dx), height: d.double(forKey: K.dy))
        placed = d.bool(forKey: K.placed)
    }

    func toggle() { isOpen.toggle() }
    func close() { isOpen = false }

    /// 首次打开时的默认位：贴容器**左下角**（参考窗默认在右下角，错开才不会一开就叠着）。
    func placeDefault(in container: CGSize) {
        guard !placed else { return }
        // 30 = 让左边缘留出与右下角默认位同量级的边距（clamp 的极限值会贴到只剩 2pt）。
        offset = Self.clampOffset(CGSize(width: -(container.width - size.width - 30), height: 0),
                                  size: size, in: container)
    }

    // MARK: 几何（与参考窗同一套口径：offset 相对**右下角**，≤0 往左上）
    //
    // 🔴 夹取做成静态的：拖动/改尺寸**期间**用视图本地的临时量，别每帧写回 `@Published`
    // （参考窗 2026-08-30 报过「拖拽时内容抖动」就是这么来的）。

    static func clampSize(_ s: CGSize, in container: CGSize) -> CGSize {
        let maxW = max(minSize.width, container.width - 24)
        let maxH = max(minSize.height, container.height - 24)
        return CGSize(width: min(max(s.width, minSize.width), maxW),
                      height: min(max(s.height, minSize.height), maxH))
    }

    static func clampOffset(_ o: CGSize, size: CGSize, in container: CGSize) -> CGSize {
        let minX = -max(0, container.width - size.width - 16)
        let minY = -max(0, container.height - size.height - 16)
        return CGSize(width: min(0, max(o.width, minX)),
                      height: min(0, max(o.height, minY)))
    }

    func setSize(_ s: CGSize, in container: CGSize) { size = Self.clampSize(s, in: container) }

    func setOffset(_ o: CGSize, in container: CGSize) {
        offset = Self.clampOffset(o, size: size, in: container)
    }

    func persistGeometry() {
        let d = UserDefaults.standard
        d.set(size.width, forKey: K.w); d.set(size.height, forKey: K.h)
        d.set(offset.width, forKey: K.dx); d.set(offset.height, forKey: K.dy)
        d.set(true, forKey: K.placed)
        placed = true
    }
}
