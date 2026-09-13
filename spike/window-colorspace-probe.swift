// 窗口色彩空间 × 页图零副本 对照探针（2026-09-13，「连接设备后内存飙升」排查的落地依据）。运行：
//   cp spike/window-colorspace-probe.swift /tmp/main.swift && \
//   swiftc -O Sources/App/PageBitmap.swift /tmp/main.swift -o /tmp/wcp && \
//   MallocStackLogging=1 /tmp/wcp <default|srgb|p3|generic|screen> [lg]
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift；MallocStackLogging=1 才记得到 VM 分配的栈）
//
// 做什么：在屏幕角上开一个 4×4、几乎全透明的窗口（不抢焦点），里面按阅读区的结构放三页
//（ScrollView([.vertical,.horizontal]) + scrollPosition + ZStack + Image(decorative:).resizable().interpolation(.high)），
// 50Hz 用 scrollTo(point:) 推着滚、每秒换一页（= 平板驱动 Mac 跟随），6 秒后列出进程里 ≥8MB 的
// CoreAnimation / VM_ALLOCATE / purgeable zone 区域，并对新出现的块跑 malloc_history 看分配栈。
//
// 结论（两块屏都跑过，内置 Color LCD 与外接 LG HDR WFHD）：
//   窗口 colorSpace = 显示器 ICC（默认）→ 每张页图多一份 CA 副本（42.3M），栈是
//       _SwiftUIProxyImage prepare → CA::Render::copy_image → create_image_by_rendering（CG 整张重画做色彩转换）
//   窗口 colorSpace = sRGB（= 页图的色彩空间）→ 只剩我们自己的 mmap，CA 直接引用页图缓冲，零副本。
// app 里在 create_image_by_rendering 之下还会多一块 CG 给源图挂的转换缓存（img_data_lock →
// create_image_data_handle，43.7M，purgeable zone 非 volatile、不随页图释放），探针里复现不出那一块，
// 但同为 sRGB 之后根本不走重画，两笔一起消失。故 `ReaderWindowController`/`RefWindowController` 都设
// `win.colorSpace = .sRGB`。
import AppKit
import SwiftUI
import CoreGraphics
import PDFKit

enum PadLog {
    static func log(_ s: @autoclosure () -> String) {}
    static func ms(_ t: Double) -> String { String(format: "%.1fms", t * 1000) }
}

func regions() -> [(addr: String, desc: String)] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
    p.arguments = ["-v", "\(ProcessInfo.processInfo.processIdentifier)"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    try! p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    var out: [(String, String)] = []
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let l = String(line)
        guard (l.hasPrefix("MALLOC_LARGE") && l.contains("Purgeable")) || l.hasPrefix("CoreAnimation") || l.hasPrefix("VM_ALLOCATE"),
              let m = l.range(of: #"\[\s*([0-9.]+)M"#, options: .regularExpression) else { continue }
        let sz = Double(l[m].dropFirst().trimmingCharacters(in: .whitespaces).dropLast()) ?? 0
        guard sz >= 8 else { continue }
        let addr = String(l.split(separator: " ", omittingEmptySubsequences: true)[1].split(separator: "-")[0])
        let kind = l.hasPrefix("CoreAnimation") ? "CA" : (l.hasPrefix("VM_ALLOCATE") ? "mmap" : (l.contains("PURGE=V") ? "purg(v)" : "purg(N)"))
        out.append((addr, String(format: "%@ %.1fM", kind, sz)))
    }
    return out
}

func history(_ addr: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/malloc_history")
    p.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "0x" + addr]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try! p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let s = String(decoding: data, as: UTF8.self)
    let keys = ["create_image_by_rendering", "create_image_by_copying", "copy_image", "CGContextDrawImage",
                "create_image_data_handle", "img_data_lock", "ProxyImage", "PageBitmap", "CGImageSource", "makeImageRaw"]
    let frames = s.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { f in keys.contains { f.contains($0) } }
        .map { f in f.replacingOccurrences(of: #"^0x[0-9a-f]+ \([^)]*\) "#, with: "", options: .regularExpression) }
        .map { $0.replacingOccurrences(of: "CA::Render::(anonymous namespace)::", with: "")
                 .replacingOccurrences(of: #"\(.*\)$"#, with: "()", options: .regularExpression) }
    return frames.isEmpty ? String(s.prefix(120)).replacingOccurrences(of: "\n", with: " ") : frames.joined(separator: " ← ")
}

func makePDF(pages: Int) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("probe6-\(getpid()).pdf")
    let w = 1240, h = 1754
    var bytes = [UInt8](repeating: 255, count: w * h * 4)
    var seed: UInt32 = 12345
    for i in stride(from: 0, to: bytes.count, by: 4) {
        seed = seed &* 1664525 &+ 1013904223
        if UInt8(truncatingIfNeeded: seed >> 24) < 40 { bytes[i] = 20; bytes[i+1] = 20; bytes[i+2] = 20 }
    }
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let img = ctx.makeImage()!
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let pdfCtx = CGContext(url as CFURL, mediaBox: &box, nil)!
    for _ in 0..<pages { pdfCtx.beginPDFPage(nil); pdfCtx.draw(img, in: box); pdfCtx.endPDFPage() }
    pdfCtx.closePDF()
    return url
}

let pdfURL = makePDF(pages: 8)
let pdfDoc = PDFDocument(url: pdfURL)!

final class Model: ObservableObject {
    @Published var images: [Int: CGImage] = [:]
    @Published var realized: ClosedRange<Int> = 0...2
    @Published var tick = 0
}

let pageW: CGFloat = 1587           // 与 app 一样：fit 1783pt × zoom 0.89
let pageH: CGFloat = pageW * 842 / 595
let gap: CGFloat = 12

struct Reader: View {
    @ObservedObject var model: Model
    @State var pos = ScrollPosition()
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(model.realized), id: \.self) { i in
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(Color.white).frame(width: pageW, height: pageH)
                        if let img = model.images[i] {
                            Image(decorative: img, scale: 1)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: pageW, height: pageH)
                        }
                    }
                    .offset(x: 100, y: CGFloat(i) * (pageH + gap))
                }
            }
            .frame(width: 1800, height: 8 * (pageH + gap), alignment: .topLeading)
            .transaction { $0.animation = nil }
        }
        .defaultScrollAnchor(.topLeading)
        .scrollPosition($pos)
        .onChange(of: model.tick) { _, t in
            // 50Hz 推着滚：每拍 6pt
            pos.scrollTo(point: CGPoint(x: 0, y: CGFloat(t) * 6))
        }
        .frame(width: 1800, height: 1050)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let model = Model()
func render(_ i: Int) -> CGImage { PageBitmap.render(page: pdfDoc.page(at: i)!, pixelWidth: 2800)! }
for i in 0...2 { model.images[i] = render(i) }

let screen = NSScreen.screens.first { $0.backingScaleFactor == (CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "lg" ? 1 : 2) } ?? NSScreen.main!
// 尽量像 app 的窗口壳：带标题栏 + 工具栏（Tahoe 玻璃）+ 全尺寸内容 + 透明标题栏，内容延伸到工具栏下面
let win = NSWindow(contentRect: NSRect(x: screen.frame.maxX - 220, y: screen.frame.minY, width: 220, height: 160),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
win.alphaValue = 0.03; win.ignoresMouseEvents = true; win.hasShadow = false
win.titlebarAppearsTransparent = true
switch CommandLine.arguments.dropFirst().first ?? "" {
case "srgb": win.colorSpace = .sRGB
case "p3": win.colorSpace = .displayP3
case "screen": win.colorSpace = screen.colorSpace
case "generic": win.colorSpace = .genericRGB
default: break   // 不设，用默认
}
final class TB: NSObject, NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("x")] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("x")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let it = NSToolbarItem(itemIdentifier: id); it.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil); return it
    }
}
let tbd = TB()
let tb = NSToolbar(identifier: "probe"); tb.delegate = tbd
win.toolbar = tb
let host = NSHostingController(rootView: Reader(model: model).ignoresSafeArea())
host.sizingOptions = []
win.contentViewController = host
win.orderFrontRegardless()
print("窗口在 \(win.screen?.localizedName ?? "?") colorSpace=\(win.colorSpace?.localizedName ?? "?")")

// 先静置 1s 让首帧准备好
RunLoop.main.run(until: Date().addingTimeInterval(1.0))
let base = Set(regions().map(\.addr))
print("[首帧后] " + regions().map(\.desc).joined(separator: ", ") + " · liveImages \(PageBitmap.liveImages.count)")

// 6 秒：50Hz 滚动；每秒实化窗口往下挪一页（丢最上一页的图、渲新的一页）——模拟平板跟随
let t0 = Date()
var lastShift = 0
while Date().timeIntervalSince(t0) < 6 {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    model.tick += 1
    let sec = Int(Date().timeIntervalSince(t0))
    if sec > lastShift {
        lastShift = sec
        let lo = model.realized.lowerBound + 1, hi = min(7, model.realized.upperBound + 1)
        model.images[model.realized.lowerBound] = nil
        model.realized = lo...hi
        model.images[hi] = render(hi)
    }
}
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
let now = regions()
print("[滚动 6s 后] " + now.map(\.desc).joined(separator: ", ") + " · liveImages \(PageBitmap.liveImages.count)")
for r in now where !base.contains(r.addr) && !r.desc.hasPrefix("mmap") {
    print("   \(r.desc) ← \(history(r.addr))")
}
win.orderOut(nil)
try? FileManager.default.removeItem(at: pdfURL)
