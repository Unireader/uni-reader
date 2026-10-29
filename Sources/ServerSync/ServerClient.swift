import Foundation

/// 连 UniReader 服务器的 HTTP 客户端（方案 `SERVER-MODE-PLAN.md §3.3`；接口全表在
/// `server/Sources/UniServerHTTP/ServerApp.swift` 文件头）。只管收发，同步算法在 `SyncClient`。
///
/// 🔴 本目录（`Sources/ServerSync/`）**只给 App 用**：用了 URLSession / Keychain / AppKit。
/// 服务器也会编的共享代码在 `Sources/Sync/`，那里只许 Foundation + Store 层。
struct ServerClient: Sendable {
    let baseURL: URL
    let token: String?

    enum Failure: LocalizedError, Equatable {
        /// 服务器回了错误状态（带上它给的说明）。
        case http(Int, String)
        case badAddress
        case badResponse

        var errorDescription: String? {
            switch self {
            case .http(let code, let msg): return msg.isEmpty ? String(format: L("Server error %d"), code) : msg
            case .badAddress: return L("Not a valid server address")
            case .badResponse: return L("The server sent something unexpected")
            }
        }

        var status: Int? { if case .http(let c, _) = self { return c } else { return nil } }
    }

    /// 用户填的地址 → 基础地址：没写协议补 `http://`，去掉末尾的 `/`。
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme),
              u.host != nil else { return nil }
        return u
    }

    // MARK: - 接口

    struct Paired: Decodable {
        let deviceId: String; let token: String; let schemaVersion: Int
        let serverId: String?; let serverName: String?
    }
    struct Info: Decodable {
        let serverVersion: String; let schemaVersion: Int; let deviceId: String; let deviceName: String
        let serverId: String?; let serverName: String?
    }
    struct WorkspaceInfo: Decodable, Hashable { let id: String; let name: String; let head: UInt64 }
    private struct WorkspaceList: Decodable { let workspaces: [WorkspaceInfo] }
    private struct Upload: Decodable { let upload: String }

    static func pair(baseURL: URL, code: String, deviceName: String) async throws -> Paired {
        let c = ServerClient(baseURL: baseURL, token: nil)
        let body = try JSONSerialization.data(withJSONObject: ["code": code, "deviceName": deviceName])
        var req = try c.request("v1/pair", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try c.decode(Paired.self, try await c.send(req, body: body).0)
    }

    func info() async throws -> Info { try decode(Info.self, try await send(request("v1/info")).0) }

    func workspaces() async throws -> [WorkspaceInfo] {
        try decode(WorkspaceList.self, try await send(request("v1/workspaces")).0).workspaces
    }

    func push(_ ws: String, body: Data) async throws -> Data {
        var req = try request("v1/workspaces/\(ws)/push", method: "POST")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        return try await send(req, body: body).0
    }

    func pull(_ ws: String, since: UInt64, limit: Int = 5000) async throws -> Data {
        var req = try request("v1/workspaces/\(ws)/pull",
                              query: [URLQueryItem(name: "since", value: String(since)),
                                      URLQueryItem(name: "limit", value: String(limit))])
        req.timeoutInterval = 120
        return try await send(req).0
    }

    /// 下载快照到 [dst]（不能已存在），返回快照对应的修订号。
    func downloadSnapshot(_ ws: String, to dst: URL) async throws -> UInt64 {
        let resp = try await download(request("v1/workspaces/\(ws)/snapshot"), to: dst)
        guard let rev = resp.value(forHTTPHeaderField: "X-UniReader-Rev").flatMap({ UInt64($0) }) else {
            throw Failure.badResponse
        }
        return rev
    }

    /// 服务器上有没有这份 PDF：有 = 字节数，没有 = nil。
    func pdfSize(_ ws: String, hash: String) async throws -> Int64? {
        try await headSize(request("v1/workspaces/\(ws)/pdf/\(hash)", method: "HEAD"))
    }

    /// 下载一份 PDF 到 [dst]。[progress] 收到的是已下载的字节数（约每 0.15 秒一次，下完那一下必报）。
    func downloadPDF(_ ws: String, hash: String, to dst: URL,
                     progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        _ = try await download(request("v1/workspaces/\(ws)/pdf/\(hash)"), to: dst, progress: progress)
    }

    func uploadPDF(_ ws: String, hash: String, file: URL, progress: ((Int64, Int64) -> Void)? = nil) async throws {
        try await resumableUpload(path: "v1/workspaces/\(ws)/pdf/\(hash)", query: [], file: file, progress: progress)
    }

    func downloadImage(_ ws: String, sha: String, ext: String, to dst: URL) async throws {
        _ = try await download(request("v1/workspaces/\(ws)/image/\(sha).\(ext)"), to: dst)
    }

    func uploadImage(_ ws: String, sha: String, ext: String, file: URL) async throws {
        try await resumableUpload(path: "v1/workspaces/\(ws)/image/\(sha).\(ext)", query: [], file: file, progress: nil)
    }

    // MARK: 上传本地工作区

    func newUpload() async throws -> String {
        try decode(Upload.self, try await send(request("v1/uploads", method: "POST")).0).upload
    }

    func uploadFile(upload: String, path: String, file: URL, progress: ((Int64, Int64) -> Void)? = nil) async throws {
        try await resumableUpload(path: "v1/uploads/\(upload)/file", query: [URLQueryItem(name: "path", value: path)],
                                  file: file, progress: progress)
    }

    func finishUpload(_ upload: String) async throws -> WorkspaceInfo {
        var req = try request("v1/uploads/\(upload)/finish", method: "POST")
        req.timeoutInterval = 600   // 服务器要逐个校验 PDF 的哈希
        return try decode(WorkspaceInfo.self, try await send(req).0)
    }

    func cancelUpload(_ upload: String) async {
        _ = try? await send(request("v1/uploads/\(upload)", method: "DELETE"))
    }

    // MARK: - 收发

    /// 连服务器**一律不走系统代理**（2026-10-29 用户定）：服务器是自己搭的，用不着代理；经代理反而连不上——
    /// 实测系统代理（127.0.0.1:1087）既不排除局域网（192.168.x 全断），也连不上只有 IPv6 地址的自家域名（TLS 握手失败）。
    private var session: URLSession { Self.directSession }

    private static let directSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.connectionProxyDictionary = [:]       // 空表 = 不用代理（nil 才是跟随系统设置）
        return URLSession(configuration: c)
    }()

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) throws -> URLRequest {
        guard var c = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw Failure.badAddress
        }
        if !query.isEmpty { c.queryItems = query }
        guard let url = c.url else { throw Failure.badAddress }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func send(_ req: URLRequest, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        let data: Data, resp: URLResponse
        if let body {
            (data, resp) = try await session.upload(for: req, from: body)
        } else {
            (data, resp) = try await session.data(for: req)
        }
        guard let http = resp as? HTTPURLResponse else { throw Failure.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw Self.failure(http.statusCode, data) }
        return (data, http)
    }

    private func download(_ req: URLRequest, to dst: URL,
                          progress: (@Sendable (Int64) -> Void)? = nil) async throws -> HTTPURLResponse {
        var req = req
        req.timeoutInterval = 300
        let (tmp, resp) = try await session.download(for: req, delegate: progress.map(DownloadWatcher.init))
        guard let http = resp as? HTTPURLResponse else { throw Failure.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let data = (try? Data(contentsOf: tmp)) ?? Data()
            try? FileManager.default.removeItem(at: tmp)
            throw Self.failure(http.statusCode, data)
        }
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
        return http
    }

    /// HEAD：200 → 字节数；404 → nil（其余状态照常抛错）。
    private func headSize(_ req: URLRequest) async throws -> Int64? {
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw Failure.badResponse }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode, "") }
        return http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) } ?? 0
    }

    /// 续传上传（服务器接口约定见 `ServerApp.swift` 文件头）：先 `HEAD` 问已经收到多少，再按块 `PUT`，
    /// 每块带 `Upload-Offset` / `Upload-Length`。网络断了重问一次偏移接着传（最多重试 3 次）。
    private func resumableUpload(path: String, query: [URLQueryItem], file: URL,
                                 progress: ((Int64, Int64) -> Void)?) async throws {
        let total = ((try FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let chunk = 8 * 1024 * 1024
        var retries = 0
        guard var offset = try await uploadOffset(path: path, query: query) else {   // 服务器已经有了
            progress?(total, total)
            return
        }
        while true {
            try Task.checkCancellation()
            let at = offset
            progress?(at, total)
            try handle.seek(toOffset: UInt64(at))
            let data = try handle.read(upToCount: chunk) ?? Data()
            var req = try request(path, method: "PUT", query: query)
            req.setValue(String(at), forHTTPHeaderField: "Upload-Offset")
            req.setValue(String(total), forHTTPHeaderField: "Upload-Length")
            req.timeoutInterval = 300
            let http: HTTPURLResponse
            let body: Data
            do {
                let (d, r) = try await session.upload(for: req, from: data)
                guard let h = r as? HTTPURLResponse else { throw Failure.badResponse }
                http = h; body = d
            } catch let e as URLError where retries < 3 && e.code != .cancelled {
                retries += 1
                guard let o = try await uploadOffset(path: path, query: query) else { progress?(total, total); return }
                offset = o
                continue
            }
            switch http.statusCode {
            case 200, 201:
                progress?(total, total)
                return
            case 202, 409:
                guard let o = http.value(forHTTPHeaderField: "Upload-Offset").flatMap({ Int64($0) }) else {
                    throw Failure.badResponse
                }
                if http.statusCode == 409 {
                    retries += 1
                    if retries > 3 { throw Self.failure(409, body) }
                }
                offset = o
            default:
                throw Self.failure(http.statusCode, body)
            }
        }
    }

    /// 已经传了多少：nil = 服务器已经有完整的了。
    private func uploadOffset(path: String, query: [URLQueryItem]) async throws -> Int64? {
        let (_, resp) = try await session.data(for: request(path, method: "HEAD", query: query))
        guard let http = resp as? HTTPURLResponse else { throw Failure.badResponse }
        if (200..<300).contains(http.statusCode) { return nil }
        guard http.statusCode == 404 else { throw Failure.http(http.statusCode, "") }
        return http.value(forHTTPHeaderField: "Upload-Offset").flatMap { Int64($0) } ?? 0
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw Failure.badResponse }
    }

    /// 服务器的错误体是 `{"error":{"message":"…"}}`（Hummingbird 的 `HTTPError`）。
    private static func failure(_ status: Int, _ data: Data) -> Failure {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let msg = (obj?["error"] as? [String: Any])?["message"] as? String ?? ""
        return .http(status, msg)
    }
}

/// 下载进度：系统新建任务时交给每任务的代理（`didCreateTask`），盯着任务的 `countOfBytesReceived` 报已收到的字节数。
/// ⚠️ 别盯 `task.progress`：它的单位不是字节（实测总数是 100，报出来的是 5、100）。
/// 按时间节流（KVO 每收一块就来一次），收满那一下必报，免得最后停在 9x%。
private final class DownloadWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?
    private var last: TimeInterval = 0

    init(_ report: @escaping @Sendable (Int64) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let o = task.observe(\.countOfBytesReceived) { [weak self] t, _ in
            self?.changed(t.countOfBytesReceived, total: t.countOfBytesExpectedToReceive)
        }
        lock.withLock { observation = o }
    }

    private func changed(_ done: Int64, total: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        let due: Bool = lock.withLock {
            guard (total > 0 && done >= total) || now - last >= 0.15 else { return false }
            last = now
            return true
        }
        if due { report(done) }
    }
}
