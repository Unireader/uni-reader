import Foundation
import PDFKit

/// ⌘P 搜目录用的目录来源（`QUICK-OPEN-PLAN.md §6.2`）。每篇文档取**当前生效的目录**，同阅读区的口径：
///  1. 这篇开着（这个工作区任一窗口的任一标签）→ 用它会话里的 `toc`（已按自建优先 / 用户切回 PDF 目录算好）；
///  2. 没开、有自建目录（note kind=7，读库很快）→ 自建目录；
///  3. 否则 PDF 自带目录：**后台**解析（大书一本要 100ms 上下，不能卡住弹出），按「路径 + 修改时间」缓存到 App 退出；
///     解析好了回调 `onUpdate`，面板据此重排。
/// 扫描页对齐不参与（落点的页内比例差零点几个百分点，跳过去看不出来）。
@MainActor
final class QuickOpenTOCCache {
    static let shared = QuickOpenTOCCache()

    private struct Key: Hashable { let path: String; let mtime: Date? }
    private var pdf: [Key: [TOCEntry]] = [:]
    private var building: Set<Key> = []

    /// 每篇文档现在能拿到的目录（文档 id → 目录树）；缺的 PDF 目录排进后台，解析完一批调一次 `onUpdate`。
    func entries(in ws: WorkspaceManager, onUpdate: @escaping () -> Void) -> [String: [TOCEntry]] {
        var out: [String: [TOCEntry]] = [:]
        var openTOC: [String: [TOCEntry]] = [:]
        for c in AppDelegate.shared?.readerWindowControllers ?? [] where c.workspace === ws {
            for t in c.tabs.tabs {
                if let id = t.docID, openTOC[id] == nil, !t.session.toc.isEmpty { openTOC[id] = t.session.toc }
            }
        }
        var missing: [Key] = []
        for d in ws.documents {
            if let t = openTOC[d.id] { out[d.id] = t; continue }
            let custom = ws.customTOC(documentId: d.id)
            if !custom.isEmpty { out[d.id] = CustomTOCItem.entries(custom); continue }
            guard let path = ws.currentFilePath(documentId: d.id) else { continue }
            let key = Key(path: path, mtime: Self.mtime(path))
            if let t = pdf[key] { out[d.id] = t }
            else if !building.contains(key) { missing.append(key) }
        }
        if !missing.isEmpty { build(missing, onUpdate: onUpdate) }
        return out
    }

    private func build(_ keys: [Key], onUpdate: @escaping () -> Void) {
        building.formUnion(keys)
        Task.detached(priority: .utility) {
            var done: [(Key, [TOCEntry])] = []
            for k in keys {
                let toc = PDFDocument(url: URL(fileURLWithPath: k.path)).map { TOCEntry.build(from: $0, align: nil) } ?? []
                done.append((k, toc))
            }
            await MainActor.run {
                let me = QuickOpenTOCCache.shared
                for (k, t) in done {
                    me.pdf[k] = t
                    me.building.remove(k)
                }
                if done.contains(where: { !$0.1.isEmpty }) { onUpdate() }
            }
        }
    }

    private static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
