import SwiftUI

/// 标准设置页（⌘,）：多 Tab 分类（通用 / 平板 / 阅读），持久化到 UserDefaults，全窗口共享。
/// Tab 用系统标准 `Tab`（macOS 26 设置页样式：顶部图标标签页），布局/观感交给系统。
struct SettingsView: View {
    @EnvironmentObject private var app: AppModel

    @AppStorage("autoNightMode") private var autoNightMode = false
    @AppStorage("scrollInterp") private var scrollInterp = true      // true=时间戳插值 / false=纯低通
    @AppStorage("autoStartServer") private var autoStartServer = false
    @AppStorage("ocrEngine") private var ocrEngine = "off"          // "off" | "paddle"
    @AppStorage("ocrPaddleKey") private var ocrPaddleKey = ""
    @AppStorage("renderCacheMB") private var renderCacheMB = 512     // 页图缓存上限（MB）
    @AppStorage("showTOCButton") private var showTOCButton = true    // 工具栏「目录」按钮
    @AppStorage("showOCRButton") private var showOCRButton = true    // 工具栏「文字识别」按钮

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

            Section {
                Toggle(L("Show Contents Button"), isOn: $showTOCButton)
                Toggle(L("Show Text Recognition (OCR) Button"), isOn: $showOCRButton)
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
                    Text("2 GB").tag(2048)
                }
                .onChange(of: renderCacheMB) { _, mb in PageRenderEngine.shared.setCacheLimitMB(mb) }
            } header: {
                Text(L("Rendering"))
            } footer: {
                Text(L("A larger cache re-renders less when scrolling back or switching documents, at the cost of more RAM."))
            }

            Section {
                Picker(L("OCR Engine"), selection: $ocrEngine) {
                    Text(L("Off")).tag("off")
                    Text(L("Paddle OCR (API)")).tag("paddle")
                }
                if ocrEngine == "paddle" {
                    SecureField(L("Paddle API Key"), text: $ocrPaddleKey)
                        .textFieldStyle(.roundedBorder)
                }
            } header: {
                Text(L("Text Recognition (OCR)"))
            } footer: {
                Text(L("For scanned or bad-text PDFs, use API OCR for accurate selectable/searchable text. The key is stored locally on this Mac only."))
            }
        }
        .formStyle(.grouped)
    }
}
