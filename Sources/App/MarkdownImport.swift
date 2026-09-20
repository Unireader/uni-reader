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


    /// 文件名里不能出现的字符换成 `-`（同 Obsidian 导出那套口径）。
    static func safeFileName(_ s: String) -> String {
        var out = s
        for c in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "#", "^", "[", "]"] {
            out = out.replacingOccurrences(of: c, with: "-")
        }
        return out.trimmed.nonEmpty ?? "note"
    }
}
