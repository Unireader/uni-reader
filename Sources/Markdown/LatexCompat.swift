import Foundation

/// SwiftMath（公式排版库）不认的 LaTeX 写法，交给它之前换成**意思相同**、它认的写法。
///
/// 起因（用户 2026-10-07）：块公式 `$$… e^{-x}\big[…\big]$$` 整条显示成源码——SwiftMath 不认 `\big`，一个命令不认
/// 整条公式就渲染失败。同一轮用 `spike/latex-look.swift` 普查了笔记里常见的写法，不认的里面凡是能一一对应的都在这里换掉：
/// 只差括号大小（`\big` 一组、`\dfrac`）、字形变体（`\leqslant`、`\mathscr`）、同义命令（`\implies`、`\not=`）。
/// 每个替换目标都实测能渲染（SwiftMath 1.7.3）。只能近似的（`cases` / `array` 环境、`\boxed`、`\overset`、`\xrightarrow`、
/// `\overbrace` …）**不在这里**：换了显示效果会和原意有出入，要不要做、怎么做由用户定（见 `docs/agents/PITFALLS.md`）。
///
/// 逐个扫命令而不用正则：`\\`（换行）要当一个整体跳过，正则分不清 `\\dots`（换行 + 文字 dots）和 `\dots`。
/// 测试：`spike/latex-compat-test.swift`（替换结果 + 换完能不能渲染）。
enum LatexCompat {
    static func rewrite(_ latex: String) -> String {
        guard latex.contains("\\") else { return latex }
        let u = Array(latex.unicodeScalars)
        var out = String.UnicodeScalarView()
        func emit(_ s: String) { out.append(contentsOf: s.unicodeScalars) }
        func isLetter(_ s: Unicode.Scalar) -> Bool { s.isASCII && s.properties.isAlphabetic }
        func skipSpaces(_ k: inout Int) { while k < u.count, u[k] == " " { k += 1 } }
        /// `{…}` 从 `k` 起（可先有空格）：返回里面的内容并把 `k` 挪到 `}` 之后；没有就原样不动、返回 nil。
        func group(_ k: inout Int) -> String? {
            var p = k
            skipSpaces(&p)
            guard p < u.count, u[p] == "{" else { return nil }
            var depth = 0, q = p
            while q < u.count {
                if u[q] == "{" { depth += 1 } else if u[q] == "}" { depth -= 1; if depth == 0 { break } }
                q += 1
            }
            guard q < u.count else { return nil }
            k = q + 1
            return String(String.UnicodeScalarView(u[(p + 1)..<q]))
        }

        var i = 0
        while i < u.count {
            guard u[i] == "\\" else { out.append(u[i]); i += 1; continue }
            var j = i + 1
            while j < u.count, isLetter(u[j]) { j += 1 }
            if j == i + 1 {   // `\\` `\,` `\{`：反斜杠带一个非字母，整体照抄
                out.append(u[i])
                if j < u.count { out.append(u[j]) }
                i = j + 1
                continue
            }
            let name = String(String.UnicodeScalarView(u[(i + 1)..<j]))
            var k = j   // 命令名之后
            switch name {
            case _ where bigSizes.contains(name):
                // 只改括号大小：去掉，括号照常大小。`\bigl.`（不画的那一侧）连点一起去掉
                var p = k
                skipSpaces(&p)
                if p < u.count, u[p] == "." { k = p + 1 }
            case "dfrac", "tfrac", "cfrac": emit("\\frac")
            case "dbinom", "tbinom": emit("\\binom")
            case "dots": emit("\\ldots")
            case "leqslant": emit("\\leq")
            case "geqslant": emit("\\geq")
            case "lvert", "rvert": emit("|")
            case "lVert", "rVert": emit("\\|")
            case "middle": break   // `\middle|` → `|`
            case "operatorname":
                if k < u.count, u[k] == "*" { k += 1 }
                emit("\\mathrm")
            case "iint": emit("\\int\\!\\!\\int")
            case "iiint": emit("\\int\\!\\!\\int\\!\\!\\int")
            case "pmod":
                if let arg = group(&k) { emit("\\;(\\mathrm{mod}\\;\(arg))") } else { emit("\\pmod") }
            case "bmod": emit("\\;\\mathrm{mod}\\;")
            case "not":
                var p = k
                skipSpaces(&p)
                if p < u.count, u[p] == "=" {
                    emit("\\neq ")   // 后面可能紧跟字母，空格把命令名隔开
                    k = p + 1
                } else if p + 3 <= u.count, u[p] == "\\", u[p + 1] == "i", u[p + 2] == "n",
                          p + 3 == u.count || !isLetter(u[p + 3]) {
                    emit("\\notin")
                    k = p + 3
                } else {
                    emit("\\not")
                }
            case "implies": emit("\\Longrightarrow")
            case "impliedby": emit("\\Longleftarrow")
            case "boldsymbol": emit("\\bm")
            case "mathscr": emit("\\mathcal")
            case "varnothing": emit("\\emptyset")
            case "tag":
                let starred = k < u.count && u[k] == "*"
                var p = starred ? k + 1 : k
                if let arg = group(&p) {
                    emit(starred ? "\\qquad \(arg)" : "\\qquad(\(arg))")
                    k = p
                } else {
                    emit("\\tag")
                }
            default:
                emit("\\" + name)
            }
            i = k
        }
        return String(out)
    }

    /// 改括号大小的那一组：`\big` `\Big` `\bigg` `\Bigg`，各带 l / r / m 三种。`\bigcup` 这类大运算符不在里面。
    private static let bigSizes: Set<String> = {
        var s = Set<String>()
        for base in ["big", "Big", "bigg", "Bigg"] {
            s.insert(base)
            for side in ["l", "r", "m"] { s.insert(base + side) }
        }
        return s
    }()
}
