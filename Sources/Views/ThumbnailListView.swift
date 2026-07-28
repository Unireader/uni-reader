import SwiftUI
import PDFKit

/// 缩略图列表（Inspector 分段）：纵向滚动的页缩略图导航，点击跳到该页顶部；当前页自动追踪滚动定位。
/// 缩略图复用 `PageRenderEngine` 后台渲染 + LRU 缓存——独立像素宽度的键，不挤占阅读区基图缓存。
struct ThumbnailListView: View {
    let pdf: PDFDocument?
    let documentId: String
    let currentPage: Int
    let onSelect: (Int) -> Void

    private static let pixelWidth = 160

    /// 图存在列表层而非单元格 `@State`：单元格随 LazyVStack 滚出即被销毁，若图存在单元格上，
    /// 渲染完成回调可能落到一个已经不存在的实例上而丢失；存这里则只认页号，谁来问都拿得到。
    @State private var images: [Int: CGImage] = [:]

    var body: some View {
        if let pdf, pdf.pageCount > 0 {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(0..<pdf.pageCount, id: \.self) { i in
                            ThumbnailCell(pdf: pdf, documentId: documentId, page: i,
                                          pixelWidth: Self.pixelWidth, isCurrent: i == currentPage,
                                          image: images[i], onTap: { onSelect(i) },
                                          onRendered: { images[i] = $0 })
                                .id(i)
                        }
                    }
                    .padding(12)
                }
                .onAppear { proxy.scrollTo(currentPage, anchor: .center) }
                .onChange(of: currentPage) { _, p in
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(p, anchor: .center) }
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.grid.1x2").font(.title2).foregroundStyle(.tertiary)
                Text(L("No pages to show.")).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 单个缩略图格：当前页立即请求渲染；非当前页去抖 150ms、仍可见才提交请求——快速滚动/连续翻页时
/// 途经的页从不提交渲染（单元格滚出屏幕即被移除，`.task` 随之取消），不挤占 `PageRenderEngine`
/// 唯一的串行渲染队列、也不拖慢真正要看的当前页。`isCurrent` 变化会重启 `.task`（id 含 isCurrent），
/// 故非当前页去抖期间一旦变成当前页，立刻升级为立即渲染。
private struct ThumbnailCell: View {
    let pdf: PDFDocument
    let documentId: String
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
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
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
            Image(decorative: image, scale: 2, orientation: .up).resizable()
        } else {
            Color.clear
        }
    }

    private var aspect: CGFloat {
        guard let p = pdf.page(at: page) else { return 0.75 }
        let s = PageBitmap.displaySize(p)
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
        PageRenderEngine.shared.request(.init(key: key, page: p, pixelWidth: pixelWidth,
                                              tileRect: nil, tileScale: 1, night: false)) { doneKey, img in
            if doneKey == key { onRendered(img) }
        }
    }
}
