import Foundation

/// 「删得太多先问」（`SERVER-MODE-PLAN.md §4.6`）：一次推送里的**删除**超过阈值就先不推，等用户确认。
///
/// 为什么只拦推送、不拦拉取：服务器上的每一条删除都是某台设备推上去的，在那台设备上已经被这道闸问过了；
/// 拉取那一侧再问一遍只会让别的设备卡在「要不要接受我自己在另一台电脑上删的东西」上。
/// 纯函数（只依赖线格式），客户端在推送前调；服务器不管。
enum SyncDeleteGuard {
    /// 一次推送最多删这么多行，超过就问。
    static let maxRows = 50
    /// 或者某张表一次删掉它已同步行数的这么大一份（且至少 `minForShare` 行——只有三五行的小表删一两行不算）。
    static let maxShare = 0.2
    static let minForShare = 10

    struct Excess: Equatable {
        /// 这次推送一共要删几行。
        var total: Int
        /// 每张表几行（多的在前）。
        var byTable: [(table: String, count: Int)]
        /// 这批删除的身份（用户确认的就是这一批；之后又多删了别的要重新问）。
        var keys: Set<String>

        static func == (a: Excess, b: Excess) -> Bool { a.total == b.total && a.keys == b.keys }
    }

    static func key(_ c: SyncWire.RowChange) -> String { c.table + "\u{1}" + c.rowId }

    /// `baseCounts` = 每张表已同步的行数（`sync_base` 里的条数）。没超 → nil。
    /// `allowed` = 用户已经确认过的那批：这次的删除全在里面就放行。
    static func excess(in changes: [SyncWire.RowChange], baseCounts: [String: Int],
                       allowed: Set<String> = []) -> Excess? {
        let deletes = changes.filter { $0.op == .delete }
        guard !deletes.isEmpty else { return nil }
        let keys = Set(deletes.map(key))
        if keys.isSubset(of: allowed) { return nil }
        var per: [String: Int] = [:]
        for d in deletes { per[d.table, default: 0] += 1 }
        let tooMany = deletes.count > maxRows
        let bigShare = per.contains { table, n in
            n >= minForShare && Double(n) >= Double(baseCounts[table] ?? 0) * maxShare
        }
        guard tooMany || bigShare else { return nil }
        return Excess(total: deletes.count,
                      byTable: per.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                          .map { (table: $0.key, count: $0.value) },
                      keys: keys)
    }

    /// 推送被这道闸拦下了（关着工作区跑的那一轮没有界面可问，直接抛出来，由调度那边记成「等确认」）。
    struct Blocked: Error, Equatable { var excess: Excess }
}
