import Foundation

extension Notification.Name {
    /// 某个工作区的日程变了（加 / 改 / 打勾 / 删 / 同步拉来 / 回收站放回；object = 那个工作区）。日程页、Inspector「今天」据此重读。
    static let scheduleDidChange = Notification.Name("UniReader.scheduleDidChange")
}

/// 日程的执行层（`SCHEDULE-PLAN.md`）：`schedule_plan`、`schedule_item` 两张表（v26）的读写。
/// 写入口：日程页 / Inspector「今天」（用户自己加、改、打勾、拖到别的日子）、MCP（Agent 排计划、挪日子、打勾）。
/// 删除一律先进回收站（红线⑪）。同步不用另做：两张表都在 `MirrorFp.specs` 里。
extension WorkspaceManager {

    /// 新事项的草稿（日程页「添加」、MCP `add_schedule_items` 共用）。
    struct ScheduleDraft {
        var title: String
        var day: String = ""
        var startMin: Int = -1
        var durationMin: Int = 0
        var detail: String = ""
    }

    // MARK: 读

    var schedulePlans: [LibSchedulePlan] { (try? store?.schedulePlans()) ?? [] }
    func schedulePlan(id: String) -> LibSchedulePlan? { try? store?.schedulePlan(id: id) }
    func schedulePlanCounts() -> [String: (total: Int, done: Int)] { (try? store?.schedulePlanCounts()) ?? [:] }
    func scheduleItem(id: String) -> LibScheduleItem? { try? store?.scheduleItem(id: id) }
    func scheduleItems(from: String, to: String, planId: String? = nil) -> [LibScheduleItem] {
        (try? store?.scheduleItems(from: from, to: to, planId: planId)) ?? []
    }
    func scheduleItems(planId: String) -> [LibScheduleItem] { (try? store?.scheduleItems(planId: planId)) ?? [] }
    func scheduleItems(idPrefix: String) -> [LibScheduleItem] { (try? store?.scheduleItems(idPrefix: idPrefix)) ?? [] }
    var undatedScheduleItems: [LibScheduleItem] { (try? store?.undatedScheduleItems()) ?? [] }
    func overdueScheduleItems(before day: String = ScheduleDay.today()) -> [LibScheduleItem] {
        (try? store?.overdueScheduleItems(before: day)) ?? []
    }

    // MARK: 写

    /// 建一份计划。返回存下的那份（写不进去 = nil，原因在 `lastError`）。
    @discardableResult
    func addSchedulePlan(title: String, goal: String, agent: String) -> LibSchedulePlan? {
        guard let store else { return nil }
        let t = Self.clean(title, max: ScheduleText.titleMax)
        guard !t.isEmpty else { lastError = L("A plan needs a name."); return nil }
        let now = Date()
        let p = LibSchedulePlan(id: UUID().uuidString, title: t, goal: Self.clean(goal, max: ScheduleText.detailMax),
                                agent: agent, createdAt: now, updatedAt: now)
        do { try store.upsertSchedulePlan(p) } catch { lastError = "\(error)"; return nil }
        scheduleChanged()
        return p
    }

    /// 改计划的名字 / 目标（nil = 不改）。没变就不写。
    @discardableResult
    func updateSchedulePlan(id: String, title: String?, goal: String?) -> LibSchedulePlan? {
        guard let store, var p = schedulePlan(id: id) else { return nil }
        var changed = false
        if let title {
            let t = Self.clean(title, max: ScheduleText.titleMax)
            guard !t.isEmpty else { lastError = L("A plan needs a name."); return nil }
            if t != p.title { p.title = t; changed = true }
        }
        if let goal {
            let g = Self.clean(goal, max: ScheduleText.detailMax)
            if g != p.goal { p.goal = g; changed = true }
        }
        guard changed else { return p }
        p.updatedAt = .now
        do { try store.upsertSchedulePlan(p) } catch { lastError = "\(error)"; return nil }
        scheduleChanged()
        return p
    }

    /// 加几件事（一个事务）。`planId` 空 = 不属于哪份计划。同一天里新加的排在已有的后面，按给的先后。
    /// 标题空的跳过。返回存下的那些（写不进去 = nil）。
    @discardableResult
    func addScheduleItems(_ drafts: [ScheduleDraft], planId: String, agent: String) -> [LibScheduleItem]? {
        guard let store else { return nil }
        let now = Date()
        var nextSeq: [String: Int] = [:]
        var out: [LibScheduleItem] = []
        for (i, d) in drafts.enumerated() {
            let title = Self.clean(d.title, max: ScheduleText.titleMax)
            guard !title.isEmpty else { continue }
            let day = ScheduleDay.isValid(d.day) ? d.day : ""
            let seq: Int
            if let n = nextSeq[day] { seq = n } else { seq = (try? store.nextScheduleSeq(day: day)) ?? 1 }
            nextSeq[day] = seq + 1
            // 同一批里 `created_at` 依次加 1 毫秒：排序的最后一级按它，保住给的先后
            let at = now.addingTimeInterval(Double(i) / 1000)
            out.append(LibScheduleItem(id: UUID().uuidString, planId: planId, title: title,
                                       detail: Self.clean(d.detail, max: ScheduleText.detailMax), day: day,
                                       startMin: (0..<1440).contains(d.startMin) ? d.startMin : -1,
                                       durationMin: max(0, min(d.durationMin, 24 * 60)), doneAt: nil, result: "",
                                       seq: seq, agent: agent, createdAt: at, updatedAt: at))
        }
        guard !out.isEmpty else { lastError = L("Nothing to add: every item needs a title."); return nil }
        do { try store.upsertScheduleItems(out) } catch { lastError = "\(error)"; return nil }
        scheduleChanged()
        return out
    }

    /// 写回改过的几件（整行，按 id）。跟库里一样的不写（免得 `updated_at` 白变、同步白传）；
    /// 挪到别的日子的排到那天最后（除非调用方自己给了 `seq`）。返回真改了的那些。
    @discardableResult
    func updateScheduleItems(_ items: [LibScheduleItem]) -> [LibScheduleItem]? {
        guard let store else { return nil }
        let now = Date()
        var out: [LibScheduleItem] = []
        var nextSeq: [String: Int] = [:]
        for var m in items {
            guard let old = scheduleItem(id: m.id) else { continue }
            m.title = Self.clean(m.title, max: ScheduleText.titleMax)
            if m.title.isEmpty { m.title = old.title }
            m.detail = Self.clean(m.detail, max: ScheduleText.detailMax)
            m.result = Self.clean(m.result, max: ScheduleText.detailMax)
            if !m.day.isEmpty, !ScheduleDay.isValid(m.day) { m.day = old.day }
            if !(0..<1440).contains(m.startMin) { m.startMin = -1 }
            m.durationMin = max(0, min(m.durationMin, 24 * 60))
            m.createdAt = old.createdAt
            m.updatedAt = old.updatedAt
            guard m != old else { continue }
            if m.day != old.day, m.seq == old.seq {
                let n = nextSeq[m.day] ?? ((try? store.nextScheduleSeq(day: m.day)) ?? 1)
                m.seq = n
                nextSeq[m.day] = n + 1
            }
            m.updatedAt = now
            out.append(m)
        }
        guard !out.isEmpty else { return [] }
        do { try store.upsertScheduleItems(out) } catch { lastError = "\(error)"; return nil }
        scheduleChanged()
        return out
    }

    /// 打勾 / 取消打勾。
    @discardableResult
    func setScheduleDone(ids: [String], done: Bool) -> Bool {
        let rows = ids.compactMap(scheduleItem(id:)).filter { $0.isDone != done }
        guard !rows.isEmpty else { return true }
        let now = Date()
        return updateScheduleItems(rows.map { var m = $0; m.doneAt = done ? now : nil; return m }) != nil
    }

    /// 挪到别的日子（空串 = 不排日期）。定的时间保留。
    @discardableResult
    func moveScheduleItems(ids: [String], to day: String) -> Bool {
        guard day.isEmpty || ScheduleDay.isValid(day) else { return false }
        let rows = ids.compactMap(scheduleItem(id:)).filter { $0.day != day }
        guard !rows.isEmpty else { return true }
        return updateScheduleItems(rows.map { var m = $0; m.day = day; return m }) != nil
    }

    /// 删几份计划（连同名下的事项）和几件事项：**先归档进回收站，成功了才删**（红线⑪）。归档失败 = 一样都不删。
    @discardableResult
    func trashSchedule(planIds: [String], itemIds: [String]) -> Bool {
        guard let store else { return false }
        let plans = planIds.compactMap(schedulePlan(id:))
        let planSet = Set(plans.map(\.id))
        let items = itemIds.compactMap(scheduleItem(id:)).filter { !planSet.contains($0.planId) }
        guard !plans.isEmpty || !items.isEmpty else { return true }
        let title: String
        if plans.count == 1, items.isEmpty {
            title = plans[0].title
        } else if plans.isEmpty, items.count == 1 {
            title = items[0].title
        } else if items.isEmpty {
            title = String(format: L("%d plans"), plans.count)
        } else {
            title = String(format: L("%d schedule items"), items.count + plans.count)
        }
        guard Trash.archiveSchedule(store: store, planIds: plans.map(\.id), itemIds: items.map(\.id), title: title) != nil else {
            lastError = String(format: L("Could not archive “%@”, so nothing was deleted."), title)
            return false
        }
        do { try store.deleteSchedule(planIds: plans.map(\.id), itemIds: items.map(\.id)) } catch {
            lastError = "\(error)"
            return false
        }
        scheduleChanged()
        return true
    }

    func scheduleChanged() {
        NotificationCenter.default.post(name: .scheduleDidChange, object: self)
    }

    /// 随新对话第一句话带上的那一行（`ScheduleText.agentLine`）。
    func scheduleAgentLine() -> String? {
        let today = ScheduleDay.today()
        return ScheduleText.agentLine(today: today, todayItems: scheduleItems(from: today, to: today),
                                      overdue: overdueScheduleItems(before: today).count, plans: schedulePlans.count)
    }

    private static func clean(_ s: String, max: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > max ? String(t.prefix(max)) : t
    }
}
