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

/// 目录列表（原生可折叠树）。空目录给出占位；点条目回调跳转。
struct TOCListView: View {
    let entries: [TOCEntry]
    let onSelect: (TOCEntry) -> Void

    var body: some View {
        if entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "list.bullet.indent").font(.title2).foregroundStyle(.tertiary)
                Text(L("No table of contents")).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(entries, children: \.childrenOrNil) { e in
                Button { onSelect(e) } label: {
                    HStack(spacing: 8) {
                        Text(e.label.isEmpty ? "—" : e.label).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 6)
                        Text("\(e.pageIndex + 1)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }
}
