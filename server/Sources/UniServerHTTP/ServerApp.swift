import Foundation
import Hummingbird
import HTTPTypes
import UniServerCore

/// UniReader 服务器的 HTTP 接口（方案 `SERVER-MODE-PLAN.md §3.3`）。路由都在这里，核心逻辑在 `UniServerCore`。
///
/// | 方法 路径（都在 `/v1` 下） | 用途 |
/// |---|---|
/// | `POST pair` | 配对码换设备令牌（**唯一不要令牌的接口**，试错一分钟超过 5 次就拒） |
/// | `GET info` | 服务器版本、数据版本、我是哪台设备 |
/// | `GET workspaces` | 工作区列表（含当前修订号） |
/// | `PATCH workspaces/:ws` | 改名（JSON `{"name":…}`），回工作区（新名字 + 修订号） |
/// | `DELETE workspaces/:ws` | 删除整个工作区：先整个挪进回收站（90 天内命令行 `restore` 找回），204 |
/// | `POST uploads` → `PUT/HEAD uploads/:u/file?path=` → `POST uploads/:u/finish` | 上传本地工作区（逐个文件、可续传），齐了再登记 |
/// | `DELETE uploads/:u` | 放弃上传 |
/// | `GET workspaces/:ws/snapshot` | 建缓存用的快照（响应头 `X-UniReader-Rev` = 快照对应的修订号） |
/// | `POST workspaces/:ws/push` | 推送（`SyncWire` 二进制） |
/// | `GET workspaces/:ws/pull?since=&limit=` | 拉取（`SyncWire` 二进制） |
/// | `HEAD/GET/PUT workspaces/:ws/pdf/:hash` | PDF：查有没有 / 下载（支持 `Range`）/ 上传（可续传） |
/// | `HEAD/GET/PUT workspaces/:ws/image/:sha.:ext` | 图片本体，同上 |
/// | `GET workspaces/:ws/documents` | 书目（网页阅读器用）：书名 / 分组 / 页数 / 阅读进度 / 打开用哪份 PDF |
/// | `GET workspaces/:ws/documents/:doc/view?hash=` | 打开一本书（网页）：笔迹图层、笔记类型、扫描页对齐参数（`hash` = 打开的那份 PDF） |
/// | `GET workspaces/:ws/documents/:doc/marks?from=&to=` | 一段页（从 0 起，含两端）上的文字笔记 / 笔迹 / 高亮（网页）；笔迹点集一律二进制、base64 |
/// | `GET workspaces/:ws/head` | 当前修订号（网页轮询，变了再重拉标记） |
///
/// `/v1` 之外是网页阅读器的静态文件（`WebFiles`：`/`、`assets/…`、`pdfjs/…`），**不要令牌**、不含任何数据。
///
/// **续传**（上传会话里的文件、PDF、图片都一样）：请求头 `Upload-Offset`（从哪接着传）+ `Upload-Length`（总长）。
/// 偏移对不上 → 409，响应头 `Upload-Offset` 是服务器上已有的字节数；没传完 → 202 + 新的 `Upload-Offset`；
/// 传完 → 201（PDF / 图片会先校验 SHA-256，对不上 → 422，半截文件作废，从 0 重传）。
/// `HEAD` 查进度：已有 → 200；没有 → 404 + `Upload-Offset`。
public enum UniServerApp {

    static let revHeader = HTTPField.Name("X-UniReader-Rev")!

    public static func router(host: WorkspaceHost, store: ServerStore, name: String = "UniReader",
                              web: WebFiles = WebFiles()) -> Router<ServerRequestContext> {
        let router = Router(context: ServerRequestContext.self)
        let serverId = (try? store.serverId()) ?? ""
        router.add(middleware: ServerErrorMiddleware())

        // MARK: 网页（不要令牌，不含数据）
        web.addRoutes(to: router)

        // MARK: 配对（不要令牌）
        let limiter = PairingLimiter()
        router.post("v1/pair") { request, context -> PairResponse in
            guard await limiter.allowed() else {
                throw HTTPError(.tooManyRequests, message: "配对码试错太多，一分钟后再试")
            }
            let body = try await request.decode(as: PairRequest.self, context: context)
            do {
                let (device, token) = try store.pair(code: body.code, deviceName: body.deviceName)
                return PairResponse(deviceId: device.id, token: token, schemaVersion: ServerInfo.schemaVersion,
                                    serverId: serverId, serverName: name)
            } catch ServerError.badPairingCode {
                await limiter.recordFailure()
                throw ServerError.badPairingCode
            }
        }

        // MARK: 其余都要令牌
        let api = router.group("v1").add(middleware: AuthMiddleware(store: store))

        api.get("info") { _, context -> InfoResponse in
            InfoResponse(serverVersion: ServerInfo.version, schemaVersion: ServerInfo.schemaVersion,
                         serverId: serverId, serverName: name,
                         deviceId: context.device?.id ?? "", deviceName: context.device?.name ?? "")
        }

        api.get("workspaces") { _, _ -> WorkspaceList in
            WorkspaceList(workspaces: host.list().compactMap { s in
                (try? host.workspace(s.id)).map { WorkspaceDTO(id: s.id, name: s.name, head: $0.head) }
            })
        }

        api.patch("workspaces/:ws") { request, context -> WorkspaceDTO in
            let id = try context.parameters.require("ws")
            let body = try await request.decode(as: RenameRequest.self, context: context)
            let w = try host.workspace(id)
            let head = try await Blocking.run { try w.rename(to: body.name) }
            return WorkspaceDTO(id: w.id, name: w.name, head: head)
        }

        api.delete("workspaces/:ws") { _, context -> HTTPResponse.Status in
            let id = try context.parameters.require("ws")
            let device = context.device?.name ?? ""
            try await Blocking.run { _ = try host.delete(id, device: device) }
            return .noContent
        }

        // MARK: 上传本地工作区
        api.post("uploads") { _, _ -> UploadDTO in UploadDTO(upload: try host.newUpload()) }

        api.head("uploads/:upload/file") { request, context -> Response in
            let url = try host.uploadFileURL(upload: context.parameters.require("upload"), path: query(request, "path"))
            if FileManager.default.fileExists(atPath: url.path) {
                return Response(status: .ok, headers: [.contentLength: String(Resumable.size(url))])
            }
            return Resumable.missing(Resumable.size(Resumable.partURL(url)))
        }

        api.put("uploads/:upload/file") { request, context -> Response in
            let url = try host.uploadFileURL(upload: context.parameters.require("upload"), path: query(request, "path"))
            let part = Resumable.partURL(url)
            let (n, total) = try await Resumable.append(request, to: part)
            guard n == total else { return Resumable.progress(n) }
            let fm = FileManager.default
            try? fm.removeItem(at: url)
            try fm.moveItem(at: part, to: url)
            return Response(status: .created)
        }

        api.post("uploads/:upload/finish") { _, context -> WorkspaceDTO in
            let id = try context.parameters.require("upload")
            let w = try await Blocking.run { try host.finishUpload(id) }
            return WorkspaceDTO(id: w.id, name: w.name, head: w.head)
        }

        api.delete("uploads/:upload") { _, context -> HTTPResponse.Status in
            host.cancelUpload(try context.parameters.require("upload"))
            return .noContent
        }

        // MARK: 同步
        @Sendable func workspace(_ context: ServerRequestContext) throws -> HostedWorkspace {
            try host.workspace(context.parameters.require("ws"))
        }

        api.get("workspaces/:ws/snapshot") { _, context -> Response in
            let w = try workspace(context)
            let (url, rev) = try await Blocking.run { try w.snapshotFile() }
            let body = try await FileIO().loadFile(path: url.path, context: context)
            return Response(status: .ok, headers: [.contentType: "application/vnd.sqlite3", revHeader: String(rev)], body: body)
        }

        api.post("workspaces/:ws/push") { request, context -> Response in
            let w = try workspace(context)
            var request = request
            let buffer = try await request.collectBody(upTo: context.maxUploadSize)
            let body = Data(buffer.readableBytesView)
            let device = context.device?.name ?? ""
            return binary(try await Blocking.run { try w.push(body: body, deviceName: device) })
        }

        api.get("workspaces/:ws/pull") { request, context -> Response in
            let w = try workspace(context)
            let since = request.uri.queryParameters.get("since").flatMap { UInt64($0) } ?? 0
            let limit = min(max(request.uri.queryParameters.get("limit").flatMap { Int($0) } ?? 5000, 1), 20000)
            return binary(try await Blocking.run { try w.pull(since: since, limit: limit) })
        }

        // MARK: PDF
        @Sendable func pdfHash(_ context: ServerRequestContext) throws -> String {
            let h = try context.parameters.require("hash")
            guard ServerInfo.isContentHash(h) else { throw HTTPError(.badRequest, message: "内容哈希格式不对") }
            return h
        }

        api.head("workspaces/:ws/pdf/:hash") { _, context -> Response in
            let w = try workspace(context), hash = try pdfHash(context)
            if let url = w.pdfFile(contentHash: hash) {
                return Response(status: .ok, headers: [.contentLength: String(Resumable.size(url)), .acceptRanges: "bytes"])
            }
            return Resumable.missing(Resumable.size(host.partialFile(workspace: w.id, name: "\(hash).pdf")))
        }

        api.get("workspaces/:ws/pdf/:hash") { request, context -> Response in
            let w = try workspace(context), hash = try pdfHash(context)
            guard let url = w.pdfFile(contentHash: hash) else { throw HTTPError(.notFound, message: "服务器上没有这份 PDF") }
            return try await fileResponse(request, context, url, type: "application/pdf")
        }

        api.put("workspaces/:ws/pdf/:hash") { request, context -> Response in
            let w = try workspace(context), hash = try pdfHash(context)
            if w.pdfFile(contentHash: hash) != nil { return Response(status: .ok) }
            let part = host.partialFile(workspace: w.id, name: "\(hash).pdf")
            let (n, total) = try await Resumable.append(request, to: part)
            guard n == total else { return Resumable.progress(n) }
            try await Blocking.run { try w.storePDF(contentHash: hash, from: part) }
            return Response(status: .created)
        }

        // MARK: 网页阅读器
        api.get("workspaces/:ws/documents") { _, context -> DocumentList in
            let w = try workspace(context)
            return DocumentList(documents: try await Blocking.run { try w.documents() }.map(DocumentDTO.init))
        }

        api.get("workspaces/:ws/documents/:doc/view") { request, context -> DocumentViewDTO in
            let w = try workspace(context), doc = try context.parameters.require("doc")
            let hash = request.uri.queryParameters.get("hash").map { String($0) }
            if let hash, !ServerInfo.isContentHash(hash) { throw HTTPError(.badRequest, message: "内容哈希格式不对") }
            return DocumentViewDTO(try await Blocking.run { try w.documentView(documentId: doc, contentHash: hash) })
        }

        api.get("workspaces/:ws/documents/:doc/marks") { request, context -> PageMarkList in
            let w = try workspace(context), doc = try context.parameters.require("doc")
            guard let from = request.uri.queryParameters.get("from").flatMap({ Int($0) }),
                  let to = request.uri.queryParameters.get("to").flatMap({ Int($0) }), from >= 0, to >= from else {
                throw HTTPError(.badRequest, message: "页范围 from / to 不对")
            }
            // 一次最多 200 页：网页只取视口附近几页
            let marks = try await Blocking.run { try w.pageMarks(documentId: doc, from: from, to: min(to, from + 199)) }
            return PageMarkList(marks: marks.map(PageMarkDTO.init))
        }

        api.get("workspaces/:ws/head") { _, context -> HeadDTO in
            let w = try workspace(context)
            return HeadDTO(head: try await Blocking.run { w.head })
        }

        // MARK: 图片本体
        @Sendable func imageName(_ context: ServerRequestContext) throws -> (sha: String, ext: String) {
            let parts = try context.parameters.require("name").split(separator: ".")
            guard parts.count == 2, ServerInfo.isContentHash(String(parts[0])), ServerInfo.isImageExt(String(parts[1])) else {
                throw HTTPError(.badRequest, message: "图片名应为 <sha256>.<扩展名>")
            }
            return (String(parts[0]), String(parts[1]))
        }

        api.head("workspaces/:ws/image/:name") { _, context -> Response in
            let w = try workspace(context), (sha, ext) = try imageName(context)
            if let url = w.imageFile(sha256: sha, ext: ext) {
                return Response(status: .ok, headers: [.contentLength: String(Resumable.size(url))])
            }
            return Resumable.missing(Resumable.size(host.partialFile(workspace: w.id, name: "\(sha).\(ext)")))
        }

        api.get("workspaces/:ws/image/:name") { request, context -> Response in
            let w = try workspace(context), (sha, ext) = try imageName(context)
            guard let url = w.imageFile(sha256: sha, ext: ext) else { throw HTTPError(.notFound, message: "服务器上没有这张图") }
            return try await fileResponse(request, context, url, type: "application/octet-stream")
        }

        api.put("workspaces/:ws/image/:name") { request, context -> Response in
            let w = try workspace(context), (sha, ext) = try imageName(context)
            if w.imageFile(sha256: sha, ext: ext) != nil { return Response(status: .ok) }
            let part = host.partialFile(workspace: w.id, name: "\(sha).\(ext)")
            let (n, total) = try await Resumable.append(request, to: part)
            guard n == total else { return Resumable.progress(n) }
            try await Blocking.run { try w.storeImage(sha256: sha, ext: ext, from: part) }
            return Response(status: .created)
        }

        return router
    }

    public static func application(host: WorkspaceHost, store: ServerStore, name: String = "UniReader",
                                   web: WebFiles = WebFiles(), address: BindAddress) -> some ApplicationProtocol {
        Application(router: router(host: host, store: store, name: name, web: web),
                    configuration: .init(address: address, serverName: "UniReader/\(ServerInfo.version)"))
    }

    // MARK: - 小工具

    static func query(_ request: Request, _ key: String) throws -> String {
        guard let v = request.uri.queryParameters.get(key), !v.isEmpty else {
            throw HTTPError(.badRequest, message: "缺参数 \(key)")
        }
        return v
    }

    static func binary(_ data: Data) -> Response {
        Response(status: .ok, headers: [.contentType: "application/octet-stream"],
                 body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    /// 文件下载，支持单段 `Range`（断点续下）。
    static func fileResponse(_ request: Request, _ context: ServerRequestContext,
                             _ url: URL, type: String) async throws -> Response {
        let size = Int(Resumable.size(url))
        if let header = request.headers[.range] {
            guard let r = parseRange(header, size: size) else {
                throw HTTPError(.rangeNotSatisfiable, headers: [.contentRange: "bytes */\(size)"])
            }
            let body = try await FileIO().loadFile(path: url.path, range: r, context: context)
            return Response(status: .partialContent,
                            headers: [.contentType: type, .acceptRanges: "bytes",
                                      .contentRange: "bytes \(r.lowerBound)-\(r.upperBound)/\(size)"],
                            body: body)
        }
        let body = try await FileIO().loadFile(path: url.path, context: context)
        return Response(status: .ok, headers: [.contentType: type, .acceptRanges: "bytes"], body: body)
    }

    /// `bytes=a-b` / `bytes=a-` / `bytes=-n`（只认单段）。
    static func parseRange(_ header: String, size: Int) -> ClosedRange<Int>? {
        guard header.hasPrefix("bytes="), size > 0 else { return nil }
        let spec = header.dropFirst(6)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }
        let a = spec[..<dash], b = spec[spec.index(after: dash)...]
        if a.isEmpty {
            guard let n = Int(b), n > 0 else { return nil }
            return max(0, size - n)...(size - 1)
        }
        guard let lo = Int(a), lo >= 0, lo < size else { return nil }
        let hi = b.isEmpty ? size - 1 : min(Int(b) ?? -1, size - 1)
        return hi >= lo ? lo...hi : nil
    }
}

// MARK: - 请求上下文与中间件

public struct ServerRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    /// 认过令牌的设备（`AuthMiddleware` 填）。
    public var device: ServerStore.Device?

    public init(source: Source) {
        coreContext = .init(source: source)
        device = nil
    }

    /// `collectBody` / JSON 解码的上限（推送的请求体）。PDF 等大文件走流式写盘，不受它限制。
    public var maxUploadSize: Int { 256 * 1024 * 1024 }
}

struct AuthMiddleware: RouterMiddleware {
    typealias Context = ServerRequestContext
    let store: ServerStore

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let value = request.headers[.authorization], value.hasPrefix("Bearer "),
              let device = store.authenticate(token: String(value.dropFirst(7))) else {
            throw HTTPError(.unauthorized, message: "需要有效的设备令牌（先配对）")
        }
        var context = context
        context.device = device
        return try await next(request, context)
    }
}

/// `ServerError` → HTTP 状态码（文案原样带给客户端）。
struct ServerErrorMiddleware: RouterMiddleware {
    typealias Context = ServerRequestContext

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        do { return try await next(request, context) } catch let e as ServerError {
            throw HTTPError(Self.status(e), message: e.description)
        }
    }

    static func status(_ e: ServerError) -> HTTPResponse.Status {
        switch e {
        case .badPairingCode: return .unauthorized
        case .notAWorkspace, .badRequest: return .badRequest
        case .workspaceSchemaTooNew, .alreadyHosted, .schemaMismatch: return .conflict
        case .unknownWorkspace, .unknownDocument: return .notFound
        case .badContentHash: return .unprocessableContent
        }
    }
}

/// 配对码试错限流：一分钟内失败 5 次，之后一分钟都拒。只有用户一个人用，全局一个计数就够。
actor PairingLimiter {
    private var failures: [Date] = []

    func allowed(now: Date = .now) -> Bool {
        failures.removeAll { now.timeIntervalSince($0) >= 60 }
        return failures.count < 5
    }

    func recordFailure(now: Date = .now) { failures.append(now) }
}

/// 阻塞活（SQLite、哈希、拷文件）挪到单独的队列上，别占着处理请求的线程。
enum Blocking {
    static let queue = DispatchQueue(label: "unireader.server.blocking", qos: .userInitiated, attributes: .concurrent)

    static func run<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try body() }) }
        }
    }
}

// MARK: - 续传

enum Resumable {
    static let offset = HTTPField.Name("Upload-Offset")!
    static let length = HTTPField.Name("Upload-Length")!

    static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func partURL(_ url: URL) -> URL { url.appendingPathExtension("part") }

    static func progress(_ n: Int64) -> Response { Response(status: .accepted, headers: [offset: String(n)]) }

    static func missing(_ partSize: Int64) -> Response { Response(status: .notFound, headers: [offset: String(partSize)]) }

    /// 把请求体接到半截文件 [part] 后面，返回（现在多大，总长）。连接中途断了，已经写下的部分留着，下次接着传。
    static func append(_ request: Request, to part: URL) async throws -> (size: Int64, total: Int64) {
        guard let off = request.headers[offset].flatMap({ Int64($0) }), off >= 0,
              let total = request.headers[length].flatMap({ Int64($0) }), total >= 0 else {
            throw HTTPError(.badRequest, message: "要带 Upload-Offset 与 Upload-Length")
        }
        let fm = FileManager.default
        let current = size(part)
        guard off == current else {
            throw HTTPError(.conflict, headers: [offset: String(current)], message: "偏移对不上：服务器上已有 \(current) 字节")
        }
        try fm.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: part)
        var written = current
        do {
            try handle.seekToEnd()
            for try await buffer in request.body {
                written += Int64(buffer.readableBytes)
                guard written <= total else {
                    throw HTTPError(.contentTooLarge, message: "超过了声明的 Upload-Length")
                }
                try handle.write(contentsOf: Data(buffer.readableBytesView))
            }
            try handle.close()
        } catch {
            try? handle.close()
            if written > total { try? fm.removeItem(at: part) }
            throw error
        }
        return (written, total)
    }
}

// MARK: - JSON

struct PairRequest: Decodable { let code: String; let deviceName: String }
struct RenameRequest: Decodable { let name: String }
struct PairResponse: ResponseEncodable {
    let deviceId: String; let token: String; let schemaVersion: Int; let serverId: String; let serverName: String
}
struct InfoResponse: ResponseEncodable {
    let serverVersion: String; let schemaVersion: Int; let serverId: String; let serverName: String
    let deviceId: String; let deviceName: String
}
struct WorkspaceDTO: ResponseEncodable { let id: String; let name: String; let head: UInt64 }
struct WorkspaceList: ResponseEncodable { let workspaces: [WorkspaceDTO] }
struct UploadDTO: ResponseEncodable { let upload: String }
struct DocumentDTO: ResponseEncodable {
    let id: String; let title: String; let group: String; let pageCount: Int
    let readPage: Int; let readFrac: Double
    /// 没有 = 服务器上还没有这本书的 PDF。
    let contentHash: String?; let pdfBytes: Int64?

    init(_ d: HostedWorkspace.DocumentInfo) {
        id = d.id; title = d.title; group = d.group; pageCount = d.pageCount
        readPage = d.readPage; readFrac = d.readFrac; contentHash = d.contentHash; pdfBytes = d.pdfBytes
    }
}
struct DocumentList: ResponseEncodable { let documents: [DocumentDTO] }
struct InkLayerDTO: ResponseEncodable { let id: String; let name: String; let colorKey: String; let sortOrder: Int; let visible: Bool }
struct DocumentViewDTO: ResponseEncodable {
    let layers: [InkLayerDTO]
    /// JSON 文本原样（网页自己解）：笔记类型数组 / 扫描页对齐参数。没有 = 不出这个键。
    let noteTypes: String?; let align: String?

    init(_ v: HostedWorkspace.DocumentView) {
        layers = v.layers.map { InkLayerDTO(id: $0.id, name: $0.name, colorKey: $0.colorKey, sortOrder: $0.sortOrder, visible: $0.visible) }
        noteTypes = v.noteTypes; align = v.align
    }
}
struct PageMarkDTO: ResponseEncodable {
    let id: String; let kind: Int; let page: Int; let anchor: [Double]
    /// `note.payload` 的 JSON 文本原样（笔迹的点已摘掉）。
    let payload: String
    /// 笔迹点集（`InkPointsBlob`）的 base64；非笔迹不出这个键。
    let points: String?

    init(_ m: HostedWorkspace.PageMark) {
        id = m.id; kind = m.kind; page = m.page; anchor = m.anchor; payload = m.payload
        points = m.points?.base64EncodedString()
    }
}
struct PageMarkList: ResponseEncodable { let marks: [PageMarkDTO] }
struct HeadDTO: ResponseEncodable { let head: UInt64 }
