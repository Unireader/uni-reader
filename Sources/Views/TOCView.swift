import SwiftUI
import PDFKit

/// PDF 目录项（可嵌套）。pageIndex + frac 用于跳转（页 + 页内归一化比例）。
///
/// `pageIndex` 是 optional：**坏书签**（destination 解不出目标页）为 nil，不可当成第 0 页。
/// 现实里的坏书签形态：outline 项写了个空 destination（`/Dest [null 0 0 0]` 之类），PDFKit 直接
/// 给 `destination == nil`；也见过 dest 的 page 不属于本文档（`doc.index(for:)` 返回 NSNotFound）。
/// 这类项一律 nil —— 不显示页码、不可跳转、不参与当前页追踪。
struct TOCEntry: Identifiable {
    let id = UUID()
    let label: String
    let pageIndex: Int?
    let frac: Double
    var children: [TOCEntry]
    var childrenOrNil: [TOCEntry]? { children.isEmpty ? nil : children }

    /// 从 PDF 的 outlineRoot 递归构建目录树。
    static func build(from doc: PDFDocument) -> [TOCEntry] {
        guard let root = doc.outlineRoot else { return [] }
        func walk(_ o: PDFOutline) -> [TOCEntry] {
            var out: [TOCEntry] = []
            for i in 0..<o.numberOfChildren {
                guard let c = o.child(at: i) else { continue }
                var pageIndex: Int? = nil, frac = 0.0
                if let dest = c.destination, let page = dest.page {
                    let idx = doc.index(for: page)
                    if idx >= 0, idx < doc.pageCount {          // NSNotFound（=Int.max）等越界一律作废
                        pageIndex = idx
                        let b = page.bounds(for: PageBitmap.effectiveBox(page))
                        let y = dest.point.y
                        if y.isFinite, b.height > 0 { frac = min(max(0, Double((b.maxY - y) / b.height)), 1) }
                    }
                }
                out.append(TOCEntry(label: (c.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                    pageIndex: pageIndex, frac: frac, children: walk(c)))
            }
            return out
        }
        return walk(root)
    }

    /// 某页归属的章节名（先序里起点不晚于该页、页码最大的那项；并列取先序靠后 = 更深一层）。
    ///
    /// 与 `TOCListView` 的当前章节追踪**同一口径**（含对乱序/坏书签免疫的 argmax 写法，
    /// 理由见那边的注释）。跳转历史里没有现成名字的条目（缩略图、笔记列表跳转）靠它显示
    /// 「落在哪一章」，比干巴巴一个页码有用。没有目录或没命中时返回空串。
    static func chapterLabel(for page: Int, in entries: [TOCEntry]) -> String {
        var best: (page: Int, label: String)? = nil
        func walk(_ list: [TOCEntry]) {
            for e in list {
                if let p = e.pageIndex, p <= page, !(best.map { p < $0.page } ?? false) {
                    best = (p, e.label)
                }
                walk(e.children)
            }
        }
        walk(entries)
        return best?.label.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// 目录列表（可折叠树），**书签与目录合并显示**（规格 `REQUIREMENTS.md §1.9`）。
/// 空目录且没有书签时给出占位；点条目回调跳转。
/// **当前页追踪**：归属当前页的条目（先序最后一个 pageIndex ≤ 当前页）自动展开其祖先链 +
/// 强调显示 + 滚动到位——不用每次手动展开找所在章节。自动追踪只增展开、不动用户手动折叠的其它分支。
/// 追踪**只认目录项**，书签行不参与：它回答的是「我在第几章」，跳到书签行上没有意义。
///
/// 实现说明：系统 `List(children:)` 大纲不支持程序化展开/定位，故改手动树（ScrollView + LazyVStack，
/// 展开态自持 `expanded`）；行外观维持原纯文字行 + 页码，chevron 只管折叠。
///
/// ⚠️ `onSelect` 刻意留在**参数表最后**：三处调用点里有两处用尾随闭包写法，书签那几个参数
/// 插在它前面（都有默认值）才不会把尾随闭包绑错人。参考窗与工具栏弹窗不传书签 = 行为一行没变。
struct TOCListView: View {
    let entries: [TOCEntry]
    let currentPage: Int                    // 0 基当前页（追踪高亮用）
    var bookmarks: [Bookmark] = []          // 已按 `Bookmark.before` 有序（`WorkspaceManager.bookmarks`）
    var onSelectBookmark: ((Bookmark) -> Void)? = nil
    var onRenameBookmark: ((Bookmark) -> Void)? = nil
    var onDeleteBookmark: ((Bookmark) -> Void)? = nil
    let onSelect: (TOCEntry) -> Void

    @State private var expanded: Set<UUID> = []

    /// 一行：目录项或书签。先序拍平后带深度 + 祖先链（可见性判定与自动展开都要用）。
    private struct Flat {
        enum Kind {
            case toc(TOCEntry)
            case bookmark(Bookmark)
        }
        let kind: Kind
        let depth: Int
        let parents: [UUID]

        var id: UUID {
            switch kind {
            case .toc(let e): return e.id
            case .bookmark(let b): return b.id
            }
        }
        var page: Int? {
            switch kind {
            case .toc(let e): return e.pageIndex
            case .bookmark(let b): return b.page
            }
        }
        var tocEntry: TOCEntry? { if case .toc(let e) = kind { return e }; return nil }
        var bookmark: Bookmark? { if case .bookmark(let b) = kind { return b }; return nil }
    }

    /// 纯目录的先序拍平（合并书签之前的那一份）。
    private var tocFlat: [Flat] {
        var out: [Flat] = []
        func walk(_ list: [TOCEntry], depth: Int, parents: [UUID]) {
            for e in list {
                out.append(Flat(kind: .toc(e), depth: depth, parents: parents))
                if let cs = e.childrenOrNil { walk(cs, depth: depth + 1, parents: parents + [e.id]) }
            }
        }
        walk(entries, depth: 0, parents: [])
        return out
    }

    /// 目录 + 书签合并后的完整先序行表。**规则本身在 `TOCMerge`**（纯函数、三端契约、有 spike 覆盖），
    /// 这里只负责把落位表翻译成带 id 与祖先链的行。
    private var flat: [Flat] {
        let base = tocFlat
        guard !bookmarks.isEmpty else { return base }

        let slots = TOCMerge.place(rows: base.map { TOCMerge.Row(depth: $0.depth, page: $0.page) },
                                   bookmarkPages: bookmarks.map(\.page))
        var insertions: [Int: [Flat]] = [:]   // 插在 base 的哪个下标**之前**（base.count = 末尾）
        for (i, b) in bookmarks.enumerated() {
            let s = slots[i]
            // 祖先链 = 那个一级组自己的链 + 它本身 → 组折叠时书签跟着藏起来
            let parents: [UUID] = s.owner.map { base[$0].parents + [base[$0].id] } ?? []
            insertions[s.insertBefore, default: []]
                .append(Flat(kind: .bookmark(b), depth: s.depth, parents: parents))
        }

        var out: [Flat] = []
        out.reserveCapacity(base.count + bookmarks.count)
        for (i, f) in base.enumerated() {
            if let ins = insertions[i] { out.append(contentsOf: ins) }
            out.append(f)
        }
        if let tail = insertions[base.count] { out.append(contentsOf: tail) }
        return out
    }

    /// 归属当前页的**目录项**：起点不晚于当前页的项里页码最大的那个，并列取先序最后一个（＝最深一层）。
    ///
    /// 不能简单取「先序最后一个 pageIndex ≤ currentPage」——那要求先序页码单调不减，而真实 PDF 的书签
    /// 常常不满足：见过整本书末尾挂着两个空 destination 的项，一旦把它们当第 0 页，就会在**任何**页都
    /// 命中它们（0 ≤ 任何页，且它们排在先序最末），高亮永远钉在最后一项。取 argmax 对乱序书签同样免疫。
    private var currentId: UUID? {
        var best: (page: Int, id: UUID)? = nil
        for f in flat {
            guard let e = f.tocEntry, let p = e.pageIndex, p <= currentPage else { continue }
            if let b = best, p < b.page { continue }     // ≥ 才更新 → 同页并列时取先序靠后的（更深一层）
            best = (p, e.id)
        }
        return best?.id
    }

    /// 可见行：祖先链全部展开才显示。
    private var visibleRows: [Flat] {
        flat.filter { $0.parents.allSatisfy(expanded.contains) }
    }

    var body: some View {
        if entries.isEmpty, bookmarks.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "list.bullet.indent").font(.title2).foregroundStyle(.tertiary)
                Text(L("No table of contents")).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleRows, id: \.id) { row($0) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                }
                .onAppear { revealBookmarks(); reveal(currentId, proxy: proxy) }
                .onChange(of: currentId) { _, id in reveal(id, proxy: proxy) }
                .onChange(of: bookmarks.count) { _, _ in revealBookmarks() }
            }
        }
    }

    /// 🔴 **把带书签的那些组展开**（只增展开，不折叠任何分支）。
    ///
    /// 书签是按页号挂进一级组的，而一级组默认收着——不展开的话「加完书签在目录里找不到」。
    /// 2026-09-02 用户在安卓上实测撞到：485 条目录的书，加了一枚死活看不见，日志里
    /// `收到书签 1 枚` 且 docId 对得上，纯粹是被折叠挡住了。三端同一处理。
    ///
    /// 只在**出现/进入**与**书签数变化**时跑（不是每次重建都跑），于是用户手动折叠仍然收得住。
    private func revealBookmarks() {
        for f in flat where f.bookmark != nil {
            expanded.formUnion(f.parents)
        }
    }

    /// 自动追踪：展开目标条目的祖先链并滚动到位（只增展开，不折叠任何分支）。
    private func reveal(_ id: UUID?, proxy: ScrollViewProxy) {
        guard let id, let f = flat.first(where: { $0.id == id }) else { return }
        expanded.formUnion(f.parents)
        // 等展开后的布局落地再滚，否则目标行还没插进树里
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
    }

    @ViewBuilder private func row(_ f: Flat) -> some View {
        Group {
            if let e = f.tocEntry {
                tocRow(e, depth: f.depth)
            } else if let b = f.bookmark {
                bookmarkRow(b, depth: f.depth)
            }
        }
        .id(f.id)
    }

    @ViewBuilder private func tocRow(_ e: TOCEntry, depth: Int) -> some View {
        let isCurrent = e.id == currentId
        HStack(spacing: 4) {
            if e.childrenOrNil != nil {
                Button { toggle(e.id) } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded.contains(e.id) ? 90 : 0))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 14)   // 无子项的行留出缩进，文字对齐
            }
            Button { onSelect(e) } label: {
                HStack(spacing: 8) {
                    Text(e.label.isEmpty ? "—" : e.label).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 6)
                    // 坏书签（无目标页）留空而非显示「1」，配合 disabled 表达「跳不过去」
                    Text(e.pageIndex.map { "\($0 + 1)" } ?? "").font(.caption).monospacedDigit()
                        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(isCurrent ? Color.accentColor.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(e.pageIndex == nil)
        }
        .padding(.leading, CGFloat(depth) * 14)
    }

    /// 书签行：与目录项一眼分得开（前面一枚书签图标），但排版对齐同一套。
    /// 图标占的正是目录项 chevron 那 14pt，于是有子项的目录项与书签行的文字仍在同一条竖线上。
    @ViewBuilder private func bookmarkRow(_ b: Bookmark, depth: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "bookmark.fill")
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 14, height: 14)
            Button { onSelectBookmark?(b) } label: {
                HStack(spacing: 8) {
                    Text(b.title).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text("\(b.page + 1)").font(.caption).monospacedDigit()
                        .foregroundStyle(Color.secondary)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onSelectBookmark == nil)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .contextMenu {
            if let rename = onRenameBookmark {
                Button(L("Rename…")) { rename(b) }
            }
            if let del = onDeleteBookmark {
                Button(L("Delete"), role: .destructive) { del(b) }
            }
        }
    }

    private func toggle(_ id: UUID) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }
}
