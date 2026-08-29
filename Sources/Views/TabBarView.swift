import SwiftUI

/// 自建标签栏（**不走 NSWindow 原生标签**——用户 2026-08-29 明确否决，「过于复杂」）。
/// 本文件只是 `TabsModel` → `TabStrip`（纯呈现层，见 `TabBarChrome.swift`）的适配器。
///
/// 挂载点必须是 `ContentView.readerColumn` 那一层，与 `AIInlineLayer` 同层，两条理由缺一不可：
///  ① **身份要稳定**：不能落进 `PageStreamView` 内部 `.id(docKey)` 的下游，否则每换一次标签
///     整条标签栏跟着重建（闪一下，违反零闪烁纪律）；
///  ② **要挡得住阅读区手势**：阅读区那四个拖拽手势挂在 `ScrollView` 容器上，用 `.overlay`
///     加在**同一个视图**上的覆盖层挡不住它们（草稿纸就是为此才要在每个 gesture 里写门控）。
///     挂到上一层就是普通遮挡关系，一行门控都不用加。
struct TabBarView: View {
    @ObservedObject var tabs: TabsModel
    /// 平板当前跟随的会话（给那个标签打个 iPad 小标记）。平板可以跟着**后台**标签，
    /// 没有标记的话用户完全不知道自己的笔写到哪儿去了。
    let padSessionID: UUID?
    let onOpenInNewWindow: (String) -> Void

    @AppStorage(TabBarStyle.key) private var styleRaw = TabBarStyle.floating.rawValue
    private var style: TabBarStyle { TabBarStyle(rawValue: styleRaw) ?? .floating }

    var body: some View {
        // ≥2 个标签才显示（用户拍板）：只开一篇时完全不占地方、不盖 PDF，与从前一模一样。
        if tabs.tabs.count > 1 {
            TabStrip(items: items, activeID: tabs.activeID, style: style,
                     onSelect: { tabs.activate($0) },
                     onClose: { tabs.close($0) },
                     onCloseOthers: { tabs.closeOthers(than: $0) },
                     onOpenInNewWindow: { id in
                         if let d = tabs.tabs.first(where: { $0.id == id })?.docID { onOpenInNewWindow(d) }
                     },
                     onNewTab: { tabs.newTab() },
                     onToggleStyle: {
                         styleRaw = (style == .floating ? TabBarStyle.docked : .floating).rawValue
                     })
        }
    }

    private var items: [TabBarItem] {
        tabs.tabs.map {
            TabBarItem(id: $0.id, title: $0.tabTitle,
                       padFollowing: $0.id == padSessionID, hasDocument: $0.docID != nil)
        }
    }
}
