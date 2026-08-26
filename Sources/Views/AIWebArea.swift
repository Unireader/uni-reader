import SwiftUI
import WebKit
import AppKit

/// 网页区本体：浮窗与内置面板共用（加载进度、状态回传）。
///
/// webview 本身归 `AIPageBox` 持有，这里只是把它挂进来（`AIWebHost`）——**视图被重建也不会出事**，
/// 见 `AIWebView.swift` 顶部那段。**右键菜单不在这里做**：交给 `AIWebView.willOpenMenu` 往系统菜单上
/// 追加一项，原生的剪切/拷贝/粘贴/查询/服务全部保留（早先用 `.webViewContextMenu` 是把系统菜单整个换掉）。
///
/// 带上 `host` 是为了让模型只认前台那个宿主的状态变化。
/// 第一响应者是不是落在一个 `WKWebView` 里。
///
/// 🔴 阅读区那套**单键**工具快捷键（`e` 橡皮 / `1`~`9` 选笔 / `n b v l i t`）原来只判
/// `firstResponder is NSText` 就放行 —— **WKWebView 不是 NSText**，于是内置 AI 面板一进阅读窗口，
/// 在里面打字就会被抢走（用户 2026-08-26 报：输入 `e` 直接变成橡皮）。
///
/// 这和 ⌘C 在面板里失灵是**同一类判据错误**：按具体类型去猜「谁在接键盘」，猜不全。
/// 凡是「阅读区要不要吃掉这个键」的判断，都得把 webview 这条算进去。
func aiWebInputHasFocus() -> Bool {
    var view = NSApp.keyWindow?.firstResponder as? NSView
    while let current = view {
        if current is WKWebView { return true }
        view = current.superview
    }
    return false
}

struct AIWebArea: View {
    @ObservedObject var panel: AIPanelModel
    @ObservedObject var box: AIPageBox
    let host: AIHost

    var body: some View {
        AIWebHost(box: box)
            .onChange(of: box.url) { _, _ in panel.syncFromPage(host) }
            .onChange(of: box.title) { _, _ in panel.syncFromPage(host) }
            .onChange(of: box.isLoading) { _, loading in
                if !loading { panel.noteLoadSettled(host) }   // 加载停下来才谈得上「有没有被重定向」
            }
            .overlay(alignment: .top) { progressBar }
            .animation(.easeOut(duration: 0.15), value: box.isLoading)
    }

    /// 加载进度压在顶边：只在真的在加载时出现（常驻一条 0% 是纯噪音）。
    @ViewBuilder
    private var progressBar: some View {
        if box.isLoading {
            ProgressView(value: box.progress)
                .progressViewStyle(.linear)
                .transition(.opacity)
        }
    }
}
