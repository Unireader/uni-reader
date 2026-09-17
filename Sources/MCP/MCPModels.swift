import Foundation

// MCP 边界上的基础类型（方案 `MCP-PLAN.md §6`）。**只依赖 Foundation**——spike 要单独编译这几个文件，
// 别在这里引 AppKit / PDFKit / App 层类型。

/// MCP 边界上的 JSON 一律用 Foundation 的 `[String: Any]`（`JSONSerialization`），
/// 不为每个工具的入参/出参各写一套 Codable：协议里 `inputSchema` / `structuredContent` 本来就是自由形态。
typealias MCPObject = [String: Any]

enum MCPJSON {
    /// 编码；键排序让应答稳定（spike 比对、日志可读）。编不出来（含 NaN 这类）回退到空对象而不是崩。
    static func data(_ obj: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    static func string(_ obj: Any, pretty: Bool = false) -> String {
        var opts: JSONSerialization.WritingOptions = [.sortedKeys]
        if pretty { opts.insert(.prettyPrinted) }
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: opts) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    static func parse(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// ISO-8601（带小数秒，UTC）——与库里时间列同一写法，Agent 看到的时间戳和 SQLite 里的一致。
    static func iso(_ d: Date) -> String {
        Self.isoFormatter.string(from: d)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// 工具执行失败：一句模型读得懂的英文，落到 `tools/call` 的 `isError: true`（方案 §4.4 第二层）。
struct MCPToolError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// 参数不合法（缺必填、类型不对、范围越界）：落到 JSON-RPC `-32602`（方案 §4.4 第一层）。
struct MCPInvalidParams: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// 页码换算的**唯一位置**：对 Agent 一律 1 起（决策 D2），App 内部一律 0 起。
enum PageNo {
    /// 一次调用最多读的页数（方案 §7.7）。超了直接拒绝让 Agent 分次，而不是悄悄截断。
    static let maxPagesPerCall = 40

    /// 内部下标 → 对外页码。
    static func external(_ index: Int) -> Int { index + 1 }

    /// 对外页码 → 内部下标；越界给一句带总页数的话（模型据此自己纠正）。
    static func index(_ page: Int, pageCount: Int) throws -> Int {
        guard page >= 1, page <= pageCount else {
            throw MCPToolError("page \(page) is out of range (document has \(pageCount) pages; pages are 1-based)")
        }
        return page - 1
    }

    /// 解析页范围写法 `"12"` / `"3-7"` / `"1-3,9,20-22"` → **去重、升序**的内部下标。
    /// 空白随意；`"7-3"` 这种倒着写按 3-7 处理（不猜用户是不是想倒序读，读出来的顺序永远升序）。
    /// `limit` = 最多几页（读文本用默认的 40；纯筛选（搜索/批注列表）传 `Int.max`）。
    static func parse(_ spec: String, pageCount: Int, limit: Int = maxPagesPerCall) throws -> [Int] {
        let maxPagesPerCall = limit
        var out = Set<Int>()
        for rawPart in spec.split(separator: ",") {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            if part.isEmpty { continue }
            let ends = part.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            switch ends.count {
            case 1:
                guard let p = Int(ends[0]) else { throw MCPInvalidParams("invalid page spec '\(part)'") }
                out.insert(try index(p, pageCount: pageCount))
            case 2:
                guard let a = Int(ends[0]), let b = Int(ends[1]) else {
                    throw MCPInvalidParams("invalid page range '\(part)' (use e.g. \"3-7\" or \"1-3,9\")")
                }
                let lo = try index(min(a, b), pageCount: pageCount)
                let hi = try index(max(a, b), pageCount: pageCount)
                if hi - lo + 1 > maxPagesPerCall {
                    throw MCPToolError("page range '\(part)' spans \(hi - lo + 1) pages; at most \(maxPagesPerCall) pages per call")
                }
                for i in lo...hi { out.insert(i) }
            default:
                throw MCPInvalidParams("invalid page range '\(part)'")
            }
            if out.count > maxPagesPerCall {
                throw MCPToolError("too many pages requested (\(out.count)); at most \(maxPagesPerCall) pages per call")
            }
        }
        if out.isEmpty { throw MCPInvalidParams("pages must name at least one page") }
        return out.sorted()
    }
}

/// 工具入参的读取器：类型不对就是 `MCPInvalidParams`（-32602），而不是悄悄当作没传。
struct MCPArgs {
    let raw: MCPObject
    init(_ raw: MCPObject) { self.raw = raw }

    func string(_ key: String) throws -> String? {
        guard let v = raw[key], !(v is NSNull) else { return nil }
        guard let s = v as? String else { throw MCPInvalidParams("argument '\(key)' must be a string") }
        return s
    }

    func requiredString(_ key: String) throws -> String {
        guard let s = try string(key), !s.isEmpty else { throw MCPInvalidParams("argument '\(key)' is required") }
        return s
    }

    func int(_ key: String) throws -> Int? {
        guard let v = raw[key], !(v is NSNull) else { return nil }
        // JSON 的 true/false 解出来也是 NSNumber，按类型 id 挡掉，别把 `true` 当成 1 页。
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d = n.doubleValue
            guard d == d.rounded(), abs(d) < 1e12 else { throw MCPInvalidParams("argument '\(key)' must be an integer") }
            return n.intValue
        }
        if let s = v as? String, let i = Int(s) { return i }   // 有些客户端把数字当字符串发
        throw MCPInvalidParams("argument '\(key)' must be an integer")
    }

    func bool(_ key: String, default def: Bool) throws -> Bool {
        guard let v = raw[key], !(v is NSNull) else { return def }
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        if let s = v as? String {
            if s == "true" { return true }
            if s == "false" { return false }
        }
        throw MCPInvalidParams("argument '\(key)' must be a boolean")
    }

    /// 页范围：整数或字符串都收（`12` / `"3-7"`）。
    func pages(_ key: String) throws -> String? {
        guard let v = raw[key], !(v is NSNull) else { return nil }
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return String(n.intValue) }
        if let s = v as? String { return s }
        throw MCPInvalidParams("argument '\(key)' must be a page number or a range like \"3-7\"")
    }
}

/// `inputSchema` / `outputSchema` 的拼装小工具（JSON Schema 子集，够协议用）。
enum MCPSchema {
    static func object(_ properties: [String: MCPObject], required: [String] = [], description: String? = nil) -> MCPObject {
        var o: MCPObject = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { o["required"] = required }
        if let description { o["description"] = description }
        return o
    }
    static func string(_ description: String) -> MCPObject { ["type": "string", "description": description] }
    static func integer(_ description: String, min: Int? = nil, max: Int? = nil) -> MCPObject {
        var o: MCPObject = ["type": "integer", "description": description]
        if let min { o["minimum"] = min }
        if let max { o["maximum"] = max }
        return o
    }
    static func number(_ description: String) -> MCPObject { ["type": "number", "description": description] }
    static func boolean(_ description: String, default def: Bool? = nil) -> MCPObject {
        var o: MCPObject = ["type": "boolean", "description": description]
        if let def { o["default"] = def }
        return o
    }
    static func array(of item: MCPObject, _ description: String? = nil) -> MCPObject {
        var o: MCPObject = ["type": "array", "items": item]
        if let description { o["description"] = description }
        return o
    }
    /// 给一个字段类型加上「或 null」（JSON Schema `anyOf` 写法）。用于描述里写了 "or null" / "null for …"
    /// 但底层就是普通 `string`/`integer` 类型的字段——不加这个，DTO 侧一旦真赋值 `NSNull()`，输出就会被
    /// 客户端按 `type` 校验拒收（`data/x must be string`），哪怕文档已经说明可以是 null。
    static func nullable(_ schema: MCPObject) -> MCPObject {
        var inner = schema
        let description = inner.removeValue(forKey: "description")
        var o: MCPObject = ["anyOf": [inner, ["type": "null"]]]
        if let description { o["description"] = description }
        return o
    }
    static func enumeration(_ values: [String], _ description: String, default def: String? = nil) -> MCPObject {
        var o: MCPObject = ["type": "string", "enum": values, "description": description]
        if let def { o["default"] = def }
        return o
    }
    /// 页范围参数（整数或字符串两种写法）。
    static var pageSpec: MCPObject {
        ["anyOf": [["type": "integer"], ["type": "string"]],
         "description": "Page or page range, 1-based: 12, \"3-7\", or \"1-3,9,20-22\". At most \(PageNo.maxPagesPerCall) pages per call."]
    }
}
