import Foundation
import QuartzCore

/// 滚动平滑跟随器（纯 tick 驱动，无 AppKit 依赖；由 `TimelineView(.animation)` 逐帧调用 `step`）。
/// 算法与 PDFKitView 时代完全一致（`spike/scroll-follow-sim.swift` / `scroll-follow-interp-sim.swift`
/// 验证的就是这套数学），**只跟随、不外推**：
///  · 本地(mac / 无发送端时间戳)：临界阻尼低通逼近最新锚点，输出恒为凸组合 → 零过冲、零反转。
///  · 平板(pad，带发送端时间戳)：最小延迟滤波估时钟差，把样本落到本地时间轴，渲染落后
///    `interpDelay` 线性插值，越过末样本则保持——对 WiFi 成批/抖动免疫。
final class ScrollFollower: ObservableObject {
    var pageCount = 0
    var interpEnabled = true
    /// 有活跃跟随时为 true（View 据此挂/摘 TimelineView 帧驱动）。
    @Published private(set) var isActive = false
    /// 程序化滚动进行中（View 据此抑制 Mac 锚点回发，防回环）。
    private(set) var isSuppressing = false

    private var smCurrent = 0.0, smTarget = 0.0
    private var lastAnchorAt: CFTimeInterval = 0
    private var lastStepAt: CFTimeInterval = 0

    // 时间戳插值状态（仅平板路径）
    private struct TSample { var t: Double; var pos: Double }
    private var buf: [TSample] = []
    private var clockOffset = 0.0
    private var haveOffset = false
    private var useInterp = false
    private let interpDelay = 0.08   // 渲染落后 80ms 吸收抖动/成批（越大越稳、越滞后）

    /// 应用来自 sim/平板/toc/restore/search 的锚点。首次激活时默认当帧对齐（restore/toc 即时到位）；
    /// `a.animate`（目前只有搜索切换命中）时从 `currentProgress` 起步，交给下面的低通滤波器动画飞过去。
    func apply(_ a: ScrollAnchor, currentProgress: Double? = nil) {
        let newTarget = Double(a.page) + a.frac
        let now = CACurrentMediaTime()
        lastAnchorAt = now
        isSuppressing = true

        if a.senderT > 0 && interpEnabled {                  // 平板：时间戳插值
            useInterp = true
            let ts = a.senderT / 1000.0
            let raw = now - ts
            if !haveOffset { clockOffset = raw; haveOffset = true }
            else if raw < clockOffset { clockOffset = raw }  // 最小延迟包最接近真实时钟差
            else { clockOffset += (raw - clockOffset) * 0.02 } // 缓慢上漂，吸收时钟漂移
            appendSample(TSample(t: ts + clockOffset, pos: newTarget))
        } else {                                             // 本地：纯低通
            useInterp = false
            smTarget = newTarget
        }
        if !isActive {
            // `animate` 时从当前位置起步交给下面 step() 的低通滤波器飞过去；否则维持原样
            // 当帧对齐（TOC/restore 要即时到位，没有 currentProgress 兜底时同样即时到位）。
            smCurrent = (a.animate ? currentProgress : nil) ?? newTarget
            lastStepAt = now
            isActive = true
        }
    }

    /// 文档切换/视图销毁时复位。
    func reset() {
        isActive = false
        smCurrent = 0; smTarget = 0; lastAnchorAt = 0
        buf.removeAll(); useInterp = false; haveOffset = false; clockOffset = 0
        isSuppressing = false
    }

    /// 每帧调用；返回本帧全局进度（page+frac）。收敛后输出精确终点、自动停机，之后返回 nil。
    func step(now: CFTimeInterval) -> Double? {
        guard isActive, pageCount > 0 else { isActive = false; return nil }
        var dt = now - lastStepAt; lastStepAt = now
        if dt <= 0 || dt > 0.1 { dt = 1.0 / 120.0 }

        let target: Double
        let catchup: Double
        if useInterp {
            target = sampleAt(now - interpDelay)             // 落后 interpDelay 的插值位（不外推）
            catchup = min(1.0, 60.0 * dt)                    // 快低通(~15ms)只为平掉迟到包台阶
        } else {
            target = smTarget
            catchup = min(1.0, 22.0 * dt)                    // 本地低通（时间常数 ~45ms）
        }
        smCurrent += (target - smCurrent) * catchup

        let maxPos = Double(pageCount - 1) + 0.9999
        smCurrent = min(max(0, smCurrent), maxPos)

        // 收敛且久无新锚点 → 精确对齐、停机，随后解除抑制。
        let finalTarget = useInterp ? (buf.last?.pos ?? smCurrent) : smTarget
        if abs(finalTarget - smCurrent) < 0.0005, now - lastAnchorAt > 0.2 {
            smCurrent = min(max(0, finalTarget), maxPos)
            isActive = false
            buf.removeAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, !self.isActive else { return }
                self.isSuppressing = false
            }
        }
        return smCurrent
    }

    private func appendSample(_ s: TSample) {
        if let last = buf.last, s.t < last.t - 1.0 { return }   // 太老的迟到包丢弃
        buf.append(s)
        if buf.count >= 2 && buf[buf.count - 1].t < buf[buf.count - 2].t { buf.sort { $0.t < $1.t } }
        let cutoff = s.t - 1.5
        while buf.count > 2 && buf.first!.t < cutoff { buf.removeFirst() }
    }

    /// 在本地时间轴 t 处线性插值；早于首样本→首样本；**晚于末样本→保持(不外推)**。
    private func sampleAt(_ t: Double) -> Double {
        guard let first = buf.first, let last = buf.last else { return smCurrent }
        if t <= first.t { return first.pos }
        if t >= last.t { return last.pos }
        for i in 1..<buf.count where buf[i].t >= t {
            let a = buf[i - 1], b = buf[i]
            let span = b.t - a.t
            let u = span > 1e-6 ? (t - a.t) / span : 0
            return a.pos + (b.pos - a.pos) * u
        }
        return last.pos
    }
}
