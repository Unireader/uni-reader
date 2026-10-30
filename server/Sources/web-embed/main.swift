import Foundation

// 构建插件 EmbedWebAssets 用的生成器：把 <dist 目录> 下的全部文件写成一个 Swift 源文件（每个文件一个 base64 字符串），
// 服务器程序靠它带上网页阅读器（`UniServerHTTP/WebFiles.swift` 读它）。
//
//   web-embed <dist 目录> <输出的 .swift>
//
// 目录不存在 = 生成一张空表（程序不带网页）。以点开头的文件（.DS_Store 之类）不收。

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("用法：web-embed <dist 目录> <输出的 .swift>\n".utf8))
    exit(2)
}
let dist = URL(fileURLWithPath: args[1], isDirectory: true)
let out = URL(fileURLWithPath: args[2])
let fm = FileManager.default

var entries: [String] = []
for rel in (fm.subpaths(atPath: dist.path) ?? []).sorted() {
    guard !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
    let url = dist.appendingPathComponent(rel)
    var dir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &dir), !dir.boolValue else { continue }
    let data = try Data(contentsOf: url)
    let key = rel.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    entries.append("        \"\(key)\": \"\(data.base64EncodedString())\",")
}

let body = entries.isEmpty ? "[:]" : "[\n" + entries.joined(separator: "\n") + "\n    ]"
let source = """
// 生成物：构建插件 EmbedWebAssets 从 web/dist 生成，勿手改。
enum EmbeddedWeb {
    /// 相对路径 → 文件内容（base64）。
    static let files: [String: String] = \(body)
}

"""
try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data(source.utf8).write(to: out, options: .atomic)
