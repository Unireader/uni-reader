// OCRTextSelect 纯函数测试：charWeights / weightBounds（无单字框的兜底摊分）/
// boundsFromWordBoxes（PP-OCRv6 returnWordBox 的单字框 → 字符边界，含真机样本回归）/
// charOffset（行内 x → 字符边界，中点吸附）/ clip（字符区间 → 子文本+子行框）/ TextRun 的 Codable 兼容。运行：
//   cp spike/ocr-char-select-test.swift /tmp/main.swift && swiftc Sources/App/PageText.swift Sources/App/OCRTextSelect.swift /tmp/main.swift -o /tmp/ocst && /tmp/ocst
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
import CoreGraphics
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }
func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }

// ---- charWeights ----
print("charWeights（CJK 1.0 / ASCII 0.55 / 空格 0.3）")
let w = OCRTextSelect.charWeights("ab中 ，")
check(w.count == 5, "逐字符一一对应")
check(w[0] == 0.55 && w[1] == 0.55, "ASCII 字母 0.55")
check(w[2] == 1.0, "CJK 汉字 1.0")
check(w[3] == 0.3, "空格 0.3")
check(w[4] == 1.0, "全宽逗号（0xFF0C ≥ 0x2E80）1.0")

// ---- charOffset（均匀 CJK 行：十字，x=0.1, w=0.8 → 每字 0.08）----
print("charOffset（均匀 CJK 行，中点吸附）")
let line = TextRun(text: "一二三四五六七八九十", x: 0.1, y: 0.2, w: 0.8, h: 0.03)
check(OCRTextSelect.charOffset(in: line, atNX: 0.10) == 0, "行首 → 0")
check(OCRTextSelect.charOffset(in: line, atNX: 0.13) == 0, "首字中线前 → 0")
check(OCRTextSelect.charOffset(in: line, atNX: 0.15) == 1, "首字过中线 → 1")
check(OCRTextSelect.charOffset(in: line, atNX: 0.50) == 5, "行中 → 5")
check(OCRTextSelect.charOffset(in: line, atNX: 0.90) == 10, "行尾 → 10（=count）")
check(OCRTextSelect.charOffset(in: line, atNX: 0.02) == 0, "行左外（页边距起拖）→ clamp 0")
check(OCRTextSelect.charOffset(in: line, atNX: 0.99) == 10, "行右外 → clamp count")
check(OCRTextSelect.charOffset(in: TextRun(text: "", x: 0, y: 0, w: 0.5, h: 0.03), atNX: 0.2) == 0, "空文本 → 0")

// 混排宽度："ab中" 权重 0.55/0.55/1.0，总 2.1；行 x=0, w=0.21 → 边界在 0.055/0.11/0.21
print("charOffset（混排宽度加权）")
let mix = TextRun(text: "ab中", x: 0, y: 0, w: 0.21, h: 0.03)
check(OCRTextSelect.charOffset(in: mix, atNX: 0.02) == 0, "a 内 → 0")
check(OCRTextSelect.charOffset(in: mix, atNX: 0.08) == 1, "b 内 → 1")
check(OCRTextSelect.charOffset(in: mix, atNX: 0.15) == 2, "中 前半（中线 0.16 之前）→ 2")
check(OCRTextSelect.charOffset(in: mix, atNX: 0.20) == 3, "中 后半（过中线 0.16）→ 3（=count）")
check(OCRTextSelect.charOffset(in: mix, atNX: 0.205) == 3, "贴近行尾 → 3（=count）")

// ---- clip ----
print("clip（字符区间 → 子文本 + 子行框）")
let sub = OCRTextSelect.clip(run: line, from: 2, to: 5)
check(sub?.text == "三四五", "文本切片 [2,5)")
check(sub != nil && near(sub!.x, 0.26) && near(sub!.w, 0.24), "子行框 x/w 按权重摊分（0.1+2/10·0.8=0.26，3/10·0.8=0.24）")
check(sub != nil && near(sub!.y, 0.2) && near(sub!.h, 0.03), "y/h 原样保留")
let whole = OCRTextSelect.clip(run: line, from: 0, to: 10)
check(whole?.text == line.text && near(whole!.x, 0.1) && near(whole!.w, 0.8), "整行区间 = 原行框")
check(OCRTextSelect.clip(run: line, from: 3, to: 3) == nil, "空区间 → nil")
check(OCRTextSelect.clip(run: line, from: 10, to: 10) == nil, "行尾空区间 → nil")
check(OCRTextSelect.clip(run: line, from: -2, to: 99)?.text == line.text, "越界下标 clamp 后 = 整行")
let mixClip = OCRTextSelect.clip(run: mix, from: 0, to: 2)
check(mixClip?.text == "ab" && near(mixClip!.w, 0.11), "混排切片 w = 1.1/2.1·0.21 = 0.11")

// ---- boundsFromWordBoxes（PP-OCRv6 returnWordBox → 字符边界）----
// 框只用 x（y 与本函数无关），故辅助构造只给 x 区间。
func r(_ x0: Double, _ x1: Double) -> CGRect { CGRect(x: x0, y: 0, width: x1 - x0, height: 10) }

print("boundsFromWordBoxes（真机样本回归：2026-09-03 PP-OCRv6 实测第 0 行，41 字纯中文）")
let cjkText = "在程序执行过程中，当一个过程（函数）调用另一个过程时，需要完成参数传递、控制转移、"
let cjkWords = ["在", "程", "序", "执", "行", "过", "程", "中", "，", "当", "一", "个", "过", "程", "（", "函", "数", "）", "调", "用", "另", "一", "个", "过", "程", "时", "，", "需", "要", "完", "成", "参", "数", "传", "递", "、", "控", "制", "转", "移", "、"]
let cjkBoxes: [CGRect] = [r(278, 312), r(313, 350), r(346, 382), r(383, 420), r(416, 452), r(448, 485), r(486, 523), r(519, 555), r(563, 567), r(584, 621), r(621, 658), r(654, 691), r(687, 723), r(724, 761), r(778, 782), r(785, 822), r(822, 859), r(866, 871), r(888, 924), r(920, 957), r(958, 994), r(990, 1027), r(1023, 1060), r(1061, 1097), r(1098, 1135), r(1131, 1167), r(1170, 1175), r(1196, 1233), r(1229, 1266), r(1266, 1303), r(1299, 1336), r(1332, 1368), r(1369, 1406), r(1402, 1438), r(1439, 1476), r(1478, 1483), r(1505, 1541), r(1537, 1574), r(1570, 1607), r(1607, 1644), r(1647, 1651)]
let cjkLine = r(278, 1650)
let cjkB = OCRTextSelect.boundsFromWordBoxes(lineText: cjkText, words: cjkWords, boxes: cjkBoxes, lineBox: cjkLine)
check(cjkB?.count == 42, "41 字 → 42 个边界")
check(cjkB != nil && cjkB![0] == 0 && cjkB![41] == 1, "首 0 末 1")
check(cjkB != nil && OCRTextSelect.isMonotonic(cjkB!), "单调不减、夹在 [0,1]")
check(cjkB != nil && near(cjkB![1], 0.0257, 1e-9) && near(cjkB![2], 0.0508, 1e-9), "边界 = 相邻字心的中点（4 位小数）")
// 关键：标点的原始框退化成 4px 细条，但按「字心中点」重建后应拿到接近一个字的格宽
check(cjkB != nil && (cjkB![9] - cjkB![8]) * 1372 > 30, "「，」格宽 32.7px（原始框只有 4px）——只用心不用宽")
check(cjkBoxes[8].width == 4, "（前提）该标点的原始框确实是 4px 细条")

print("boundsFromWordBoxes（真机样本：含拉丁词与空格的代码行，条目多字）")
let codeText = "int add(int x, int y){"
let codeWords = ["int", " ", "add", "(", "int", " ", "x", ", ", "int", " ", "y", "){"]
let codeBoxes: [CGRect] = [r(360, 398), r(409, 415), r(431, 475), r(492, 497), r(508, 547), r(558, 563), r(585, 591), r(602, 618), r(640, 678), r(689, 695), r(711, 717), r(728, 755)]
let codeLine = r(344, 760)
let codeB = OCRTextSelect.boundsFromWordBoxes(lineText: codeText, words: codeWords, boxes: codeBoxes, lineBox: codeLine)
check(codeWords.joined() == codeText, "（前提）text_word 拼回去 == rec_texts")
check(codeB?.count == 23, "22 字 → 23 个边界（多字条目在框内等分）")
check(codeB != nil && near(codeB![1], 0.0689, 1e-9) && near(codeB![4], 0.1951, 1e-9), "多字条目 'int'/'add' 摊分正确")
check(codeB != nil && OCRTextSelect.isMonotonic(codeB!), "单调不减")

print("boundsFromWordBoxes（拒绝条件）")
check(OCRTextSelect.boundsFromWordBoxes(lineText: "abc", words: ["ab"], boxes: [r(0, 10)], lineBox: r(0, 10)) == nil,
      "拼不回行文本 → nil")
check(OCRTextSelect.boundsFromWordBoxes(lineText: "abc", words: ["abc"], boxes: [], lineBox: r(0, 10)) == nil,
      "词与框数量对不上 → nil")
check(OCRTextSelect.boundsFromWordBoxes(lineText: "abc", words: ["abc"], boxes: [r(0, 10)], lineBox: r(5, 5)) == nil,
      "行框零宽 → nil")
check(OCRTextSelect.boundsFromWordBoxes(lineText: "", words: [], boxes: [], lineBox: r(0, 10)) == nil,
      "空行 → nil")
let one = OCRTextSelect.boundsFromWordBoxes(lineText: "字", words: ["字"], boxes: [r(2, 8)], lineBox: r(0, 10))
check(one ?? [] == [0, 1], "单字行 → [0,1]")
let back = OCRTextSelect.boundsFromWordBoxes(lineText: "ab", words: ["a", "b"], boxes: [r(8, 9), r(1, 2)], lineBox: r(0, 10))
check(back != nil && OCRTextSelect.isMonotonic(back!), "字心回退（框乱序）也强制单调，不产生负宽")

// ---- bounds()：单字框优先，脏数据回落 ----
print("bounds（单字框优先 / 脏数据回落权重）")
let noChars = TextRun(text: "一二三四", x: 0.1, y: 0, w: 0.4, h: 0.03)
check(OCRTextSelect.bounds(noChars) == OCRTextSelect.weightBounds("一二三四"), "无单字框 → 权重摊分")
let withChars = TextRun(text: "一二三四", x: 0.1, y: 0, w: 0.4, h: 0.03, chars: [0, 0.1, 0.5, 0.9, 1])
check(OCRTextSelect.bounds(withChars) == [0, 0.1, 0.5, 0.9, 1], "有单字框 → 直接用")
let badCount = TextRun(text: "一二三四", x: 0, y: 0, w: 0.4, h: 0.03, chars: [0, 0.5, 1])
check(OCRTextSelect.bounds(badCount) == OCRTextSelect.weightBounds("一二三四"), "个数对不上 → 回落权重")
let badOrder = TextRun(text: "一二三四", x: 0, y: 0, w: 0.4, h: 0.03, chars: [0, 0.6, 0.3, 0.9, 1])
check(OCRTextSelect.bounds(badOrder) == OCRTextSelect.weightBounds("一二三四"), "非单调 → 回落权重")
let badRange = TextRun(text: "一二三四", x: 0, y: 0, w: 0.4, h: 0.03, chars: [0, 0.3, 0.6, 0.9, 1.5])
check(OCRTextSelect.bounds(badRange) == OCRTextSelect.weightBounds("一二三四"), "越出 [0,1] → 回落权重")

// ---- charOffset / clip 走单字框 ----
// 不等宽的一行：四个字的格宽 10% / 40% / 40% / 10%，权重法会均分成 25% 各一格，两者结论不同才测得出。
print("charOffset / clip（由单字框驱动）")
let uneven = TextRun(text: "一二三四", x: 0.0, y: 0, w: 1.0, h: 0.03, chars: [0, 0.1, 0.5, 0.9, 1])
check(OCRTextSelect.charOffset(in: uneven, atNX: 0.04) == 0, "落在首格（中线 0.05 前）→ 0")
check(OCRTextSelect.charOffset(in: uneven, atNX: 0.06) == 1, "过首格中线 → 1")
check(OCRTextSelect.charOffset(in: uneven, atNX: 0.28) == 1, "第二格前半（中线 0.30 前）→ 1")
check(OCRTextSelect.charOffset(in: uneven, atNX: 0.32) == 2, "第二格过中线 → 2")
check(OCRTextSelect.charOffset(in: uneven, atNX: 0.96) == 4, "末格过中线 → 4（=count）")
check(OCRTextSelect.charOffset(in: TextRun(text: "一二三四", x: 0, y: 0, w: 1.0, h: 0.03), atNX: 0.28) == 1,
      "（对照）同一点在权重均分下 → 1，与单字框结论一致；下一条才分道扬镳")
check(OCRTextSelect.charOffset(in: TextRun(text: "一二三四", x: 0, y: 0, w: 1.0, h: 0.03), atNX: 0.32) == 1,
      "（对照）权重均分把 0.32 判在第二格中线之前 → 1；单字框判 2，差一个字")
let unevenClip = OCRTextSelect.clip(run: uneven, from: 1, to: 3)
check(unevenClip?.text == "二三", "切片文本")
check(unevenClip != nil && near(unevenClip!.x, 0.1) && near(unevenClip!.w, 0.8), "子行框按单字框收窄（0.1 → 0.9）")
check(unevenClip?.chars ?? [] == [0, 0.5, 1], "子行框的单字框按子区间重新归一化")
check(OCRTextSelect.clip(run: noChars, from: 1, to: 3)?.chars == nil, "原行没有单字框 → 子行也不凭空造")
let reclip = unevenClip.flatMap { OCRTextSelect.clip(run: $0, from: 0, to: 1) }
check(reclip?.text == "二" && reclip != nil && near(reclip!.w, 0.4), "子行框可继续裁（重新归一化没走样）")

// ---- Codable 兼容：老 payload 没有 chars 键 ----
print("Codable（老 OCR payload 无 chars 键）")
let legacy = #"{"text":"一二","x":0.1,"y":0.2,"w":0.4,"h":0.03}"#.data(using: .utf8)!
let decoded = try? JSONDecoder().decode(TextRun.self, from: legacy)
check(decoded?.text == "一二" && decoded?.chars == nil, "缺 chars 键 → 解成 nil，不报错")
let rt = try? JSONDecoder().decode(TextRun.self, from: JSONEncoder().encode(withChars))
check(rt == withChars, "带 chars 往返相等")

print("\n\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
