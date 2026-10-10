import ACPModel
import Foundation

/// 对话里的一条（`AgentChat.items`）。流式到来的碎片在 `AgentTranscript.apply` 里拼成整条。
struct AgentItem: Identifiable, Equatable {
    enum Kind: Equatable {
        /// 用户的一句话 + 随它发出去的图片（回放时 Agent 推回来的图片也拼在这里）。
        case user(String, images: [AgentImage])
        case agent(String)
        case thought(String)
        case tool(AgentToolCall)
        case plan([AgentPlanEntry])
        /// 一行说明（出错 / Agent 退出 / 被取消）。
        case notice(String, isError: Bool)
    }

    let id = UUID()
    var kind: Kind
}

/// 一张随消息发给 Agent 的图片（目前只有阅读区 ⌥ 拖出来的框选截图）。
/// 相等只比 `id`：条目数组每次变化都要比一遍，别去逐字节比图片数据。
struct AgentImage: Identifiable, Equatable {
    let id = UUID()
    /// 原样发给 Agent 的字节（JPEG / PNG）。
    var data: Data
    var mimeType: String
    /// 给人看的来源，如「《书名》 · p.12 · 第三章」；回放来的图片没有。
    var caption: String?
    /// 给 Agent 看的来源说明（英文，放进隐藏的上下文块，回放时剔掉）；回放来的图片没有。
    var note: String?

    static func == (a: AgentImage, b: AgentImage) -> Bool { a.id == b.id }
}

struct AgentToolCall: Equatable {
    var callId: String
    var title: String
    var kind: String?
    var status: ToolStatus?
    /// 工具输出的文字部分（结果、diff 的路径说明）。只拿来折叠展示，不解析。
    var output: String = ""
}

struct AgentPlanEntry: Equatable {
    var text: String
    var status: PlanEntryStatus
}

/// 把 `session/update` 拼进条目数组的纯函数集合（不碰 UI、不碰网络）。
enum AgentTranscript {
    // MARK: 分段建视图

    /// 长对话不一次建完（用户 2026-10-07：「长对话要渲染加载好几秒，可以一段一段，向上滚动的时候再加载吗」）：
    /// 先只给最后一段建视图，往上翻再往前补。一段 = 从 `end` 往前取，攒够 `budget` 的分量就停（至少一条）。
    /// 返回这一段的起点下标。分量按 `weight`，大致是要排版的字数——贵的是回复正文的 Markdown / 公式排版。
    static func windowStart(_ items: [AgentItem], before end: Int, budget: Int) -> Int {
        var start = end, sum = 0
        while start > 0, sum < budget || start == end {
            start -= 1
            sum += weight(items[start].kind)
        }
        return start
    }

    /// 先建的那一段：大约两三屏。
    static let initialBudget = 4000
    /// 往上翻时每次往前补的一段。
    static let earlierBudget = 3000
    /// 贴着底往下说的时候，建了视图的那段最多这么重，超了从顶上摘回 `initialBudget`（`AgentChatNSView.trimTop`）。
    /// 取两倍：摘一次能撑好一阵，别每来一条就摘一条。工具调用每条 200，即最多四十来条。
    static let liveBudget = 8000

    /// 一条要建多重的视图：正文按字数，另加一份固定开销（每条一个视图、一次排版）。
    static func weight(_ kind: AgentItem.Kind) -> Int {
        switch kind {
        case .agent(let s), .thought(let s): return 200 + s.utf16.count
        case .user(let s, let images): return 200 + s.utf16.count + 400 * images.count
        case .tool, .plan, .notice: return 200
        }
    }

    /// 每次发给 Agent 的上下文块用这对标签包起来：回放历史时据此把它从「用户说的话」里剔掉。
    static let contextOpen = "<unireader-context>"
    static let contextClose = "</unireader-context>"

    /// 回放时要从用户消息里剔掉的段落：我们自己的上下文块 + Kimi 自己注入的 system-reminder。
    private static let hiddenTags = [(contextOpen, contextClose), ("<system-reminder>", "</system-reminder>")]

    static func stripHidden(_ s: String) -> String {
        var out = s
        for (open, close) in hiddenTags {
            while let a = out.range(of: open) {
                if let b = out.range(of: close, range: a.upperBound..<out.endIndex) {
                    out.removeSubrange(a.lowerBound..<b.upperBound)
                } else {
                    out.removeSubrange(a.lowerBound..<out.endIndex)   // 没闭合：后面全算上下文
                }
            }
        }
        return out
    }

    /// 工具名去掉 MCP 前缀：`mcp__unireader__get_state` → `get_state`。
    static func prettyTitle(_ t: String) -> String {
        if t.hasPrefix("mcp__"), let r = t.range(of: "__", range: t.index(t.startIndex, offsetBy: 5)..<t.endIndex) {
            return String(t[r.upperBound...])
        }
        return t
    }

    static func text(of block: ContentBlock) -> String? {
        switch block {
        case .text(let t): return t.text
        case .resourceLink(let r): return r.uri
        default: return nil
        }
    }

    static func outputText(_ content: [ToolCallContent]) -> String {
        content.compactMap { c -> String? in
            switch c {
            case .content(let b): return text(of: b)
            case .diff(let d): return String(format: L("Edited %@"), d.path)
            case .terminal: return nil
            }
        }.joined(separator: "\n")
    }

    /// 应用一条更新。返回 true = 条目有变化（调用方据此决定要不要发 objectWillChange）。
    @discardableResult
    static func apply(_ update: SessionUpdate, to items: inout [AgentItem]) -> Bool {
        switch update {
        case .userMessageChunk(.image(let img)):
            // 回放：图片挂到眼前这条用户消息上（发送时图片排在文字后面），没有就单起一条
            guard let data = Data(base64Encoded: img.data) else { return false }
            let pic = AgentImage(data: data, mimeType: img.mimeType)
            if case .user(let prev, let imgs)? = items.last?.kind {
                items[items.count - 1].kind = .user(prev, images: imgs + [pic])
            } else {
                items.append(AgentItem(kind: .user("", images: [pic])))
            }
            return true
        case .userMessageChunk(.resourceLink):
            // 回放：`@` 附上的文件，用户那句话里已经写着 `@名字`，不再把 URI 拼进去
            return false
        case .userMessageChunk(let b):
            guard let raw = text(of: b) else { return false }
            let t = stripHidden(raw)
            guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            // 已经带了图片的那条不再往后拼文字：图片在文字后面，再来的文字是下一句
            if case .user(let prev, let imgs)? = items.last?.kind, imgs.isEmpty {
                items[items.count - 1].kind = .user(prev + t, images: [])
            } else {
                items.append(AgentItem(kind: .user(t.trimmingCharacters(in: .whitespacesAndNewlines), images: [])))
            }
            return true
        case .agentMessageChunk(let b):
            guard let t = text(of: b) else { return false }
            if case .agent(let prev)? = items.last?.kind {
                items[items.count - 1].kind = .agent(prev + t)
            } else {
                guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                items.append(AgentItem(kind: .agent(t)))
            }
            return true
        case .agentThoughtChunk(let b):
            guard let t = text(of: b) else { return false }
            if case .thought(let prev)? = items.last?.kind {
                items[items.count - 1].kind = .thought(prev + t)
            } else {
                // Kimi 每次调工具前后会发一个空的思考片段（spike 实测），别为它多出一条空的「思考过程」
                guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                items.append(AgentItem(kind: .thought(t)))
            }
            return true
        case .toolCall(let tc):
            let call = AgentToolCall(callId: tc.toolCallId, title: prettyTitle(tc.title ?? tc.toolCallId),
                                     kind: tc.kind?.rawValue, status: tc.status, output: outputText(tc.content))
            if let i = toolIndex(tc.toolCallId, in: items) {
                items[i].kind = .tool(call)          // 同一 id 再来一次（回放）→ 覆盖
            } else {
                items.append(AgentItem(kind: .tool(call)))
            }
            return true
        case .toolCallUpdate(let u):
            guard let i = toolIndex(u.toolCallId, in: items), case .tool(var call) = items[i].kind else {
                // 没见过开头就来了更新：当成新的一条
                items.append(AgentItem(kind: .tool(AgentToolCall(
                    callId: u.toolCallId, title: prettyTitle(u.title ?? u.toolCallId), kind: u.kind?.rawValue,
                    status: u.status, output: outputText(u.content ?? [])))))
                return true
            }
            if let s = u.status { call.status = s }
            if let t = u.title { call.title = prettyTitle(t) }
            if let k = u.kind { call.kind = k.rawValue }
            if let c = u.content { call.output = outputText(c) }
            items[i].kind = .tool(call)
            return true
        case .plan(let p):
            let entries = p.entries.map { AgentPlanEntry(text: $0.content, status: $0.status) }
            // 计划是整体替换语义：已有就原地换，免得每改一项就多出一份
            if let i = items.lastIndex(where: { if case .plan = $0.kind { return true } else { return false } }) {
                items[i].kind = .plan(entries)
            } else {
                items.append(AgentItem(kind: .plan(entries)))
            }
            return true
        default:
            return false
        }
    }

    private static func toolIndex(_ id: String, in items: [AgentItem]) -> Int? {
        items.lastIndex { if case .tool(let c) = $0.kind { return c.callId == id } else { return false } }
    }
}
