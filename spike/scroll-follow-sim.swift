import Foundation

// ============================================================================
// 复现 PDFKitView.Coordinator 的滚动跟随算法，用合成的「平板上滑→停」锚点流
// （带 WiFi 突发到达）驱动，对比【当前(速度外推)】与【修复(纯临界阻尼)】的输出。
// 全局进度 pos = page + frac。上滑 = pos 减小。
// ============================================================================

// ---- 平板真实运动：pos 从 5.0 上滑到 3.0，0.8s ease-out，然后静止 ----
let startPos = 5.0, endPos = 3.0, moveDur = 0.8, simDur = 1.8
func trueMotion(_ t: Double) -> Double {
    if t <= 0 { return startPos }
    if t >= moveDur { return endPos }
    let u = t / moveDur
    let ease = 1 - (1 - u) * (1 - u)          // ease-out：末段减速，像手指抬起前
    return startPos + (endPos - startPos) * ease
}

// ---- 平板 60Hz 采样发 scroll；网络每 80ms 成批投递（突发），批内各包相隔 0.4ms
//      （模拟主 runloop 连续处理排队的 WS 消息）----
struct Anchor { var arrival: Double; var target: Double }
let emitHz = 60.0, burstInterval = 0.08, baseLatency = 0.04, intraBurst = 0.0004

var anchors: [Anchor] = []
do {
    var pending: [Double] = []                // 待投递样本的 target
    var nextBurst = burstInterval
    var k = 0
    while true {
        let te = Double(k) / emitHz
        if te > moveDur { break }             // 手指抬起后不再发 scroll
        pending.append(trueMotion(te))
        if te >= nextBurst {
            let arr = te + baseLatency
            for (j, tgt) in pending.enumerated() {
                anchors.append(Anchor(arrival: arr + Double(j) * intraBurst, target: tgt))
            }
            pending.removeAll(); nextBurst += burstInterval
        }
        k += 1
    }
    if !pending.isEmpty {
        let arr = moveDur + baseLatency
        for (j, tgt) in pending.enumerated() {
            anchors.append(Anchor(arrival: arr + Double(j) * intraBurst, target: tgt))
        }
    }
}

// ---- 当前算法：速度外推 + catchup（= 现有 PDFKitView 代码逐行搬来）----
final class SmoothCurrent {
    var smCurrent = 0.0, smTarget = 0.0, smVel = 0.0
    var lastAnchorAt = 0.0, lastStepAt = 0.0, started = false
    func onAnchor(_ target: Double, now: Double) {
        let dt = now - lastAnchorAt
        if lastAnchorAt > 0, dt > 0, dt < 0.2 {
            let instVel = (target - smTarget) / dt
            smVel = smVel * 0.4 + instVel * 0.6
        }
        smTarget = target; lastAnchorAt = now
        if !started { smCurrent = target; started = true; lastStepAt = now }
    }
    func step(now: Double) -> Double {
        var frameDt = now - lastStepAt; lastStepAt = now
        if frameDt <= 0 || frameDt > 0.1 { frameDt = 1.0 / 120.0 }
        let stale = now - lastAnchorAt
        if stale > 0.12 { smVel *= 0.85 }
        let predicted = smCurrent + smVel * frameDt
        let catchup = min(1.0, 18.0 * frameDt)
        smCurrent = predicted + (smTarget - predicted) * catchup
        // 真实代码里的边界钳制（文档 20 页 → [0, 19.9999]）：过冲会“撞顶”到 pos=0
        let maxPos = 19.9999
        if smCurrent < 0 { smCurrent = 0; smVel = 0 }
        if smCurrent > maxPos { smCurrent = maxPos; smVel = 0 }
        return smCurrent
    }
}

// ---- 修复算法：去掉速度外推，纯临界阻尼低通（收敛到最新锚点，永不过冲）----
final class SmoothFixed {
    var smCurrent = 0.0, smTarget = 0.0, lastStepAt = 0.0, started = false
    func onAnchor(_ target: Double, now: Double) {
        smTarget = target
        if !started { smCurrent = target; started = true; lastStepAt = now }
    }
    func step(now: Double) -> Double {
        var frameDt = now - lastStepAt; lastStepAt = now
        if frameDt <= 0 || frameDt > 0.1 { frameDt = 1.0 / 120.0 }
        let catchup = min(1.0, 22.0 * frameDt)   // 时间常数 ~45ms
        smCurrent += (smTarget - smCurrent) * catchup
        return smCurrent
    }
}

// ---- Mac 120Hz 帧循环，按 arrival 注入锚点 ----
let macHz = 120.0
let cur = SmoothCurrent(), fix = SmoothFixed()
var outCur: [(Double, Double)] = [], outFix: [(Double, Double)] = []
var ai = 0, frame = 0
while true {
    let now = Double(frame) / macHz
    if now > simDur { break }
    while ai < anchors.count && anchors[ai].arrival <= now {
        cur.onAnchor(anchors[ai].target, now: anchors[ai].arrival)
        fix.onAnchor(anchors[ai].target, now: anchors[ai].arrival)
        ai += 1
    }
    if cur.started { outCur.append((now, cur.step(now: now))) }
    if fix.started { outFix.append((now, fix.step(now: now))) }
    frame += 1
}

// ---- 指标 ----
func analyze(_ name: String, _ out: [(Double, Double)]) {
    let target = endPos
    let minPos = out.map { $0.1 }.min() ?? target
    // 上滑方向的过冲：越过最终目标 3.0 继续往上（更小）多少
    let overshoot = max(0, target - minPos)
    // 撤回方向的反弹：越过起点上方后又往下回弹多少（相邻帧方向反转，且发生在“停下”之后）
    var reversals = 0
    var maxFrameJump = 0.0
    for i in 1..<out.count {
        let d = out[i].1 - out[i-1].1
        let dp = out[i-1].1 - (i >= 2 ? out[i-2].1 : out[i-1].1)
        if i >= 2 && d * dp < 0 && abs(d) > 0.002 { reversals += 1 }
        maxFrameJump = max(maxFrameJump, abs(d))
    }
    // 稳态：最后 0.2s 是否停在 3.0
    let settle = out.suffix(24).map { $0.1 }.reduce(0, +) / Double(max(1, out.suffix(24).count))
    print(String(format: "  %@", name))
    print(String(format: "    过冲(越过目标继续上滑, 页): %.3f   最深到达 pos=%.3f (目标 %.2f)", overshoot, minPos, target))
    print(String(format: "    方向反转次数(撤回/抖动)     : %d", reversals))
    print(String(format: "    单帧最大跳变(闪回幅度, 页)   : %.3f", maxFrameJump))
    print(String(format: "    稳态位置(末段均值)          : %.3f", settle))
}

print("锚点总数: \(anchors.count)  投递批数≈\(Int(moveDur/burstInterval))")
print("目标运动: pos 5.00 → 3.00（上滑），0.8s 后静止\n")
print("【当前算法：速度外推 + catchup】")
analyze("current", outCur)
print("\n【修复算法：纯临界阻尼低通】")
analyze("fixed", outFix)

// ---- 输出轨迹（每 6 帧采一点，看停下后是否回弹）----
print("\n轨迹对比 (t | current | fixed)，关注 t>0.85 是否“越过后回弹”：")
for i in stride(from: 0, to: min(outCur.count, outFix.count), by: 8) {
    let t = outCur[i].0
    if t < 0.7 { continue }
    let c = outCur[i].1, f = outFix[i].1
    let mark = (i >= 8 && (outCur[i].1 - outCur[i-8].1) > 0.01) ? "  <== current 往回撤" : ""
    print(String(format: "  %.2fs | %.3f | %.3f%@", t, c, f, mark))
}
