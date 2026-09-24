import CoreServices
import Foundation

/// 盯住几个目录（含子目录）里文件的增删改名（FSEvents 文件级事件），给 Markdown 笔记用：
/// 外部编辑器（Obsidian 等）改了正文 → 开着的那篇跟着变；加 / 删 / 改名 → 侧栏跟着变。
///
/// 回调在**主线程**，参数是这一批变动的路径（`canonicalPath` 口径）。FSEvents 自己按 `latency`
/// 攒一批再报，所以不用另外防抖。实例释放即停。
final class NoteFileWatcher {
    /// 盯着的根目录（`canonicalPath` 口径，已排序）——调用方拿它判断「根变了没，要不要重建」。
    let paths: [String]
    private let onChange: ([String]) -> Void
    private var stream: FSEventStreamRef?

    init?(paths: [String], latency: TimeInterval = 0.3, onChange: @escaping ([String]) -> Void) {
        guard !paths.isEmpty else { return nil }
        self.paths = paths
        self.onChange = onChange
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let me = Unmanaged<NoteFileWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            me.onChange(list.map { $0.precomposedStringWithCanonicalMapping })
        }, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
    }

    deinit {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }

    /// 与 FSEvents 报上来的路径可比的写法：解析符号链接（`/var` → `/private/var`）+ Unicode 统一成组合形式。
    ///
    /// 🔴 别用 `URL.resolvingSymlinksInPath()`：它会反过来把 `/private` 前缀去掉，和 FSEvents 对不上。
    /// 文件不存在（刚被删）时退一步只解析父目录。
    static func canonicalPath(_ url: URL) -> String {
        let p = url.standardizedFileURL.path
        func real(_ s: String) -> String? {
            guard let r = realpath(s, nil) else { return nil }
            defer { free(r) }
            return String(cString: r)
        }
        let out: String
        if let r = real(p) {
            out = r
        } else if let parent = real((p as NSString).deletingLastPathComponent) {
            out = (parent as NSString).appendingPathComponent((p as NSString).lastPathComponent)
        } else {
            out = p
        }
        return out.precomposedStringWithCanonicalMapping
    }
}
