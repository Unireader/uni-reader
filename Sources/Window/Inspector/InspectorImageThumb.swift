import AppKit
import Combine

/// Inspector「图片」条目左边的缩略图：缓存里没有时先放占位，后台解好了自己换上。
/// `ImageThumbCache` 头一次取图只发起解码、返回 nil，不订阅它就一直停在占位图标上（2026-10-13 用户报）。
/// 解码失败（文件坏了）就留着占位——缓存不会为失败发通知。
final class InspectorImageThumb: NSImageView {
    /// 所需像素宽：48pt × 2 倍屏（落在缓存最小的 256 档，拿到的就是最终那张）。
    static let maxPixel = 96

    private let url: URL?
    private var sub: AnyCancellable?

    /// `url == nil` = 图片文件不在（没在这份副本里，或已清理），显示带叹号的占位。
    init(url: URL?, side: CGFloat) {
        self.url = url
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.6).cgColor
        imageScaling = .scaleProportionallyUpOrDown
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: side).isActive = true
        guard !refresh(), url != nil else { return }
        sub = ImageThumbCache.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.refresh() else { return }
                self.sub = nil
            }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    /// 返回 true = 已换上真图。
    @discardableResult
    private func refresh() -> Bool {
        if let url, let cg = ImageThumbCache.shared.image(url: url, maxPixel: Self.maxPixel) {
            image = NSImage(cgImage: cg, size: .zero)
            contentTintColor = nil
            return true
        }
        image = NSImage(systemSymbolName: url == nil ? "photo.badge.exclamationmark" : "photo", accessibilityDescription: nil)
        contentTintColor = .labelColor
        return false
    }
}
