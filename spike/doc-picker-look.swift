// 选文档弹窗样张：把 `DocPickerView` 放进真 `NSPopover` 里渲染出图（深色外观）。
// 用法（参数：文档条数、输出路径）：
//   cp spike/doc-picker-look.swift /tmp/main.swift && swiftc Sources/Views/DocPickerView.swift Sources/Support/L.swift Sources/Store/LibraryModels.swift /tmp/main.swift -o /tmp/pklook && /tmp/pklook 6 /tmp/picker.png
// ⚠️ `cacheDisplay` 画不出弹窗的系统材质（底色会是粉色、外圈一圈彩边），只看布局；选中条灰色是因为窗口不在前台。
import SwiftUI
import AppKit

// 桩：只为让 DocPickerView.swift 单独编过
final class DocTabStub { var docID: String?; init(_ d: String?) { docID = d } }
final class TabsModel { var tabs: [DocTabStub] = []; var docPickerPresented = false; func open(_ id: String) {} }
final class WorkspaceManager { var documents: [LibDocument] = [] }

func doc(_ t: String, _ g: String = "", _ ago: Double, pages: Int = 120) -> LibDocument {
    LibDocument(id: t, title: t, pageCount: pages, addedAt: .now, lastOpenedAt: .now.addingTimeInterval(-ago), sortOrder: 0, group: g)
}
let docs = [
    doc("软件工程 2024张琼声_带目录", "考研", 10, pages: 412),
    doc("大纲部分", "考研", 100, pages: 36),
    doc("数据结构 严蔚敏", "考研", 1000, pages: 334),
    doc("Designing Data-Intensive Applications", "", 5000, pages: 616),
    doc("计算机网络 第八版 谢希仁 高清扫描版 带书签", "考研", 9000, pages: 500),
    doc("The Rust Programming Language", "Rust", 20000, pages: 560),
]
let count = Int(CommandLine.arguments.dropFirst().first ?? "6") ?? 6
let out = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "look.png"

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.appearance = NSAppearance(named: .darkAqua)
let win = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
let anchor = NSView(frame: NSRect(x: 340, y: 40, width: 20, height: 20))
win.contentView = NSView()
win.contentView!.addSubview(anchor)
win.orderFrontRegardless()

let pop = NSPopover()
pop.contentViewController = NSHostingController(rootView:
    DocPickerView(documents: Array(docs.prefix(count)), openIDs: ["大纲部分", "软件工程 2024张琼声_带目录"], onPick: { _ in }))
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        guard let v = pop.contentViewController?.view.window?.contentView?.superview else { exit(1) }
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        print("wrote \(out) \(v.bounds.size)")
        exit(0)
    }
}
app.run()
