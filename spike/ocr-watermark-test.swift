// OCRWatermark 纯函数测试：候选门槛（大字 + 近方形）/ 跨页指纹（位置格 3×3 邻域 + 文本）/
// 同页伙伴兜底 / 掩码。运行：
//   cp spike/ocr-watermark-test.swift /tmp/main.swift && swiftc Sources/App/PageText.swift Sources/App/OCRWatermark.swift /tmp/main.swift -o /tmp/owmt && /tmp/owmt
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
//
// 真实数据回归（王道 2027 组成原理，340 页）见 `spike/ocr-watermark-real.swift`——那份要连工作区库，
// 这份只用手造样本，保证算法本身可离线复现。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

/// 一行正文（行高 0.014，水平）。
func body(_ t: String, _ x: Double, _ y: Double, _ w: Double = 0.7) -> TextRun {
    TextRun(text: t, x: x, y: y, w: w, h: 0.014)
}
/// 一块斜排水印（行高 0.10，包围盒近方形）。
func wm(_ t: String, _ x: Double, _ y: Double) -> TextRun {
    TextRun(text: t, x: x, y: y, w: 0.11, h: 0.10)
}

// ---- medianHeight / isCandidate ----
print("候选门槛（大字 + 近方形）")
let med = OCRWatermark.medianHeight([body("a", 0.1, 0.1), body("b", 0.1, 0.2), wm("王道计", 0.8, 0.3)])
check(abs(med - 0.014) < 1e-9, "行高中位数取正文行高（水印是少数派）")
check(OCRWatermark.isCandidate(wm("王道计", 0.8, 0.3), medianH: 0.014), "斜排水印块 = 候选")
check(!OCRWatermark.isCandidate(body("正文一行", 0.1, 0.2), medianH: 0.014), "正文行不是候选（不够大）")
check(!OCRWatermark.isCandidate(TextRun(text: "第2章 数据的表示", x: 0.1, y: 0.1, w: 0.6, h: 0.05), medianH: 0.014),
      "整行水平大字标题不是候选（w/h≈12 太扁）")
check(!OCRWatermark.isCandidate(TextRun(text: "中央处理器", x: 0.3, y: 0.4, w: 0.016, h: 0.062), medianH: 0.014),
      "竖排框图标签不是候选（w/h≈0.26 太窄）")
check(!OCRWatermark.isCandidate(TextRun(text: "x", x: 0.3, y: 0.4, w: 0.1, h: 0), medianH: 0.014), "零高度不崩、不算候选")
check(!OCRWatermark.isCandidate(wm("王道计", 0.8, 0.3), medianH: 0), "空页（中位数 0）不算候选")

// ---- 文本归一化 / 2-gram ----
print("文本归一化与公共子串")
check(OCRWatermark.normalizedText(" 王道 计算机\n") == "王道计算机", "去掉全部空白")
check(OCRWatermark.shareBigram("算机教育", "卓机教育"), "错认变体共享「机教」→ 同一水印")
check(OCRWatermark.shareBigram("王道计", "王道计算机教育"), "残缺片段是完整文本的子串")
check(!OCRWatermark.shareBigram("中断请求", "寄存器A"), "不相干的两块不算一家")
check(OCRWatermark.shareBigram("育", "育"), "单字退化为完全相同")
check(!OCRWatermark.shareBigram("育", "教"), "单字不同 → 不算")
check(!OCRWatermark.shareBigram("", "教育"), "空文本不算")

// ---- 位置格与邻域 ----
print("位置格（3×3 邻域容错）")
let a = wm("王道计", 0.880, 0.120), b = wm("王道计算机", 0.884, 0.124)
var prof = OCRWatermark.Profile()
prof.sampledPages = 100
prof.cellPages[OCRWatermark.cellOf(a), default: []].formUnion(Set(0..<40))
check(OCRWatermark.repeatPages(of: b, in: prof) >= 40, "中心漂移小半格仍算同一处（邻域容错）")
check(OCRWatermark.repeatPages(of: wm("王道计", 0.2, 0.6), in: prof) == 0, "页面另一头不沾边")
check(OCRWatermark.threshold(sampledPages: 340) == 20, "阈值 = 6% 页数（340 页 → 20）")
check(OCRWatermark.threshold(sampledPages: 30) == OCRWatermark.minRepeatPages, "样本少时吃绝对下限 8")

// ---- buildProfile + mask：整本书 ----
print("整本书：水印每页同位置，正文章标题每章一次")
var pages: [Int: [TextRun]] = [:]
for p in 0..<100 {
    var runs: [TextRun] = []
    for i in 0..<20 { runs.append(body("正文第\(i)行", 0.10, 0.10 + Double(i) * 0.035)) }
    // 三块水印，每页同一位置，文本按页轮换成不同的错认变体（模拟 OCR 抖动）
    let variants = ["王道计", "算机教育", "卓机教育", "王道计算机教", "首计算机教育"]
    runs.append(wm(variants[p % 5], 0.880, 0.120))
    runs.append(wm(variants[(p + 1) % 5], 0.000, 0.420))
    runs.append(wm(variants[(p + 2) % 5], 0.380, 0.780))
    // 每 20 页一个章标题：大字、近方形（w/h≈2.2，落在候选区间内），位置固定 —— 不该被误杀
    if p % 20 == 0 { runs.append(TextRun(text: "第\(p / 20 + 1)章", x: 0.10, y: 0.06, w: 0.175, h: 0.078)) }
    pages[p] = runs
}
let profile = OCRWatermark.buildProfile(pages)
check(profile.sampledPages == 100, "指纹记下样本页数")

var hitWM = 0, missWM = 0, killedBody = 0, killedTitle = 0
for (p, runs) in pages {
    let m = OCRWatermark.mask(runs: runs, profile: profile)
    for (i, r) in runs.enumerated() {
        let isWM = r.h > 0.05 && !r.text.hasSuffix("章")
        let isTitle = r.text.hasSuffix("章")
        if isWM { m[i] ? (hitWM += 1) : (missWM += 1) }
        else if isTitle { if m[i] { killedTitle += 1 } }
        else if m[i] { killedBody += 1 }
        _ = p
    }
}
check(hitWM == 300 && missWM == 0, "300 块水印全部命中（漏 \(missWM)）")
check(killedBody == 0, "正文一行都没被误杀")
check(killedTitle == 0, "章标题（每章一次、位置固定）没被误杀")

// ---- 同页伙伴兜底：只有 3 页样本，跨页统计够不到阈值 ----
print("冷启动兜底：样本不足时靠同页伙伴")
// 正文行要够多——行高中位数是判「大字」的尺子，一页里水印块若占了多数，尺子本身就被顶高了
// （封面/扉页那种几乎全是水印的页确实会失守，但那种页也没有正文可选，无所谓）。
var coldRuns = (0..<10).map { body("正文第\($0)行", 0.1, 0.08 + Double($0) * 0.03) }
coldRuns += [wm("王道计", 0.88, 0.12), wm("算机教育", 0.00, 0.42), wm("卓机教育", 0.38, 0.78)]
let coldMask = OCRWatermark.mask(runs: coldRuns, profile: OCRWatermark.Profile())
// 「王道计」与另两块没有 2 字公共子串（王道/道计 vs 算机/机教/教育），同页判据够不着它——
// 这类孤立变体要等跨页指纹建起来（位置每页固定）才被抓到，属**设计如此**，不是漏判。
check(coldMask == Array(repeating: false, count: 11) + [true, true],
      "空指纹下互相沾亲的两块先被判掉")

var coldRuns2 = (0..<10).map { body("正文第\($0)行", 0.1, 0.08 + Double($0) * 0.03) }
coldRuns2 += [wm("王道计算机教育", 0.88, 0.12), wm("算机教育", 0.00, 0.42), wm("卓机教育", 0.38, 0.78)]
check(OCRWatermark.mask(runs: coldRuns2, profile: OCRWatermark.Profile())
        == Array(repeating: false, count: 10) + [true, true, true],
      "三块同源变体（共享「机教」「教育」）全判水印")

var twoOnly = (0..<10).map { body("正文第\($0)行", 0.1, 0.08 + Double($0) * 0.03) }
twoOnly += [wm("王道计", 0.88, 0.12), wm("王道计", 0.00, 0.42)]
check(!OCRWatermark.mask(runs: twoOnly, profile: OCRWatermark.Profile()).contains(true),
      "只有两块 → 不足以下结论（同页判据要求 ≥3）")

var titleOnly = (0..<10).map { body("正文第\($0)行", 0.1, 0.08 + Double($0) * 0.03) }
titleOnly.append(TextRun(text: "第2章", x: 0.10, y: 0.06, w: 0.175, h: 0.078))
check(!OCRWatermark.mask(runs: titleOnly, profile: OCRWatermark.Profile()).contains(true),
      "孤零零一个大字标题不会被兜底规则误杀")

// ---- 无水印文档：一行都不动 ----
print("无水印文档")
var clean: [Int: [TextRun]] = [:]
for p in 0..<40 {
    var runs = (0..<25).map { body("正文第\($0)行", 0.10, 0.08 + Double($0) * 0.034) }
    runs.append(TextRun(text: "2.1 数据的表示", x: 0.10, y: 0.05, w: 0.35, h: 0.022))   // 小标题
    clean[p] = runs
}
let cleanProfile = OCRWatermark.buildProfile(clean)
check(cleanProfile.cellPages.isEmpty, "没有候选 → 指纹为空")
var touched = 0
for (_, runs) in clean where OCRWatermark.mask(runs: runs, profile: cleanProfile).contains(true) { touched += 1; _ = runs }
check(touched == 0, "没水印的文档一行都不会被剔除")

check(OCRWatermark.mask(runs: [], profile: profile).isEmpty, "空页返回空掩码")

print("\n\(pass) 通过, \(fail) 失败")
exit(fail == 0 ? 0 : 1)
