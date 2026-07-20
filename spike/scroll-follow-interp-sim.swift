import Foundation

// ============================================================================
// 验证【时间戳插值】跟随：同一份「上滑→停」运动 + WiFi 成批到达，对比三者：
//   A 旧·速度外推        （闪回/撤回）
//   B 纯低通（当前默认）  （无过冲，稳态有滞后）
//   C 时间戳插值 + 快低通 （无过冲，运动中更贴、滞后更小）
// 位置 pos = page + frac；上滑 = pos 减小。发送端戳用平板本地时钟(ms)。
// ============================================================================

let startPos = 5.0, endPos = 3.0, moveDur = 0.8, simDur = 1.8
func trueMotion(_ t: Double) -> Double {
    if t <= 0 { return startPos }
    if t >= moveDur { return endPos }
    let u = t / moveDur
    return startPos + (endPos - startPos) * (1 - (1 - u) * (1 - u))
}

// 平板 60Hz 发；**恶劣 WiFi**：投递间隔在 40~200ms 间乱跳、偶发 260ms 卡顿，批内相隔 0.4ms；
// 发送端戳=平板本地时钟(与 Mac 差 12.34s，算法须自估掉)。种子 LCG 保证可复现。
struct Anchor { var arrival: Double; var target: Double; var senderMs: Double }
let emitHz = 60.0, baseLatency = 0.04, intraBurst = 0.0004
let clockSkew = 12.34

var seed: UInt64 = 0x9E3779B97F4A7C15
func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }

var anchors: [Anchor] = []
do {
    var pending: [(te: Double, tgt: Double)] = []
    var nextBurst = 0.06, k = 0
    func flush(_ at: Double) {
        for (j, p) in pending.enumerated() {
            anchors.append(Anchor(arrival: at + Double(j) * intraBurst,
                                  target: p.tgt, senderMs: (p.te + clockSkew) * 1000.0))
        }
        pending.removeAll()
    }
    while true {
        let te = Double(k) / emitHz
        if te > moveDur { break }
        pending.append((te, trueMotion(te)))
        if te >= nextBurst {
            let stall = rnd() < 0.15 ? 0.26 : 0.0           // 15% 概率一次长卡顿
            flush(te + baseLatency + stall)
            nextBurst += 0.04 + rnd() * 0.16                // 下次投递 40~200ms 后
        }
        k += 1
    }
    if !pending.isEmpty { flush(moveDur + baseLatency) }
    anchors.sort { $0.arrival < $1.arrival }               // 卡顿会打乱到达序，按到达重排
}

// ---- A 旧·速度外推 ----
final class A {
    var cur = 0.0, tgt = 0.0, vel = 0.0, lastAnchor = 0.0, lastStep = 0.0, started = false
    func onAnchor(_ target: Double, now: Double) {
        let dt = now - lastAnchor
        if lastAnchor > 0, dt > 0, dt < 0.2 { vel = vel*0.4 + ((target - tgt)/dt)*0.6 }
        tgt = target; lastAnchor = now
        if !started { cur = target; started = true; lastStep = now }
    }
    func step(now: Double) -> Double {
        var dt = now - lastStep; lastStep = now
        if dt <= 0 || dt > 0.1 { dt = 1.0/120 }
        if now - lastAnchor > 0.12 { vel *= 0.85 }
        let pred = cur + vel*dt
        cur = pred + (tgt - pred) * min(1.0, 18*dt)
        cur = min(max(0, cur), 19.9999)
        return cur
    }
}

// ---- B 纯低通 ----
final class B {
    var cur = 0.0, tgt = 0.0, lastStep = 0.0, started = false
    func onAnchor(_ target: Double, now: Double) { tgt = target; if !started { cur = target; started = true; lastStep = now } }
    func step(now: Double) -> Double {
        var dt = now - lastStep; lastStep = now
        if dt <= 0 || dt > 0.1 { dt = 1.0/120 }
        cur += (tgt - cur) * min(1.0, 22*dt)
        return min(max(0, cur), 19.9999)
    }
}

// ---- C 时间戳插值（复刻 Coordinator 逻辑）----
final class C {
    struct S { var t: Double; var pos: Double }
    var buf: [S] = [], cur = 0.0, offset = 0.0, haveOff = false, lastStep = 0.0, started = false
    let delay = 0.08
    func onAnchor(senderMs: Double, target: Double, now: Double) {
        let ts = senderMs/1000.0, raw = now - ts
        if !haveOff { offset = raw; haveOff = true }
        else if raw < offset { offset = raw } else { offset += (raw - offset)*0.02 }
        let s = S(t: ts + offset, pos: target)
        if let last = buf.last, s.t < last.t - 1.0 { return }
        buf.append(s)
        if buf.count >= 2 && buf[buf.count-1].t < buf[buf.count-2].t { buf.sort { $0.t < $1.t } }
        let cut = s.t - 1.5
        while buf.count > 2 && buf.first!.t < cut { buf.removeFirst() }
        if !started { cur = target; started = true; lastStep = now }
    }
    func sampleAt(_ t: Double) -> Double {
        guard let f = buf.first, let l = buf.last else { return cur }
        if t <= f.t { return f.pos }
        if t >= l.t { return l.pos }
        for i in 1..<buf.count where buf[i].t >= t {
            let a = buf[i-1], b = buf[i], span = b.t - a.t
            return a.pos + (b.pos - a.pos) * (span > 1e-6 ? (t - a.t)/span : 0)
        }
        return l.pos
    }
    func step(now: Double) -> Double {
        var dt = now - lastStep; lastStep = now
        if dt <= 0 || dt > 0.1 { dt = 1.0/120 }
        cur += (sampleAt(now - delay) - cur) * min(1.0, 60*dt)
        return min(max(0, cur), 19.9999)
    }
}

let macHz = 120.0
let a = A(), b = B(), c = C()
var oa: [(Double,Double)] = [], ob: [(Double,Double)] = [], oc: [(Double,Double)] = []
var ai = 0, frame = 0
while true {
    let now = Double(frame)/macHz
    if now > simDur { break }
    while ai < anchors.count && anchors[ai].arrival <= now {
        a.onAnchor(anchors[ai].target, now: anchors[ai].arrival)
        b.onAnchor(anchors[ai].target, now: anchors[ai].arrival)
        c.onAnchor(senderMs: anchors[ai].senderMs, target: anchors[ai].target, now: anchors[ai].arrival)
        ai += 1
    }
    if a.started { oa.append((now, a.step(now: now))) }
    if b.started { ob.append((now, b.step(now: now))) }
    if c.started { oc.append((now, c.step(now: now))) }
    frame += 1
}

// 真实运动在 Mac 时间轴上的“理想应显示位”= trueMotion(now - baseLatency)（最小延迟后的真值）
func ideal(_ t: Double) -> Double { trueMotion(max(0, t - baseLatency)) }

func stats(_ name: String, _ out: [(Double,Double)]) {
    let minPos = out.map { $0.1 }.min() ?? endPos
    let overshoot = max(0, endPos - minPos)
    var reversals = 0, maxJump = 0.0, lagSum = 0.0, lagN = 0.0
    for i in 1..<out.count {
        let d = out[i].1 - out[i-1].1, dp = i >= 2 ? out[i-1].1 - out[i-2].1 : 0
        if i >= 2 && d*dp < 0 && abs(d) > 0.002 { reversals += 1 }
        maxJump = max(maxJump, abs(d))
        if out[i].0 > 0.1 && out[i].0 < moveDur {           // 运动中的跟随滞后
            lagSum += abs(out[i].1 - ideal(out[i].0)); lagN += 1
        }
    }
    let follow = lagN > 0 ? lagSum/lagN : 0
    print(String(format: "  %-14@ 过冲%.2f页  反转%2d次  单帧跳%.3f页  运动中平均滞后%.3f页", name, overshoot, reversals, maxJump, follow))
}

print("场景：pos 5→3 上滑 0.8s 后停；恶劣WiFi(40~200ms乱跳+偶发260ms卡顿)；平板时钟比Mac快\(clockSkew)s（须自估掉）\n")
stats("A 速度外推", oa)
stats("B 纯低通",   ob)
stats("C 时间戳插值", oc)
print("\n轨迹 (t | 理想 | A外推 | B低通 | C插值)：")
for i in stride(from: 0, to: min(oa.count, ob.count, oc.count), by: 12) {
    let t = oa[i].0
    if t < 0.3 { continue }
    print(String(format: "  %.2f | %.3f | %.3f | %.3f | %.3f", t, ideal(t), oa[i].1, ob[i].1, oc[i].1))
}
