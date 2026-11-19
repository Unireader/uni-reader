import Foundation

/// 一份网页「按路径取文件」的那一层（`docs/WEB-DOC-PLAN.md §3`）：内嵌显示（`WebDocSchemeHandler`）与
/// 本机浏览器服务（`WebDocLocalServer`）共用——同一个路径在两边回同样的东西（类型、Range、404）。
struct WebDocFiles {
    let doc: LibWebDoc
    let folder: URL
    let entries: [String: WebAssets.Entry]

    init(doc: LibWebDoc, folder: URL) {
        self.doc = doc
        self.folder = folder
        var map: [String: WebAssets.Entry] = [:]
        for e in doc.entries { map[e.p] = e }
        entries = map
    }

    struct Reply {
        var status: Int
        var headers: [String: String]
        /// 回的是哪个文件的哪一段（nil = 没有正文，比如 404 的说明放在 `body`）。
        var file: URL?
        var range: ClosedRange<Int64>?
        var body: Data?
        /// 这是入口 / 子页面那种 html（浏览器那条路要往里塞脚本）。
        var isHTML = false
    }

    /// [path] = URL 里的路径（已百分号解码，可以带开头的 `/`）；[rangeHeader] = 请求的 `Range` 头。
    func reply(path: String, rangeHeader: String?) -> Reply {
        guard let e = WebAssets.resolve(path, in: entries) else {
            return Reply(status: 404, headers: ["Content-Type": "text/plain; charset=utf-8"], file: nil, range: nil,
                         body: Data("Not found: \(path)".utf8))
        }
        let url = WebAssets.url(in: folder, sha256: e.h)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        guard let size else {
            return Reply(status: 404, headers: ["Content-Type": "text/plain; charset=utf-8"], file: nil, range: nil,
                         body: Data("This file has not been downloaded to this device yet: \(e.p)".utf8))
        }
        var h: [String: String] = [
            "Content-Type": WebAssets.mimeType(path: e.p),
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-cache",
        ]
        if let r = WebAssets.byteRange(rangeHeader, size: size) {
            h["Content-Range"] = "bytes \(r.lowerBound)-\(r.upperBound)/\(size)"
            h["Content-Length"] = String(r.upperBound - r.lowerBound + 1)
            return Reply(status: 206, headers: h, file: url, range: r, body: nil, isHTML: false)
        }
        if rangeHeader != nil, size > 0, rangeHeader?.lowercased().hasPrefix("bytes=") == true {
            // 合法格式但越界：416
            if WebAssets.byteRange(rangeHeader, size: size) == nil, !(rangeHeader ?? "").contains(",") {
                return Reply(status: 416, headers: ["Content-Range": "bytes */\(size)", "Content-Length": "0"],
                             file: nil, range: nil, body: Data())
            }
        }
        h["Content-Length"] = String(size)
        return Reply(status: 200, headers: h, file: url, range: size > 0 ? 0...(size - 1) : nil, body: size > 0 ? nil : Data(),
                     isHTML: WebAssets.isHTML(e.p))
    }

    /// 正文（整段读进内存：给内嵌显示与 html 改写用；浏览器那条路的大文件分块读，不走这里）。
    func body(of r: Reply) throws -> Data {
        if let b = r.body { return b }
        guard let f = r.file, let range = r.range else { return Data() }
        return try WebAssets.read(f, range: range)
    }
}
