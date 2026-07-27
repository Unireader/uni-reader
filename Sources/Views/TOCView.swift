import SwiftUI
import PDFKit

/// PDF 目录项（可嵌套）。pageIndex + frac 用于跳转（页 + 页内归一化比例）。
struct TOCEntry: Identifiable {
    let id = UUID()
    let label: String
    let pageIndex: Int
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
                var pageIndex = 0, frac = 0.0
                if let dest = c.destination, let page = dest.page {
                    pageIndex = doc.index(for: page)
                    let b = page.bounds(for: .mediaBox)
                    let y = dest.point.y
                    if y.isFinite, b.height > 0 { frac = min(max(0, Double((b.maxY - y) / b.height)), 1) }
                }
                out.append(TOCEntry(label: (c.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                    pageIndex: pageIndex, frac: frac, children: walk(c)))
            }
            return out
        }
        return walk(root)
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

    /// 归属当前页的条目：先序里最后一个起点不晚于当前页的（子项页码 ≥ 父项，故命中最深一层）。
    private var currentId: UUID? {
        flat.last { $0.entry.pageIndex <= currentPage }?.entry.id
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
                    Text("\(e.pageIndex + 1)").font(.caption).monospacedDigit()
                        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(isCurrent ? Color.accentColor.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
