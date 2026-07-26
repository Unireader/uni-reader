import Foundation

/// 平板采集端网页：`Resources/capture.html` 由 `web/` 前端工程（Svelte + Vite）构建产出
/// （`scripts/build-web.sh`，单文件 bundle，CSS/JS 全内联，**勿手改产物**；二进制编解码器 wire.js
/// 已在构建期打进包内）。运行时读取并替换占位符。
/// 占位符：`__WS_PORT__`（WebSocket 端口）、`__TOKEN__`（配对 token）、`__PENS__`（可配置笔预设 JSON）。
enum CapturePage {
    static func html(token: String, wsPort: UInt16) -> String {
        guard let url = Bundle.main.url(forResource: "capture", withExtension: "html"),
              let template = try? String(contentsOf: url, encoding: .utf8) else {
            return "<!DOCTYPE html><meta charset=\"utf-8\">"
                + "<body style=\"font-family:sans-serif;padding:2rem;color:#333\">"
                + "采集页资源缺失：capture.html 未打包进 App。</body>"
        }
        return template
            .replacingOccurrences(of: "__WS_PORT__", with: String(wsPort))
            .replacingOccurrences(of: "__TOKEN__", with: token)
            .replacingOccurrences(of: "__PENS__", with: PenPresets.captureJSON())   // 可配置笔预设
    }
}
