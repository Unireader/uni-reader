// 「删得太多先问」的判定（`Sources/Sync/SyncDeleteGuard.swift`，`SERVER-MODE-PLAN.md §4.6 / §13.13`）。运行：
//   O=/tmp/sdg; mkdir -p $O && cp spike/sync-delete-guard-test.swift $O/main.swift \
//   && swiftc Sources/Store/*.swift Sources/Sync/*.swift Sources/App/BackupRetention.swift $O/main.swift -o $O/t && $O/t
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

func del(_ table: String, _ n: Int, from: Int = 0) -> [SyncWire.RowChange] {
    (from..<(from + n)).map { SyncWire.RowChange(table: table, rowId: "\(table)-\($0)", op: .delete, baseFp: "x", row: nil) }
}
func up(_ table: String, _ n: Int) -> [SyncWire.RowChange] {
    (0..<n).map { SyncWire.RowChange(table: table, rowId: "u\($0)", op: .upsert, baseFp: nil, row: [:]) }
}
let base = ["note": 1000, "exercise": 40, "meta": 5]

check(SyncDeleteGuard.excess(in: up("note", 500), baseCounts: base) == nil, "只有新增 / 修改：不问")
check(SyncDeleteGuard.excess(in: del("note", 50), baseCounts: base) == nil, "删 50 行（1000 行里）：不问")
let x = SyncDeleteGuard.excess(in: del("note", 51) + up("note", 3), baseCounts: base)
check(x?.total == 51, "删 51 行：问（共 \(x?.total ?? -1) 行）")
check(SyncDeleteGuard.excess(in: del("exercise", 9), baseCounts: base) == nil, "小表删 9 行（不到 10 行）：不问")
let y = SyncDeleteGuard.excess(in: del("exercise", 10), baseCounts: base)
check(y != nil, "40 行的表删 10 行（25%）：问")
check(SyncDeleteGuard.excess(in: del("note", 30), baseCounts: base) == nil, "1000 行的表删 30 行（3%）：不问")
check(SyncDeleteGuard.excess(in: del("meta", 2), baseCounts: base) == nil, "只有几行的小表删 2 行：不问")
let z = SyncDeleteGuard.excess(in: del("note", 40) + del("exercise", 12), baseCounts: base)!
check(z.total == 52 && z.byTable.map(\.table) == ["note", "exercise"], "按表分开数，多的在前")
// 用户确认过的那一批放行；之后又多删了别的要重新问
check(SyncDeleteGuard.excess(in: del("note", 51), baseCounts: base, allowed: x!.keys) == nil, "确认过的同一批：放行")
check(SyncDeleteGuard.excess(in: del("note", 40), baseCounts: base, allowed: x!.keys) == nil, "确认过的那批里的一部分：放行")
check(SyncDeleteGuard.excess(in: del("note", 60), baseCounts: base, allowed: x!.keys) != nil, "比确认的多删了：重新问")
check(SyncDeleteGuard.excess(in: del("brand_new", 12), baseCounts: base) != nil, "基线里没有这张表的行数（当 0）：12 行也问")

print("\n通过 \(pass)，失败 \(fail)")
exit(fail == 0 ? 0 : 1)
