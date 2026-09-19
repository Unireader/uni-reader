import Foundation

/// 标签栏的两种形态（用户 2026-08-29：「两个模式都要支持，浮动可以固定，固定可以浮动」）。
/// 存 app 级偏好，不逐窗口记——它是一条外观偏好，不是某扇窗口的状态。
enum TabBarStyle: String {
    case floating   // 浮动胶囊：与笔架 / 查找条 / 截图提示 / 草稿纸工具条同一套浮层样子
    case docked     // 贴底整条：满宽 + 顶部分隔线
    static let key = "tabBarStyle"
}

enum TabBarMetrics {
    static let rowHeight: CGFloat = 26      // 单个标签的高度（不含容器内边距）
    static let pad: CGFloat = 4             // 容器内边距
    /// 浮动胶囊两端额外的水平内边距：胶囊左右各是一个半圆，4pt 的通用内边距到了圆弧那儿就显得贴边
    /// （2026-09-01 用户报「收紧的时候有点贴边」）。贴底形态是直角条，不需要这一份。
    static let capsuleSideInset: CGFloat = 7
    static let floatBottom: CGFloat = 12    // 浮动形态离阅读区底边的距离

    /// 阅读区底部要给标签栏让出多少：笔架的拖动夹取、滚动条的让位都读它。
    /// 只有一个标签时标签栏不显示（用户拍板），故为 0。
    static func inset(style: TabBarStyle, tabCount: Int) -> CGFloat {
        guard tabCount > 1 else { return 0 }
        let bar = rowHeight + pad * 2
        return style == .floating ? bar + floatBottom : bar
    }
}

/// 标签栏上的一个标签（纯值）。
struct TabBarItem: Identifiable, Equatable {
    let id: UUID
    var title: String
    var padFollowing: Bool      // 平板正跟随这个标签
    var hasDocument: Bool       // 空标签没有「在新窗口打开」
}
