import ACPModel
import Foundation

/// 对话里的一条（`AgentChat.items`）。流式到来的碎片在 `AgentTranscript.apply` 里拼成整条。
struct AgentItem: Identifiable, Equatable {
    enum Kind: Equatable {
        /// 用户的一句话 + 随它发出去的图片（回放时 Agent 推回来的图片也拼在这里）+ 随它发出去、气泡里看不见的上下文
        /// （`@` 引用、引用出处、交接摘要、用户在看什么……显示在气泡下面一行，`ACP-AGENT-PLAN.md §18`）。
        case user(String, images: [AgentImage], context: [AgentSentContext] = [])
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
        case .user(let s, let images, let ctx): return 200 + s.utf16.count + 400 * images.count + 40 * ctx.count
        case .tool, .plan, .notice: return 200
        }
    }

    /// 每次发给 Agent 的上下文块用这对标签包起来：回放历史时据此把它从「用户说的话」里剔掉。
    static let contextOpen = "<unireader-context>"
    static let contextClose = "</unireader-context>"

    /// 回放时要从用户消息里剔掉的段落：我们自己的上下文块 + Kimi 自己注入的 system-reminder。
    private static let hiddenTags = [(contextOpen, contextClose), ("<system-reminder>", "</system-reminder>")]

    static func stripHidden(_ s: String) -> String { splitHidden(s).visible }

    /// 拆成用户看得见的部分 + 我们自己的隐藏上下文块里面的文字（Kimi 的 system-reminder 只剔不留）。
    /// 隐藏块里的东西据 `AgentSentContext.parse` 显示在气泡下面那行「上下文」里（`ACP-AGENT-PLAN.md §18`）。
    static func splitHidden(_ s: String) -> (visible: String, hidden: [String]) {
        var out = s
        var hidden: [String] = []
        for (open, close) in hiddenTags {
            while let a = out.range(of: open) {
                let inner: Range<String.Index>
                if let b = out.range(of: close, range: a.upperBound..<out.endIndex) {
                    inner = a.upperBound..<b.lowerBound
                    if open == contextOpen { hidden.append(String(out[inner])) }
                    out.removeSubrange(a.lowerBound..<b.upperBound)
                } else {
                    if open == contextOpen { hidden.append(String(out[a.upperBound...])) }
                    out.removeSubrange(a.lowerBound..<out.endIndex)   // 没闭合：后面全算上下文
                }
            }
        }
        return (out, hidden)
    }

    /// 给眼前这条用户消息补上下文（回放时附件 / 隐藏块跟在那句话后面单独推来）。没有用户消息 / 没新东西 → false。
    private static func addContext(_ extra: [AgentSentContext], to items: inout [AgentItem]) -> Bool {
        guard !extra.isEmpty, case .user(let s, let imgs, let ctx)? = items.last?.kind else { return false }
        let merged = AgentSentContext.merged(ctx, extra)
        guard merged != ctx else { return false }
        items[items.count - 1].kind = .user(s, images: imgs, context: merged)
        return true
    }

    /// 工具名去掉 MCP 前缀：`mcp__unireader__get_state` → `get_state`。
    static func prettyTitle(_ t: String) -> String {
        var t = t
        if t.hasPrefix("mcp__"), let r = t.range(of: "__", range: t.index(t.startIndex, offsetBy: 5)..<t.endIndex) {
            t = String(t[r.upperBound...])
        }
        return clampTitle(t)
    }

    /// 工具调用的标题只留第一行、最多 `maxTitle` 个字符。有的 Agent 把调用参数整段拼进标题（`import_exercises` 一次几十道题
    /// 就是几万字），单行标签每次量宽 / 重排都要排整段文字，拖动窗口或 Inspector 时主线程被它占满。
    static let maxTitle = 160
    static func clampTitle(_ t: String) -> String {
        let line = t.prefix(maxTitle * 4).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return line.count > maxTitle ? String(line.prefix(maxTitle)) + "…" : line
    }

    /// 工具输出存进条目前的上限：界面只展示前 4000 字（`AgentChatNSView.tool`），其余没用，也别在每次增量更新时反复比较 / 拷贝。
    static let maxOutput = 8000

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
        }.joined(separator: "\n").prefix(maxOutput).description
    }

    /// 应用一条更新。返回 true = 条目有变化（调用方据此决定要不要发 objectWillChange）。
    @discardableResult
    static func apply(_ update: SessionUpdate, to items: inout [AgentItem]) -> Bool {
        switch update {
        case .userMessageChunk(.image(let img)):
            // 回放：图片挂到眼前这条用户消息上（发送时图片排在文字后面），没有就单起一条
            guard let data = Data(base64Encoded: img.data) else { return false }
            let pic = AgentImage(data: data, mimeType: img.mimeType)
            if case .user(let prev, let imgs, let ctx)? = items.last?.kind {
                items[items.count - 1].kind = .user(prev, images: imgs + [pic], context: ctx)
            } else {
                items.append(AgentItem(kind: .user("", images: [pic])))
            }
            return true
        case .userMessageChunk(.resourceLink(let r)):
            // 回放：`@` 附上的文件，用户那句话里已经写着 `@名字`，不再把 URI 拼进去；记进气泡下面那行「上下文」
            return addContext([AgentSentContext.reference(name: r.name, uri: r.uri, mimeType: r.mimeType,
                                                          description: r.description)], to: &items)
        case .userMessageChunk(let b):
            guard let raw = text(of: b) else { return false }
            let parts = splitHidden(raw)
            let extra = parts.hidden.flatMap { AgentSentContext.parse(hidden: $0) }
            let t = parts.visible.trimmingCharacters(in: .whitespacesAndNewlines)
            if case .user(let prev, let imgs, let ctx)? = items.last?.kind {
                if t.isEmpty { return addContext(extra, to: &items) }
                // Agent 把 `@` 附件（resource_link）转成了文字、跟在那句话后面单独一块（Kimi 是本机路径 / `<resource_link …/>`，
                // Claude Code 是 `[@名字](file://…)`；用户 2026-11-12 截图「后面有一堆路径」）：那句话里已经写着 `@名字`，
                // 正文里不显示，记进「上下文」
                if AgentMention.isLinkEcho(t) { return addContext(AgentSentContext.references(echo: t) + extra, to: &items) }
                // 我们发的每条消息只有**一块**看得见的文字（其余是附件 / 图片 / 上下文块），眼前这条已经有字了，再来的字就是
                // 下一句（那句话之后 Agent 没回就又发了「继续」，以前会接成一句「……空的继续」）。还没字的那条（只有图片）把字补上。
                if prev.isEmpty {
                    items[items.count - 1].kind = .user(t, images: imgs, context: AgentSentContext.merged(ctx, extra))
                    return true
                }
            }
            guard !t.isEmpty else { return false }
            items.append(AgentItem(kind: .user(t, images: [], context: extra)))
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
            // 什么都没变就别写回去：写一次 = 面板刷新一次（有的 Agent 同一条更新会重复推）
            guard items[i].kind != .tool(call) else { return false }
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
