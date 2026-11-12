import Foundation

/// 全工作区搜索（MCP `search`，`SEARCH-PLAN.md`）的主线程那一半：认工作区、抄下来源清单；查完给命中补链接。
extension MCPFacade {

    func searchPrepare(workspacePath: String?) throws -> (index: SearchIndex, sources: [SearchIndex.Source], ws: WorkspaceManager) {
        let ws = try manager(workspacePath: workspacePath)
        guard let id = SearchSources.indexID(ws) else { throw MCPToolError("the workspace is not open") }
        let index: SearchIndex
        do { index = try SearchIndex.shared(workspaceID: id) }
        catch { throw MCPToolError("cannot open the search index: \(error)") }
        return (index, SearchSources.all(for: ws), ws)
    }

    /// 命中 → DTO（带 `unireader://` 链接；笔记 / 批注 / 习题的身份字段各给各的）。
    func searchHitDTO(_ ws: WorkspaceManager, _ h: SearchIndex.Hit, terms: [String]) -> MCPObject {
        var o: MCPObject = ["kind": h.kind, "title": h.title, "snippet": SearchText.snippet(h.body, terms: terms),
                            "score": (h.score * 1000).rounded() / 1000]
        switch h.kind {
        case "pdf":
            let page = PageNo.external(h.page ?? 0)
            o["document_id"] = h.owner
            o["page"] = page
            o["link"] = link(ws, doc: h.owner, page: page)
        case "markdown":
            o["note_ref"] = h.owner
            o["line"] = h.line ?? 1
            if !h.heading.isEmpty { o["heading"] = h.heading }
            o["link"] = link(ws, markdown: h.owner)
        case "annotation":
            let page = PageNo.external(h.page ?? 0)
            o["document_id"] = h.owner
            o["page"] = page
            o["annotation_id"] = h.sub
            o["annotation_kind"] = h.heading
            o["link"] = link(ws, doc: h.owner, page: page, note: UUID(uuidString: h.sub))
        case "exercise":
            o["exercise_id"] = h.owner
            if let d = h.docID { o["document_id"] = d }
            if let p = h.page { o["page"] = PageNo.external(p) }
            if !h.heading.isEmpty { o["chapter"] = h.heading }
            o["link"] = link(ws, exercise: h.owner)
        case "context":
            o["context_id"] = h.owner
            if !h.heading.isEmpty { o["agent"] = h.heading }
        default: break
        }
        return o
    }
}

// MARK: - 设置页用：预热 / 重建 / 状态

extension MCPFacade {
    /// 开着的各工作区：要进索引的来源与它们的索引。
    private static func openIndexes() -> [(name: String, index: SearchIndex, sources: [SearchIndex.Source])] {
        WorkspaceRegistry.shared.openManagers.compactMap { ws in
            guard let id = SearchSources.indexID(ws), let index = try? SearchIndex.shared(workspaceID: id) else { return nil }
            return (ws.name, index, SearchSources.all(for: ws))
        }
    }

    /// 让开着的工作区在后台把索引（和语义搜索打开时的向量）建起来，不等它建完。设置里改了语义搜索时调。
    static func warmUpSearchIndexes() async {
        let embedder = SemanticSearchSettings.current()
        for x in openIndexes() { _ = await x.index.refresh(x.sources, budget: 0, embedder: embedder) }
    }

    /// 整个丢掉重建（设置 › Agent › 搜索 › 重建索引）。
    static func rebuildSearchIndexes() async {
        for x in openIndexes() { await x.index.reset() }
        await warmUpSearchIndexes()
    }

    /// 设置页那一行：key 窗口的工作区（没有就第一个开着的）的索引状态。
    static func searchIndexStatus() async -> String {
        let key = AppDelegate.shared?.readerWindowControllers.first { $0.window?.isKeyWindow == true }?.workspace
        guard let ws = key ?? WorkspaceRegistry.shared.openManagers.first,
              let id = SearchSources.indexID(ws), let index = try? SearchIndex.shared(workspaceID: id) else {
            return L("No workspace is open")
        }
        let stats = await index.stats, p = await index.progress, e = await index.embedProgress
        let vectors = await index.vectorCount
        var s = stats.chunks == 0 && !p.building ? L("Not built yet")
            : (SemanticSearchSettings.enabled
               ? String(format: L("%@: %d pieces of text, %d with vectors"), ws.name, stats.chunks, vectors)
               : String(format: L("%@: %d pieces of text"), ws.name, stats.chunks))
        if p.building || e.running { s += " · " + L("building…") }
        if let err = e.lastError ?? p.lastError { s += "\n" + String(format: L("Last error: %@"), err) }
        return s
    }
}
