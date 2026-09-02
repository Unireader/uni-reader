import CoreGraphics
import CryptoKit
import Foundation

/// 平板页图的**磁盘缓存**：把已经编码好的那张页图字节原样落
/// `~/Library/Caches/<bundleid>/padpage/`，跨换文档、跨关窗、跨重启都还在
/// （2026-08-29 用户提：「不管 macOS 还是安卓端都可以利用好磁盘缓存」）。
///
/// ### 它省的是哪一段
/// 平板要一页图的账是「**等 Mac**（排队 + 栅格化 + 编码，100~300ms）+ 下载 + 解码」。
/// 前一段全部发生在 `LANServer` 那条**串行** queue 上——同一条队列还在跑笔迹 RT 与 WS 广播，
/// 所以它不只是慢，是**压着所有人**（`PageRenderer.Format` 那张表就是为这条队列选的 JPEG）。
/// 内存里那层 `NSCache`（256MB）只兜得住当前这本书常看的几十页，关窗/换文档/重启就没了；
/// 而一页编码后才 200~600KB，**1GB 磁盘能装几千页**，等于这台 Mac 上看过的书基本不用再渲第二遍。
///
/// ### 语义
/// - 键就是内存缓存那个键（`contentHash#页号@档位/格式`）：含内容哈希 → 改了文档自然换键，
///   旧键没人再问，跟着 LRU 老死即可。**别用文件名直接拼键**（含 `/`、可能很长），一律折 SHA-256。
/// - LRU 按文件 `contentModificationDate`：读到就往后推一下，超额时从最旧的删起（删到 90%）。
/// - 落 `Caches/`：系统在磁盘紧张时可以自行清掉，语义正好（丢了只是慢一次，不丢数据）。
/// - **读同步、写异步**：读发生在服务 queue 上（几百 KB 的读是几毫秒，比重渲便宜两个数量级），
///   写与整理一律甩到自己的 utility 队列，不占服务 queue。
final class PageDiskCache {

    /// 平板 `/page.png` 那份（键 = `内容哈希#页@档位/格式`）。
    static let shared = PageDiskCache()

    /// **Mac 阅读区那份**（2026-09-02 加）。键就是 `PageRenderEngine.baseKey`，
    /// 与平板那份分目录、分预算：Mac 的页图宽得多（一页 340KB~1.1MB vs 平板 200~600KB），
    /// 混在一个池子里互相挤兑，谁也说不清是被谁淘汰的。
    ///
    /// 它省的那一段与平板不同：Mac 是**冷启动第一屏**。同一页第一次栅格化 87~168ms
    /// （PDF 内容流要现解析），之后同进程内再渲只要 ~41ms——而进程一退全没了，
    /// 内存那层 LRU 救不了下一次启动。落盘之后，重开一本书 = 解码 + 重绘进 mmap 缓冲，
    /// 实测 5~13ms，**便宜一个数量级**。
    static let reader = PageDiskCache(dirName: "readerpage")

    /// 上限。一页 200~600KB，1GB ≈ 两三千页。
    private let maxBytes: Int
    private let dir: URL
    private let io = DispatchQueue(label: "tech.xvanturing.unireader.pagedisk", qos: .utility)
    /// 只在 [io] 上碰
    private var total = 0
    /// 等着编码的图有几张（见 `storeImage`）。
    private static let maxPendingEncodes = 8
    private let pendingLock = NSLock()
    private var pending = 0

    init(dirName: String = "padpage", maxBytes: Int = 1024 * 1024 * 1024) {
        self.maxBytes = maxBytes
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let bundle = Bundle.main.bundleIdentifier ?? "UniReader"
        dir = base.appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent(dirName, isDirectory: true)
        io.async { [weak self] in self?.scan() }
    }

    /// 命中返回字节（并把它标成「刚用过」）；未命中/读坏一律 nil——丢了只是慢一次。
    func data(for key: String) -> Data? {
        let url = dir.appendingPathComponent(name(key))
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), !d.isEmpty else { return nil }
        io.async { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
        // mmap 的 Data 生命周期挂在文件上（trim 删掉它就悬了），拷一份实在的再交出去。
        return Data(d)
    }

    /// 异步落盘（先写临时文件再改名：中途挂掉不会留下半张图被当成好的读出来）。
    func store(_ data: Data, for key: String) {
        io.async { [weak self] in
            guard let self else { return }
            let url = self.dir.appendingPathComponent(self.name(key))
            if FileManager.default.fileExists(atPath: url.path) { return }
            let tmp = url.appendingPathExtension("tmp")
            do {
                try data.write(to: tmp, options: .atomic)
                try FileManager.default.moveItem(at: tmp, to: url)
                self.total += data.count
                self.trim()
            } catch {
                try? FileManager.default.removeItem(at: tmp)
            }
        }
    }

    /// 收一张还没编码的图（Mac 阅读区用）。
    ///
    /// 🔴 **编码也甩到 [io] 上**：JPEG 一页 6~19ms（PNG 是 86~228ms，见 `PageRenderer.Format` 那张表），
    /// 占的可是渲染队列——那条队列正忙着出下一页，不能替磁盘缓存打工。
    /// 已经有同名文件就直接跳过，连编码都省了。
    ///
    /// 排队里最多压 [maxPendingEncodes] 张：闭包捕获着那张 `CGImage`，而它的像素是 `PageBitmap`
    /// 自持的 mmap 缓冲（一张十几到几十 MB）。正常情况下那张图本来就还在渲染引擎的 LRU 里、
    /// 这个引用不额外占内存；但快滚时 LRU 淘汰得比这条队列排干还快，压太多就等于替它续命。
    /// 超了就直接丢——磁盘缓存丢一张只是下次慢一次。
    func storeImage(_ image: CGImage, for key: String) {
        pendingLock.lock()
        guard pending < Self.maxPendingEncodes else { pendingLock.unlock(); return }
        pending += 1
        pendingLock.unlock()
        io.async { [weak self] in
            guard let self else { return }
            defer { self.pendingLock.lock(); self.pending -= 1; self.pendingLock.unlock() }
            guard !FileManager.default.fileExists(atPath: self.dir.appendingPathComponent(self.name(key)).path)
            else { return }
            guard let data = PageRenderer.encode(image,
                                                 format: .jpeg(quality: PageRenderer.defaultJPEGQuality))
            else { return }
            self.store(data, for: key)
        }
    }

    func clear() {
        io.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.dir)
            try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
            self.total = 0
        }
    }

    // MARK: - 私有

    private func scan() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        total = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        PadLog.log("页图磁盘缓存 \(files.count) 张/\(total / 1024 / 1024)MB，上限 \(maxBytes / 1024 / 1024)MB → \(dir.path)")
        trim()
    }

    /// 超额就从最旧的删起，删到 90% 上限为止（在 [io] 上跑）。
    private func trim() {
        guard total > maxBytes else { return }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        var files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys)) ?? []
        files.sort {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        let want = maxBytes * 9 / 10
        var dropped = 0
        for f in files {
            if total <= want { break }
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if (try? FileManager.default.removeItem(at: f)) != nil { total -= size; dropped += 1 }
        }
        if dropped > 0 { PadLog.log("页图磁盘缓存超额，删掉最旧的 \(dropped) 张 → \(total / 1024 / 1024)MB") }
    }

    /// 键含 `/` 与任意长度，一律折成 SHA-256 十六进制当文件名。
    private func name(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
