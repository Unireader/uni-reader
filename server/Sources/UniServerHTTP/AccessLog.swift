import Foundation
import Hummingbird
import HTTPTypes
import UniServerCore

/// 请求耗时日志（2026-10-30，查网页取 PDF 慢在哪）：`/v1` 下的每个请求一行，写到标准输出（systemd 下进 journald）。
///
/// `请求 GET /v1/workspaces/8f2c…/pdf/1a2b… bytes=0-262143 → 206 262144B 首字节 3ms 发完 15ms 网页 · Chrome`
/// - 首字节 = 处理完、开始返回（含校验令牌、查文件）；发完 = 正文全部交给网络（大段 PDF 主要在这一段）。
/// - 工作区 id、内容哈希只留前 8 位；令牌不在地址里，不会写进日志。
/// - 网页每 5 秒查一次的修订号（`head`）不记，除非慢于 200ms。
/// 关掉：`serve --no-access-log`。
struct AccessLogMiddleware: RouterMiddleware {
    typealias Context = ServerRequestContext

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        let start = ContinuousClock.now
        let line = Self.describe(request)
        let quiet = request.uri.path.hasSuffix("/head")
        do {
            var response = try await next(request, context)
            let first = ContinuousClock.now - start
            let status = response.status.code
            let device = context.device?.name ?? ""
            let body = response.body
            let length = body.contentLength
            response.body = ResponseBody(contentLength: length) { writer in
                var failure = ""
                do { try await body.write(writer) } catch {
                    failure = " 没发完：\(error)"
                    Self.emit(line, status, length, first, ContinuousClock.now - start, device, failure, quiet)
                    throw error
                }
                Self.emit(line, status, length, first, ContinuousClock.now - start, device, failure, quiet)
            }
            return response
        } catch {
            // 服务器自己的错误到外层（`ServerErrorMiddleware`）才换成状态码：这里照同一张表换，日志与客户端收到的一致
            let status = (error as? ServerError).map { ServerErrorMiddleware.status($0).code }
                ?? (error as? HTTPResponseError)?.status.code ?? 500
            let took = ContinuousClock.now - start
            Self.emit(line, status, nil, took, took, context.device?.name ?? "", "", quiet)
            throw error
        }
    }

    /// 方法 + 路径（长 id 缩短）+ 查询参数 + Range。
    static func describe(_ request: Request) -> String {
        let parts = request.uri.path.split(separator: "/", omittingEmptySubsequences: false).map { seg -> String in
            seg.count >= 32 ? String(seg.prefix(8)) + "…" : String(seg)
        }
        var s = "\(request.method.rawValue) \(parts.joined(separator: "/"))"
        if let q = request.uri.query, !q.isEmpty {
            s += "?" + q.split(separator: "&").map { kv -> String in
                guard let eq = kv.firstIndex(of: "="), kv.distance(from: eq, to: kv.endIndex) > 32 else { return String(kv) }
                return String(kv[...eq]) + kv[kv.index(after: eq)...].prefix(8) + "…"
            }.joined(separator: "&")
        }
        if let r = request.headers[.range] { s += " \(r)" }
        return s
    }

    static func emit(_ line: String, _ status: Int, _ length: Int?, _ first: Duration, _ total: Duration,
                     _ device: String, _ failure: String, _ quiet: Bool) {
        let ms = { (d: Duration) -> Int in Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) }
        if quiet && status < 400 && ms(total) < 200 { return }
        let size = length.map { "\($0)B" } ?? "-"
        print("请求 \(line) → \(status) \(size) 首字节 \(ms(first))ms 发完 \(ms(total))ms \(device)\(failure)")
    }
}
