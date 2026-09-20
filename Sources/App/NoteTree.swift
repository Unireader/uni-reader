import Foundation

/// 笔记的**来源**与**目录树**（`MARKDOWN-NOTES-PLAN.md §8`，2026-09-20 第三批）。
///
/// 只依赖 Foundation（建树、解析索引都是纯函数），`spike/markdown-link-test.swift` 直接编它。
///
/// ## 两种源
///
/// | | 内建（`kind == .workspace`） | 引用（`kind == .reference`） |
/// |---|---|---|
/// | 文件在哪 | 工作区包里的 `Notes/` | 用户指的**外部绝对路径**，App 不搬动它 |
/// | 进不进库 | 进（`md_doc` 当扫描缓存 + 记「上次打开」） | **不进**——外部路径是这台机器的事实，同 `location` 表的规矩 |
/// | 离线镜像 | 跟着工作区走 | **不同步**（源列表存 `meta.note_sources`，不在同步白名单里） |
///
/// 两种源在界面上一视同仁：侧栏各占一段，底下按**真实目录层级**展开（多级）。
enum NoteRootKind: String, Codable {
    case workspace
    case reference
}

/// 一个笔记源。
struct NoteRoot: Codable, Equatable, Identifiable {
    var id: String
    var kind: NoteRootKind
    /// `workspace` 源：相对工作区的路径（恒为 `Notes`）。`reference` 源：绝对路径。
    var path: String
    /// 侧栏上这一段叫什么（引用源默认取目录名）。
    var name: String

    /// 内建源的固定身份（一个工作区只有一个，不用存进 `note_sources`）。
    static let workspaceID = "ws"
    static let workspaceDir = "Notes"

    static func workspaceRoot(name: String) -> NoteRoot {
        NoteRoot(id: workspaceID, kind: .workspace, path: workspaceDir, name: name)
    }

    /// 这个源的根目录绝对路径。
    func rootURL(workspace: URL?) -> URL? {
        switch kind {
        case .workspace: return workspace?.appendingPathComponent(path)
        case .reference: return URL(fileURLWithPath: path)
        }
    }
}

/// 指向一篇笔记：哪个源 + 源内相对路径。**这就是笔记在 App 内部的身份**
/// （文件里的 `[[…]]` 一个字都不改，所以没有、也不需要写进文件的 id）。
struct NoteRef: Hashable, Codable {
    var sourceID: String
    /// 相对源根，如 `数学/微积分/极限.md`。
    var relPath: String

    /// 拼成一个字符串（给引擎当不透明 id、给 `unireader://…&md=` 用）。
    var key: String { "\(sourceID):\(relPath)" }

    init(sourceID: String, relPath: String) {
        self.sourceID = sourceID
        self.relPath = relPath
    }
    /// `key` 的反解（第一个冒号之前是源 id）。
    init?(key: String) {
        guard let i = key.firstIndex(of: ":") else { return nil }
        sourceID = String(key[key.startIndex..<i])
        relPath = String(key[key.index(after: i)...])
        if sourceID.isEmpty || relPath.isEmpty { return nil }
    }

    /// 笔记标题 = 文件名去扩展名（Obsidian 的惯例）。
    var title: String { MarkdownImport.dropExt(relPath.split(separator: "/").last.map(String.init) ?? relPath) }
    /// 所在目录（源内相对，顶层为空串）。
    var folder: String {
        let parts = relPath.split(separator: "/").dropLast()
        return parts.joined(separator: "/")
    }
}

/// 一篇笔记在内存里的样子（来自库里那行，或来自目录扫描）。
struct NoteItem: Equatable, Identifiable {
    var ref: NoteRef
    var title: String
    /// 库里那行的 UUID（只有内建源有；引用源为 nil）。给 `unireader://…&md=<uuid>` 与「上次打开」用。
    var rowID: String?
    var lastOpenedAt: Date?

    var id: String { ref.key }

    init(ref: NoteRef, title: String? = nil, rowID: String? = nil, lastOpenedAt: Date? = nil) {
        self.ref = ref
        self.title = title ?? ref.title
        self.rowID = rowID
        self.lastOpenedAt = lastOpenedAt
    }
}

/// 一个源底下的目录树（**多级**，2026-09-20 用户要求：「需要支持多级目录了，笔记还是很复杂的」）。
///
/// 从 `NoteItem` 的相对路径推出来，**不看库里的 `group_name`**——目录结构是文件系统的事实，
/// 存一份在库里迟早对不上（第一批那套「一级分组 = 第一段目录名」就是因此被推翻的）。
final class NoteFolder {
    let name: String
    /// 相对源根的路径（根目录为空串）。
    let path: String
    private(set) var folders: [NoteFolder] = []
    private(set) var notes: [NoteItem] = []

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    var isEmpty: Bool { folders.isEmpty && notes.isEmpty }
    /// 连子目录一起看有没有笔记（段头用：一篇笔记都没有的源仍然要列出来，好让用户往里加）。
    var hasAnything: Bool { !isEmpty }
    /// 连子目录一起数。
    var noteCount: Int { notes.count + folders.reduce(0) { $0 + $1.noteCount } }

    /// 把一批笔记按相对路径建成树。同级里**目录在前、笔记在后，各自按名字排**（访达的观感）。
    ///
    /// `dirs` = 源里**全部**子目录（相对源根）。传它进来是为了让**空目录也出现**——
    /// 只按笔记路径建树的话，还没放笔记的目录在侧栏上看不见，用户没地方往里加笔记。
    static func build(_ items: [NoteItem], dirs: [String] = [], rootName: String) -> NoteFolder {
        let root = NoteFolder(name: rootName, path: "")
        var byPath: [String: NoteFolder] = ["": root]

        func folder(_ path: String) -> NoteFolder {
            if let hit = byPath[path] { return hit }
            let parts = path.split(separator: "/")
            let name = parts.last.map(String.init) ?? path
            let parentPath = parts.dropLast().joined(separator: "/")
            let parent = folder(parentPath)
            let node = NoteFolder(name: name, path: path)
            parent.folders.append(node)
            byPath[path] = node
            return node
        }

        for d in dirs { _ = folder(d) }          // 先把空目录也建出来
        for item in items { folder(item.ref.folder).notes.append(item) }
        sort(root)
        return root
    }

    /// 把库里那行的 UUID / 上次打开补进这一层的条目（`notes` 是 `private(set)`，故由本类型自己改）。
    func fillNotes(_ cache: [String: LibMarkdownDoc]) {
        for i in notes.indices {
            guard let row = cache[notes[i].ref.relPath] else { continue }
            notes[i].rowID = row.id
            notes[i].lastOpenedAt = row.lastOpenedAt
        }
    }

    private static func sort(_ node: NoteFolder) {
        node.folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        node.notes.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        for f in node.folders { sort(f) }
    }
}

/// 「名字 → 笔记」的解析索引（`[[…]]` 按**名字**解析，方案 §3 改版）。
///
/// 🔴 2026-09-20 用户定：**文件里的 `[[…]]` 一个字都不许改**，所以不能靠写进文件的 id。
/// 代价是 Obsidian 本来的代价：**笔记改名 / 挪目录，指向它的链接就断**——用户明确接受
/// （「哪怕不兼容也不要改」）。
struct NoteIndex {
    private var exact: [String: NoteRef] = [:]
    private var folded: [String: NoteRef] = [:]
    private var tieBreaks: [String: String] = [:]
    /// 被多篇笔记共用、只能挑一篇的名字。
    private(set) var ambiguous: [String] = []
    /// 附件（图片等非 md 文件）：相对路径 / 文件名 → 绝对路径。
    private var files: [String: URL] = [:]
    private var filesByName: [String: URL] = [:]

    /// macOS 上文件名是 NFD、正文里多半是 NFC——不归一化的话「é」这类名字永远查不中。
    static func normalize(_ s: String) -> String {
        s.trimmed.precomposedStringWithCanonicalMapping
    }

    mutating func add(_ key: String, _ ref: NoteRef) {
        let k = Self.normalize(key)
        guard !k.isEmpty else { return }
        if let old = exact[k] {
            if old == ref { return }
            if !ambiguous.contains(k) { ambiguous.append(k) }
            // 重名挑 key 字典序最小的那篇：稳定、可预期
            guard ref.key < (tieBreaks[k] ?? "") else { return }
            exact[k] = ref
            tieBreaks[k] = ref.key
            if folded[k.lowercased()] == old { folded[k.lowercased()] = ref }
            return
        }
        exact[k] = ref
        tieBreaks[k] = ref.key
        if folded[k.lowercased()] == nil { folded[k.lowercased()] = ref }
    }

    /// 一篇笔记的三个解析键：标题、相对路径去扩展名、frontmatter 别名（别名由调用方读出来再加）。
    mutating func add(note: NoteItem) {
        add(note.title, note.ref)
        add(MarkdownImport.dropExt(note.ref.relPath), note.ref)
    }

    mutating func addFile(relPath: String, url: URL) {
        let k = Self.normalize(relPath)
        guard !k.isEmpty else { return }
        if files[k] == nil { files[k] = url }
        let name = Self.normalize(relPath.split(separator: "/").last.map(String.init) ?? relPath)
        if filesByName[name] == nil { filesByName[name] = url }
    }

    /// `[[名字]]` / `[[子目录/名字]]` / `[[名字#锚点\\|别名]]` → 哪篇笔记。
    ///
    /// **先按原样查一次**：名字里本来就带 `#` 或 `|` 的笔记（`C#入门` 这种）不该被收拾掉。
    /// 查不中再用 `MarkdownLink.linkTarget` 去掉别名段 / 锚点 / 转义之后重来一遍——
    /// 引擎交给 `resolve(displayName:)` 的就是没收拾过的原串（见那个函数的注释）。
    func note(for key: String) -> NoteRef? {
        let raw = Self.normalize(key)
        guard !raw.isEmpty else { return nil }
        if let r = lookup(raw) { return r }
        let t = Self.normalize(MarkdownLink.linkTarget(raw))
        if t != raw, let r = lookup(t) { return r }
        return nil
    }

    private func lookup(_ k: String) -> NoteRef? {
        if let r = exact[k] ?? folded[k.lowercased()] { return r }
        // 带扩展名写法 `[[极限.md]]`
        let noExt = MarkdownImport.dropExt(k)
        if noExt != k, let r = exact[noExt] ?? folded[noExt.lowercased()] { return r }
        // 带路径但只对得上末段：`[[数学/极限]]` 写成了别的目录
        if let last = k.split(separator: "/").last.map(String.init), last != k {
            let l = Self.normalize(MarkdownImport.dropExt(last))
            if let r = exact[l] ?? folded[l.lowercased()] { return r }
        }
        return nil
    }

    /// `![[图.png]]` / `![[attachments/图.png]]` → 文件在哪（Obsidian 的规矩：先按路径，再按文件名全库找）。
    func file(for key: String) -> URL? {
        let k = Self.normalize(key)
        guard !k.isEmpty else { return nil }
        if let u = files[k] { return u }
        let name = Self.normalize(k.split(separator: "/").last.map(String.init) ?? k)
        return filesByName[name]
    }
}
