// API 探针（只 -typecheck，不运行）：v2 阅读区（纯 SwiftUI）依赖的全部关键 API 签名验证。
// 运行：swiftc -typecheck spike/swiftui-api-probe.swift
// 覆盖：ScrollPosition 的多种 scrollTo、ScrollGeometry 字段（contentOffset/contentInsets/containerSize/contentSize/visibleRect）、
//      MagnifyGesture.Value 字段（magnification/startLocation/velocity）、TimelineView(.animation) 逐帧驱动、
//      withTransaction 禁动画、Canvas 变宽笔画、Image(decorative:scale:)、scaleEffect(anchor:) + offset 补偿层。

import SwiftUI

struct GeoSnap: Equatable {
    var offset: CGPoint
    var container: CGSize
    var content: CGSize
    var insetTop: CGFloat
    var insetLeading: CGFloat
}

struct ProbeV2: View {
    @State private var pos = ScrollPosition()
    @State private var zoom: CGFloat = 1
    @State private var gestureK: CGFloat = 1
    @State private var gestureAnchor: UnitPoint = .center
    @State private var holdOffset: CGSize = .zero
    @State private var geo = GeoSnap(offset: .zero, container: .zero, content: .zero, insetTop: 0, insetLeading: 0)
    @State private var followerActive = false

    private let cg: CGImage? = nil

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            ZStack(alignment: .topLeading) {
                ForEach(0..<3, id: \.self) { i in
                    ZStack {
                        Color.white
                        if let cg {
                            Image(decorative: cg, scale: 2)
                                .resizable()
                                .interpolation(.high)
                        }
                        Canvas { ctx, size in
                            var p = Path()
                            p.move(to: .zero)
                            p.addQuadCurve(to: CGPoint(x: size.width, y: size.height),
                                           control: CGPoint(x: size.width / 2, y: 0))
                            ctx.stroke(p, with: .color(.blue), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        }
                        .allowsHitTesting(false)
                    }
                    .frame(width: 600 * zoom, height: 800 * zoom)
                    .offset(x: 0, y: CGFloat(i) * 808 * zoom)
                }
            }
            .frame(width: 600 * zoom, height: 3 * 808 * zoom, alignment: .topLeading)
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        gestureK = v.magnification
                        let c = v.startLocation                     // content 坐标
                        gestureAnchor = UnitPoint(x: c.x / max(1, 600 * zoom),
                                                  y: c.y / max(1, 3 * 808 * zoom))
                        _ = v.velocity
                    }
                    .onEnded { v in
                        var t = Transaction()
                        t.animation = nil
                        withTransaction(t) {
                            zoom = zoom * v.magnification
                            gestureK = 1
                            pos.scrollTo(x: 10)
                            pos.scrollTo(y: 20)
                            pos.scrollTo(point: CGPoint(x: 10, y: 20))
                        }
                    }
            )
            .scaleEffect(gestureK, anchor: gestureAnchor)
            .offset(holdOffset)
        }
        .scrollPosition($pos)
        .onScrollGeometryChange(for: GeoSnap.self) { g in
            GeoSnap(offset: g.contentOffset,
                    container: g.containerSize,
                    content: g.contentSize,
                    insetTop: g.contentInsets.top,
                    insetLeading: g.contentInsets.leading)
        } action: { _, new in
            geo = new
        }
        .overlay {
            if followerActive {
                TimelineView(.animation) { tl in
                    Color.clear
                        .onChange(of: tl.date) { _, _ in
                            pos.scrollTo(y: 42)
                        }
                }
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
}
