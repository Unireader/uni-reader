import AppKit

/// 自建目录 / 回顾点的界面动作（`TOC-REVIEW-PLAN.md`）：阅读区右键、页边标记、Inspector 目录页与回顾分区共用。
/// 全部只写库（`WorkspaceManager+TOCReview`），界面靠通知重读。
@MainActor
enum TOCReviewActions {

    private static func hint(_ s: DocSession, page: Int) -> String {
        let pageText = String(format: L("Page %d"), page + 1)
        let chapter = TOCEntry.chapterLabel(for: page, in: s.toc)
        return chapter.isEmpty ? pageText : "\(chapter) · \(pageText)"
    }

    // MARK: 自建目录

    /// 在某处加一项目录。PDF 自带目录正显示着时，加完自动切到自建目录（不然加了看不见）。
    static func addTOCEntry(_ s: DocSession, _ ws: WorkspaceManager, page: Int, frac: Double, window: NSWindow?) {
        guard let docId = s.documentId else { return }
        let level = CustomTOCItem.defaultLevel(page: page, frac: frac, in: s.customTOC)
        TOCReviewSheets.tocEntry(in: window, isNew: true, hint: hint(s, page: page), name: "", level: level) { name, lv in
            let seq = (s.customTOC.map(\.seq).max() ?? -1) + 1
            ws.saveCustomTOCItem(documentId: docId, CustomTOCItem(page: page, frac: frac, level: lv, title: name, seq: seq))
            s.tocShowsPDF = false
        }
    }

    static func editTOCEntry(_ s: DocSession, _ ws: WorkspaceManager, id: UUID, window: NSWindow?) {
        guard let docId = s.documentId, var it = s.customTOC.first(where: { $0.id == id }) else { return }
        TOCReviewSheets.tocEntry(in: window, isNew: false, hint: hint(s, page: it.page), name: it.title, level: it.level) { name, lv in
            it.title = name
            it.level = lv
            it.updatedAt = .now
            ws.saveCustomTOCItem(documentId: docId, it)
        }
    }

    /// 升一级（delta = -1）/ 降一级（+1）。
    static func shiftTOCEntry(_ s: DocSession, _ ws: WorkspaceManager, id: UUID, delta: Int) {
        guard let docId = s.documentId, var it = s.customTOC.first(where: { $0.id == id }) else { return }
        let lv = min(max(0, it.level + delta), CustomTOCItem.maxLevel)
        guard lv != it.level else { return }
        it.level = lv
        it.updatedAt = .now
        ws.saveCustomTOCItem(documentId: docId, it)
    }

    static func deleteTOCEntry(_ s: DocSession, _ ws: WorkspaceManager, id: UUID) {
        guard let docId = s.documentId else { return }
        if !ws.deleteCustomTOCItems(documentId: docId, ids: [id]) { NSSound.beep() }
    }

    /// 把 PDF 自带目录复制成自建目录（已有自建目录时先确认：旧的进回收站）。
    static func copyPDFTOC(_ s: DocSession, _ ws: WorkspaceManager, window: NSWindow?) {
        guard let docId = s.documentId else { return }
        let items = CustomTOCItem.copy(from: s.pdfTOC)
        guard !items.isEmpty else { return }
        let go = {
            do { try ws.replaceCustomTOC(documentId: docId, items: items); s.tocShowsPDF = false }
            catch { NSSound.beep() }
        }
        guard !s.customTOC.isEmpty else { go(); return }
        confirm(window, L("Replace the custom contents?"),
                L("The current custom contents will be moved to Recently Deleted."), button: L("Replace"), then: go)
    }

    /// 清空自建目录（进回收站）。
    static func clearCustomTOC(_ s: DocSession, _ ws: WorkspaceManager, window: NSWindow?) {
        guard let docId = s.documentId, !s.customTOC.isEmpty else { return }
        confirm(window, L("Clear the custom contents?"),
                L("All custom contents entries of this document will be moved to Recently Deleted. The PDF's own contents are not affected."),
                button: L("Clear")) {
            do { try ws.replaceCustomTOC(documentId: docId, items: []) } catch { NSSound.beep() }
        }
    }

    // MARK: 回顾点

    static func addReview(_ s: DocSession, _ ws: WorkspaceManager, page: Int, frac: Double, window: NSWindow?) {
        guard let docId = s.documentId else { return }
        TOCReviewSheets.review(in: window, isNew: true, hint: hint(s, page: page), tags: ws.reviewTags(),
                               tag: ReviewMark.lastTag, period: ReviewMark.lastPeriod, remark: "") { tag, period, remark in
            ReviewMark.lastTag = tag
            ReviewMark.lastPeriod = period
            ws.saveReviewMarks([ReviewMark(documentId: docId, page: page, frac: frac, tag: tag, remark: remark, period: period)])
        }
    }

    static func editReview(_ m: ReviewMark, _ ws: WorkspaceManager, window: NSWindow?) {
        let pageText = String(format: L("Page %d"), m.page + 1)
        let docTitle = ws.document(id: m.documentId)?.title ?? ""
        TOCReviewSheets.review(in: window, isNew: false, hint: docTitle.isEmpty ? pageText : "\(docTitle) · \(pageText)",
                               tags: ws.reviewTags(), tag: m.tag, period: m.period, remark: m.remark) { tag, period, remark in
            var x = m
            x.tag = tag
            x.period = period
            x.remark = remark
            x.updatedAt = .now
            ws.saveReviewMarks([x])
        }
    }

    /// 看完：期号后推 k 期（k = `ReviewMark.advanceStep`）。
    static func advanceReview(_ m: ReviewMark, _ ws: WorkspaceManager) {
        var x = m
        x.advance(by: ReviewMark.advanceStep)
        ws.saveReviewMarks([x])
    }

    static func deleteReview(_ m: ReviewMark, _ ws: WorkspaceManager) {
        if ws.deleteReviewMarks([m]) == 0 { NSSound.beep() }
    }

    // MARK: 共用

    private static func confirm(_ window: NSWindow?, _ title: String, _ detail: String, button: String, then: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        let b = a.addButton(withTitle: button)
        b.hasDestructiveAction = true
        a.addButton(withTitle: L("Cancel"))
        if let window {
            a.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { then() } }
        } else if a.runModal() == .alertFirstButtonReturn {
            then()
        }
    }
}
