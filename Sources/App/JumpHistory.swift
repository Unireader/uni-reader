import Foundation

/// 跳转的来源类别 —— **只**用来在历史列表里分辨图标与语义，不参与任何跨端协议、不落库。
enum JumpKind: String, Equatable {
    /// 跳走之前停留的阅读位置（历史轨迹里的「离开点」）。
    case reading
    /// 目录条目（Mac 侧栏/弹窗的目录，或平板下发的同款跳转）。
    case toc
    /// 搜索命中。
    case search
    /// 其它列表跳转：缩略图、笔迹/注解/高亮/草稿纸列表、参考窗「在主视图显示这一页」。
    case list

    var symbol: String {
        switch self {
        case .reading: return "book.pages"
        case .toc: return "list.bullet.indent"
        case .search: return "magnifyingglass"
        case .list: return "arrow.turn.down.right"
        }
    }
}

/// 一条跳转标记 = 一处阅读位置的快照。
///
/// 位置口径与 `ScrollAnchor` 完全一致（页 + 页内归一化比例，与缩放/视口无关），
/// 于是「回到这一条」就是原样发一次锚点，不必再算任何几何。
struct JumpMark: Identifiable, Equatable {
    let id: UUID
    var page: Int
    var frac: Double
    var kind: JumpKind
    /// 人给的名字（目录条目名 / 搜索词）。**空 = 让 UI 按页去推导章节名**——
    /// 缩略图、笔记列表这类跳转本来就没有现成的名字，与其写死「第 N 页」不如显示它落在哪一章。
    var label: String
    var at: Date

    init(page: Int, frac: Double, kind: JumpKind, label: String = "",
         id: UUID = UUID(), at: Date = Date()) {
        self.id = id
        self.page = page
        self.frac = max(0, min(1, frac))
        self.kind = kind
        self.label = label
        self.at = at
    }

    /// 同一处位置：同页且页内比例几乎相同。折叠重复记录用（阈值 1% 页高 ≈ 一两行字）。
    func samePlace(as o: JumpMark) -> Bool { page == o.page && abs(frac - o.frac) < 0.01 }
}

/// 一篇文档的跳转历史（浏览器式：一条线性轨迹 + 一个游标）。
///
/// **纯值类型**，作为 `DocSession` 的 `@Published` 属性存放：改一下就自动通知视图
/// （工具栏返回按钮的禁用态、浮窗列表都靠它），不必再嵌一层 `ObservableObject` 手工转发
/// （`DocSession → DocTabModel → TabsModel → ContentView` 那条转发链已经现成）。
///
/// 🔴 **一份也不落库**（同参考窗的视口状态）：它描述的是「这次阅读的来路」，关掉就该忘掉；
/// 也**一个字节不上线**——平板下发的跳转会在 Mac 这边记一条，但历史本身不镜像回去，
/// 故本类不碰 `PROTOCOL.md` 也不碰 schema。
struct JumpHistory: Equatable {
    /// 最多留多少条（超了从最旧的删）。
    static let limit = 60

    private(set) var marks: [JumpMark] = []
    /// 当前处在第几条（-1 = 空）。后退/前进就是在这条轴上移动游标。
    private(set) var cursor = -1

    var isEmpty: Bool { marks.isEmpty }
    var current: JumpMark? { marks.indices.contains(cursor) ? marks[cursor] : nil }
    var canGoBack: Bool { cursor > 0 }
    var canGoForward: Bool { cursor >= 0 && cursor + 1 < marks.count }

    mutating func reset() {
        marks = []
        cursor = -1
    }

    /// 记一次跳转。`from` = 跳走前停的地方（实时阅读位置），`to` = 目标。
    ///
    /// 三条规则，都是为了让列表读起来像「我走过的路」而不是流水账：
    ///  ① **离开点与当前这条不在同一处就先把它垫进去**——包含「历史还是空的」这一种情形。
    ///     不垫的话，跳完就再也退不回刚才读到的地方（跳转后又自己滚了一段的情况尤其明显）。
    ///  ② 后退到中途再跳，后面那截**前进分支作废**（浏览器语义）。
    ///  ③ 落到同一处、或同一个搜索词的连续命中 → **就地更新当前条**，不新增：
    ///     按 20 次「下一个」不该在历史里留 20 条。
    mutating func record(leaving from: JumpMark, to target: JumpMark) {
        if cursor + 1 < marks.count { marks.removeSubrange((cursor + 1)...) }   // ②
        if !(current?.samePlace(as: from) ?? false) {                            // ①
            marks.append(from)
            cursor = marks.count - 1
        }
        if let cur = current, cur.samePlace(as: target) || Self.sameSearch(cur, target) {   // ③
            // 保留原 id：浮窗列表里那一行原地更新，不会跳位/重建
            marks[cursor] = JumpMark(page: target.page, frac: target.frac, kind: target.kind,
                                     label: target.label, id: cur.id, at: target.at)
            trim()
            return
        }
        marks.append(target)
        cursor = marks.count - 1
        trim()
    }

    /// 同一次搜索的两次命中？——词相同，**或者一方是另一方的前缀**。
    ///
    /// 前缀那半条是给「边打字边搜」用的：查找是防抖 250ms 跑一次，打「傅里叶」会依次搜出
    /// 「傅」「傅里」「傅里叶」三批结果、每批都自动跳到首个命中。只比相等的话历史里会平白多出
    /// 两条半截词。真换个词（「卷积」）与前一个词没有前缀关系，照旧新增一条。
    private static func sameSearch(_ a: JumpMark, _ b: JumpMark) -> Bool {
        guard a.kind == .search, b.kind == .search else { return false }
        if a.label == b.label { return true }
        guard !a.label.isEmpty, !b.label.isEmpty else { return false }
        return a.label.hasPrefix(b.label) || b.label.hasPrefix(a.label)
    }

    /// 后退一步，返回要去的位置（已经在最前端则 nil）。
    mutating func back() -> JumpMark? {
        guard canGoBack else { return nil }
        cursor -= 1
        return marks[cursor]
    }

    /// 前进一步。
    mutating func forward() -> JumpMark? {
        guard canGoForward else { return nil }
        cursor += 1
        return marks[cursor]
    }

    /// 直接跳到列表里的某一条（点击浮窗行）。
    mutating func go(to id: UUID) -> JumpMark? {
        guard let i = marks.firstIndex(where: { $0.id == id }) else { return nil }
        cursor = i
        return marks[i]
    }

    /// 超上限时从最旧的开始丢，游标跟着往前挪（丢掉的正好在它前面）。
    private mutating func trim() {
        let over = marks.count - Self.limit
        guard over > 0 else { return }
        marks.removeFirst(over)
        cursor = max(0, cursor - over)
    }
}
