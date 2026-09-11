import AppKit
import SwiftUI

// 工具栏那几枚按钮弹出的面板。迁移前它们是 `ContentView` 里挂在 SwiftUI Button 上的 `.popover`，
// 现在由 `ReaderWindowController` 用 `NSPopover` 锚到工具栏按钮上弹（内容照旧是 SwiftUI）。

/// 一次性目录弹窗：无分割线，点条目跳转并关闭。持久目录见 Inspector 的「目录」页。
struct TOCPopoverContent: View {
    @ObservedObject var tabs: TabsModel
    var onPicked: () -> Void

    private var session: DocSession { tabs.active.session }

    var body: some View {
        VStack(spacing: 0) {
            Text(L("Contents"))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
            // 书签一并列在这儿（与 Inspector 目录页同一棵树）：用户来这里就是找「跳哪儿去」，
            // 书签正是自己标的那些落点，藏起来反而要跑两个地方找。改名/删除仍走 Inspector 那一份。
            TOCListView(entries: session.toc, currentPage: session.currentPageIndex,
                        bookmarks: session.bookmarks,
                        onSelectBookmark: { b in
                            session.jump(page: b.page, frac: b.frac, kind: .toc, label: b.title)
                            onPicked()
                        }) { e in
                guard let page = e.pageIndex else { return }   // 坏书签：跳不过去
                session.jump(page: page, frac: e.frac, kind: .toc, label: e.label)
                onPicked()
            }
            .frame(width: 320, height: 420)
        }
    }
}

/// 参考窗的目录弹窗：覆盖层形态里挂在 SwiftUI `.popover` 上，独立窗口形态里由
/// `RefWindowController` 用 `NSPopover` 锚到工具栏按钮上弹——**同一份内容两处用**。
/// 跳转只动小窗自己的视口，不写回那本书的阅读进度（`REF-WINDOW-PLAN.md §3` 红线）。
struct RefTOCPopoverContent: View {
    @ObservedObject var model: RefWindowModel
    var onPicked: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(L("Contents"))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
            TOCListView(entries: model.toc, currentPage: model.currentPage) { e in
                guard let page = e.pageIndex else { return }   // 坏书签：跳不过去
                model.goto(page: page, frac: e.frac)
                onPicked()
            }
            .frame(width: 300, height: 380)
        }
    }
}

/// OCR 面板：开关「用 OCR 文本」+ 进度 + 手动「识别全部页」。未配置 key 时引导去设置。
struct OCRPopoverContent: View {
    @ObservedObject var tabs: TabsModel
    @AppStorage("ocrEngine") private var ocrEngine = "off"

    private var session: DocSession { tabs.active.session }

    private func bind<V>(_ keyPath: ReferenceWritableKeyPath<DocSession, V>) -> Binding<V> {
        Binding(get: { session[keyPath: keyPath] }, set: { session[keyPath: keyPath] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Text Recognition (OCR)")).font(.headline)
            if ocrEngine != "paddle" {
                Text(L("Enable API OCR in Settings (⌘,) and paste your key first."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                // 迁移后设置窗是我们自己的一扇 NSWindow，不再是 SwiftUI 的 Settings scene，
                // 所以不必再靠 `showSettingsWindow:` 那个私有 selector。
                Button(L("Open Settings…")) { SettingsWindowController.show() }
            } else {
                Toggle(L("Use OCR text for this document"),
                       isOn: Binding(get: { session.ocrEnabled }, set: { session.setOCREnabled($0) }))
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                if session.ocrRunning { ProgressView().controlSize(.small) }
                Button(L("Recognize all pages")) { session.ocrAllPages() }
                    .disabled(session.pdf == nil)
                Divider()
                Toggle(L("Ignore tiled watermark blocks"), isOn: bind(\.ocrIgnoreWatermark))
                Text(L("Scanned books often carry a tiled diagonal watermark; OCR turns it into big blocks that break text selection. Detected by geometry and cross-page repetition, not by wording."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                Toggle(L("Show recognition blocks (debug)"), isOn: bind(\.showOCRBlocks))
                Text(L("Colors each recognized text block to inspect layout/selection accuracy; ignored watermark blocks show as grey dashed outlines."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if session.showOCRBlocks {
                    Picker("", selection: bind(\.ocrBlockGrouped)) {
                        Text(L("Per block")).tag(false)
                        Text(L("Selectable groups")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if let err = session.ocrLastError {
                    Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    private var statusText: String {
        let done = session.ocrDoneCount, total = session.ocrTotalPages
        if session.ocrRunning {
            return String(format: L("Recognizing… %d/%d pages, %d queued"),
                          done, total, session.ocrPendingCount)
        }
        if done == 0 { return L("Not recognized yet.") }
        return String(format: L("%d of %d pages recognized"), done, total)
    }
}
