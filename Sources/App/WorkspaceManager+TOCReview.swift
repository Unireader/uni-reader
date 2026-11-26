import Foundation

extension Notification.Name {
    /// 某篇文档的自建目录变了（object = 工作区，userInfo["documentId"]）。开着这篇的标签据此重读。
    static let customTOCDidChange = Notification.Name("UniReader.customTOCDidChange")
    /// 某个工作区的回顾点变了（object = 工作区，userInfo["documentIds"] = [String]，可能为空 = 不确定哪几篇）。
    static let reviewMarksDidChange = Notification.Name("UniReader.reviewMarksDidChange")
}

/// 自建目录（note kind=7）与回顾点（note kind=8）的读写（`TOC-REVIEW-PLAN.md`）。
///
/// 两样都**直接写库**、写完发通知，界面收到通知重读——不走书签那套「会话列表 + 增量对账」：
/// 它们改得少、改的入口多（Inspector / 阅读区 / MCP / 同步），从库里重读最不容易出错。
/// 🔴 删除一律先进回收站再删库（红线 11）。
extension WorkspaceManager {

    // MARK: - 自建目录

    /// 某篇文档的自建目录，已按 `CustomTOCItem.before` 排好。
    func customTOC(documentId: String) -> [CustomTOCItem] {
        ((try? store?.notes(documentId: documentId, kind: CustomTOCItem.noteKind)) ?? [])
            .compactMap(CustomTOCItem.init(note:))
            .sorted(by: CustomTOCItem.before)
    }

    /// 新建或修改一项。
    func saveCustomTOCItem(documentId: String, _ item: CustomTOCItem) {
        guard let store, let n = item.toNote(documentId: documentId) else { return }
        try? store.upsertNote(n)
        postCustomTOCChanged(documentId)
    }

    /// 删掉几项（先进回收站）。成功返回 true。
    @discardableResult
    func deleteCustomTOCItems(documentId: String, ids: [UUID]) -> Bool {
        guard let store, !ids.isEmpty else { return false }
        let title = ids.count == 1
            ? (customTOC(documentId: documentId).first { $0.id == ids[0] }.map { "“\($0.title)”" } ?? L("Contents"))
            : String(format: L("%d contents entries"), ids.count)
        guard Trash.archiveNotes(store: store, documentId: documentId, documentTitle: document(id: documentId)?.title ?? "",
                                 ids: ids, title: title) != nil else { return false }
        try? store.replaceNotes(deleteIds: ids.map(\.uuidString), upserts: [])
        postCustomTOCChanged(documentId)
        return true
    }

    /// 整份替换（Agent 的 `set_toc`、「从 PDF 目录复制」、「清空」都走这里）：旧的先整份进回收站，
    /// 再在一个事务里删旧写新。`items` 为空 = 清空。归档失败就什么都不改，抛错。
    func replaceCustomTOC(documentId: String, items: [CustomTOCItem]) throws {
        guard let store else { throw NSError(domain: "UniReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "the workspace is not open"]) }
        let old = customTOC(documentId: documentId)
        if !old.isEmpty {
            let docTitle = document(id: documentId)?.title ?? ""
            guard Trash.archiveNotes(store: store, documentId: documentId, documentTitle: docTitle, ids: old.map(\.id),
                                     title: String(format: L("Contents of “%@”"), docTitle)) != nil else {
                throw NSError(domain: "UniReader", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "could not move the old contents to Recently Deleted, so nothing was changed"])
            }
        }
        try store.replaceNotes(deleteIds: old.map(\.id.uuidString), upserts: items.compactMap { $0.toNote(documentId: documentId) })
        postCustomTOCChanged(documentId)
    }

    func postCustomTOCChanged(_ documentId: String) {
        NotificationCenter.default.post(name: .customTOCDidChange, object: self, userInfo: ["documentId": documentId])
    }

    // MARK: - 回顾点

    /// 某篇文档的回顾点（按 `ReviewMark.before`）。
    func reviewMarks(documentId: String) -> [ReviewMark] {
        ((try? store?.notes(documentId: documentId, kind: ReviewMark.noteKind)) ?? [])
            .compactMap(ReviewMark.init(note:))
            .sorted(by: ReviewMark.before)
    }

    /// 整个工作区的回顾点（文档已不在库里的行丢掉）。
    func allReviewMarks() -> [ReviewMark] {
        let ids = Set(documents.map(\.id))
        return ((try? store?.notes(kind: ReviewMark.noteKind)) ?? [])
            .compactMap(ReviewMark.init(note:))
            .filter { ids.contains($0.documentId) }
    }

    /// 工作区里用过的全部标签（按名字排）。
    func reviewTags() -> [String] {
        Array(Set(allReviewMarks().map(\.tag).filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 新建或修改（几条一起，一次通知）。
    func saveReviewMarks(_ marks: [ReviewMark]) {
        guard let store, !marks.isEmpty else { return }
        try? store.replaceNotes(deleteIds: [], upserts: marks.compactMap { $0.toNote(documentId: $0.documentId) })
        postReviewsChanged(Array(Set(marks.map(\.documentId))))
    }

    /// 删掉几条（按文档分批进回收站，再删库）。全部归档成功才删；返回删掉的条数。
    @discardableResult
    func deleteReviewMarks(_ marks: [ReviewMark]) -> Int {
        guard let store, !marks.isEmpty else { return 0 }
        var deleted = 0
        var docs: [String] = []
        for (docId, group) in Dictionary(grouping: marks, by: \.documentId) {
            let head = group[0].remark.isEmpty ? group[0].tag : group[0].remark
            let title = group.count == 1 ? "“\(String(head.prefix(24)))”"
                : String(format: L("%d review points"), group.count)
            guard Trash.archiveNotes(store: store, documentId: docId, documentTitle: document(id: docId)?.title ?? "",
                                     ids: group.map(\.id), title: title) != nil else { continue }
            try? store.replaceNotes(deleteIds: group.map(\.id.uuidString), upserts: [])
            deleted += group.count
            docs.append(docId)
        }
        if !docs.isEmpty { postReviewsChanged(docs) }
        return deleted
    }

    func postReviewsChanged(_ documentIds: [String]) {
        NotificationCenter.default.post(name: .reviewMarksDidChange, object: self, userInfo: ["documentIds": documentIds])
    }
}
