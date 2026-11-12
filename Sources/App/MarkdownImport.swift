import Foundation

/// 「把现有笔记目录搬进工作区」用到的**路径与文件小工具**（`MARKDOWN-NOTES-PLAN.md §4`）。
///
/// 只依赖 Foundation，`spike/markdown-link-test.swift` 直接编它；真正的复制与落库在
/// `WorkspaceManager+Markdown`。
///
/// 🔴 2026-09-20 用户定「不要改 `[[]]`」之后，这里原来那套**导入计划**（给每篇分配 id、建解析索引、
/// 再逐份重写链接）整段删除了——导入现在就是**把整个目录原样复制进来**，一个字节不改，
/// 链接按名字解析（`NoteIndex`）。
enum MarkdownImport {

    /// 笔记在工作区内的落脚目录。
    static let notesDir = NoteRoot.workspaceDir

    // MARK: - 路径

    /// `./a//b.md` → `a/b.md`；去掉开头的 `/`，丢掉 `..`（不许跳出源目录）。
    static func normalizeRel(_ p: String) -> String {
        p.split(separator: "/").filter { $0 != "." && $0 != ".." && !$0.isEmpty }.joined(separator: "/")
    }
    static func stripNotesDir(_ p: String) -> String {
        p.hasPrefix(notesDir + "/") ? String(p.dropFirst(notesDir.count + 1)) : p
    }
    /// 撞名就在扩展名前加 `-2`、`-3`…（`md_doc.rel_path` 是 UNIQUE，必须先避让）。
    static func availablePath(_ want: String, used: inout Set<String>) -> String {
        if used.insert(want.lowercased()).inserted { return want }
        let ext = want.pathExtension.map { "." + $0 } ?? ""
        let stem = ext.isEmpty ? want : String(want.dropLast(ext.count))
        var n = 2
        while true {
            let candidate = "\(stem)-\(n)\(ext)"
            if used.insert(candidate.lowercased()).inserted { return candidate }
            n += 1
        }
    }
    static func dropExt(_ s: String) -> String {
        guard let ext = s.pathExtension, !ext.isEmpty else { return s }
        return String(s.dropLast(ext.count + 1))
    }

    // MARK: - 文件系统（执行层用，放这里是为了 spike 跑得到；`WorkspaceManager+Markdown` 只是转调）

    /// 递归列文件。跳过隐藏目录与 `.obsidian` / `trash`（方案 §4.1）。
    static func walk(_ root: URL) -> [URL] {
        let fm = FileManager.default
        guard let it = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in it {
            let name = url.lastPathComponent.lowercased()
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if name.hasPrefix(".") || name == "trash" { it.skipDescendants() }
                continue
            }
            out.append(url)
        }
        return out
    }

    /// 递归列出**全部子目录**（相对 root），跳过的目录同 `walk`。
    ///
    /// 🔴 空目录也要列出来：目录树是给用户往里加笔记用的，只按「有笔记的路径」建树的话，
    /// 空目录在侧栏上根本不出现，用户没地方右键「在这里新建笔记」（2026-09-20 用户提）。
    static func walkDirs(_ root: URL) -> [String] {
        let fm = FileManager.default
        guard let it = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [String] = []
        for case let url as URL in it {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let name = url.lastPathComponent.lowercased()
            if name.hasPrefix(".") || name == "trash" { it.skipDescendants(); continue }
            out.append(relativePath(of: url, under: root))
        }
        return out
    }

    static func relativePath(of url: URL, under root: URL) -> String {
        let base = root.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        guard p.hasPrefix(base + "/") else { return url.lastPathComponent }
        return String(p.dropFirst(base.count + 1))
    }

    /// UTF-8 优先；不是 UTF-8 的按系统编码猜一次（导入别人的 vault 时偶尔会遇到）。
    static func readText(_ url: URL) -> String? {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        var enc: String.Encoding = .utf8
        return try? String(contentsOf: url, usedEncoding: &enc)
    }

    /// 先写 `.part` 再原子改名（同 `ImageAssets.write`）：中途断电只会留一个 `.part`，
    /// 不会留一份写了一半、看着像好的笔记。
    static func writeAtomically(_ text: String, to url: URL) throws {
        let part = url.appendingPathExtension("part")
        try Data(text.utf8).write(to: part, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: part)
        } else {
            try FileManager.default.moveItem(at: part, to: url)
        }
    }

    /// 递归复制一个笔记目录（md + 附件 + 子目录，原样搬）。跳过的目录同 `walk`。
    /// **逐文件复制**而不是 `copyItem` 整个目录：那样会把 `.obsidian` 这类也带进来。
    /// 返回（复制了几个文件, 其中几篇是 md, 失败的那些）。
    @discardableResult
    static func copyTree(from src: URL, to dst: URL) throws -> (files: Int, notes: Int, failed: [(String, String)]) {
        let fm = FileManager.default
        var files = 0, notes = 0
        var failed: [(String, String)] = []
        for url in walk(src) {
            let rel = relativePath(of: url, under: src)
            let target = dst.appendingPathComponent(rel)
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: url, to: target)
                files += 1
                if isMarkdown(url) { notes += 1 }
            } catch {
                failed.append((rel, "\(error)"))
            }
        }
        return (files, notes, failed)
    }

    static func isMarkdown(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        return e == "md" || e == "markdown"
    }


    /// Agent 新建笔记（MCP `create_markdown`，`MARKDOWN-NOTES-PLAN.md §14`）落在源里的哪个相对路径：标题 = 文件名
    /// （去掉多写的 `.md`，非法字符换成 `-`），`folder` 一级一级查。不行 → 一句英文原因（原样回给 Agent）。
    /// `..`、点开头、`trash` 的目录与点开头的文件扫描时跳过（`NoteScan`）——建在那里就看不见了，直接拒绝。
    static func newNotePath(title: String, folder: String) -> Result<String, NewNoteRejected> {
        noteFileName(title).flatMap { file in
            noteFolderParts(folder).map { ($0 + [file + ".md"]).joined(separator: "/") }
        }
    }

    /// Agent 改名 / 挪目录（MCP `rename_markdown`，`MARKDOWN-NOTES-PLAN.md §15`）之后的相对路径。
    /// `title` 为 nil = **文件名一个字不动**（只挪目录时不能顺手把 `a#b.md` 洗成 `a-b.md`）；给了就按 `newNotePath` 的口径，
    /// 原来的扩展名照留（`.markdown` 不变成 `.md`）。`folder` 为 nil = 留在原目录；空串 = 源根。
    static func movedNotePath(from relPath: String, title: String?, folder: String?) -> Result<String, NewNoteRejected> {
        let parts = relPath.split(separator: "/").map(String.init)
        guard let oldFile = parts.last else { return .failure(NewNoteRejected("the note path is empty")) }
        let file: String
        if let title {
            let ext = (oldFile as NSString).pathExtension
            switch noteFileName(title) {
            case .failure(let why): return .failure(why)
            case .success(let name): file = name + "." + (ext.isEmpty ? "md" : ext)
            }
        } else {
            file = oldFile
        }
        let dirs: [String]
        if let folder {
            switch noteFolderParts(folder) {
            case .failure(let why): return .failure(why)
            case .success(let d): dirs = d
            }
        } else {
            dirs = Array(parts.dropLast())
        }
        return .success((dirs + [file]).joined(separator: "/"))
    }

    /// Agent 给笔记目录改名 / 挪位置（MCP `move_markdown_folder`，`MARKDOWN-NOTES-PLAN.md §16`）之后的相对路径。
    /// `name` 为 nil = 目录名不变（一个字不动）；`parent` 为 nil = 留在原上级、空串 = 源根。不许挪进它自己里面。
    static func movedFolderPath(from folder: String, name: String?, parent: String?) -> Result<String, NewNoteRejected> {
        let old = folder.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard let oldName = old.last else { return .failure(NewNoteRejected("folder is empty; the source root itself cannot be moved")) }
        var newName = oldName
        if let name {
            let n = name.trimmed
            guard !n.isEmpty else { return .failure(NewNoteRejected("folder name is empty")) }
            newName = safeFileName(n)
            guard !newName.hasPrefix("."), newName.lowercased() != "trash" else {
                return .failure(NewNoteRejected("folder names cannot start with a dot or be 'trash' (such folders are hidden)"))
            }
        }
        let dirs: [String]
        if let parent {
            switch noteFolderParts(parent) {
            case .failure(let why): return .failure(why)
            case .success(let d): dirs = d
            }
        } else {
            dirs = Array(old.dropLast())
        }
        let new = (dirs + [newName]).joined(separator: "/")
        let oldPath = old.joined(separator: "/")
        guard !(new.lowercased() + "/").hasPrefix(oldPath.lowercased() + "/") || new.lowercased() == oldPath.lowercased() else {
            return .failure(NewNoteRejected("a folder cannot be moved into itself"))
        }
        return .success(new)
    }

    /// 标题 → 文件名（不带扩展名）：去掉多写的 `.md`、非法字符换成 `-`，空的 / 点开头的拒绝。
    private static func noteFileName(_ title: String) -> Result<String, NewNoteRejected> {
        var name = title.trimmed
        if name.lowercased().hasSuffix(".md") { name = String(name.dropLast(3)).trimmed }
        guard !name.isEmpty else { return .failure(NewNoteRejected("title is empty")) }
        let file = safeFileName(name)
        guard !file.hasPrefix(".") else {
            return .failure(NewNoteRejected("a note name cannot start with a dot (such files are not shown)"))
        }
        return .success(file)
    }

    /// 源里的相对目录 → 各级目录名（前后的 `/` 与空段去掉）；`..` / 点开头 / `trash` 拒绝。
    private static func noteFolderParts(_ folder: String) -> Result<[String], NewNoteRejected> {
        let parts = folder.split(separator: "/").map { String($0).trimmed }.filter { !$0.isEmpty }
        for p in parts where p == ".." || p.hasPrefix(".") || p.lowercased() == "trash" {
            return .failure(NewNoteRejected("folder '\(folder)' is not allowed: no '..', no names starting with a dot, no 'trash' (such folders are hidden)"))
        }
        return .success(parts)
    }

    struct NewNoteRejected: Error, Equatable {
        let reason: String
        init(_ r: String) { reason = r }
    }

    /// 文件名里不能出现的字符换成 `-`（同 Obsidian 导出那套口径）。
    static func safeFileName(_ s: String) -> String {
        var out = s
        for c in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "#", "^", "[", "]"] {
            out = out.replacingOccurrences(of: c, with: "-")
        }
        return out.trimmed.nonEmpty ?? "note"
    }
}
