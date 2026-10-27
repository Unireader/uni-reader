import Foundation

/// Agent 报上来的上下文占用（`usage_update` 的 `used` / `size`）。
///
/// 🔴 **只有 Agent 主动推才有**（2026-10-26 用 `spike/acp-notify-probe.py` 实测本机两个 Agent：
/// Kimi 每轮回答结束推一条 `{"used": 45790, "size": 1000000}`；Qwen Code 整轮一条都不推）。
/// 没推的就是 nil，面板上那一块不显示——**不按字数自己估**：估出来的和 Agent 的真实上下文对不上
/// （不含工具结果、不含它自己读进去的文件），显示一个不可靠的百分比比空着更糟（用户 2026-10-26 定）。
/// 同理，发出压缩命令就收起（`AgentChat.send`）：Kimi 压缩完不推新数字，要等下一轮回答结束才报；
/// Claude Code 压缩完马上推。换会话也收起，回放的旧会话 Kimi 同样要说一句之后才有。
///
/// 只依赖 Foundation + `L`，spike `agent-usage-test.swift`。
struct AgentContextUsage: Equatable {
    var used: Int
    var size: Int

    /// 占比，四舍五入取整并夹在 0…100。`size` 不成话（≤0）或 `used` 为负 = 当作没报。
    var percent: Int? {
        guard size > 0, used >= 0 else { return nil }
        return min(100, max(0, Int((Double(used) / Double(size) * 100).rounded())))
    }

    /// 摆在输入框那一行的那几个字。才用了一点点但确实用了的时候给 `<1%`，别显示成 `0%`。
    var shortText: String? {
        guard let p = percent else { return nil }
        if p == 0 && used > 0 { return "<1%" }
        return "\(p)%"
    }

    /// 悬停提示：数字带千分位，占比多给一位小数（45,790 / 1,000,000 是 4.6%，取整成 5% 会对不上）。
    var detailText: String? {
        guard size > 0, used >= 0 else { return nil }
        let pct = String(format: "%.1f%%", Double(used) / Double(size) * 100)
        return String(format: L("Context: %1$@ of %2$@ tokens (%3$@)"),
                      used.formatted(.number.grouping(.automatic)),
                      size.formatted(.number.grouping(.automatic)), pct)
    }
}
