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

/// 目录列表（可折叠树）。空目录给出占位；点条目回调跳转。
/// **当前页追踪**：归属当前页的条目（先序最后一个 pageIndex ≤ 当前页）自动展开其祖先链 +
/// 强调显示 + 滚动到位——不用每次手动展开找所在章节。自动追踪只增展开、不动用户手动折叠的其它分支。
///
/// 实现说明：系统 `List(children:)` 大纲不支持程序化展开/定位，故改手动树（ScrollView + LazyVStack，
/// 展开态自持 `expanded`）；行外观维持原纯文字行 + 页码，chevron 只管折叠。
struct TOCListView: View {
    let entries: [TOCEntry]
    let currentPage: Int                    // 0 基当前页（追踪高亮用）
    let onSelect: (TOCEntry) -> Void

    @State private var expanded: Set<UUID> = []

    /// 先序拍平：深度 + 祖先链（可见性判定与自动展开都要用）。
    private struct Flat {
        let entry: TOCEntry
        let depth: Int
        let parents: [UUID]
    }

    private var flat: [Flat] {
        var out: [Flat] = []
        func walk(_ list: [TOCEntry], depth: Int, parents: [UUID]) {
            for e in list {
                out.append(Flat(entry: e, depth: depth, parents: parents))
                if let cs = e.childrenOrNil { walk(cs, depth: depth + 1, parents: parents + [e.id]) }
            }
        }
        walk(entries, depth: 0, parents: [])
        return out
    }

    /// 归属当前页的条目：起点不晚于当前页的项里页码最大的那个，并列取先序最后一个（＝最深一层）。
    ///
    /// 不能简单取「先序最后一个 pageIndex ≤ currentPage」——那要求先序页码单调不减，而真实 PDF 的书签
    /// 常常不满足：见过整本书末尾挂着两个空 destination 的项，一旦把它们当第 0 页，就会在**任何**页都
    /// 命中它们（0 ≤ 任何页，且它们排在先序最末），高亮永远钉在最后一项。取 argmax 对乱序书签同样免疫。
    private var currentId: UUID? {
        var best: (page: Int, id: UUID)? = nil
        for f in flat {
            guard let p = f.entry.pageIndex, p <= currentPage else { continue }
            if let b = best, p < b.page { continue }     // ≥ 才更新 → 同页并列时取先序靠后的（更深一层）
            best = (p, f.entry.id)
        }
        return best?.id
    }

    /// 可见行：祖先链全部展开才显示。
    private var visibleRows: [Flat] {
        flat.filter { $0.parents.allSatisfy(expanded.contains) }
    }

    var body: some View {
        if entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "list.bullet.indent").font(.title2).foregroundStyle(.tertiary)
                Text(L("No table of contents")).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleRows, id: \.entry.id) { row($0) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                }
                .onAppear { reveal(currentId, proxy: proxy) }
                .onChange(of: currentId) { _, id in reveal(id, proxy: proxy) }
            }
        }
    }

    /// 自动追踪：展开目标条目的祖先链并滚动到位（只增展开，不折叠任何分支）。
    private func reveal(_ id: UUID?, proxy: ScrollViewProxy) {
        guard let id, let f = flat.first(where: { $0.entry.id == id }) else { return }
        expanded.formUnion(f.parents)
        // 等展开后的布局落地再滚，否则目标行还没插进树里
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
    }

    @ViewBuilder private func row(_ f: Flat) -> some View {
        let e = f.entry
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
        .padding(.leading, CGFloat(f.depth) * 14)
        .id(e.id)
    }

    private func toggle(_ id: UUID) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }
}
