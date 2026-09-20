import AppKit
import MarkdownEngine

/// 笔记引擎的两个服务：`[[…]]` 指向哪篇笔记（`WikiLinkResolver`）、`![[…]]` 的图片字节从哪来
/// （`EmbeddedImageProvider`）。方案见 `MARKDOWN-NOTES-PLAN.md §3`。
///
/// 🔴 **按名字解析，不写 id**（2026-09-20 用户定「不要改 `[[]]`」）。给引擎的
/// `WikiLinkResolution.id` 用的是 `NoteRef.key`（`<源 id>:<相对路径>`），**只活在内存里**——
/// 引擎只会把文件里**本来就有**的 `|id` 写回去，我们给的这个永远不会落到文件上
/// （`WikiLinkService.makeStorageState` 的 id 取自存储文本的竖线后缀，不是问 resolver 要的）。
///
/// **一个工作区一个实例**（`WorkspaceManager.wiki`）：名字只在自己工作区里有意义，
/// 做成全局单例的话 A 工作区的 `[[极限]]` 会连到 B 工作区那篇同名的去。
///
/// 线程：引擎在主线程排版时同步调这几个方法，但协议要求 `Sendable`，所以内部用锁护着一份快照
/// （`@unchecked Sendable`，同 `NoteLatexRenderer` 的办法）。快照由 `WorkspaceManager.refreshNotes()` 换。
final class WorkspaceWikiIndex: @unchecked Sendable {

    private let lock = NSLock()
    private var index = NoteIndex()
    /// 引擎的 `fingerprint()`：变了就重排 `[[…]]` 的样式（新导入一批笔记之后，原先的断链当场接上）。
    private var version = 0
    /// 图片缓存（引擎每次排版都会问一遍同一张）。换快照就清。
    private var imageCache: [String: NSImage] = [:]

    init() {}

    /// 换一份索引（`refreshNotes()` 重扫目录之后调）。
    func update(index: NoteIndex) {
        lock.lock()
        self.index = index
        imageCache = [:]
        version &+= 1
        lock.unlock()
    }

    /// `[[名字]]` 指到哪篇（App 自己也用：导入报告要数「还有哪些名字解析不到」）。
    func note(for key: String) -> NoteRef? {
        lock.lock()
        defer { lock.unlock() }
        return index.note(for: key)
    }
}

// MARK: - WikiLinkResolver

extension WorkspaceWikiIndex: WikiLinkResolver {
    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? {
        // 老文件里可能残留 `[[名字|<uuid>]]`（第一批导入写过），引擎会拿后缀当 displayName 递进来；
        // 那串 uuid 现在解析不到 → 画成断链，不报错。
        guard let ref = note(for: displayName) else { return nil }
        return WikiLinkResolution(id: ref.key, exists: true)
    }

    /// 🔴 **一律返回 nil**：这是「把显示名换成目标当前名字」的钩子，只对文件里带 `|id` 的链接生效。
    /// 我们不写 id、也不改别人的正文，所以显示什么就该是文件里写的什么。
    func name(forID id: String) -> String? { nil }

    func fingerprint() -> AnyHashable {
        lock.lock()
        defer { lock.unlock() }
        return version
    }
}

// MARK: - EmbeddedImageProvider

extension WorkspaceWikiIndex: EmbeddedImageProvider {
    /// `![[图.png]]` / `![[attachments/图.png]]` → 笔记树里那个文件（Obsidian 的规矩：
    /// 先按相对路径找，再按文件名全库找）。附件**保持原相对路径**，不做内容寻址
    /// （2026-09-20 用户定：那要改 `![[…]]` 里的文件名，与「不改 `[[]]`」相抵触）。
    func image(for request: EmbeddedImageRequest) -> NSImage? {
        let name = request.name.trimmed
        guard !name.isEmpty else { return nil }
        lock.lock()
        if let hit = imageCache[name] { lock.unlock(); return hit }
        let url = index.file(for: name)
        lock.unlock()

        guard let url, let img = NSImage(contentsOf: url) else { return nil }
        lock.lock()
        imageCache[name] = img
        lock.unlock()
        return img
    }
}
