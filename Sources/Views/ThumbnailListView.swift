import SwiftUI
import PDFKit

/// 缩略图列表（Inspector 分段）：纵向滚动的页缩略图导航，点击跳到该页顶部；当前页自动追踪滚动定位。
/// 缩略图复用 `PageRenderEngine` 后台渲染 + LRU 缓存——独立像素宽度的键，不挤占阅读区基图缓存。
struct ThumbnailListView: View {
    let pdf: PDFDocument?
    /// 页图键的 doc 段（显示身份 `DocSession.displayKey`，不是库文档 id）。
    let documentId: String
    /// 扫描页对齐参数（没开为 nil）：缩略图也按对齐后的页面出。
    let align: ScanAlignTable?
    let currentPage: Int
    let onSelect: (Int) -> Void

    /// 缩略图渲染像素宽。阅读区也会读它：目标宽度的页图还没渲出来时，拿这份小图当最后兜底
    /// （同 doc/page 键空间，见 `ReaderSurface.fallbackBase`）。
    ///
    /// 🔴 **必须跟得上侧栏的物理像素**：栏最小宽 300pt（`ReaderWindowController.paneMinWidth`）
    /// 减去两边 12pt 内边距 ≈ 276pt，Retina 下就是 552 物理像素。原来的 160 要放大 3.4 倍，
    /// 用户 2026-09-03 报「糊得几乎认不出任何文字」。480 只放大 1.15 倍，肉眼基本无损。
    /// 改大它要连带看两处开销：View 层的 `images` 字典（见 `maxKeptImages`）和
    /// `PageRenderEngine` 那个与阅读区共享的 LRU——一张从 0.14MB 涨到约 1.3MB。
    static let pixelWidth = 480

    /// View 层最多留几张图。480px 一张约 1.3MB，几百页无上限地攒就是几百 MB
    /// （160px 时代一张才 0.14MB，所以原来不限也没出事）。丢掉的图在 `PageRenderEngine` 的
    /// LRU 与磁盘缓存里都还在，滚回去重取很快。
    private static let maxKeptImages = 48
    /// 缩略图圆角（图、底、选中描边共用一个值，三者必须一致，否则方角图会盖住圆角底）。
    static let corner: CGFloat = 5

    /// 图存在列表层而非单元格 `@State`：单元格随 LazyVStack 滚出即被销毁，若图存在单元格上，
    /// 渲染完成回调可能落到一个已经不存在的实例上而丢失；存这里则只认页号，谁来问都拿得到。
    @State private var images: [Int: CGImage] = [:]
    /// `PageHoldings` 台账的键（同一文档可能开在两个窗口，各自一份）。
    @State private var clientID = "thumbs-" + UUID().uuidString

    var body: some View {
        if let pdf, pdf.pageCount > 0 {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(0..<pdf.pageCount, id: \.self) { i in
                            ThumbnailCell(pdf: pdf, documentId: documentId, align: align?.page(i), page: i,
                                          pixelWidth: Self.pixelWidth, isCurrent: i == currentPage,
                                          image: images[i], onTap: { onSelect(i) },
                                          onRendered: { keep(page: i, image: $0) })
                                .id(i)
                        }
                    }
                    .padding(12)
                }
                .onAppear { proxy.scrollTo(currentPage, anchor: .center) }
                .onChange(of: currentPage) { _, p in
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(p, anchor: .center) }
                }
                .onDisappear { PageHoldings.shared.remove(client: clientID) }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.grid.1x2").font(.title2).foregroundStyle(.tertiary)
                Text(L("No pages to show.")).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 收下一张渲好的图，顺手把超额的丢掉（离当前页最远的先丢——那是最不可能马上又要看的）。
    private func keep(page: Int, image: CGImage) {
        images[page] = image
        let excess = images.count - Self.maxKeptImages
        if excess > 0 {
            for p in images.keys.sorted(by: { abs($0 - currentPage) > abs($1 - currentPage) }).prefix(excess) {
                images.removeValue(forKey: p)
            }
        }
        // 台账：缩略图一张 ~1MB、最多 48 张，也是页位图预算的一部分（见 `PageHoldings`）。
        var h = PageHolding(kind: .thumbs, label: String(documentId.prefix(8)), active: false, realized: nil)
        for img in images.values { h.imageCount += 1; h.imageBytes += PageHolding.bytes(of: img) }
        PageHoldings.shared.report(h, client: clientID)
    }
}

/// 单个缩略图格：当前页立即请求渲染；非当前页去抖 150ms、仍可见才提交请求——快速滚动/连续翻页时
/// 途经的页从不提交渲染（单元格滚出屏幕即被移除，`.task` 随之取消），不挤占 `PageRenderEngine`
/// 唯一的串行渲染队列、也不拖慢真正要看的当前页。`isCurrent` 变化会重启 `.task`（id 含 isCurrent），
/// 故非当前页去抖期间一旦变成当前页，立刻升级为立即渲染。
private struct ThumbnailCell: View {
    let pdf: PDFDocument
    let documentId: String
    let align: PageAlign?
    let page: Int
    let pixelWidth: Int
    let isCurrent: Bool
    let image: CGImage?
    let onTap: () -> Void
    let onRendered: (CGImage) -> Void

    private struct RenderTaskID: Equatable { let page: Int; let isCurrent: Bool }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                thumbnail
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: ThumbnailListView.corner))
                    // 页图本身也要裁圆角：只给底和描边做圆角的话，方角的图会正好盖住那圈圆角，
                    // 观感就是"选中框是圆的、图是方的"。
                    .clipShape(RoundedRectangle(cornerRadius: ThumbnailListView.corner))
                    .overlay(
                        RoundedRectangle(cornerRadius: ThumbnailListView.corner)
                            .strokeBorder(isCurrent ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                Text("\(page + 1)")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: RenderTaskID(page: page, isCurrent: isCurrent)) { await render() }
    }

    @ViewBuilder private var thumbnail: some View {
        if let image {
            // `.high`：缩略图是静态的（不像阅读区那样每帧重画），插值质量给满不心疼。
            Image(decorative: image, scale: 2, orientation: .up).resizable().interpolation(.high)
        } else {
            Color.clear
        }
    }

    private var aspect: CGFloat {
        guard let p = pdf.page(at: page) else { return 0.75 }
        let s = PageBitmap.displaySize(p, align: align)
        return s.height > 0 ? s.width / s.height : 0.75
    }

    private func render() async {
        guard image == nil, let p = pdf.page(at: page) else { return }
        let key = PageRenderEngine.baseKey(doc: documentId, page: page, pixelWidth: pixelWidth, night: false)
        if let hit = PageRenderEngine.shared.cached(key) { onRendered(hit); return }
        if !isCurrent {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
        }
        // 落盘：一张百来 KB，而侧栏一拉就是几百页 —— 换本书回来、下次开 app 都不用再渲。
        // （`PageDiskCache` 自带 1GB 上限 + trim，攒不炸。）
        PageRenderEngine.shared.request(.init(key: key, page: p, pixelWidth: pixelWidth,
                                              tileRect: nil, tileScale: 1, night: false,
                                              diskCache: true, align: align)) { doneKey, img in
            if doneKey == key { onRendered(img) }
        }
    }
}
