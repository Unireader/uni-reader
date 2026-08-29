import SwiftUI
import AppKit

/// 进行中的框选矩形（滚动容器坐标，与 `DragGesture(.local)` 同空间）。
struct SnipRect {
    var start: CGPoint
    var end: CGPoint

    var cgRect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
    var size: CGSize { CGSize(width: end.x - start.x, height: end.y - start.y) }
}

/// 截图投递的即时反馈。样式与 `PenRackView`/`findBanner` 同一套（material 胶囊 + 0.5 描边 + 阴影），
/// 不自绘仿系统外观。
struct SnipToast: Identifiable {
    enum Kind { case working, ok, fail }
    let id = UUID()
    var kind: Kind
    var text: String
}

/// 框选截图（snip）：在阅读区拖一个矩形 → **按页重渲染**成一张图 → 塞进 AI 面板当前对话的输入框。
///
/// **入口两条**（`AI-PLAN.md §5`，用户要求「一定要方便」）：
///  · **⌥ 拖**（主入口）：任何 `pointerTool` 下按住 ⌥ 拖即可，松手自动回原工具——零切换成本
///    （Preview 的 ⌥拖矩形选择先例）。⌥ 在阅读区此前没被占用，⇧ 已被尺子占了。
///  · 常驻工具 `pointerTool == .snip`（笔架那枚 / ⌥S）：连续截多块时用。
///
/// 与另外三个拖拽手势（拖选 / 本机落墨 / 框选移动）同挂容器、互斥门控：**⌥ 按下时它们让位**，
/// 但只让「尚未起手」的那一次——已经在拖的不打断（各自 guard 里读 `snipModifierDown` + 自己的锚点）。
///
/// 🔴 **只画覆盖层，不碰 `contentBody`**（`PDF-VIEWER-REBUILD-PLAN.md` 的零闪烁纪律）。
extension ReaderSurface {

    /// 此刻是否按着 ⌥。纯事件读取，不引 AppKit 视图（同 ⇧ 尺子读 `NSEvent.modifierFlags` 的先例）。
    var snipModifierDown: Bool { NSEvent.modifierFlags.contains(.option) }

    /// 手势 + 覆盖层 + ⌥S 路由，单独包一层挂在 `body` 上（理由见 `ReaderSurface.body` 注释）。
    func snipRoutes<V: View>(_ base: V) -> some View {
        base
            .simultaneousGesture(snipGesture)
            .overlay { snipOverlay }
            .overlay(alignment: .bottomTrailing) { snipToastView }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSnipTool)) { _ in
                guard isActiveWindow else { return }
                app.pointerTool = (app.pointerTool == .snip) ? .textSelect : .snip
            }
    }

    // MARK: - 手势

    var snipGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { v in
                guard scratch.pinch == nil, session.openPadID == nil else { return }
                if snipRect == nil {
                    // 起手闸：常驻 snip 工具，或按着 ⌥ 临时截。两者都不满足就整条手势哑火。
                    guard app.pointerTool == .snip || snipModifierDown else { return }
                    scratch.snipViaOption = (app.pointerTool != .snip)
                }
                snipRect = SnipRect(start: v.startLocation, end: v.location)
            }
            .onEnded { v in
                guard let r = snipRect else { return }
                snipRect = nil
                scratch.snipViaOption = false
                finishSnip(start: r.start, end: v.location)
            }
    }

    // MARK: - 覆盖层

    /// 框选中的视觉：区域外压暗 + 1px 强调色边 + 页码角标。
    /// 用 `.blendMode(.destinationOut)` 挖洞（系统合成），不是自己画四条边。
    @ViewBuilder var snipOverlay: some View {
        if let r = snipRect {
            let box = r.cgRect
            ZStack {
                Rectangle()
                    .fill(.black.opacity(0.28))
                    .overlay {
                        Rectangle()
                            .frame(width: box.width, height: box.height)
                            .position(x: box.midX, y: box.midY)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 1)
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
                snipBadge(box)
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }

    /// 角标：这一框覆盖了哪几页。贴在框的左上外侧；靠顶时翻到框内，免得被工具栏吃掉。
    @ViewBuilder private func snipBadge(_ box: CGRect) -> some View {
        if let label = snipPageLabel(box) {
            Text(label)
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.regularMaterial, in: Capsule())
                .position(x: box.minX + 26, y: box.minY > 26 ? box.minY - 11 : box.minY + 13)
        }
    }

    /// 「p.12」/「p.12–13」。取不到布局时不显示（宁可没有，也别显示错的页码）。
    private func snipPageLabel(_ box: CGRect) -> String? {
        guard let a = containerPointToPageNorm(CGPoint(x: box.midX, y: box.minY)),
              let b = containerPointToPageNorm(CGPoint(x: box.midX, y: box.maxY)) else { return nil }
        let lo = min(a.page, b.page) + 1, hi = max(a.page, b.page) + 1
        return lo == hi ? String(format: L("p.%d"), lo) : "\(String(format: L("p.%d"), lo))–\(hi)"
    }

    @ViewBuilder var snipToastView: some View {
        if let t = snipToast {
            HStack(spacing: 7) {
                switch t.kind {
                case .working: ProgressView().controlSize(.small)
                case .ok: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                case .fail: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Text(t.text).lineLimit(2)
            }
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(.separator, lineWidth: 0.5) }
            .shadow(radius: 6, y: 2)
            .padding(18)
            .padding(.trailing, aiInlineInset)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    // MARK: - 截图 → 投递

    /// 松手：框太小当误拖静默丢弃，否则渲图 + 投递。
    func finishSnip(start: CGPoint, end: CGPoint) {
        let r = SnipRect(start: start, end: end)
        guard PageSnip.isMeaningful(r.size) else { return }
        guard let pdf = session.pdf, let docId = session.documentId,
              let a = containerPointToPageNorm(start), let b = containerPointToPageNorm(end) else { return }

        let region = PageSnip.region(from: (a.page, Double(a.nx), Double(a.ny)),
                                     to: (b.page, Double(b.nx), Double(b.ny)))
        guard let first = PageSnip.slices(region).first else { return }

        // 面板先开起来、绑定上下文对齐到这一页（不强制新对话——框第二块多半是想接着问）。
        AIPanelModel.shared.present(window: session.windowID) { openWindow(id: $0) }
        AIPanelModel.shared.prepareForSend(
            AIBindContext(sessionID: session.id, documentId: docId, docTitle: session.title,
                          page: first.page, anchor: first.rect))

        showSnipToast(SnipToast(kind: .working, text: L("Capturing…")))

        let prompt = snipPrompt(page: first.page)
        let name = snipFileName(page: first.page)
        let provider = AIPanelModel.shared.currentProvider?.name ?? L("AI")

        // 🔴 渲染走 `PageRenderEngine` 那条队列，不在主线程：阅读区的页图渲染就在它上面，
        // 同一份 `PDFDocument` 不能被并发使用。
        PageRenderEngine.shared.renderOffMain {
            PageSnip.render(pdf: pdf, region: region)
        } completion: { shot in
            guard let shot else {
                showSnipToast(SnipToast(kind: .fail, text: L("Could not capture that area.")))
                return
            }
            Task { @MainActor in
                let out = await AIPanelModel.shared.attach(imageJPEG: shot.data,
                                                           fileName: name, prompt: prompt)
                if out.ok {
                    AIPanelModel.shared.noteSentContext(
                        AIContext(kind: .region, page: first.page, rect: first.rect))
                    showSnipToast(SnipToast(kind: .ok,
                                            text: String(format: L("Added to %@"), provider)))
                } else {
                    // 静默失败是这条链路最难查的形态 → 把走过的三级都打进日志。
                    wsLog("[SNIP] 投递失败 tried=\(out.tried) text=\(out.textOK)")
                    showSnipToast(SnipToast(kind: .fail, text: L("Couldn't put it in the chat box.")))
                }
            }
        }
    }

    /// 提示词：书名 + 页码 + 章节。**成本几乎为零、收益明显**——没有书名页码的裸截图，
    /// 模型答得明显差（`AI-PLAN.md §4`）。用户可编辑的模板留作后续。
    private func snipPrompt(page: Int) -> String {
        var parts: [String] = []
        if !session.title.isEmpty { parts.append("《\(session.title)》") }
        parts.append(String(format: L("p.%d"), page + 1))
        if let ch = snipChapter(page: page) { parts.append(ch) }
        return parts.joined(separator: " · ")
    }

    /// 该页所属章节：目录先序拍平后，取最后一个「页码 ≤ 本页」的条目。坏书签（无 pageIndex）跳过。
    private func snipChapter(page: Int) -> String? {
        var best: (page: Int, label: String)?
        func walk(_ es: [TOCEntry]) {
            for e in es {
                if let p = e.pageIndex, p <= page, (best.map { p >= $0.page } ?? true) {
                    best = (p, e.label)
                }
                walk(e.children)
            }
        }
        walk(session.toc)
        let label = best?.label.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? nil : label
    }

    /// 文件名要**页面上不可能自然出现**：适配器就靠「正文里出现了这个名字」判断站点收下没有
    /// （见 `ai-adapters.js` 的 `evidence`）。
    private func snipFileName(page: Int) -> String {
        "unireader-p\(page + 1)-\(UUID().uuidString.prefix(6)).jpg"
    }

    /// 内置 AI 面板在本窗口占掉的右侧宽度（气泡时按气泡算）——toast 靠右下，得给它让开。
    /// **刻意不 observe `AIPanelModel`**：ReaderSurface 订阅一个 App 级 `@Published` 会让面板的
    /// 任何变化都重算整个阅读区（`readZoom` 那条性能红线就是这么踩出来的）。toast 是按需出现的，
    /// 出现那一刻现读一次就够。
    var aiInlineInset: CGFloat {
        let p = AIPanelModel.shared
        guard p.mode == .inline else { return 0 }
        return p.isInlineOpen(session.windowID) ? CGFloat(p.inlineWidth) : 60
    }

    /// 显示一条反馈并定时收起。`working` 给长一点的兜底超时（正常会被结果那条顶掉）。
    private func showSnipToast(_ t: SnipToast) {
        snipToast = t
        let id = t.id
        let delay: TimeInterval = t.kind == .working ? 12 : (t.kind == .fail ? 4.5 : 2.4)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if snipToast?.id == id { snipToast = nil }
        }
    }
}
