import SwiftUI

/// 标准设置页（⌘,）：持久化到 UserDefaults，全窗口共享。
/// 三项：夜间模式自动化 / 平板滚动跟随算法（延迟处理方式）/ 平板服务开机自启。
struct SettingsView: View {
    @EnvironmentObject private var app: AppModel

    @AppStorage("autoNightMode") private var autoNightMode = false
    @AppStorage("scrollInterp") private var scrollInterp = true      // true=时间戳插值 / false=纯低通
    @AppStorage("autoStartServer") private var autoStartServer = false
    @AppStorage("ocrEngine") private var ocrEngine = "off"          // "off" | "paddle"
    @AppStorage("ocrPaddleKey") private var ocrPaddleKey = ""
    @AppStorage("renderCacheMB") private var renderCacheMB = 512     // 页图缓存上限（MB）
    @State private var pens: [PenPreset] = PenPresets.load()         // 笔预设（本机 UserDefaults）

    var body: some View {
        Form {
            Section {
                Toggle(L("Auto Night Mode (follow system Dark Mode)"), isOn: $autoNightMode)
            } header: {
                Text(L("Appearance"))
            } footer: {
                Text(L("When on, Night Mode follows the system appearance automatically."))
            }

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
                ForEach($pens) { $pen in
                    HStack(spacing: 8) {
                        TextField(L("Pen"), text: $pen.name).frame(width: 56)
                        ColorPicker("", selection: Binding(
                            get: { pen.color.swiftUIColor },
                            set: { pen.color = InkColor(color: $0) }), supportsOpacity: true)
                            .labelsHidden()
                        Slider(value: $pen.width, in: 2...40)
                        Text("\(Int(pen.width))").monospacedDigit().frame(width: 24, alignment: .trailing)
                        Button(role: .destructive) {
                            pens.removeAll { $0.id == pen.id }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .disabled(pens.count <= 1)
                    }
                }
                Button {
                    pens.append(PenPreset(name: L("Pen"), color: InkColor(r: 90, g: 90, b: 90, a: 0.95), width: 8))
                } label: {
                    Label(L("Add Pen"), systemImage: "plus")
                }
            } header: {
                Text(L("Pens"))
            } footer: {
                Text(L("Pen presets the tablet cycles through (side button / PageDown). A translucent, wide pen acts as a highlighter; the eraser is its own mode."))
            }
            .onChange(of: pens) { _, v in PenPresets.save(v) }

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
        .frame(width: 480, height: 460)
    }
}
