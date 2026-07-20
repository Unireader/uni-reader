// API 探针：只做 -typecheck，验证页图流阅读区依赖的 macOS 15+ 滚动 API 签名是否可用。
// 这些是 PageStreamView 的地基：容器宽（fit-width）、几何变化上报锚点、程序化滚到指定 Y。
// 运行：swiftc -typecheck spike/scroll-api-probe.swift
import SwiftUI

struct Probe: View {
    @State private var pos = ScrollPosition()
    @State private var viewportW: CGFloat = 0
    @State private var visibleTop: CGFloat = 0

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(spacing: 8) {
                ForEach(0..<10, id: \.self) { _ in
                    Color.blue.frame(height: 100)
                        .containerRelativeFrame(.horizontal) { w, _ in w * 1.0 }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($pos)
        // 读：容器宽 + 可见区顶部在内容坐标里的 Y（锚点/布局用）
        .onScrollGeometryChange(for: CGFloat.self) { geo in geo.containerSize.width } action: { _, w in viewportW = w }
        .onScrollGeometryChange(for: CGFloat.self) { geo in geo.visibleRect.minY } action: { _, y in visibleTop = y }
        // 写：程序化滚到指定内容 Y（平滑跟随器每帧调用）
        .onChange(of: viewportW) { _, _ in
            pos.scrollTo(y: 200)
        }
    }
}
