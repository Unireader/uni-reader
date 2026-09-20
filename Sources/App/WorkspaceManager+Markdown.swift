import Foundation

/// 工作区里的 Markdown 笔记：源（内建 + 引用）、扫描、读写、导入（`MARKDOWN-NOTES-PLAN.md §4/§8`）。
///
/// 这里是**执行层**——碰文件系统、碰库。路径与扫描的纯函数在 `MarkdownImport` / `NoteTree` /
/// `MarkdownLink`（`spike/markdown-link-test.swift` 编的是那三个）。
///
/// 🔴 **文件是真源**（红线 §6）。库里的 `md_doc` 只是**内建源的扫描缓存 + 记「上次打开」**；
/// 引用源（外部目录）**一行都不进库**——外部路径是这台机器的事实，同 `location` 表的规矩，
/// 也因此不会跟着离线镜像跑到别的机器上去指不到。
///
/// 🔴 **谁都不许改笔记正文里的 `[[…]]`**（2026-09-20 用户定）。导入 = 整个目录原样复制。
extension WorkspaceManager {

    // MARK: - 源

    /// 全部笔记源：内建的 `Notes/` 永远排第一，后面是用户引用进来的外部目录。
    /// 引用列表存 `meta.note_sources`（**不在 `MirrorFp.syncedMetaKeys` 白名单里，故不同步**）。
    var noteSources: [NoteRoot] {
        [NoteRoot.workspaceRoot(name: L("Notes"))] + referencedNoteSources
    }

    var referencedNoteSources: [NoteRoot] {
        guard let s = store?.meta("note_sources"), let data = s.data(using: .utf8),
              let list = try? JSONDecoder().decode([NoteRoot].self, from: data) else { return [] }
        return list.filter { $0.kind == .reference }
    }

    func noteSource(id: String) -> NoteRoot? { noteSources.first { $0.id == id } }

    /// 引用一个外部目录（不复制，直接在那儿编辑）。已经引用过的同一个目录 → 原样返回，不重复加。
    @discardableResult
    func addReferencedNotesFolder(_ url: URL) -> NoteRoot? {
        guard let store else { return nil }
        let path = url.standardizedFileURL.path
        if let hit = referencedNoteSources.first(where: { $0.path == path }) { return hit }
        // 引用工作区自己里面的目录没有意义（那就是内建源）
        if let folder, path == folder.standardizedFileURL.path
            || path.hasPrefix(folder.standardizedFileURL.path + "/") { return nil }
        var list = referencedNoteSources
        list.append(NoteRoot(id: UUID().uuidString, kind: .reference, path: path,
                               name: url.lastPathComponent))
        saveReferencedSources(list, store: store)
        refreshNotes()
        return list.last
    }

    /// 取消引用。**只是不再列出来，外部目录一个字节都不动。**
    func removeReferencedNotesFolder(id: String) {
        guard let store else { return }
        saveReferencedSources(referencedNoteSources.filter { $0.id != id }, store: store)
        refreshNotes()
    }

    func renameReferencedNotesFolder(id: String, name: String) {
        guard let store, let clean = name.trimmed.nonEmpty else { return }
        var list = referencedNoteSources
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].name = clean
        saveReferencedSources(list, store: store)
        refreshNotes()
    }

    private func saveReferencedSources(_ list: [NoteRoot], store: LibraryStore) {
        let data = (try? JSONEncoder().encode(list)) ?? Data("[]".utf8)
        try? store.setMeta("note_sources", String(data: data, encoding: .utf8) ?? "[]")
    }

    // MARK: - 扫描

    func noteRootURL(_ source: NoteRoot) -> URL? { source.rootURL(workspace: folder) }

    func noteURL(_ ref: NoteRef) -> URL? {
        guard let src = noteSource(id: ref.sourceID), let root = noteRootURL(src) else { return nil }
        return root.appendingPathComponent(ref.relPath)
    }

    /// 重扫全部源，刷新 `noteTrees` / `markdownDocs` / `[[…]]` 索引。
    ///
    /// 内建源顺手与 `md_doc` 对账（文件多了就补行、没了就删行）——那张表是**缓存**，以文件为准。
    /// 引用源不落库。
    func refreshNotes() {
        guard folder != nil else {
            noteTrees = []
            markdownDocs = []
            wiki.update(index: NoteIndex())
            return
        }
        var trees: [NoteTreeSection] = []
        var index = NoteIndex()
        var wsItems: [NoteItem] = []

        for src in noteSources {
            guard let root = noteRootURL(src) else { continue }
            var items: [NoteItem] = []
            for url in MarkdownImport.walk(root) {
                let rel = MarkdownImport.relativePath(of: url, under: root)
                if MarkdownImport.isMarkdown(url) {
                    let item = NoteItem(ref: NoteRef(sourceID: src.id, relPath: rel))
                    items.append(item)
                    index.add(note: item)
                } else {
                    index.addFile(relPath: rel, url: url)     // 附件：`![[attachments/图.png]]` 按它找
                }
            }
            if src.kind == .workspace { wsItems = items }
            // 空目录也要进树（用户要往里加笔记），所以除了笔记还要把子目录清单一起给它
            let dirs = MarkdownImport.walkDirs(root)
            trees.append(NoteTreeSection(source: src,
                                         root: NoteFolder.build(items, dirs: dirs, rootName: src.name)))
        }

        // 内建源与库对账（缓存）：补上新文件、删掉已经不在的行；`last_opened_at` 保留。
        if let store {
            let rows = (try? store.allMarkdownDocs()) ?? []
            let byPath = Dictionary(rows.map { ($0.relPath, $0) }, uniquingKeysWith: { a, _ in a })
            for item in wsItems where byPath[item.ref.relPath] == nil {
                _ = try? store.addMarkdownDoc(id: UUID().uuidString, title: item.title,
                                              relPath: item.ref.relPath)
            }
            let live = Set(wsItems.map { $0.ref.relPath })
            for row in rows where !live.contains(row.relPath) {
                try? store.deleteMarkdownDoc(id: row.id)
            }
            markdownDocs = (try? store.allMarkdownDocs()) ?? []
            let cache = Dictionary(markdownDocs.map { ($0.relPath, $0) }, uniquingKeysWith: { a, _ in a })
            for t in trees where t.source.kind == .workspace { t.root.fill(from: cache) }
        }

        noteTrees = trees
        registerAliases(into: &index, trees: trees)
        wiki.update(index: index)
    }

    /// 扫一遍全部正文，把每条 `[[名字|别名]]` 的**别名**登记到它指的那篇上。
    ///
    /// 🔴 少了这一步，所有带别名的链接在 App 里都是灰的、点不动——引擎把竖线后面那段当 id 递给
    /// `resolve()`，真名它自己留着（详见 `NoteIndex.aliases`）。用户 2026-09-20 的 vault 里
    /// 47 条链接有 36 条带竖线。
    ///
    /// ⚠️ 代价是**要把每篇正文读一遍**。放在建完名字索引之后（否则 `[[名字|别名]]` 的名字还查不到）。
    /// 现在是同步读：几百篇没问题，上万篇的 vault 会慢，那时再加「按修改时间缓存」这一层。
    private func registerAliases(into index: inout NoteIndex, trees: [NoteTreeSection]) {
        for section in trees {
            guard let root = noteRootURL(section.source) else { continue }
            for item in section.root.allNotes {
                guard let text = MarkdownImport.readText(root.appendingPathComponent(item.ref.relPath)),
                      text.contains("[[") else { continue }
                for pair in MarkdownLink.wikiAliases(text) {
                    guard let ref = index.note(for: pair.target) else { continue }
                    index.addAlias(pair.alias, ref)
                }
            }
        }
    }

    /// 全部笔记的平铺清单（侧栏之外的地方用：标签标题、deep link 查找）。
    var allNotes: [NoteItem] { noteTrees.flatMap { $0.root.allNotes } }

    func note(ref: NoteRef) -> NoteItem? { allNotes.first { $0.ref == ref } }

    /// `unireader://…&md=` 的两种写法：库里那行的 UUID，或 `<源 id>:<相对路径>`。
    /// 按「一串东西」找笔记。认三种写法，按这个顺序：
    ///  ① `<源 id>:<源内相对路径>`（`NoteRef.key`，我们自己拼链接时用）；
    ///  ② 库里那行的 UUID（`unireader://…&md=<uuid>`）；
    ///  ③ 🔴 **笔记名字**——引擎点 `[[…]]` 回调给的就是文件里写的那个名字。
    ///     因为我们不往文件里写 id，`styleWikiLink` 里 `.link = linkID ?? nodeName` 取的永远是后者；
    ///     不认这一种，点链接就会静悄悄什么都不发生（2026-09-20 用户连报两次）。
    func note(key: String) -> NoteItem? {
        if let r = NoteRef(key: key), let hit = note(ref: r) { return hit }
        if let hit = allNotes.first(where: { $0.rowID == key }) { return hit }
        if let r = wiki.note(for: key), let hit = note(ref: r) { return hit }
        return nil
    }

    // MARK: - 正文

    /// 读正文。文件不在（被手动删了 / 引用的盘没挂上）→ nil。
    func noteBody(_ ref: NoteRef) -> String? {
        noteURL(ref).flatMap { MarkdownImport.readText($0) }
    }

    /// 存正文。**只写文件**——内建源顺手打一下 `updated_at`（引用源没有库行）。
    @discardableResult
    func saveNoteBody(_ ref: NoteRef, text: String) -> Bool {
        guard let url = noteURL(ref) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try MarkdownImport.writeAtomically(text, to: url)
            // 🔴 **不调 `refreshNotes()`**：这里只有正文变了，而自动保存是打字时每 0.8 秒一次
            //    ——重扫一遍目录 + 侧栏整棵树重建，代价完全不对等。
            if ref.sourceID == NoteRoot.workspaceID,
               let row = markdownDocs.first(where: { $0.relPath == ref.relPath }) {
                try? store?.touchMarkdownDoc(id: row.id)
            }
            return true
        } catch {
            lastError = "\(error)"
            wsLog("[MD] 存正文失败 \(ref.key): \(error)")
            return false
        }
    }

    func noteWasOpened(_ ref: NoteRef) {
        guard ref.sourceID == NoteRoot.workspaceID,
              let row = markdownDocs.first(where: { $0.relPath == ref.relPath }) else { return }
        try? store?.updateMarkdownLastOpened(id: row.id)
    }

    // MARK: - 增删改

    /// 新建一篇空笔记（默认落在内建源根目录；`subdir` 给相对源根的子目录）。
    @discardableResult
    func createNote(title: String, in sourceID: String = NoteRoot.workspaceID,
                    folder subdir: String = "") -> NoteRef? {
        guard let src = noteSource(id: sourceID), let root = noteRootURL(src) else { return nil }
        let clean = title.trimmed.nonEmpty ?? L("Untitled Note")
        var used = Set(allNotes.filter { $0.ref.sourceID == sourceID }.map { $0.ref.relPath.lowercased() })
        let rel = MarkdownImport.availablePath(
            [subdir.trimmed.nonEmpty, MarkdownImport.safeFileName(clean) + ".md"]
                .compactMap { $0 }.joined(separator: "/"), used: &used)
        do {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try MarkdownImport.writeAtomically("", to: url)
            refreshNotes()
            return NoteRef(sourceID: sourceID, relPath: rel)
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    /// 改名 = **改文件名**（标题就是文件名，Obsidian 的惯例）。
    ///
    /// 🔴 指向它的 `[[旧名字]]` 会**断链**——我们不改别人的正文（红线），这是用户 2026-09-20
    /// 明确接受的代价（「哪怕不兼容也不要改」）。
    @discardableResult
    func renameNote(_ ref: NoteRef, to title: String) -> NoteRef? {
        guard let url = noteURL(ref), let clean = title.trimmed.nonEmpty,
              let root = noteSource(id: ref.sourceID).flatMap({ noteRootURL($0) }) else { return nil }
        let ext = url.pathExtension.nonEmpty ?? "md"
        let newRel = [ref.folder.nonEmpty, MarkdownImport.safeFileName(clean) + "." + ext]
            .compactMap { $0 }.joined(separator: "/")
        guard newRel != ref.relPath else { return ref }
        let dst = root.appendingPathComponent(newRel)
        guard !FileManager.default.fileExists(atPath: dst.path) else {
            lastError = L("A note with that name already exists in this folder.")
            return nil
        }
        do {
            try FileManager.default.moveItem(at: url, to: dst)
            refreshNotes()
            return NoteRef(sourceID: ref.sourceID, relPath: newRel)
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    /// 删一篇：**进废纸篓**（不是抹掉）。引用源删的是用户自己目录里的原件，调用方必须先问清楚。
    func deleteNote(_ ref: NoteRef) {
        guard let url = noteURL(ref) else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            lastError = "\(error)"
            return
        }
        refreshNotes()
    }

    // MARK: - 导入（把一个现有笔记目录**复制**进工作区）

    struct MarkdownImportReport {
        var folderName = ""
        var notes = 0
        var files = 0
        /// 正文里 `[[…]]` 指到的名字里，导完之后仍然解析不到的那些。
        var unresolved: [String] = []
        var failed: [(path: String, reason: String)] = []
        var isEmpty: Bool { notes == 0 && failed.isEmpty }
    }

    /// 把一个目录**整个复制**进 `Notes/<目录名>/`，一个字节都不改（红线：`[[…]]` 不许动）。
    /// 附件跟着原相对路径一起进来，所以 `![[attachments/图.png]]` 照样能显示。
    @discardableResult
    func importMarkdown(from sourceDir: URL) throws -> MarkdownImportReport {
        guard let folder else { throw MarkdownError.noWorkspace }
        let src = sourceDir.standardizedFileURL
        if src.path == folder.standardizedFileURL.path
            || src.path.hasPrefix(folder.standardizedFileURL.path + "/") {
            throw MarkdownError.sourceInsideWorkspace
        }
        let notesRoot = folder.appendingPathComponent(NoteRoot.workspaceDir, isDirectory: true)
        var used = Set(((try? FileManager.default.contentsOfDirectory(atPath: notesRoot.path)) ?? [])
            .map { $0.lowercased() })
        let name = MarkdownImport.availablePath(MarkdownImport.safeFileName(src.lastPathComponent),
                                                used: &used)

        var report = MarkdownImportReport(folderName: name)
        let out = try MarkdownImport.copyTree(from: src, to: notesRoot.appendingPathComponent(name))
        report.files = out.files
        report.notes = out.notes
        report.failed = out.failed.map { (path: $0.0, reason: $0.1) }

        refreshNotes()
        report.unresolved = unresolvedLinks(underPrefix: name)
        wsLog("[MD] 导入「\(name)」：\(report.notes) 篇、\(report.files) 个文件、\(report.unresolved.count) 个链接没解析到")
        return report
    }

    /// 刚导进来那批笔记里，指不到任何一篇的 `[[名字]]`（导入报告用；**不改正文**，只是告诉用户）。
    private func unresolvedLinks(underPrefix prefix: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in allNotes where item.ref.sourceID == NoteRoot.workspaceID
            && item.ref.relPath.hasPrefix(prefix + "/") {
            guard let text = noteBody(item.ref) else { continue }
            for name in MarkdownLink.wikiReferences(text) where wiki.note(for: name) == nil {
                let k = name.trimmed
                if !k.isEmpty, seen.insert(k).inserted { out.append(k) }
            }
        }
        return out
    }

    enum MarkdownError: LocalizedError {
        case noWorkspace
        case sourceInsideWorkspace

        var errorDescription: String? {
            switch self {
            case .noWorkspace: return L("No workspace is open.")
            case .sourceInsideWorkspace: return L("That folder is already inside this workspace.")
            }
        }
    }
}

/// 侧栏一段 = 一个源 + 它的目录树。
struct NoteTreeSection {
    var source: NoteRoot
    var root: NoteFolder
}

extension NoteFolder {
    /// 树里的全部笔记（含子目录）。
    var allNotes: [NoteItem] { notes + folders.flatMap { $0.allNotes } }

    /// 把库里那行的 UUID / 上次打开补进内存条目（只有内建源有）。
    func fill(from cache: [String: LibMarkdownDoc]) {
        fillNotes(cache)
        for f in folders { f.fill(from: cache) }
    }
}
