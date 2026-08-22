import CoreGraphics

/// OCR 行内字符级选择的纯函数（无 UI 依赖，spike/ocr-char-select-test.swift 可测）。
///
/// OCR 只有**行框**没有字符框，行内定位靠「行框宽度按字符显示权重摊分」的近似：
/// CJK/全宽标点权重 1.0，ASCII 字母数字 0.55，空格 0.3，其余 0.8。
/// 中文等宽排版下几乎精确；混排比例字体是近似（但远比整行可选好用）。
enum OCRTextSelect {

    /// 每个字符的显示权重。命中（`charOffset`）与裁剪（`clip`）共用同一组权重，两边结果才一致。
    static func charWeights(_ text: String) -> [Double] {
        text.map { c in
            guard let s = c.unicodeScalars.first else { return 0.8 }
            if s == " " { return 0.3 }
            return s.value >= 0x2E80 ? 1.0 : 0.55   // 0x2E80 起为 CJK 部首/假名/汉字/全宽标点区
        }
    }

    /// 行内 x（页内归一化）→ 字符边界下标（0...count）。中点吸附：落点越过某字符中线即算到它后面。
    static func charOffset(in run: TextRun, atNX nx: Double) -> Int {
        let w = charWeights(run.text)
        guard !w.isEmpty, run.w > 0 else { return 0 }
        let total = w.reduce(0, +)
        let target = ((nx - run.x) / run.w) * total
        var acc = 0.0
        for (i, cw) in w.enumerated() {
            if target < acc + cw / 2 { return i }
            acc += cw
        }
        return w.count
    }

    /// 行内字符区间 [lo, hi) → 子文本 + 子行框（高亮/批注锚框同步收窄）；空区间返回 nil。
    static func clip(run: TextRun, from lo: Int, to hi: Int) -> TextRun? {
        let chars = Array(run.text)
        let w = charWeights(run.text)
        let lo = max(0, min(lo, chars.count)), hi = max(lo, min(hi, chars.count))
        guard lo < hi else { return nil }
        let total = w.reduce(0, +)
        guard total > 0 else { return nil }
        let x0 = run.x + w.prefix(lo).reduce(0, +) / total * run.w
        let x1 = run.x + w.prefix(hi).reduce(0, +) / total * run.w
        return TextRun(text: String(chars[lo..<hi]), x: x0, y: run.y, w: x1 - x0, h: run.h)
    }
}
