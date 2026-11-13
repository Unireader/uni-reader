import Foundation

/// 工具调用输出里给人看的那部分（纯函数，`AgentTranscript.outputText` 存进条目前过一遍；测试 `spike/agent-tool-output-test.swift`）。
///
/// Kimi 把 MCP 工具结果里的 `structuredContent` 原样拼在文字后面：`<mcp-result-extras>{"structuredContent":…}</mcp-result-extras>`
/// （2026-11-13 用户截图：`read_pages` / `read_markdown` 展开后正文下面又是一大段 JSON，内容和正文重复）。
enum AgentToolText {
    static let extrasOpen = "<mcp-result-extras>"
    static let extrasClose = "</mcp-result-extras>"
    /// 多长以内才试着当 JSON 排版：流式推参数时每推一次都要过一遍，长的不去解析（与 `AgentTranscript.maxOutput` 同值）。
    static let jsonLimit = 8000

    /// - 有正文时去掉 `<mcp-result-extras>` 那段（没收尾标签就去到末尾——输出被截断时）；
    /// - 只有那段（服务只回了结构化结果）就把里面的 JSON 排成多行显示；
    /// - 整段就是一个 JSON（对象 / 数组）也排成多行；不完整 / 不是 JSON 的照原样。
    static func clean(_ s: String) -> String {
        guard let open = s.range(of: extrasOpen) else { return prettyJSON(s) ?? s }
        let close = s.range(of: extrasClose, range: open.upperBound..<s.endIndex)
        // 🔴 只去正文**末尾**的空白：开头的空格是第一行行号的对齐（`  36\t…`），去了第一行就和下面对不齐
        let before = trimmingTrailing(s[..<open.lowerBound])
        let after = close.map { trimmingTrailing(s[$0.upperBound...].drop { $0 == "\n" || $0 == "\r" }) } ?? ""
        let rest = after.isEmpty ? "" : clean(after)
        if !before.isEmpty { return rest.isEmpty ? before : before + "\n" + rest }
        let extras = String(s[open.upperBound..<(close?.lowerBound ?? s.endIndex)])
        var shown = prettyJSON(extras, unwrapping: "structuredContent") ?? extras.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { shown += "\n" + rest }
        return shown
    }

    private static func trimmingTrailing(_ s: Substring) -> String {
        var t = s
        while let c = t.last, c.isWhitespace { t = t.dropLast() }
        return String(t)
    }

    /// 整段是 JSON 对象 / 数组时排成多行（键按字母序）；不是就 nil。
    /// - Parameter key: 外面只包了这一个键（`{"structuredContent": …}`）就拆掉这层。
    static func prettyJSON(_ s: String, unwrapping key: String? = nil) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= jsonLimit, let first = t.first, let last = t.last,
              (first == "{" && last == "}") || (first == "[" && last == "]"),
              var obj = try? JSONSerialization.jsonObject(with: Data(t.utf8)) else { return nil }
        if let key, let d = obj as? [String: Any], d.count == 1, let inner = d[key] { obj = inner }
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let out = String(data: data, encoding: .utf8) else { return nil }
        return out
    }
}
