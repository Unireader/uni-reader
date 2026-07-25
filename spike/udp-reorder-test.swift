// UDP 重排（UDPReorder）确定性单测——无网络、可复现。
// 编译运行（项目根目录）：
//   swiftc spike/udp-reorder-test.swift Sources/Server/UDPReorder.swift -o /tmp/urt && /tmp/urt
// 覆盖：REL 顺序交付 / 乱序重排+NACK 缺口 / 重复丢弃 / flushStale 超时跳过 / UNREL 最新胜。
import Foundation

var pass = 0, fail = 0
func check(_ name: String, _ cond: Bool) {
    if cond { pass += 1 } else { print("✗ \(name)"); fail += 1 }
}
func body(_ s: String) -> Data { Data(s.utf8) }
func strs(_ ds: [Data]) -> [String] { ds.map { String(decoding: $0, as: UTF8.self) } }

let t0 = Date(timeIntervalSince1970: 1000)

@main
struct UDPReorderTest {
    static func main() {
        // —— 1. REL 顺序直达：无缓冲、无 NACK ——
        do {
            var r = UDPReorder()
            let a = r.reliable(1, body("a"), now: t0)
            let b = r.reliable(2, body("b"), now: t0)
            check("顺序交付 a", strs(a.deliver) == ["a"] && a.nack.isEmpty)
            check("顺序交付 b", strs(b.deliver) == ["b"] && b.nack.isEmpty)
            check("顺序后 relExpected=3", r.relExpected == 3 && r.relBuf.isEmpty)
        }

        // —— 2. REL 乱序：先入缓冲报缺口，补齐后连排交付 ——
        do {
            var r = UDPReorder()
            let s3 = r.reliable(3, body("c"), now: t0)          // 缺口 1,2
            check("乱序 3 缓冲+nack[1,2]", s3.deliver.isEmpty && s3.nack == [1, 2])
            let s2 = r.reliable(2, body("b"), now: t0)          // 缺口 1
            check("乱序 2 缓冲+nack[1]", s2.deliver.isEmpty && s2.nack == [1])
            let s1 = r.reliable(1, body("a"), now: t0)          // 补齐 → 排空
            check("补齐后连排交付 a,b,c", strs(s1.deliver) == ["a", "b", "c"] && s1.nack.isEmpty)
            check("排空后 relExpected=4", r.relExpected == 4 && r.relBuf.isEmpty)
        }

        // —— 3. 重复包：已交付的旧 seq 丢弃；缓冲内重复保留先到者 ——
        do {
            var r = UDPReorder()
            _ = r.reliable(1, body("a"), now: t0)
            let dup = r.reliable(1, body("a2"), now: t0)
            check("已交付重复丢弃", dup.deliver.isEmpty && dup.nack.isEmpty)
            _ = r.reliable(3, body("c"), now: t0)               // 缓冲 3
            let dupBuf = r.reliable(3, body("c2"), now: t0)     // 重复乱序包
            check("缓冲重复不交付", dupBuf.deliver.isEmpty)
            let s2 = r.reliable(2, body("b"), now: t0)
            check("缓冲重复保留先到者", strs(s2.deliver) == ["b", "c"])
        }

        // —— 4. 迟到包（被 flushStale 跳过后才到）：按重复丢弃 ——
        do {
            var r = UDPReorder(now: t0)
            _ = r.reliable(3, body("c"), now: t0)               // 缺口 1,2
            let flushed = r.flushStale(now: t0.addingTimeInterval(0.3))  // >200ms
            check("flushStale 跳到 3 交付", strs(flushed) == ["c"] && r.relExpected == 4)
            let late = r.reliable(2, body("b"), now: t0)
            check("迟到包按重复丢弃", late.deliver.isEmpty && late.nack.isEmpty)
            let s4 = r.reliable(4, body("d"), now: t0)
            check("跳过后流继续", strs(s4.deliver) == ["d"])
        }

        // —— 5. flushStale 未超时 / 缓冲空：不动 ——
        do {
            var r = UDPReorder(now: t0)
            check("空缓冲 flush 空", r.flushStale(now: t0.addingTimeInterval(10)).isEmpty)
            _ = r.reliable(2, body("b"), now: t0)
            check("未超时不跳过", r.flushStale(now: t0.addingTimeInterval(0.1)).isEmpty && r.relExpected == 1)
            // 有推进后重新计时：交付 1,2 后又来 4，lastAdvance 更新，旧缺口计时失效
            _ = r.reliable(1, body("a"), now: t0.addingTimeInterval(0.15))
            _ = r.reliable(4, body("d"), now: t0.addingTimeInterval(0.15))
            check("推进后重新计时", r.flushStale(now: t0.addingTimeInterval(0.3)).isEmpty)
            check("新计时超时才跳", strs(r.flushStale(now: t0.addingTimeInterval(0.4))) == ["d"])
        }

        // —— 6. UNREL 最新胜 ——
        do {
            var r = UDPReorder()
            check("UNREL 首包放行", r.unreliable(5, body("s5")) != nil)
            check("UNREL 旧包丢弃", r.unreliable(4, body("s4")) == nil)
            check("UNREL 同 seq 丢弃", r.unreliable(5, body("s5b")) == nil)
            check("UNREL 新包放行", String(decoding: r.unreliable(6, body("s6"))!, as: UTF8.self) == "s6")
            check("UNREL lastUnrel=6", r.lastUnrel == 6)
        }

        // —— 7. UNREL 与 REL 互不影响（独立 seq 空间）——
        do {
            var r = UDPReorder()
            _ = r.unreliable(100, body("u"))
            let rel = r.reliable(1, body("a"), now: t0)
            check("UNREL 高 seq 不影响 REL", strs(rel.deliver) == ["a"])
            _ = r.reliable(50, body("z"), now: t0)               // REL 缓冲高 seq
            check("REL 缓冲不影响 UNREL", r.unreliable(101, body("u2")) != nil)
        }

        // —— 8. 回归：交付后静置 >stallMs 再出缺口，不得立即跳过（NACK 窗口要留足）——
        do {
            var r = UDPReorder(now: t0)
            _ = r.reliable(1, body("a"), now: t0)
            _ = r.reliable(2, body("b"), now: t0)
            // 静置 1s 后来了乱序的 4（缺口 3 刚出现）
            _ = r.reliable(4, body("d"), now: t0.addingTimeInterval(1.0))
            check("静置后新缺口不立即跳过", r.flushStale(now: t0.addingTimeInterval(1.1)).isEmpty)
            // NACK 重传在窗口内补齐 → 正常连排交付
            let fix = r.reliable(3, body("c"), now: t0.addingTimeInterval(1.12))
            check("窗口内补齐仍按序", strs(fix.deliver) == ["c", "d"])
        }

        print("—")
        print("udp-reorder: \(pass) 通过, \(fail) 失败")
        exit(fail == 0 ? 0 : 1)
    }
}
