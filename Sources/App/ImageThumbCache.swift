import CoreGraphics
import Foundation

/// 图片笔记的缩略图缓存（气泡 / Inspector / 编辑器共用）：按「文件路径 + 像素档」缓存解码好的 `CGImage`，
/// 解码在后台队列做，解好了 bump `version`，**只有正在显示那张图的叶子视图**订阅它——
/// 别让 `ReaderSurface` 订阅（App 级 `@Published` 一变就重算整个阅读区，`readZoom` 那条老账）。
///
/// 像素档只有几个（256 / 512 / 1024 / 原图）：气泡跟页缩放，请求的像素宽每帧都在变，
/// 按精确宽缓存等于每帧一次解码。取**不小于所需**的最小档，显示时再缩。
@MainActor
final class ImageThumbCache: ObservableObject {
    static let shared = ImageThumbCache()

    @Published private(set) var version = 0

    private let cache = NSCache<NSString, CGImage>()
    private var inflight: Set<String> = []
    private let queue = DispatchQueue(label: "tech.xvanturing.unireader.thumbs", qos: .userInitiated)

    static let buckets = [256, 512, 1024]

    private init() {
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    /// 所需像素宽 → 档位（超过最大档就要原图，传 nil）。
    static func bucket(for px: Int) -> Int? {
        buckets.first { $0 >= px }
    }

    /// 取缩略图：有就同步返回；没有就后台解码、先返回 nil（也可能返回一张**更小档**的先顶着，免得空一下）。
    func image(url: URL, maxPixel px: Int) -> CGImage? {
        let bucket = Self.bucket(for: px)
        let key = Self.key(url, bucket)
        if let hit = cache.object(forKey: key as NSString) { return hit }
        request(url: url, bucket: bucket, key: key)
        // 退而求其次：已有的更小档里最大的那个先顶上（糊一点总比空一块好），解好了 version 一变就换成清晰的
        for b in Self.buckets.reversed() where (bucket.map { b < $0 } ?? true) {
            if let smaller = cache.object(forKey: Self.key(url, b) as NSString) { return smaller }
        }
        return nil
    }

    private func request(url: URL, bucket: Int?, key: String) {
        guard !inflight.contains(key) else { return }
        inflight.insert(key)
        queue.async { [weak self] in
            let img = ImageAssets.load(url, maxPixel: bucket)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inflight.remove(key)
                if let img {
                    self.cache.setObject(img, forKey: key as NSString, cost: img.bytesPerRow * img.height)
                    self.version &+= 1
                }
            }
        }
    }

    /// 图片被清理/工作区关掉后不必主动清——键带路径，路径不复用；NSCache 自己按成本淘汰。

    private static func key(_ url: URL, _ bucket: Int?) -> String {
        "\(url.path)#\(bucket.map(String.init) ?? "full")"
    }
}
