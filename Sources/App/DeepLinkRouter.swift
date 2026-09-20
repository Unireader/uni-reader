import AppKit
import Foundation

/// 把解析好的 `unireader://open?…` 链接（`DeepLink`）变成「哪扇窗、哪个标签、翻到哪、展开哪条笔记」。
///
/// 全部在主线程：`AppDelegate.application(_:open:)` 直接进来。找窗口 / 开文档那一段与 MCP 的
/// `open_document` **共用 `AppDelegate.showDocument`**（别另写一份，两边的规则一分叉就会各开各的窗）。
///
/// 解析顺序（每一步都可省，省了就往下兜底）：
///  1. 工作区：`ws` 路径正开着 → 它；`wsid` 在开着的实例 / 最近列表里 → 它（盘不在就开离线副本）；
///     `ws` 路径在最近列表 → 同上兜底副本；`ws` 路径本身是个真实工作区 → 开它；都没给 → 哪个开着的
///     工作区有这篇文档就用哪个，还没有就用 key 窗口的。
///  2. 窗口：该工作区没有窗口就新开一扇（**照常恢复它的标签**，与双击 `.unrd` 一样——链接只是多开一篇）。
///  3. 文档：`doc` 找不到再按 `hash` 找 `variant`；给了却找不到就报错（不静默落在别的文档上）。
///  4. 位置：`note`（所在页 + 锚点上沿，同 Inspector 点条目的口径）> `page`+`frac`；页码越界钳到末页。
///  5. 展开：文字 / 图片笔记把 id 交给 `DocSession.revealNoteID`，阅读区把它加进 `expandedNotes`。
@MainActor
enum DeepLinkRouter {
    enum RouteError: LocalizedError {
        case appNotReady
        case workspaceNotFound(String)
        case documentNotFound(String)
        case nothingOpen

        var errorDescription: String? {
            switch self {
            case .appNotReady: return L("UniReader is still starting up.")
            case .workspaceNotFound(let p): return String(format: L("Workspace not found: %@"), p)
            case .documentNotFound(let d): return String(format: L("Document not found in this workspace: %@"), d)
            case .nothingOpen: return L("The link does not say which workspace or document to open, and nothing is open.")
            }
        }
    }

    /// 入口：成功就到位，失败弹一个框（链接是别处写的，静默吞掉用户只看到「点了没反应」）。
    /// 冷启动被链接拉起却失败时，仍然开一扇默认窗口——不然 App 起来了却一扇窗都没有。
    static func open(_ link: DeepLink) {
        do { try route(link) } catch {
            wsLog("链接路由失败：\(link.absoluteString) — \(error.localizedDescription)")
            if let d = AppDelegate.shared, d.readerWindowControllers.isEmpty {
                d.openReaderWindow(workspacePath: nil, docId: nil)
            }
            alert(url: link.url, error: error)
        }
    }

    static func route(_ link: DeepLink) throws {
        guard let delegate = AppDelegate.shared else { throw RouteError.appNotReady }
        if link.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // 1 + 2：工作区与它的窗口
        let c0 = try controllerForWorkspace(link, delegate: delegate)
        let ws = c0.workspace

        // 3a：Markdown 笔记（v15）。与 `doc` 互斥且**优先**（`DeepLink.markdownId` 的约定），
        // 笔记没有「页」也没有「气泡」，到这里就结束。
        if let mdID = link.markdownId {
            guard let item = ws.note(key: mdID) else { throw RouteError.documentNotFound(mdID) }
            c0.tabs.openMarkdown(item.ref)
            NSApp.activate(ignoringOtherApps: true)
            c0.window?.makeKeyAndOrderFront(nil)
            wsLog("链接到位：\(ws.name) md=\(mdID)")
            return
        }

        // 3：文档（没给就停在该工作区当前标签上）
        var c = c0
        var tab = c0.tabs.active
        if let docId = try resolveDocument(link, in: ws) {
            (c, tab) = try delegate.showDocument(docId, in: ws, activate: true)
        }

        // 4 + 5：位置与展开（标签是空的——工作区级链接、当前标签没文档——就没有「位置」可言）
        if tab.docID != nil, let target = target(for: link, in: tab.session) {
            tab.session.jump(page: target.page, frac: target.frac, kind: .list, label: L("Link"), origin: "link")
            if let id = target.reveal { tab.session.revealNoteID = id }
        }

        NSApp.activate(ignoringOtherApps: true)
        c.window?.makeKeyAndOrderFront(nil)
        wsLog("链接到位：\(ws.name) doc=\(tab.docID ?? "nil") page=\(tab.session.currentPageIndex + 1)")
    }

    // MARK: - 工作区

    /// 找到（或开出）目标工作区的一扇窗。
    private static func controllerForWorkspace(_ link: DeepLink, delegate: AppDelegate) throws -> ReaderWindowController {
        let windows = delegate.readerWindowControllers
        func window(of ws: WorkspaceManager) -> ReaderWindowController? {
            windows.first { $0.window?.isKeyWindow == true && $0.workspace === ws } ?? windows.first { $0.workspace === ws }
        }
        func window(at folder: URL) -> ReaderWindowController? {
            WorkspaceRegistry.shared.openManager(at: folder).flatMap(window(of:))
        }

        if let folder = try resolveFolder(link) {
            if let c = window(at: folder) { return c }
            // 没窗口 → 新开一扇。`docId: nil` = 照常恢复该工作区上次的标签（链接只是往里多开一篇，
            // 与双击 `.unrd` 再点侧栏的效果一致；MCP 的 `open_document` 才是「只装这一篇」）。
            return try delegate.makeReaderWindow(workspacePath: folder.path, docId: nil, activate: true)
        }

        // 链接没说工作区：哪个开着的工作区有这篇就用哪个
        if let mdID = link.markdownId,
           let ws = WorkspaceRegistry.shared.openManagers.first(where: { $0.note(key: mdID) != nil }),
           let c = window(of: ws) { return c }
        if let docId = link.documentId,
           let ws = WorkspaceRegistry.shared.openManagers.first(where: { $0.document(id: docId) != nil }),
           let c = window(of: ws) { return c }
        if let hash = link.contentHash,
           let ws = WorkspaceRegistry.shared.openManagers.first(where: { (try? $0.store?.variant(hash: hash)) != nil }),
           let c = window(of: ws) { return c }
        // 还是没有 → key 窗口（没 key 就最靠前那扇）
        if let key = windows.first(where: { $0.window?.isKeyWindow == true }) { return key }
        let order = NSApp.orderedWindows
        if let front = windows.min(by: { a, b in
            (a.window.flatMap { order.firstIndex(of: $0) } ?? .max) < (b.window.flatMap { order.firstIndex(of: $0) } ?? .max)
        }) { return front }
        throw RouteError.nothingOpen
    }

    /// 链接指的工作区在磁盘上的哪个文件夹（源盘不在就是离线副本）；链接没提工作区 → nil。
    /// 只查、不 `acquire`（引用计数归开窗那一步管）。
    static func resolveFolder(_ link: DeepLink) throws -> URL? {
        let reg = WorkspaceRegistry.shared
        let path = link.workspacePath.map { URL(fileURLWithPath: $0).standardizedFileURL }

        // ① 路径正开着
        if let p = path, reg.openManager(at: p) != nil { return p }
        // ② 按 workspace_id：开着的实例 → 最近列表（源盘 / 副本）
        if let wid = link.workspaceId {
            if let m = reg.openManagers.first(where: { $0.store?.workspaceId == wid }), let f = m.folder { return f }
            if let r = reg.recents.first(where: { $0.id == wid }), let f = WorkspaceRegistry.resolve(r) { return f }
        }
        // ③ 按路径：真实存在 → 它；在最近列表里（盘可能没插）→ 副本兜底
        if let p = path {
            if WorkspaceManager.hasLibrary(p) { return p }
            if let r = reg.recents.first(where: { URL(fileURLWithPath: $0.sourcePath).standardizedFileURL == p }),
               let f = WorkspaceRegistry.resolve(r) { return f }
            throw RouteError.workspaceNotFound(p.path)
        }
        if let wid = link.workspaceId { throw RouteError.workspaceNotFound(wid) }
        return nil
    }

    // MARK: - 文档

    /// `doc` → 直接；找不到（或没给）再按 `hash` 查 variant。给了却都找不到 → 报错。都没给 → nil。
    static func resolveDocument(_ link: DeepLink, in ws: WorkspaceManager) throws -> String? {
        if let id = link.documentId, ws.document(id: id) != nil { return id }
        if let hash = link.contentHash,
           let v = try? ws.store?.variant(hash: hash), ws.document(id: v.documentId) != nil {
            return v.documentId
        }
        if let id = link.documentId { throw RouteError.documentNotFound(id) }
        if let hash = link.contentHash { throw RouteError.documentNotFound(String(hash.prefix(12)) + "…") }
        return nil
    }

    // MARK: - 位置

    struct Target: Equatable {
        /// 0 起页号。
        var page: Int
        var frac: Double
        /// 要展开气泡的笔记（文字 / 图片笔记才有；高亮与书签只跳不展开）。
        var reveal: UUID?
    }

    /// 链接说的「哪里」落到这个会话的具体页 + 页内位置。`note` 优先（它自带位置），找不到再看
    /// `page`/`frac`；什么都没说 → nil（只开文档不动位置）。
    static func target(for link: DeepLink, in s: DocSession) -> Target? {
        if let id = link.noteId {
            // 与 Inspector 点条目同一口径：锚点上沿再往上让 3%，标题/图钉不顶在视口边上
            func above(_ r: CGRect) -> Double { max(0, Double(r.minY) - 0.03) }
            if let n = s.textNotes.first(where: { $0.id == id }) { return Target(page: n.page, frac: above(n.anchor), reveal: n.id) }
            if let n = s.imageNotes.first(where: { $0.id == id }) { return Target(page: n.page, frac: above(n.anchor), reveal: n.id) }
            if let h = s.highlights.first(where: { $0.id == id }) { return Target(page: h.page, frac: above(h.anchor), reveal: nil) }
            if let b = s.bookmarks.first(where: { $0.id == id }) { return Target(page: b.page, frac: b.frac, reveal: nil) }
            wsLog("链接里的笔记不在这篇文档里，退回页码：\(id.uuidString)")
        }
        guard link.page != nil || link.frac != nil else { return nil }
        let count = s.pdf?.pageCount ?? 0
        var page = (link.page ?? (s.currentPageIndex + 1)) - 1
        if count > 0 { page = min(max(page, 0), count - 1) } else { page = max(page, 0) }
        return Target(page: page, frac: min(max(link.frac ?? 0, 0), 1), reveal: nil)
    }

    // MARK: - 提示

    static func alert(url: URL, error: Error) {
        let a = NSAlert()
        a.messageText = L("Cannot Open Link")
        let reason: String
        if let e = error as? DeepLink.ParseError {
            switch e {
            case .notDeepLink: reason = L("This is not a UniReader link.")
            case .unknownHost(let h): reason = String(format: L("Unknown link type “%@” (expected “open”)."), h)
            case .badPage(let v): reason = String(format: L("Bad page number “%@” (pages start at 1)."), v)
            case .badFrac(let v): reason = String(format: L("Bad position “%@” (expected 0…1)."), v)
            case .badNote(let v): reason = String(format: L("Bad note id “%@”."), v)
            }
        } else {
            reason = error.localizedDescription
        }
        a.informativeText = reason + "\n\n" + url.absoluteString
        a.addButton(withTitle: L("OK"))
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
