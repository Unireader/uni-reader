import CryptoKit
import Foundation

/// 平板阅读 Markdown 笔记（`PROTOCOL.md §4.10`，`MARKDOWN-NOTES-PLAN.md §21`）：被跟随的标签是 Markdown 笔记时，
/// 把那篇的正文和图片表发给平板（`mdNote`），平板只读显示。
///
/// 正文取开着的编辑器里那份（比文件领先不到自动保存的 0.8 秒），没开着就读文件。
/// 发送时机：随 `boards`（kind = 1）一起、标签换了一篇、那一篇存盘或被外部改了（内容没变不重发）。
extension AppModel {

    /// 发平板正在看的那篇。`force`：内容没变也发（接入 / 换会话 / 换篇时，平板那边可能是空的）。
    func broadcastMarkdownNote(force: Bool = false) {
        guard server.hasClients else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.broadcastMarkdownNote(force: force) }
            return
        }
        MainActor.assumeIsolated {
            guard let s = padSession, s.showsMarkdown, let ref = s.markdownRef, let ws = padWorkspace else {
                padMarkdownSent = ""
                return
            }
            let text = MarkdownDocView.editors(showing: ref, in: ws).first?.currentText ?? ws.noteBody(ref) ?? ""
            let images = markdownImages(text, ws: ws)
            let sig = ref.key + "\u{1}" + text + "\u{1}" + images.map { $0.target + "=" + $0.sha }.joined(separator: ",")
            guard force || sig != padMarkdownSent else { return }
            padMarkdownSent = sig
            // 先把这几张图登记给 `/image`（只认登记过的 sha，不拿请求里的字符串拼路径）
            var files: [String: URL] = [:]
            for im in images { files[im.sha] = im.url }
            setNoteImageFiles(files)
            server.broadcast(["type": "mdNote", "key": ref.key, "title": ref.title, "text": text,
                              "images": images.map { ["target": $0.target, "sha": $0.sha] }])
        }
    }

    /// 某篇笔记存盘 / 被外部改了：是平板正在看的那篇就重发（内容没变不发）。
    func markdownNoteChanged(key: String?) {
        guard server.hasClients, let s = padSession, s.showsMarkdown, let ref = s.markdownRef else { return }
        if let key, key != ref.key { return }
        broadcastMarkdownNote()
    }

    /// 正文里 `![[目标]]` 能解析到的图片附件：(收拾过的目标, 文件, 内容 sha)。目标的收拾规则同 `MarkdownLink.linkTarget`，
    /// 平板按同一规则从正文里取、拿它查表。代码块 / 行内代码里的不算。
    @MainActor private func markdownImages(_ text: String, ws: WorkspaceManager) -> [(target: String, url: URL, sha: String)] {
        let ns = text as NSString
        let guarded = MarkdownLink.protectedRanges(text)
        var out: [(String, URL, String)] = []
        var seen = Set<String>()
        for m in MarkdownLink.wikiRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        where ns.substring(with: m.range).hasPrefix("!")
            && !guarded.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
            let target = MarkdownLink.linkTarget(ns.substring(with: m.range(at: 1)))
            guard !target.isEmpty, seen.insert(target).inserted,
                  let url = ws.wiki.fileURL(for: target),
                  MarkdownLink.imageExts.contains(url.pathExtension.lowercased()),
                  let sha = fileSHA(url) else { continue }
            out.append((target, url, sha))
        }
        return out
    }

    /// 文件内容的 SHA-256（小写十六进制）。按路径缓存，修改时间与大小都没变就用上次算的。
    private func fileSHA(_ url: URL) -> String? {
        let path = url.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.intValue else { return nil }
        if let c = padMarkdownShaCache[path], c.date == date, c.size == size { return c.sha }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        padMarkdownShaCache[path] = (date, size, sha)
        return sha
    }
}
