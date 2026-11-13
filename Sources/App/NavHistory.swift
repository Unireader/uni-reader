import Foundation

/// 一扇窗口的「去过哪里」：工具栏「返回」/ ⌘[ 与 ⌘] 用（2026-11-13 用户报「返回按钮在很多页面都是无效的」，
/// 选了「像浏览器：跨标签回到上一个位置」）。纯逻辑，测试 `spike/nav-history-test.swift`。
///
/// 两个栈：每次离开一处（切标签、在标签里换内容、PDF 里的目录 / 搜索 / 链接跳转）把**离开的那一处**压进后退栈、
/// 清空前进栈；后退 = 弹出一处、把眼下这处压进前进栈；前进反过来。连着记同一处只留一条。
/// 只管顺序与去重，「一处」是什么、怎么回去由 `TabsModel`（`NavPlace`）定。
struct NavHistory<Place> {
    private(set) var backStack: [Place] = []
    private(set) var forwardStack: [Place] = []
    /// 后退栈最多留多少处（旧的先丢）。
    static var limit: Int { 100 }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// 离开 `place`（新的一次走动）：压进后退栈，前进栈作废。和栈顶是同一处就不重复记。
    mutating func record(leaving place: Place, same: (Place, Place) -> Bool) {
        forwardStack.removeAll()
        if let top = backStack.last, same(top, place) { return }
        backStack.append(place)
        if backStack.count > Self.limit { backStack.removeFirst(backStack.count - Self.limit) }
    }

    /// 后退：返回要去的那一处；`current`（眼下所在，可能没有——空标签）压进前进栈。
    mutating func back(from current: Place?) -> Place? {
        guard let target = backStack.popLast() else { return nil }
        if let current { forwardStack.append(current) }
        return target
    }

    /// 前进：与后退对称。
    mutating func forward(from current: Place?) -> Place? {
        guard let target = forwardStack.popLast() else { return nil }
        if let current { backStack.append(current) }
        return target
    }

    /// 去不了的地方（文档被删、笔记没了）从两个栈里拿掉。
    mutating func remove(where unreachable: (Place) -> Bool) {
        backStack.removeAll(where: unreachable)
        forwardStack.removeAll(where: unreachable)
    }
}
