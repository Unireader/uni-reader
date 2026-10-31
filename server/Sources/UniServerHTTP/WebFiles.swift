import Foundation
import Hummingbird
import HTTPTypes

/// 网页阅读器的静态文件（方案 `WEB-READER-PLAN.md §2 / §5`）。
///
/// 默认用编进程序里的那份（构建插件 `EmbedWebAssets` 从 `web/dist` 生成的 `EmbeddedWeb.files`）；
/// 开发时 `serve --web-dir <目录>` 直接读磁盘，改了网页不用重编服务器。
///
/// 🔴 网页本身（HTML / JS / CSS / pdf.js 的字形表等，**不含任何数据**）不要令牌——服务器「所有接口都要令牌」的唯一例外；
/// 数据照旧走 `/v1`，要令牌。
public final class WebFiles: @unchecked Sendable {
    private let directory: URL?
    private let lock = NSLock()
    private var decoded: [String: Data] = [:]

    /// [directory] 为 nil = 用编进程序里的那份。
    public init(directory: URL? = nil) {
        self.directory = directory
    }

    /// 有没有网页可给（没有就是构建时 `web/dist` 不存在，或 `--web-dir` 指错了）。
    public var available: Bool { data("index.html") != nil }

    /// 说给人看的来源（启动信息里打印）。
    public var sourceDescription: String {
        guard available else {
            return directory.map { "没有（\($0.path) 里没有 index.html）" } ?? "没有（构建时 web/dist 不存在，先跑 scripts/build-web.sh）"
        }
        return directory.map { "读磁盘 \($0.path)" } ?? "编在程序里（\(EmbeddedWeb.files.count) 个文件）"
    }

    func data(_ rel: String) -> Data? {
        guard Self.isSafe(rel) else { return nil }
        if let directory {
            return try? Data(contentsOf: directory.appendingPathComponent(rel))
        }
        lock.lock(); defer { lock.unlock() }
        if let d = decoded[rel] { return d }
        guard let b64 = EmbeddedWeb.files[rel], let d = Data(base64Encoded: b64) else { return nil }
        decoded[rel] = d
        return d
    }

    /// 只认普通的相对路径：不许 `..`、空段、以点开头的段（隐藏文件）。
    static func isSafe(_ rel: String) -> Bool {
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\\") }
    }

    static func contentType(_ rel: String) -> String {
        switch (rel as NSString).pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "webmanifest": return "application/manifest+json"
        case "ico": return "image/x-icon"
        case "wasm": return "application/wasm"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    /// 网页的内容安全策略：只许加载本服务器上的脚本 / 样式 / 字体；pdf.js 解 JPEG 2000 要 WebAssembly。
    static let contentSecurityPolicy = [
        "default-src 'self'", "script-src 'self' 'wasm-unsafe-eval'", "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: blob:", "font-src 'self' data:", "worker-src 'self' blob:", "connect-src 'self'",
        "object-src 'none'", "base-uri 'none'", "form-action 'none'", "frame-ancestors 'none'",
    ].joined(separator: "; ")

    func response(_ rel: String) throws -> Response {
        guard let data = data(rel) else {
            if rel == "index.html" {
                return Response(status: .notFound, headers: [.contentType: "text/plain; charset=utf-8"],
                                body: .init(byteBuffer: ByteBuffer(string: "这个服务器程序没有带网页：构建前先跑 server/scripts/build-web.sh。\n")))
            }
            throw HTTPError(.notFound)
        }
        var headers: HTTPFields = [.contentType: Self.contentType(rel), Self.nosniff: "nosniff"]
        if rel == "index.html" {
            headers[.cacheControl] = "no-cache"
            headers[Self.csp] = Self.contentSecurityPolicy
            headers[Self.referrerPolicy] = "no-referrer"
        } else if rel.hasPrefix("assets/") {
            headers[.cacheControl] = "public, max-age=31536000, immutable"   // 文件名里带内容哈希
        } else {
            headers[.cacheControl] = "public, max-age=86400"
        }
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    static let nosniff = HTTPField.Name("X-Content-Type-Options")!
    static let csp = HTTPField.Name("Content-Security-Policy")!
    static let referrerPolicy = HTTPField.Name("Referrer-Policy")!

    /// 网页的路由（不要令牌）：`/` 是页面，`assets/…` 是 vite 打出来的脚本与样式，`pdfjs/…` 是 pdf.js 的字形表、标准字体与 wasm。
    /// 页面内用 `#/…` 切换，服务器只认这几个路径。
    func addRoutes(to router: Router<ServerRequestContext>) {
        router.get("/") { _, _ in try self.response("index.html") }
        router.get("index.html") { _, _ in try self.response("index.html") }
        // 网页应用清单与图标（安卓 Chrome「添加到主屏幕」后像应用一样全屏打开）
        for file in ["favicon.svg", "manifest.webmanifest", "icon-192.png", "icon-512.png", "apple-touch-icon.png"] {
            router.get(RouterPath(file)) { _, _ in try self.response(file) }
        }
        for prefix in ["assets", "pdfjs"] {
            router.get("\(prefix)/**") { _, context in
                try self.response(prefix + "/" + context.parameters.getCatchAll().joined(separator: "/"))
            }
        }
    }
}
