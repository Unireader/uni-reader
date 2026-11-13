import Foundation

/// 批 8（2026-11-13）：日程（`SCHEDULE-PLAN.md §6`）。日历 + 待办，按工作区存、随同步。
/// Agent 能看（`list_schedule`）、排计划（`add_schedule_items`：一批事项，可以挂在一份新计划下）、挪日子 / 改 / 打勾
/// （`update_schedule_items`）、删（`delete_schedule`，先进回收站）、给用户打开（`open_schedule`）。
/// 🔴 每个返回的键都要在 `outputSchema` 里声明（Kimi 严格校验，多一个键整次调用作废）。
extension MCPTools {

    static func registerBatch8(into server: MCPServer) {
        let c = server.catalog
        c.register(listScheduleTool())
        c.register(addScheduleItemsTool())
        c.register(updateScheduleItemsTool())
        c.register(deleteScheduleTool())
        c.register(openScheduleTool())
    }

    private static let scheduleWorkspaceArg = MCPSchema.string("Workspace .unrd path; default = the workspace of the key reader window.")

    static var scheduleItemSchema: MCPObject {
        MCPSchema.object([
            "item_id": MCPSchema.string("schedule item id"),
            "plan_id": MCPSchema.nullable(MCPSchema.string("the plan it belongs to; null = none")),
            "title": MCPSchema.string("what to do"),
            "detail": MCPSchema.string("details (Markdown; may contain [[book title#page=N]] links)"),
            "day": MCPSchema.nullable(MCPSchema.string("YYYY-MM-DD (local calendar day); null = not scheduled on a day yet")),
            "start": MCPSchema.nullable(MCPSchema.string("start time HH:mm; null = any time that day")),
            "duration_minutes": MCPSchema.integer("estimated minutes; 0 = not given"),
            "done": MCPSchema.boolean("ticked off"),
            "done_at": MCPSchema.nullable(MCPSchema.string("ISO 8601 time it was ticked off")),
            "result": MCPSchema.string("the user's note on how it went (empty = none)"),
            "overdue": MCPSchema.boolean("not done and its day is before today"),
            "agent": MCPSchema.string("the agent that added it (empty = the user)"),
        ])
    }

    static var schedulePlanSchema: MCPObject {
        MCPSchema.object([
            "plan_id": MCPSchema.string("plan id"),
            "title": MCPSchema.string("plan name"),
            "goal": MCPSchema.string("what the plan is for"),
            "agent": MCPSchema.string("the agent that made it (empty = the user)"),
            "items": MCPSchema.integer("items in the plan"),
            "done": MCPSchema.integer("items ticked off"),
            "first_day": MCPSchema.nullable(MCPSchema.string("earliest scheduled day")),
            "last_day": MCPSchema.nullable(MCPSchema.string("latest scheduled day")),
            "created_at": MCPSchema.string("ISO 8601"),
        ])
    }

    static func listScheduleTool() -> MCPTool {
        MCPTool(
            name: "list_schedule",
            title: "Read the schedule",
            description: "Read the workspace schedule (日程, calendar + to-dos): the plans and the items on each day — what to do, when, how long, whether it is done, and the note the user wrote on how it went. By default: today and the next 13 days, plus every overdue item (not done, earlier day) and the items with no day yet. plan_id lists one plan's items on every day. Use this before planning or rescheduling, and workspace_stats for counts.",
            inputSchema: MCPSchema.object([
                "workspace": scheduleWorkspaceArg,
                "from": MCPSchema.string("first day, YYYY-MM-DD (default today)"),
                "to": MCPSchema.string("last day, YYYY-MM-DD (default from + 13 days; at most 366 days)"),
                "plan_id": MCPSchema.string("only this plan's items (all its days unless from / to are given)"),
                "status": MCPSchema.enumeration(["all", "open", "done"], "which items (default all)"),
                "include_overdue": MCPSchema.boolean("also list overdue items before from (default true)"),
                "include_undated": MCPSchema.boolean("also list items with no day (default true)"),
            ]),
            outputSchema: MCPSchema.object([
                "today": MCPSchema.string("today, YYYY-MM-DD"),
                "from": MCPSchema.string("first day listed"),
                "to": MCPSchema.string("last day listed"),
                "plans": MCPSchema.array(of: schedulePlanSchema),
                "items": MCPSchema.array(of: scheduleItemSchema),
                "truncated": MCPSchema.boolean("more than 500 items matched; narrow the range"),
            ]),
            tier: .read
        ) { _, args in
            let wsPath = try args.string("workspace")
            let r = try await MainActor.run {
                try MCPFacade.shared.listSchedule(from: try args.string("from"), to: try args.string("to"),
                                                  planId: try args.string("plan_id"), status: try args.string("status") ?? "all",
                                                  includeOverdue: try args.bool("include_overdue", default: true),
                                                  includeUndated: try args.bool("include_undated", default: true),
                                                  workspacePath: wsPath)
            }
            return MCPToolResult(text: scheduleText(r), structured: r)
        }
    }

    static func addScheduleItemsTool() -> MCPTool {
        MCPTool(
            name: "add_schedule_items",
            title: "Add items to the schedule",
            description: "Add items to the workspace schedule, e.g. a study plan the user asked for. Give plan (title + goal) to group the items as one new plan — the user can then see its progress and delete or adjust it as a whole; or plan_id to add to an existing plan; or neither for loose items. Each item is one concrete task on one day: a short title, day (YYYY-MM-DD, omit for no day yet), optional start (HH:mm, only when the user gave times), duration_minutes, and detail with exact pages as [[book title#page=N]] links or which exercises to do. Keep each day realistic, and check list_schedule first so you don't duplicate items.",
            inputSchema: MCPSchema.object([
                "workspace": scheduleWorkspaceArg,
                "plan": MCPSchema.object([
                    "title": MCPSchema.string("plan name, e.g. 第三章复习（两周）"),
                    "goal": MCPSchema.string("what it should achieve, by when"),
                ], required: ["title"], description: "make a new plan for these items"),
                "plan_id": MCPSchema.string("add to this existing plan instead"),
                "items": MCPSchema.array(of: MCPSchema.object([
                    "title": MCPSchema.string("what to do (short)"),
                    "day": MCPSchema.string("YYYY-MM-DD; omit or empty = no day yet"),
                    "start": MCPSchema.string("HH:mm; omit = any time that day"),
                    "duration_minutes": MCPSchema.integer("estimated minutes", min: 0, max: 1440),
                    "detail": MCPSchema.string("details (Markdown, [[book title#page=N]] links)"),
                ], required: ["title"]), "the items, in order (at most 300)"),
            ], required: ["items"]),
            outputSchema: MCPSchema.object([
                "plan_id": MCPSchema.nullable(MCPSchema.string("the plan they were added to")),
                "item_ids": MCPSchema.array(of: MCPSchema.string("new item id"), "in the order given"),
            ]),
            tier: .write
        ) { ctx, args in
            guard let list = args.raw["items"] as? [Any], !list.isEmpty else { throw MCPInvalidParams("items is required") }
            guard list.count <= 300 else { throw MCPInvalidParams("at most 300 items per call") }
            let drafts = try list.enumerated().map { i, raw -> WorkspaceManager.ScheduleDraft in
                guard let o = raw as? [String: Any] else { throw MCPInvalidParams("items[\(i)] must be an object") }
                return try scheduleDraft(o, index: i)
            }
            let plan = args.raw["plan"] as? [String: Any]
            let planId = try args.string("plan_id")
            if plan != nil, planId?.isEmpty == false { throw MCPInvalidParams("give plan or plan_id, not both") }
            let wsPath = try args.string("workspace")
            let agent = ctx.clientName == MCPCallContext.anonymous.clientName ? "" : ctx.clientName
            let r = try await MainActor.run {
                try MCPFacade.shared.addScheduleItems(drafts, plan: plan.map { ($0["title"] as? String ?? "", $0["goal"] as? String ?? "") },
                                                      planId: planId, agent: agent, workspacePath: wsPath)
            }
            let n = (r["item_ids"] as? [String])?.count ?? 0
            let p = (r["plan_id"] as? String).map { " to plan \($0)" } ?? ""
            return MCPToolResult(text: "Added \(n) item(s)\(p). The user sees them in the Schedule tab and the Inspector's Today page.",
                                 structured: r)
        }
    }

    /// 一件事的草稿（`add_schedule_items` 的一项）。格式不对的直接报错（别悄悄丢掉日子 / 时间）。
    private static func scheduleDraft(_ o: [String: Any], index i: Int) throws -> WorkspaceManager.ScheduleDraft {
        let title = (o["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MCPInvalidParams("items[\(i)].title is required") }
        var d = WorkspaceManager.ScheduleDraft(title: title)
        if let day = o["day"] as? String, !day.isEmpty {
            guard ScheduleDay.isValid(day) else { throw MCPInvalidParams("items[\(i)].day must be YYYY-MM-DD, got \(day)") }
            d.day = day
        }
        if let s = o["start"] as? String, !s.isEmpty {
            guard let m = ScheduleTime.minutes(s) else { throw MCPInvalidParams("items[\(i)].start must be HH:mm, got \(s)") }
            d.startMin = m
        }
        if let n = o["duration_minutes"] as? Int { d.durationMin = max(0, min(n, 1440)) }
        else if let n = o["duration_minutes"] as? Double { d.durationMin = max(0, min(Int(n), 1440)) }
        d.detail = o["detail"] as? String ?? ""
        return d
    }

    static func updateScheduleItemsTool() -> MCPTool {
        MCPTool(
            name: "update_schedule_items",
            title: "Change schedule items",
            description: "Change existing schedule items: reschedule (day, or empty day for no day; start, or empty start for any time), rename, rewrite details, set duration, tick off or reopen (done), write the result note, or move to another plan (plan_id, empty = none). Only the fields you give change. plans renames a plan or rewrites its goal. Use it to adjust a plan to how the user is doing — move overdue items forward instead of adding duplicates.",
            inputSchema: MCPSchema.object([
                "workspace": scheduleWorkspaceArg,
                "items": MCPSchema.array(of: MCPSchema.object([
                    "item_id": MCPSchema.string("item id (full, or its first 8 characters)"),
                    "title": MCPSchema.string("new title"),
                    "detail": MCPSchema.string("new details"),
                    "day": MCPSchema.string("YYYY-MM-DD, or empty for no day"),
                    "start": MCPSchema.string("HH:mm, or empty for any time"),
                    "duration_minutes": MCPSchema.integer("estimated minutes (0 = not given)", min: 0, max: 1440),
                    "done": MCPSchema.boolean("true = tick off, false = reopen"),
                    "result": MCPSchema.string("note on how it went"),
                    "plan_id": MCPSchema.string("move to this plan; empty = no plan"),
                ], required: ["item_id"]), "items to change (at most 300)"),
                "plans": MCPSchema.array(of: MCPSchema.object([
                    "plan_id": MCPSchema.string("plan id"),
                    "title": MCPSchema.string("new name"),
                    "goal": MCPSchema.string("new goal"),
                ], required: ["plan_id"]), "plans to rename or re-goal"),
            ]),
            outputSchema: MCPSchema.object([
                "updated": MCPSchema.integer("items changed"),
                "unchanged": MCPSchema.integer("items that already had those values"),
                "plans_updated": MCPSchema.integer("plans changed"),
            ]),
            tier: .write
        ) { _, args in
            let items = (args.raw["items"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            let plans = (args.raw["plans"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            guard !items.isEmpty || !plans.isEmpty else { throw MCPInvalidParams("give items or plans") }
            guard items.count <= 300 else { throw MCPInvalidParams("at most 300 items per call") }
            let wsPath = try args.string("workspace")
            let r = try await MainActor.run {
                try MCPFacade.shared.updateSchedule(items: items, plans: plans, workspacePath: wsPath)
            }
            return MCPToolResult(text: "Changed \(r["updated"] ?? 0) item(s) (\(r["unchanged"] ?? 0) already so), \(r["plans_updated"] ?? 0) plan(s).",
                                 structured: r)
        }
    }

    static func deleteScheduleTool() -> MCPTool {
        MCPTool(
            name: "delete_schedule",
            title: "Delete schedule items or plans",
            description: "Delete schedule items, or whole plans together with all their items (they go to UniReader's Trash and can be restored there). Prefer update_schedule_items to reschedule or rewrite; delete only what the user no longer wants, or a plan you are replacing at their request.",
            inputSchema: MCPSchema.object([
                "workspace": scheduleWorkspaceArg,
                "item_ids": MCPSchema.array(of: MCPSchema.string("item id (full, or its first 8 characters)"), "items to delete"),
                "plan_ids": MCPSchema.array(of: MCPSchema.string("plan id"), "plans to delete with all their items"),
            ]),
            outputSchema: MCPSchema.object([
                "items": MCPSchema.integer("items moved to the Trash (including those of deleted plans)"),
                "plans": MCPSchema.integer("plans moved to the Trash"),
            ]),
            tier: .delete
        ) { _, args in
            let items = (args.raw["item_ids"] as? [Any] ?? []).compactMap { $0 as? String }
            let plans = (args.raw["plan_ids"] as? [Any] ?? []).compactMap { $0 as? String }
            guard !items.isEmpty || !plans.isEmpty else { throw MCPInvalidParams("give item_ids or plan_ids") }
            let wsPath = try args.string("workspace")
            let r = try await MainActor.run {
                try MCPFacade.shared.deleteSchedule(itemIds: items, planIds: plans, workspacePath: wsPath)
            }
            return MCPToolResult(text: "Moved \(r["items"] ?? 0) item(s) and \(r["plans"] ?? 0) plan(s) to the Trash.", structured: r)
        }
    }

    static func openScheduleTool() -> MCPTool {
        MCPTool(
            name: "open_schedule",
            title: "Show the schedule",
            description: "Show the user the Schedule tab in UniReader: on a given day, or with one item selected (its details open).",
            inputSchema: MCPSchema.object([
                "workspace": scheduleWorkspaceArg,
                "day": MCPSchema.string("YYYY-MM-DD (default: the item's day, or today)"),
                "item_id": MCPSchema.string("select this item"),
            ]),
            outputSchema: MCPSchema.object([
                "window_id": MCPSchema.string("window id"),
                "session_id": MCPSchema.string("tab / session id"),
                "day": MCPSchema.string("the day shown"),
            ]),
            tier: .write
        ) { _, args in
            let wsPath = try args.string("workspace")
            let r = try await MainActor.run {
                try MCPFacade.shared.openSchedule(day: try args.string("day"), itemId: try args.string("item_id"), workspacePath: wsPath)
            }
            return MCPToolResult(text: "Showing the schedule on \(r["day"] ?? "").", structured: r)
        }
    }

    /// `list_schedule` 的文字版：按天分组，一件一行。
    static func scheduleText(_ r: MCPObject) -> String {
        var lines: [String] = ["Today is \(r["today"] ?? ""). Listing \(r["from"] ?? "") … \(r["to"] ?? "")."]
        let plans = r["plans"] as? [MCPObject] ?? []
        if !plans.isEmpty {
            lines.append("Plans:")
            for p in plans {
                var s = "- \(p["title"] ?? "") (plan_id \(p["plan_id"] ?? "")): \(p["done"] ?? 0)/\(p["items"] ?? 0) done"
                if let a = p["first_day"] as? String, let b = p["last_day"] as? String { s += ", \(a) … \(b)" }
                if let g = p["goal"] as? String, !g.isEmpty { s += " — goal: \(g)" }
                lines.append(s)
            }
        }
        let items = r["items"] as? [MCPObject] ?? []
        if items.isEmpty { lines.append("No items.") }
        let titles = Dictionary(plans.map { ($0["plan_id"] as? String ?? "", $0["title"] as? String ?? "") }, uniquingKeysWith: { a, _ in a })
        var lastDay: String?? = .none
        for m in items {
            let day = m["day"] as? String
            if lastDay == .none || lastDay! != day {
                lines.append(day.map { "\n\($0)" } ?? "\nNo day yet")
                lastDay = .some(day)
            }
            var s = "  [\((m["done"] as? Bool) == true ? "x" : " ")] "
            if let t = m["start"] as? String { s += t + " " }
            s += m["title"] as? String ?? ""
            if let d = m["duration_minutes"] as? Int, d > 0 { s += " (\(ScheduleTime.durationText(d)))" }
            if (m["overdue"] as? Bool) == true { s += " — overdue" }
            if let pid = m["plan_id"] as? String, let t = titles[pid] { s += " · \(t)" }
            s += " · item_id \(m["item_id"] ?? "")"
            lines.append(s)
            if let d = m["detail"] as? String, !d.isEmpty { lines.append("      " + d.replacingOccurrences(of: "\n", with: "\n      ")) }
            if let res = m["result"] as? String, !res.isEmpty { lines.append("      result: " + res) }
        }
        if (r["truncated"] as? Bool) == true { lines.append("\n(more than 500 items; narrow from / to)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 执行（主线程）

extension MCPFacade {

    func listSchedule(from: String?, to: String?, planId: String?, status: String, includeOverdue: Bool,
                      includeUndated: Bool, workspacePath: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        let today = ScheduleDay.today()
        for (k, v) in [("from", from), ("to", to)] {
            if let v, !v.isEmpty, !ScheduleDay.isValid(v) { throw MCPInvalidParams("\(k) must be YYYY-MM-DD, got \(v)") }
        }
        guard ["all", "open", "done"].contains(status) else { throw MCPInvalidParams("status must be all, open or done") }
        let plan = try planId.flatMap { $0.isEmpty ? nil : try resolvePlan($0, in: ws) }
        let f = from.flatMap { $0.isEmpty ? nil : $0 }
        let t = to.flatMap { $0.isEmpty ? nil : $0 }
        var start = f ?? today
        var end = t ?? ScheduleDay.adding(13, to: start) ?? start
        if end < start { swap(&start, &end) }
        if let n = ScheduleDay.days(from: start, to: end), n > 366 { end = ScheduleDay.adding(366, to: start) ?? end }
        var items: [LibScheduleItem]
        if let plan, f == nil, t == nil {
            items = ws.scheduleItems(planId: plan.id)
            let days = items.map(\.day).filter { !$0.isEmpty }
            if let a = days.min(), let b = days.max() { start = a; end = b }
        } else {
            items = ws.scheduleItems(from: start, to: end, planId: plan?.id)
            if includeOverdue {
                items = ws.overdueScheduleItems(before: min(start, today)).filter { plan == nil || $0.planId == plan!.id } + items
            }
            if includeUndated { items += ws.undatedScheduleItems.filter { plan == nil || $0.planId == plan!.id } }
        }
        var seen = Set<String>()
        items = items.filter { seen.insert($0.id).inserted }
        if status == "open" { items = items.filter { !$0.isDone } } else if status == "done" { items = items.filter(\.isDone) }
        let truncated = items.count > 500
        let counts = ws.schedulePlanCounts()
        let plans = ws.schedulePlans.filter { plan == nil || $0.id == plan!.id }.map { p -> MCPObject in
            let days = ws.scheduleItems(planId: p.id).map(\.day).filter { !$0.isEmpty }
            let c = counts[p.id] ?? (0, 0)
            return ["plan_id": p.id, "title": p.title, "goal": p.goal, "agent": p.agent, "items": c.total, "done": c.done,
                    "first_day": days.min() ?? NSNull(), "last_day": days.max() ?? NSNull(), "created_at": ISO.string(p.createdAt)]
        }
        return ["today": today, "from": start, "to": end, "plans": plans,
                "items": items.prefix(500).map { Self.scheduleItemDTO($0, today: today) }, "truncated": truncated]
    }

    static func scheduleItemDTO(_ m: LibScheduleItem, today: String) -> MCPObject {
        ["item_id": m.id, "plan_id": m.planId.isEmpty ? NSNull() : m.planId as Any, "title": m.title, "detail": m.detail,
         "day": m.day.isEmpty ? NSNull() : m.day as Any, "start": ScheduleTime.string(m.startMin) ?? NSNull() as Any,
         "duration_minutes": m.durationMin, "done": m.isDone, "done_at": m.doneAt.map(ISO.string) ?? NSNull() as Any,
         "result": m.result, "overdue": !m.isDone && !m.day.isEmpty && m.day < today, "agent": m.agent]
    }

    func addScheduleItems(_ drafts: [WorkspaceManager.ScheduleDraft], plan: (title: String, goal: String)?, planId: String?,
                          agent: String, workspacePath: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        var pid = ""
        if let planId, !planId.isEmpty {
            pid = try resolvePlan(planId, in: ws).id
        } else if let plan {
            guard !plan.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MCPInvalidParams("plan.title is required") }
            guard let p = ws.addSchedulePlan(title: plan.title, goal: plan.goal, agent: agent) else {
                throw MCPToolError(ws.lastError ?? "could not create the plan")
            }
            pid = p.id
        }
        guard let added = ws.addScheduleItems(drafts, planId: pid, agent: agent) else {
            throw MCPToolError(ws.lastError ?? "could not add the items")
        }
        return ["plan_id": pid.isEmpty ? NSNull() : pid as Any, "item_ids": added.map(\.id)]
    }

    func updateSchedule(items: [[String: Any]], plans: [[String: Any]], workspacePath: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        // 先全部校验、拼好，再一次写（一项不对整批不动）
        var changed: [LibScheduleItem] = []
        for (i, o) in items.enumerated() {
            guard let id = o["item_id"] as? String, !id.isEmpty else { throw MCPInvalidParams("items[\(i)].item_id is required") }
            var m = try resolveScheduleItem(id, in: ws)
            if let t = o["title"] as? String {
                guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MCPInvalidParams("items[\(i)].title can't be empty") }
                m.title = t
            }
            if let d = o["detail"] as? String { m.detail = d }
            if let day = o["day"] as? String {
                guard day.isEmpty || ScheduleDay.isValid(day) else { throw MCPInvalidParams("items[\(i)].day must be YYYY-MM-DD or empty") }
                m.day = day
            }
            if let s = o["start"] as? String {
                if s.isEmpty { m.startMin = -1 } else {
                    guard let v = ScheduleTime.minutes(s) else { throw MCPInvalidParams("items[\(i)].start must be HH:mm or empty") }
                    m.startMin = v
                }
            }
            if let n = o["duration_minutes"] as? Int { m.durationMin = max(0, min(n, 1440)) }
            else if let n = o["duration_minutes"] as? Double { m.durationMin = max(0, min(Int(n), 1440)) }
            if let done = o["done"] as? Bool, done != m.isDone { m.doneAt = done ? Date() : nil }
            if let r = o["result"] as? String { m.result = r }
            if let p = o["plan_id"] as? String { m.planId = p.isEmpty ? "" : try resolvePlan(p, in: ws).id }
            changed.append(m)
        }
        var plansUpdated = 0
        for (i, o) in plans.enumerated() {
            guard let id = o["plan_id"] as? String, !id.isEmpty else { throw MCPInvalidParams("plans[\(i)].plan_id is required") }
            let p = try resolvePlan(id, in: ws)
            let title = o["title"] as? String, goal = o["goal"] as? String
            guard title != nil || goal != nil else { continue }
            guard let saved = ws.updateSchedulePlan(id: p.id, title: title, goal: goal) else {
                throw MCPToolError(ws.lastError ?? "could not change the plan")
            }
            if saved != p { plansUpdated += 1 }
        }
        guard let written = ws.updateScheduleItems(changed) else { throw MCPToolError(ws.lastError ?? "could not change the items") }
        return ["updated": written.count, "unchanged": changed.count - written.count, "plans_updated": plansUpdated]
    }

    func deleteSchedule(itemIds: [String], planIds: [String], workspacePath: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        let items = try itemIds.map { try resolveScheduleItem($0, in: ws) }
        let plans = try planIds.map { try resolvePlan($0, in: ws) }
        let planSet = Set(plans.map(\.id))
        let total = items.filter { !planSet.contains($0.planId) }.count + plans.reduce(0) { $0 + ws.scheduleItems(planId: $1.id).count }
        guard ws.trashSchedule(planIds: plans.map(\.id), itemIds: items.map(\.id)) else {
            throw MCPToolError(ws.lastError ?? "could not delete")
        }
        return ["items": total, "plans": plans.count]
    }

    func openSchedule(day: String?, itemId: String?, workspacePath: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        if let day, !day.isEmpty, !ScheduleDay.isValid(day) { throw MCPInvalidParams("day must be YYYY-MM-DD") }
        let item = try itemId.flatMap { $0.isEmpty ? nil : try resolveScheduleItem($0, in: ws) }
        let d = day.flatMap { $0.isEmpty ? nil : $0 } ?? item.flatMap { $0.day.isEmpty ? nil : $0.day } ?? ScheduleDay.today()
        guard let app = AppDelegate.shared else { throw MCPToolError("UniReader is still starting up") }
        let (c, tab) = try app.showSchedule(focus: ScheduleFocus(day: d, itemId: item?.id), in: ws, activate: true)
        return ["window_id": c.windowId.uuidString, "session_id": tab.id.uuidString, "day": d]
    }

    /// 完整 id，或至少 8 个字符的前缀（唯一才算）。
    private func resolveScheduleItem(_ id: String, in ws: WorkspaceManager) throws -> LibScheduleItem {
        let key = id.trimmingCharacters(in: .whitespaces)
        if let m = ws.scheduleItem(id: key) ?? ws.scheduleItem(id: key.uppercased()) { return m }
        let hits = key.count >= 8 ? ws.scheduleItems(idPrefix: key) : []
        guard hits.count == 1 else {
            throw MCPToolError(hits.isEmpty ? "no schedule item with id \(id); call list_schedule"
                                            : "id \(id) matches several items; give the full id")
        }
        return hits[0]
    }

    private func resolvePlan(_ id: String, in ws: WorkspaceManager) throws -> LibSchedulePlan {
        let key = id.trimmingCharacters(in: .whitespaces)
        if let p = ws.schedulePlan(id: key) ?? ws.schedulePlan(id: key.uppercased()) { return p }
        let hits = key.count >= 8 ? ws.schedulePlans.filter { $0.id.uppercased().hasPrefix(key.uppercased()) } : []
        guard hits.count == 1 else {
            throw MCPToolError(hits.isEmpty ? "no plan with id \(id); call list_schedule" : "id \(id) matches several plans; give the full id")
        }
        return hits[0]
    }
}
