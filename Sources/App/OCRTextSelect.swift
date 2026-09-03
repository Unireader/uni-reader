import CoreGraphics

/// OCR 行内字符级选择的纯函数（无 UI 依赖，spike/ocr-char-select-test.swift 可测）。
///
/// 行内定位有两条精度路径，`bounds(_:)` 是**唯一入口**（命中与裁剪都走它，两边口径才一致）：
///
/// 1. **单字框**（`TextRun.chars`）——PP-OCRv6 `returnWordBox` 给的真实字位，首选；
/// 2. **等宽权重近似**（没有单字框时兜底）：CJK/全宽标点 1.0，ASCII 字母数字 0.55，空格 0.3，其余 0.8。
///    注意这条路对标点密集的行会系统性偏——全角标点排版实际比一个字窄，权重却按 1.0 算。
enum OCRTextSelect {

    // MARK: - 字符边界

    /// 这一行的字符边界：**行框内比例 0~1**，单调不减，`count == 字数 + 1`，首 0 末 1。
    /// 有可信的单字框就用单字框，否则按权重摊。
    static func bounds(_ run: TextRun) -> [Double] {
        let n = run.text.count
        guard n > 0 else { return [0] }
        if let c = run.chars, c.count == n + 1, isMonotonic(c) { return c }
        return weightBounds(run.text)
    }

    /// 边界数组是否可信：夹在 [0,1] 内且单调不减（落库的数据也可能来自别的端/旧版本，别信）。
    static func isMonotonic(_ b: [Double]) -> Bool {
        guard let f = b.first, let l = b.last, f >= -0.001, l <= 1.001 else { return false }
        return !zip(b, b.dropFirst()).contains { $0 > $1 + 1e-9 }
    }

    /// 每个字符的显示权重（无单字框时的兜底摊分）。
    static func charWeights(_ text: String) -> [Double] {
        text.map { c in
            guard let s = c.unicodeScalars.first else { return 0.8 }
            if s == " " { return 0.3 }
            return s.value >= 0x2E80 ? 1.0 : 0.55   // 0x2E80 起为 CJK 部首/假名/汉字/全宽标点区
        }
    }

    /// 权重摊出的字符边界（同 `bounds` 的约定：0~1、count = 字数+1）。
    static func weightBounds(_ text: String) -> [Double] {
        let w = charWeights(text)
        guard !w.isEmpty else { return [0] }
        let total = w.reduce(0, +)
        guard total > 0 else { return [0] + w.indices.map { Double($0 + 1) / Double(w.count) } }
        var out = [0.0], acc = 0.0
        for cw in w { acc += cw; out.append(acc / total) }
        return out
    }

    /// PP-OCRv6 `returnWordBox` 的单字框 → 字符边界（行框内比例 0~1）。
    ///
    /// - `words` 条目可能是多字（拉丁词 `"int"`、`"), "`），按条目框内等分摊给它的每个字符；
    /// - **只用框的中心、不用框宽**：中文字框宽是全行均值，标点/窄字母的框会退化成 1 个 CTC cell
    ///   的细条（实测 4~5px），宽度不可信；中心是 CTC 峰值列换算来的，是真的（量化抖动 ±7% 字宽）。
    /// - 边界取相邻字心的中点，两端夹到行框。
    ///
    /// 校验不过（字数对不上 / 拼不回行文本 / 行框退化）返回 nil，上层回落权重近似。
    /// 坐标系无关：`boxes` 与 `lineBox` 同系即可（像素或归一化都行），出参永远是行框内比例。
    static func boundsFromWordBoxes(lineText: String, words: [String],
                                    boxes: [CGRect], lineBox: CGRect) -> [Double]? {
        let n = lineText.count
        guard n > 0, !words.isEmpty, words.count == boxes.count,
              lineBox.width > 0, words.joined() == lineText else { return nil }

        // 每个条目在自己的框内等分出 k 个字心（k=1 时即框心）
        var centers: [Double] = []
        centers.reserveCapacity(n)
        for (w, b) in zip(words, boxes) {
            let k = w.count
            guard k > 0 else { continue }
            for j in 0..<k { centers.append(b.minX + (Double(j) + 0.5) * b.width / Double(k)) }
        }
        guard centers.count == n else { return nil }

        // 夹进行框 + 强制单调（CTC 列量化偶有并列/回退）
        var cursor = lineBox.minX
        for i in centers.indices {
            cursor = max(cursor, min(max(centers[i], lineBox.minX), lineBox.maxX))
            centers[i] = cursor
        }

        var out = [0.0]
        out.reserveCapacity(n + 1)
        for i in 1..<n {
            out.append(((centers[i - 1] + centers[i]) / 2 - lineBox.minX) / lineBox.width)
        }
        out.append(1.0)

        // 夹到 [0,1]、保单调，再收成 4 位小数——1/10000 行宽 ≈ 0.14px，远细于 CTC 列量化的 ±2.3px，
        // 但能把落库 JSON 从「0.42372881355932203」压到「0.4237」（一本书差好几 MB）。
        var prev = 0.0
        for i in out.indices {
            prev = max(prev, min(max(out[i], 0), 1))
            out[i] = (prev * 10000).rounded() / 10000
        }
        out[0] = 0
        out[n] = 1
        return out
    }

    // MARK: - 命中与裁剪

    /// 行内 x（页内归一化）→ 字符边界下标（0...count）。中点吸附：落点越过某字符中线即算到它后面。
    static func charOffset(in run: TextRun, atNX nx: Double) -> Int {
        let n = run.text.count
        guard n > 0, run.w > 0 else { return 0 }
        let b = bounds(run)
        guard b.count == n + 1 else { return 0 }
        let target = (nx - run.x) / run.w
        for i in 0..<n where target < (b[i] + b[i + 1]) / 2 { return i }
        return n
    }

    /// 行内字符区间 [lo, hi) → 子文本 + 子行框（高亮/批注锚框同步收窄）；空区间返回 nil。
    /// 单字框会一并切下来并按子区间重新归一化，子行框还能继续被裁。
    static func clip(run: TextRun, from lo: Int, to hi: Int) -> TextRun? {
        let chars = Array(run.text)
        let lo = max(0, min(lo, chars.count)), hi = max(lo, min(hi, chars.count))
        guard lo < hi else { return nil }
        let b = bounds(run)
        guard b.count == chars.count + 1 else { return nil }
        let x0 = run.x + b[lo] * run.w
        let x1 = run.x + b[hi] * run.w
        let span = b[hi] - b[lo]
        // 只有原行**真有**单字框才往下传；权重摊出来的不算「实测字位」，切完让下游继续按权重算即可
        // （逐字权重相互独立，子串重摊与整行切片完全等价，不会因此走样）。
        let sub = (run.chars != nil && span > 0) ? (lo...hi).map { (b[$0] - b[lo]) / span } : nil
        return TextRun(text: String(chars[lo..<hi]), x: x0, y: run.y, w: x1 - x0, h: run.h, chars: sub)
    }
}
