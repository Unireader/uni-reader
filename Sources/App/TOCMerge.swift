import Foundation

/// **目录 + 书签的合并规则**（`REQUIREMENTS.md §1.9`）——纯函数，只认「深度 + 页号」，
/// 不认 PDFKit、不认 SwiftUI，于是能用 spike 单文件测（视图层测不了），也给 web 与安卓两端
/// 当参照实现。**三端同一口径，改这里必须同步另外两端。**
///
/// 规则三条：
/// ① 取全部 **depth==0 且有页号**的目录项，按页号升序得到区间边界；页号为 b 的书签落在
///    `[pᵢ, pᵢ₊₁)` → 挂到第 i 个一级组下，作为它的**直接子项**（depth=1）。
/// ② 落在第一个一级组之前、或压根没有可用的一级组（含整本书没目录）→ 平铺在**树顶**（depth=0），
///    不套任何组，也不造「书签」这种假分组标题。
/// ③ 组内位置：插在该组直接子项中**第一个页号大于它**的那一项之前（无页号的子项跳过顺延），
///    都不大于就排在该组子树末尾。**目录项之间的相对顺序一行不动**——绝不为排序重排 PDF 自己的目录。
enum TOCMerge {

    /// 拍平（先序）后的一行目录。合并算法只需要这两样。
    struct Row: Equatable {
        let depth: Int
        /// 0 基页号；nil = 坏书签（destination 解不出目标页，真实 PDF 里很常见）。
        let page: Int?

        init(depth: Int, page: Int?) {
            self.depth = depth
            self.page = page
        }
    }

    /// 一枚书签的落位。
    struct Slot: Equatable {
        /// 插在拍平目录的第几行**之前**；等于行数表示排在最末。
        let insertBefore: Int
        /// 缩进深度：0 = 平铺树顶，1 = 挂在某个一级组下。
        let depth: Int
        /// 挂在拍平目录的第几行（那个一级组）；nil = 树顶。祖先链由调用方据此拼。
        let owner: Int?
    }

    /// 给每枚书签算落位。
    ///
    /// - Parameters:
    ///   - rows: 拍平（先序）后的目录行。
    ///   - bookmarkPages: 书签页号，**必须按升序**（`Bookmark.before` 的前两级已保证）。
    /// - Returns: 与 `bookmarkPages` 等长、一一对应的落位表。
    ///
    /// 同一个 `insertBefore` 上可能落多枚书签；调用方按输入顺序依次插入即可，
    /// 于是同页多枚的先后仍是 `Bookmark.before` 那个顺序。
    static func place(rows: [Row], bookmarkPages: [Int]) -> [Slot] {
        guard !bookmarkPages.isEmpty else { return [] }

        // 一级组边界：(行下标, 页号) 按**页号**升序。
        // 不能直接拿先序当顺序——真实 PDF 的目录先序并不保证页号单调（见 `TOCEntry.chapterLabel`
        // 那处同源的账：整本书末尾挂着空 destination 的项）。
        let groups: [(idx: Int, page: Int)] = rows.enumerated()
            .compactMap { (i, r) in
                guard r.depth == 0, let p = r.page else { return nil }
                return (i, p)
            }
            .sorted { $0.page < $1.page }

        /// 某个一级组的子树尾（开区间）：从组的下一行起，到下一个 depth==0 为止。
        func subtreeEnd(after idx: Int) -> Int {
            var j = idx + 1
            while j < rows.count, rows[j].depth > 0 { j += 1 }
            return j
        }

        return bookmarkPages.map { page in
            guard let g = groups.last(where: { $0.page <= page }) else {
                return Slot(insertBefore: 0, depth: 0, owner: nil)   // ② 树顶
            }
            let end = subtreeEnd(after: g.idx)
            var at = end                                             // ③ 默认排在该组子树末尾
            var j = g.idx + 1
            while j < end {
                if rows[j].depth == 1, let p = rows[j].page, p > page { at = j; break }
                j += 1
            }
            return Slot(insertBefore: at, depth: 1, owner: g.idx)
        }
    }
}
