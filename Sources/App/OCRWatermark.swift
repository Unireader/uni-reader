import CoreGraphics
import Foundation

/// 扫描件**平铺水印**（整页斜排的机构名之类）的识别，纯函数、无 UI/无 store 依赖
/// （测试 `spike/ocr-watermark-test.swift`）。
///
/// 为什么需要它：扫描件 OCR 会把水印识别成一堆**独立的大字块**，常被页边裁掉半截、字也认错成
/// 各种形近字（「王道计」「卓机教育」「首计算机教」…），散落在正文行之间。`OCRFlow.columnGroups`
/// 只看几何相邻，落进正文列里的水印块会被并进正文分组——于是拖选正文时会带出一串水印碎片，
/// 复制出来全是噪音（用户 2026-09-03 报）。
///
/// 判据全部是**几何 + 跨页统计**，不写死任何字符串（换一本别家出版社的书同样有效）：
///
///  · **候选**（`isCandidate`）：行高 ≥ `bigRatio`×页内行高中位数，且包围盒近方形
///    （w/h ∈ [`whLo`, `whHi`]）。近方形是**斜排**的签名：n 个字水平排 w/h≈n、竖排 w/h≈1/n，
///    只有旋转 ~45° 才让水平包围盒接近正方。于是竖排框图标签（w/h≈0.3）、整行大字标题（w/h≈10）
///    压根进不了候选，天然免疫。
///  · **跨页重复**（`Profile` + `repeatPages`）：候选的**位置**（页内归一化中心，`cell` 网格 +
///    3×3 邻域容错）或**归一化文本**在 ≥ `threshold` 页重复出现即判水印。阈值取
///    `max(minRepeatPages, repeatFraction×页数)`：正文的章标题也在每章固定位置，但一本书只有几章、
///    够不到阈值；平铺水印每页都落在同一格。
///  · **同页伙伴**（`mask` 里那一段）：一页内候选 ≥ 3 个、且某块与同页另一块文本相同或有 ≥2 字
///    公共子串 → 判水印。这条**不需要样本量**，用于刚开始逐页识别、跨页统计还攒不出来时兜底。
///
/// 实测（王道 2027 计算机组成原理，340 页 21842 行）：候选 2569，判水印 2563，剩下 6 条全是正文
/// 章标题（「第2章」「第4章」…），零误伤；只喂 3 页样本时靠同页伙伴仍抓到 24/27。
/// 另一本无水印的排版书候选数为 0——没水印的文档一行都不会被动。
enum OCRWatermark {

    // MARK: 参数（改动前先用 spike 在真实工作区上回归，阈值是实测卡出来的）

    /// 候选门槛：行高 ≥ 这个倍数的页内行高中位数。
    static let bigRatio = 2.5
    /// 候选门槛：包围盒 w/h 的上下界（斜排 ≈1，竖排 ≪1，整行水平大字 ≫1）。
    static let whLo = 0.7, whHi = 3.5
    /// 位置网格边长（页内归一化）。判定时查 3×3 邻域，所以实际容差 ≈ ±1 格。
    static let cell = 0.04
    /// 跨页重复的绝对下限——低于它一律不判，否则「每章一次」的章标题会被当水印。
    static let minRepeatPages = 8
    /// 跨页重复的相对阈值（占样本页数的比例）。
    static let repeatFraction = 0.06

    /// 位置格（页内归一化中心 / `cell`）。
    struct Cell: Hashable {
        var cx: Int, cy: Int
    }

    /// 全书水印指纹：候选块的位置格 / 文本各出现在哪些页。由 `buildProfile` 一次性统计。
    /// 空指纹（`sampledPages == 0`）时 `mask` 只剩同页伙伴那条判据。
    struct Profile: Equatable {
        var cellPages: [Cell: Set<Int>] = [:]
        var textPages: [String: Set<Int>] = [:]
        var sampledPages = 0
        var isEmpty: Bool { sampledPages == 0 }
    }

    // MARK: 基本量

    /// 页内行高中位数（空页返回 0）。水印判定一律相对它，与页面 DPI / 纸张大小无关。
    static func medianHeight(_ runs: [TextRun]) -> Double {
        guard !runs.isEmpty else { return 0 }
        let hs = runs.map(\.h).sorted()
        return hs[hs.count / 2]
    }

    /// 是否「可能是斜排水印」的候选块：够大 + 包围盒近方形。
    static func isCandidate(_ run: TextRun, medianH: Double) -> Bool {
        guard medianH > 0, run.h > 0, run.w > 0 else { return false }
        guard run.h >= bigRatio * medianH else { return false }
        let wh = run.w / run.h
        return wh >= whLo && wh <= whHi
    }

    /// 归一化文本：去掉全部空白（OCR 对同一水印的空格切分不稳定）。
    static func normalizedText(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    /// 两段文本是否有 ≥2 字的公共子串（单字文本退化为「完全相同」）。
    /// 用来把同一水印的各种残缺/错认变体（「算机教育」「卓机教育」「算机」）认成一家。
    static func shareBigram(_ a: String, _ b: String) -> Bool {
        let ca = Array(a), cb = Array(b)
        guard ca.count >= 2, cb.count >= 2 else { return !ca.isEmpty && ca == cb }
        var grams = Set<String>()
        for i in 0..<(ca.count - 1) { grams.insert(String(ca[i...(i + 1)])) }
        for i in 0..<(cb.count - 1) where grams.contains(String(cb[i...(i + 1)])) { return true }
        return false
    }

    /// 该块中心落在哪个位置格。
    static func cellOf(_ run: TextRun) -> Cell {
        Cell(cx: Int(floor((run.x + run.w / 2) / cell)), cy: Int(floor((run.y + run.h / 2) / cell)))
    }

    // MARK: 指纹

    /// 统计全书（或已识别的那部分）候选块的位置/文本重复情况。
    /// `pages` 是页 → 该页**原始** OCR 行（不是过滤后的）。
    static func buildProfile(_ pages: [Int: [TextRun]]) -> Profile {
        var p = Profile()
        p.sampledPages = pages.count
        for (page, runs) in pages {
            let med = medianHeight(runs)
            for run in runs where isCandidate(run, medianH: med) {
                p.cellPages[cellOf(run), default: []].insert(page)
                p.textPages[normalizedText(run.text), default: []].insert(page)
            }
        }
        return p
    }

    /// 判「重复」所需的页数。
    static func threshold(sampledPages: Int) -> Int {
        max(minRepeatPages, Int(repeatFraction * Double(sampledPages)))
    }

    /// 该块所在位置（含 3×3 邻域）在多少页出现过候选块。
    /// 邻域容错是必需的：同一水印在不同页的中心会因 OCR 切分长短漂移小半格。
    static func repeatPages(of run: TextRun, in profile: Profile) -> Int {
        let c = cellOf(run)
        var pages = Set<Int>()
        for dx in -1...1 {
            for dy in -1...1 {
                if let s = profile.cellPages[Cell(cx: c.cx + dx, cy: c.cy + dy)] { pages.formUnion(s) }
            }
        }
        return pages.count
    }

    // MARK: 逐页判定

    /// 一页的水印掩码（与 `runs` 同序，true = 判为水印、应从选择/分组里剔除）。
    /// 跨页判据（需要 `profile`）与同页伙伴判据取**并集**。
    static func mask(runs: [TextRun], profile: Profile) -> [Bool] {
        var out = [Bool](repeating: false, count: runs.count)
        guard !runs.isEmpty else { return out }
        let med = medianHeight(runs)
        let cand = runs.indices.filter { isCandidate(runs[$0], medianH: med) }
        guard !cand.isEmpty else { return out }
        let texts = cand.map { normalizedText(runs[$0].text) }
        let need = threshold(sampledPages: profile.sampledPages)

        for (k, i) in cand.enumerated() {
            var hit = false
            if !profile.isEmpty {
                hit = repeatPages(of: runs[i], in: profile) >= need
                    || (profile.textPages[texts[k]]?.count ?? 0) >= need
            }
            // 同页伙伴兜底：一页里三块以上大方块、且彼此文本沾亲带故 —— 正文极难凑齐这个形状。
            if !hit, cand.count >= 3 {
                hit = texts.indices.contains { $0 != k && shareBigram(texts[k], texts[$0]) }
            }
            out[i] = hit
        }
        return out
    }
}
