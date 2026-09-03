// PaddleOCR.parse 端到端测试：真实 PP-OCRv6(returnWordBox) 响应 → [TextRun] + 单字框。运行：
//   cp spike/ocr-parse-test.swift /tmp/main.swift && swiftc Sources/App/PageText.swift \
//     Sources/App/OCRTextSelect.swift Sources/Support/Keychain.swift Sources/App/PaddleOCR.swift \
//     /tmp/main.swift -o /tmp/ocrparse && /tmp/ocrparse spike/ocr-wordbox-vector.jsonl
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
//
// 样本 `spike/ocr-wordbox-vector.jsonl` 是 2026-09-03 云端真实响应，裁到只剩 parse 消费的四个键
// （原始响应里的 inputImage/ocrImage 是**带签名的预签名 URL**，不入库）。图尺寸 2123×1474。
// 它守的是**与云端的字段契约**：哪天 `text_word`/`text_word_boxes` 改名或换形状，这里先红。
import CoreGraphics
import Foundation

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "spike/ocr-wordbox-vector.jsonl"
guard let data = FileManager.default.contents(atPath: path) else {
    print("❌ 读不到样本 \(path)（请在仓库根目录运行）"); exit(1)
}
var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

let runs = PaddleOCR.parse(jsonl: data, imageSize: CGSize(width: 2123, height: 1474))

print("parse（字段契约）")
check(runs.count == 27, "27 行（实得 \(runs.count)）")
check(runs.allSatisfy { $0.w > 0 && $0.h > 0 }, "行框都非退化")
check(runs.allSatisfy { $0.x >= 0 && $0.x + $0.w <= 1.001 }, "行框归一化在 [0,1]")
check(zip(runs, runs.dropFirst()).allSatisfy { $0.y <= $1.y }, "按阅读顺序（y 递增）排好")

print("单字框")
let got = runs.filter { $0.chars != nil }.count
check(got == 27, "27 行全部拿到单字框（实得 \(got)）")
check(runs.allSatisfy { $0.chars == nil || $0.chars!.count == $0.text.count + 1 }, "每行 chars 数 = 字数 + 1")
check(runs.allSatisfy { $0.chars == nil || OCRTextSelect.isMonotonic($0.chars!) }, "每行 chars 单调且夹在 [0,1]")
check(runs.allSatisfy { $0.chars == nil || ($0.chars!.first == 0 && $0.chars!.last == 1) }, "每行首 0 末 1")

print("选择自洽（这是「不切半个字」的实际口径）")
// 每个字格内取一点（格内 25% 处，稳在中线左侧），charOffset 必须判回这个字。
var miss = 0, total = 0
for run in runs {
    let b = OCRTextSelect.bounds(run)
    for i in 0..<run.text.count {
        total += 1
        let probe = run.x + (b[i] * 0.75 + b[i + 1] * 0.25) * run.w
        if OCRTextSelect.charOffset(in: run, atNX: probe) != i { miss += 1 }
    }
}
check(miss == 0, "每个字格内取点都命中该字（\(total - miss)/\(total)）")
// 每个字都能单独裁出来，且文本对得上
var clipBad = 0
for run in runs {
    let chars = Array(run.text)
    for i in 0..<chars.count {
        guard let c = OCRTextSelect.clip(run: run, from: i, to: i + 1), c.text == String(chars[i]) else { clipBad += 1; continue }
    }
}
check(clipBad == 0, "每个字都能单独裁出且文本一致（\(total - clipBad)/\(total)）")

print("没有 CTC 细条泄漏进字格")
// 云端给中文字的框宽是**全行均值**、给标点/窄字母的框会退化成 1 个 CTC cell（本样本实测 4~5px，
// 约 12% 汉字宽）。我们只取框心、边界取相邻字心中点，所以字格宽必须远大于那个细条。
// ⚠️ 别拿「行宽/字数」当每个字的应有宽度：中英混排行里半角字母本来就只占半个汉字宽
// （实测 x86/call/ECX 这些落在 31%~49%，是对的，不是 bug）。
var thin = 0, minRatio = 1.0
for run in runs {
    let b = OCRTextSelect.bounds(run)
    let avg = 1.0 / Double(run.text.count)
    for i in 0..<run.text.count {
        let ratio = (b[i + 1] - b[i]) / avg
        minRatio = min(minRatio, ratio)
        if ratio < 0.25 { thin += 1 }
    }
}
check(thin == 0, String(format: "无字格窄于平均的 25%%（最窄 %.1f%%，细条会是 ~12%%）", minRatio * 100))

// 纯汉字行（无 ASCII）里字格应该接近等宽——这条才是抓几何回归的强断言。
// 两个限定条件都是实测逼出来的，别去掉：
//  · 掐头去尾——行框贴着墨迹裁，首尾标点的留白被裁掉，边格窄属正常；
//  · 只看 ≥8 字的行——文本检测框带 unclip 外扩，短行里这点 padding 占行宽比例大，
//    会把 avg 抬高（实测 3 字的「机教育」中间格因此只有 63%），与字位本身无关。
var cjkBad = 0, cjkChecked = 0
for run in runs where !run.text.contains(where: { $0.isASCII }) && run.text.count >= 8 {
    let b = OCRTextSelect.bounds(run)
    let avg = 1.0 / Double(run.text.count)
    for i in 1..<(run.text.count - 1) {
        cjkChecked += 1
        let ratio = (b[i + 1] - b[i]) / avg
        if ratio < 0.7 || ratio > 1.3 { cjkBad += 1 }
    }
}
check(cjkChecked > 100, "纯汉字长行样本足够（\(cjkChecked) 个字格）")
check(cjkBad == 0, "纯汉字长行的字格宽都在平均的 70%~130%（越界 \(cjkBad) 个）")

let first = runs[0]
print("\n首行「\(first.text.prefix(10))…」\(first.text.count) 字")
print("  [0..<2] → 「\(OCRTextSelect.clip(run: first, from: 0, to: 2)!.text)」")
let comma = OCRTextSelect.clip(run: first, from: 8, to: 9)!
print(String(format: "  [8..<9] → 「%@」格宽 %.1f%% 汉字宽（云端原始框只有 4px ≈ 12%%）",
             comma.text, comma.w / first.w * Double(first.text.count) * 100))

print("\n\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
