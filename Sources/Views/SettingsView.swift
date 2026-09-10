import SwiftUI

/// 标准设置页（⌘,）：多 Tab 分类（通用 / 平板 / 阅读），持久化到 UserDefaults，全窗口共享。
/// 例外：API key 这类密钥存 Keychain（见 `PaddleOCR.apiKey()`），不落 UserDefaults 明文。
/// Tab 用系统标准 `Tab`（macOS 26 设置页样式：顶部图标标签页），布局/观感交给系统。
struct SettingsView: View {
    @EnvironmentObject private var app: AppModel

    @AppStorage("autoNightMode") private var autoNightMode = false
    @AppStorage("scrollInterp") private var scrollInterp = true      // true=时间戳插值 / false=纯低通
    @AppStorage("autoStartServer") private var autoStartServer = false
    @AppStorage("ocrEngine") private var ocrEngine = "off"          // "off" | "paddle"
    @State private var ocrPaddleKey = ""   // Paddle API key：存 Keychain（不进 UserDefaults），见 PaddleOCR.apiKey()
    /// 页图缓存上限（MB，= 真实占用；引擎按「一张图三份」计费，见 `PageRenderEngine.copiesPerImage`）。
    /// ⚠️ 默认值与 `ContentView` 启动时那句 `?? 256` **必须一致**，改一处要改两处。
    @AppStorage("renderCacheMB") private var renderCacheMB = 256

    var body: some View {
        TabView {
            Tab(L("General"), systemImage: "gear") { generalTab }
            Tab(L("Tablet"), systemImage: "ipad") { tabletTab }
            Tab(L("Reading"), systemImage: "book") { readingTab }
        }
        .frame(width: 480, height: 420)
    }

    /// 通用：外观（夜间模式自动化）+ 工具栏按钮显隐。
    private var generalTab: some View {
        Form {
            Section {
                Toggle(L("Auto Night Mode (follow system Dark Mode)"), isOn: $autoNightMode)
            } header: {
                Text(L("Appearance"))
            } footer: {
                Text(L("When on, Night Mode follows the system appearance automatically."))
            }

            // 工具栏的显隐/排序改走**系统那套**（`.toolbar(id: "reader")`，见 `ContentView.toolbarContent`），
            // 这里只留一句指路——设置页再放一份开关就是两套状态打架。
            Section {
                Text(L("Right-click the toolbar in a reading window and choose “Customize Toolbar…” to add, remove or rearrange buttons."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(L("Toolbar"))
            }
        }
        .formStyle(.grouped)
    }

    /// 平板：滚动跟随算法 + 服务开机自启。
    private var tabletTab: some View {
        Form {
            Section {
                Picker(L("Delay handling"), selection: $scrollInterp) {
                    Text(L("Interpolation")).tag(true)
                    Text(L("Low-pass")).tag(false)
                }
            } header: {
                Text(L("Tablet Scroll Follow"))
            } footer: {
                Text(L("Interpolation tracks fast flings tighter; Low-pass is simpler and smoother on LAN."))
            }

            Section {
                Toggle(L("Start tablet service on launch"), isOn: $autoStartServer)
                    .onChange(of: autoStartServer) { _, on in
                        if on, !app.server.isRunning { app.server.start() }   // 打开即启，立即生效
                    }
            } header: {
                Text(L("Tablet Service"))
            }
        }
        .formStyle(.grouped)
    }

    /// 阅读：页图渲染缓存 + 文字识别（OCR）。
    private var readingTab: some View {
        Form {
            Section {
                Picker(L("Page render cache limit"), selection: $renderCacheMB) {
                    Text("128 MB").tag(128)
                    Text("256 MB").tag(256)
                    Text("512 MB").tag(512)
                    Text("1 GB").tag(1024)
                }
                .onChange(of: renderCacheMB) { _, mb in PageRenderEngine.shared.setCacheLimitMB(mb) }
                // 每秒重算：设置窗不销毁，静态取值会一直显示第一次打开时的快照（诊断时被这个骗过一次）。
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    memoryDiagRows(MemoryDiag.snapshot())
                }
            } header: {
                Text(L("Rendering"))
            } footer: {
                Text(L("The limit covers all page bitmaps in memory: those shown in windows plus the cache; the cache yields room to what windows hold. Every bitmap also has a CoreAnimation copy of the same size, already counted here."))
            }

            Section {
                Picker(L("OCR Engine"), selection: $ocrEngine) {
                    Text(L("Off")).tag("off")
                    Text(L("Paddle OCR (API)")).tag("paddle")
                }
                if ocrEngine == "paddle" {
                    SecureField(L("Paddle API Key"), text: $ocrPaddleKey)
                        .textFieldStyle(.roundedBorder)
                        .onAppear { ocrPaddleKey = PaddleOCR.apiKey() }
                        .onChange(of: ocrPaddleKey) { _, v in PaddleOCR.setApiKey(v) }
                }
            } header: {
                Text(L("Text Recognition (OCR)"))
            } footer: {
                Text(L("For scanned or bad-text PDFs, use API OCR for accurate selectable/searchable text. The key is stored in this Mac's Keychain."))
            }
        }
        .formStyle(.grouped)
    }

    /// 真实内存台账（`MemoryDiag`）：进程总量 → 页位图（存活 / 缓存 / 各窗口持有）→ 堆。
    /// 每一行都是进程里量出来的数，不是估算；页位图的 CA 副本按 ×2 记（见 `PageRenderEngine.copiesPerImage`）。
    @ViewBuilder private func memoryDiagRows(_ s: MemoryDiag.Snapshot) -> some View {
        let mb = MemoryDiag.mb
        LabeledContent(L("App memory (Activity Monitor)"), value: mb(s.footprint))
        LabeledContent(L("Page bitmaps alive"),
                       value: "\(s.liveCount) · \(mb(s.liveBytes)) + CA \(mb(s.liveBytes)) = \(mb(s.bitmapFootprint))")
        LabeledContent(L("In cache"),
                       value: "\(s.cacheBaseCount)+\(s.cacheTileCount) · \(mb(s.cacheBaseBytes + s.cacheTileBytes))"
                       + " · \(L("room")) \(mb(s.cacheEffectiveBytes / PageRenderEngine.copiesPerImage))")
        LabeledContent(L("Held by windows"), value: "\(s.heldCount) · \(mb(s.heldBytes))")
        ForEach(Array(s.holdings.enumerated()), id: \.offset) { _, h in
            LabeledContent {
                Text(holdingValue(h))
            } label: {
                Text((h.active ? "● " : "○ ") + holdingLabel(h))
            }
        }
        LabeledContent(L("Heap (malloc)"),
                       value: "\(mb(s.mallocUsed)) · \(L("freed, not yet returned")) \(mb(s.mallocRetained))")
    }

    private func holdingLabel(_ h: PageHolding) -> String {
        switch h.kind {
        case .reader: return h.label
        case .ref: return L("Reference window") + " · " + h.label
        case .thumbs: return L("Thumbnails") + " · " + h.label
        }
    }

    private func holdingValue(_ h: PageHolding) -> String {
        let mb = MemoryDiag.mb
        var parts: [String] = []
        if let r = h.realized { parts.append("p\(r.lowerBound + 1)–\(r.upperBound + 1)") }
        parts.append("\(h.imageCount) \(L("img")) \(mb(h.imageBytes))")
        if h.tileCount > 0 { parts.append("\(h.tileCount) \(L("tile")) \(mb(h.tileBytes))") }
        if h.snapCount > 0 { parts.append("\(h.snapCount) \(L("snap")) \(mb(h.snapBytes))") }
        return parts.joined(separator: " · ")
    }
}
