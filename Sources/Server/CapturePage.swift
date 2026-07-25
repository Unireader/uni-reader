import Foundation

/// 平板采集端网页：HTML/CSS/JS 独立存放于 `Resources/capture.html`（避免嵌在 Swift 多行字符串里的
/// 转义坑，例如 JS 的 `\n` 会被 Swift 当换行转义而破坏脚本），运行时读取并替换占位符。
/// 占位符：`__WS_PORT__`（WebSocket 端口）、`__TOKEN__`（配对 token）。
enum CapturePage {
    static func html(token: String, wsPort: UInt16) -> String {
        guard let url = Bundle.main.url(forResource: "capture", withExtension: "html"),
              let template = try? String(contentsOf: url, encoding: .utf8) else {
            return "<!DOCTYPE html><meta charset=\"utf-8\">"
                + "<body style=\"font-family:sans-serif;padding:2rem;color:#333\">"
                + "采集页资源缺失：capture.html 未打包进 App。</body>"
        }
        // 二进制编解码器**内联**进页面（不再走单独的 <script src="/wire.js"> 请求）：
        // 少一个失败面（路由缺失/资源没进包/缓存/时序都会导致 Wire 未定义 → 采集页永久白屏）。
        // wire.js 内容从文件读入后原样注入，不经 Swift 字符串字面量，无转义坑。
        let wire = Bundle.main.url(forResource: "wire", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "console.error('wire.js 资源缺失');"
        return template
            .replacingOccurrences(of: "__WS_PORT__", with: String(wsPort))
            .replacingOccurrences(of: "__TOKEN__", with: token)
            .replacingOccurrences(of: "__PENS__", with: PenPresets.captureJSON())   // 可配置笔预设
            .replacingOccurrences(of: "__WIRE_JS__", with: wire)                     // 内联编解码器（放最后）
    }
}
