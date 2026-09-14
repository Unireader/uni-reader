import Foundation

/// `unireader://open?…` 链接（契约见 `URL-SCHEME-PLAN.md`）：从别的 App（Obsidian 笔记里的链接、
/// Agent 写出来的清单、终端 `open`）**回到 UniReader 里的某个位置**。
///
/// 只有一个入口 `open`，靠查询参数说清楚「哪个工作区 / 哪篇 / 哪页 / 哪条笔记」，参数全部可省：
///
/// | 参数 | 含义 |
/// |---|---|
/// | `ws`   | 工作区 `.unrd` 包的绝对路径（也接受 `file://` 形式与 `~`） |
/// | `wsid` | 工作区 `workspace_id`（路径变了靠它在最近列表 / 离线副本里找回来） |
/// | `doc`  | 文档 id（`document.id`） |
/// | `hash` | 文件内容 SHA-256（`variant.content_hash`）；`doc` 找不到时按它兜底 |
/// | `page` | 页码，**1 起**（对外口径与 MCP 一致，换算只在 `PageNo`） |
/// | `frac` | 页内位置 0（页顶）… 1（页底），默认 0 |
/// | `note` | 笔记 id（文字笔记 / 高亮 / 图片笔记 / 书签任一，`note.id`）：跳到它所在处并展开气泡；给了它 `page`/`frac` 只作兜底 |
///
/// 本类型**只依赖 Foundation**（解析 + 生成两个纯函数），`spike/deep-link-test.swift` 直接编它；
/// 解析出来之后怎么找窗口、开文档，在 `DeepLinkRouter`。
struct DeepLink: Equatable {
    static let scheme = "unireader"
    static let host = "open"

    /// 给 Agent 看的一行格式说明（MCP `get_state.app.deep_link`）：不用翻文档也能自己拼链接。
    static let formatHint = "unireader://open?ws=<.unrd path>&doc=<document_id>[&page=N (1-based)][&frac=0…1][&note=<note/highlight/bookmark id>] — every document / annotation DTO also carries a ready-made `link`"

    var workspacePath: String?
    var workspaceId: String?
    var documentId: String?
    var contentHash: String?
    /// 对外页码（1 起）。
    var page: Int?
    var frac: Double?
    var noteId: UUID?

    /// 没有任何定位参数（`unireader://open` 光杆）= 只把 App 叫到前台。
    var isEmpty: Bool {
        workspacePath == nil && workspaceId == nil && documentId == nil && contentHash == nil
            && page == nil && frac == nil && noteId == nil
    }

    enum ParseError: Error, Equatable {
        /// 不是 `unireader://` 开头——调用方该把它当别的东西（`.unrd` 文件）处理。
        case notDeepLink
        /// 主机不是 `open`。
        case unknownHost(String)
        case badPage(String)
        case badFrac(String)
        case badNote(String)
    }

    // MARK: - 解析

    /// 这个 URL 是不是我们的 scheme（大小写不敏感）。只看 scheme，不管后面对不对。
    static func isDeepLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    static func parse(_ url: URL) throws -> DeepLink {
        guard isDeepLink(url) else { throw ParseError.notDeepLink }
        // `URLComponents` 负责百分号解码；查询里的 `+` 保持字面量（我们生成时从不用它表示空格）。
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let h = (comps?.host ?? "").lowercased()
        guard h == host else { throw ParseError.unknownHost(h) }

        var link = DeepLink()
        for item in comps?.queryItems ?? [] {
            guard let raw = item.value else { continue }
            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty { continue }
            switch item.name.lowercased() {
            case "ws":   link.workspacePath = Self.normalizePath(v)
            case "wsid": link.workspaceId = v
            case "doc":  link.documentId = v
            case "hash": link.contentHash = v.lowercased()
            case "page":
                guard let n = Int(v), n >= 1 else { throw ParseError.badPage(v) }
                link.page = n
            case "frac":
                guard let d = Double(v), d.isFinite else { throw ParseError.badFrac(v) }
                link.frac = min(max(d, 0), 1)
            case "note":
                guard let id = UUID(uuidString: v) else { throw ParseError.badNote(v) }
                link.noteId = id
            default:
                break   // 不认识的参数忽略：以后加参数，老版本 App 照样能开
            }
        }
        return link
    }

    /// `ws` 的三种写法归一成绝对路径：裸路径 / `file://…` / `~/…`。
    private static func normalizePath(_ s: String) -> String {
        if s.hasPrefix("file://"), let u = URL(string: s), u.isFileURL { return u.path }
        return (s as NSString).expandingTildeInPath
    }

    // MARK: - 生成

    /// 拼出链接。**值只保留 RFC 3986 的 unreserved 字符（`A-Z a-z 0-9 - . _ ~`），其余一律百分号编码**——
    /// 比 `URLComponents` 的默认严得多，为的是这个链接要**原样贴进 Markdown**：空格、括号、`#`、中文
    /// 任何一个漏编，`[text](url)` 在 Obsidian 里就断在半截。
    var url: URL {
        var items: [(String, String)] = []
        if let v = workspacePath { items.append(("ws", v)) }
        if let v = workspaceId { items.append(("wsid", v)) }
        if let v = documentId { items.append(("doc", v)) }
        if let v = contentHash { items.append(("hash", v)) }
        if let v = page { items.append(("page", String(v))) }
        if let v = frac { items.append(("frac", Self.formatFrac(v))) }
        if let v = noteId { items.append(("note", v.uuidString)) }
        let query = items.map { "\($0.0)=\(Self.encode($0.1))" }.joined(separator: "&")
        return URL(string: "\(Self.scheme)://\(Self.host)" + (query.isEmpty ? "" : "?\(query)"))!
    }

    var absoluteString: String { url.absoluteString }

    private static let unreserved: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~")
        // `alphanumerics` 含全部 Unicode 字母数字（中文也算），这里只要 ASCII 那一段。
        return s.intersection(CharacterSet(charactersIn: UnicodeScalar(0)...UnicodeScalar(127)))
    }()

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    /// 0…1 的位置写成最多三位小数、去掉尾零（`0.43`、`0`、`1`）。
    static func formatFrac(_ f: Double) -> String {
        let v = min(max(f, 0), 1)
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
