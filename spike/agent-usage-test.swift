// Agent 面板三件纯逻辑：上下文占用的显示（`AgentUsage.swift`）、斜杠命令（`AgentCommand.swift`）、
// ⌘V 剪贴板怎么处理（`AgentPaste.swift`）。只依赖 Foundation / UniformTypeIdentifiers（+ 这里桩一个 `L`）。运行：
//   cp spike/agent-usage-test.swift /tmp/main.swift && swiftc Sources/Agent/AgentUsage.swift Sources/Agent/AgentCommand.swift \
//     Sources/Agent/AgentPaste.swift /tmp/main.swift -o /tmp/aut && /tmp/aut
// 覆盖：占比取整 / 夹住 / 用了一点给 <1% / 不成话的数字当没报、悬停文字带千分位和一位小数；
//       斜杠命令的认法（与 Kimi / Qwen / Claude Code 一致：命令名到第一个空白、路径不算）、压缩命令按 Agent 报的挑；
//       剪贴板分类（截图 / 浏览器图 / 访达图片文件 / 访达别的文件 / 文档里复制的文字 / PDF / 纯文字），
//       以及用一块**私有命名剪贴板**（不碰用户的剪贴板）核对 AppKit 的类型名与 UTType 标识一致。
import AppKit
import Foundation
import UniformTypeIdentifiers

func L(_ key: String) -> String { key }

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

print("上下文占用")
let kimi = AgentContextUsage(used: 45790, size: 1_000_000)
check(kimi.percent == 5, "45,790 / 1,000,000 → 5%（四舍五入）")
check(kimi.shortText == "5%", "输入框那行显示 5%")
check(kimi.detailText == "Context: 45,790 of 1,000,000 tokens (4.6%)", "悬停：千分位 + 一位小数（\(kimi.detailText ?? "nil")）")
check(AgentContextUsage(used: 300, size: 1_000_000).shortText == "<1%", "用了一点点：<1%，不显示成 0%")
check(AgentContextUsage(used: 0, size: 200_000).shortText == "0%", "一点没用：0%")
check(AgentContextUsage(used: 250_000, size: 200_000).percent == 100, "超出窗口：夹在 100%")
check(AgentContextUsage(used: 199_000, size: 200_000).percent == 100, "99.5% 四舍五入到 100%")
check(AgentContextUsage(used: 10, size: 0).percent == nil, "size 为 0：当没报")
check(AgentContextUsage(used: 10, size: 0).shortText == nil && AgentContextUsage(used: 10, size: 0).detailText == nil, "size 为 0：两段文字都没有")
check(AgentContextUsage(used: -1, size: 100).percent == nil, "used 为负：当没报")

print("斜杠命令")
func p(_ s: String) -> String? { AgentSlash.parse(s).map { "\($0.name)|\($0.args)" } }
check(p("/compact") == "compact|", "/compact")
check(p("/compact 只保留和习题有关的") == "compact|只保留和习题有关的", "带参数")
check(p("/compact   多个空格  ") == "compact|多个空格", "参数前后的空白去掉")
check(p("/skill:pdf 第 3 页") == "skill:pdf|第 3 页", "Kimi 技能命令（skill: 前缀）")
check(p("/usr/bin/python 怎么用") == nil, "路径（命令名里还有 /）不算")
check(p("/") == nil && p("/   ") == nil, "只有斜杠不算")
check(p("请 /compact") == nil, "不在开头不算")
check(p("/help\n第二行") == "help|第二行", "换行也算空白")
let kimiCmds = [AgentCommand(name: "compact", description: "", hint: "<optional custom summarization instructions>"),
                AgentCommand(name: "status", description: "")]
let qwenCmds = [AgentCommand(name: "compress", description: ""), AgentCommand(name: "about", description: "")]
check(AgentSlash.compactCommand(in: kimiCmds) == "compact", "Kimi / Claude Code：compact")
check(AgentSlash.compactCommand(in: qwenCmds) == "compress", "Qwen Code：compress")
check(AgentSlash.compactCommand(in: []) == nil, "Agent 没报命令：不给压缩那一项")
check(AgentSlash.compactCommand(in: [AgentCommand(name: "status", description: "")]) == nil, "报了但没有压缩命令")

print("剪贴板分类（类型名）")
let png = UTType.png.identifier, tiff = UTType.tiff.identifier, str = UTType.utf8PlainText.identifier
let rtf = UTType.rtf.identifier, html = UTType.html.identifier, file = UTType.fileURL.identifier
check(AgentPaste.classify(types: [png], imageFileCount: 0) == .bitmap(type: png), "截图（只有 PNG）→ 附图")
check(AgentPaste.classify(types: [tiff, png], imageFileCount: 0) == .bitmap(type: tiff), "多种位图取第一种")
check(AgentPaste.classify(types: [png, html], imageFileCount: 0) == .bitmap(type: png), "浏览器拷贝图像（PNG + HTML、没有文字）→ 附图")
check(AgentPaste.classify(types: [tiff, str, "public.url"], imageFileCount: 0) == .bitmap(type: tiff), "图 + 网址文字、没有格式 → 附图")
check(AgentPaste.classify(types: [str, rtf, tiff], imageFileCount: 0) == .text, "文档里复制的文字（文字 + RTF + 渲染图）→ 粘文字")
check(AgentPaste.classify(types: [str, html, png], imageFileCount: 0) == .text, "网页 / Excel（文字 + HTML + 图）→ 粘文字")
check(AgentPaste.classify(types: [file, str, tiff], imageFileCount: 2) == .imageFiles, "访达里复制的图片文件 → 按文件附上")
check(AgentPaste.classify(types: [file, str, tiff], imageFileCount: 0) == .text, "访达里复制的别的文件（带图标图）→ 粘文件名")
check(AgentPaste.classify(types: [UTType.pdf.identifier], imageFileCount: 0) == .text, "只有 PDF → 不当位图")
check(AgentPaste.classify(types: [str], imageFileCount: 0) == .text, "纯文字")
check(AgentPaste.classify(types: [], imageFileCount: 0) == .text, "空剪贴板")
check(AgentPaste.bitmapType(in: [UTType.heic.identifier]) == UTType.heic.identifier, "HEIC 也算位图")

print("剪贴板分类（AppKit 实际类型名，私有命名剪贴板）")
let pb = NSPasteboard(name: NSPasteboard.Name("UniReader.agent-usage-test.\(UUID().uuidString)"))
defer { pb.releaseGlobally() }
check(NSPasteboard.PasteboardType.rtfd.rawValue == UTType.flatRTFD.identifier, "AppKit 的 RTFD 类型名 = UTType.flatRTFD（\(NSPasteboard.PasteboardType.rtfd.rawValue)）")
check(NSPasteboard.PasteboardType.string.rawValue == str && NSPasteboard.PasteboardType.fileURL.rawValue == file,
      "文字 / 文件 URL 的类型名与 UTType 一致")
let img = NSImage(size: NSSize(width: 8, height: 8))
img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); img.unlockFocus()
pb.clearContents()
pb.writeObjects([img])
let imgTypes = (pb.types ?? []).map(\.rawValue)
if case .bitmap(let t)? = Optional(AgentPaste.classify(types: imgTypes, imageFileCount: 0)) {
    check(pb.data(forType: NSPasteboard.PasteboardType(t)) != nil, "写进去一张 NSImage → 认成位图且取得到数据（\(t)）")
} else {
    check(false, "写进去一张 NSImage 没认成位图：\(imgTypes)")
}
pb.clearContents()
pb.declareTypes([.string, .rtf, .tiff], owner: nil)
pb.setString("一段文字", forType: .string)
pb.setData(Data("{\\rtf1 x}".utf8), forType: .rtf)
pb.setData(img.tiffRepresentation ?? Data(), forType: .tiff)
check(AgentPaste.classify(types: (pb.types ?? []).map(\.rawValue), imageFileCount: 0) == .text, "文字 + RTF + TIFF（模拟 Pages）→ 粘文字")

print("\n通过 \(pass)，失败 \(fail)")
exit(fail == 0 ? 0 : 1)
