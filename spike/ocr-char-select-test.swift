// OCRTextSelect 纯函数测试：charWeights（全宽/半宽/空格）/ charOffset（行内 x → 字符边界，中点吸附）/ clip（字符区间 → 子文本+子行框）。运行：
//   cp spike/ocr-char-select-test.swift /tmp/main.swift && swiftc Sources/App/PageText.swift Sources/App/OCRTextSelect.swift /tmp/main.swift -o /tmp/ocst && /tmp/ocst
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
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

print("\n\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
