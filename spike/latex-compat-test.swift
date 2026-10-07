// `LatexCompat.rewrite`（SwiftMath 不认的 LaTeX 换成同义写法）的测试：① 替换结果逐条比对；② 每条样例换之前
// SwiftMath 渲染失败、换之后能渲染（走 App 里同一条 `SwiftMathBridge`）。运行（先按 AGENTS.md 编一次 Debug，要用它的产物）：
//   P=build/dev/Build/Products/Debug; D=/tmp/latex-compat; mkdir -p $D && cp spike/latex-compat-test.swift $D/main.swift \
//     && rm -rf $D/SwiftMath_SwiftMath.bundle && cp -R $P/SwiftMath_SwiftMath.bundle $D/ \
//     && swiftc -I $P $D/main.swift Sources/Markdown/LatexCompat.swift $P/MarkdownEngine.o $P/MarkdownEngineLatex.o $P/SwiftMath.o -o $D/run \
//     && $D/run
// SwiftMath 的字体包按 `Bundle.module` 找，要和可执行文件放在同一目录——所以上面要把 bundle 复制过去。
import AppKit
import MarkdownEngine
import MarkdownEngineLatex

_ = NSApplication.shared   // bridge 要读 NSApp.keyWindow 判深浅色，NSApp 不能是 nil

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { print("✅ \(label)") } else { failures += 1; print("❌ \(label) \(detail())") }
}

// ① 替换结果
let cases: [(String, String)] = [
    (#"e^{-x}\big[(a) - 2(b)\big]"#, #"e^{-x}[(a) - 2(b)]"#),
    (#"\Bigl( a \Bigr)"#, #"( a )"#),
    (#"\biggl\{ x \biggr\}"#, #"\{ x \}"#),
    (#"\left. f \bigr|_{0}"#, #"\left. f |_{0}"#),
    (#"\bigl. f \bigr|"#, #" f |"#),
    (#"\bigcup_i A_i \bigoplus B"#, #"\bigcup_i A_i \bigoplus B"#),   // 大运算符不动
    (#"\dfrac{a}{b}+\tfrac12+\cfrac{1}{x}"#, #"\frac{a}{b}+\frac12+\frac{1}{x}"#),
    (#"\dbinom{n}{k}\tbinom{n}{k}"#, #"\binom{n}{k}\binom{n}{k}"#),
    (#"a_1,\dots,a_n"#, #"a_1,\ldots,a_n"#),
    (#"\ldots\cdots\vdots"#, #"\ldots\cdots\vdots"#),                  // 别的 dots 不动
    (#"a \\dots"#, #"a \\dots"#),                                      // `\\` 换行后面的文字不当命令
    (#"a\leqslant b\geqslant c"#, #"a\leq b\geq c"#),
    (#"\lvert x\rvert + \lVert v\rVert"#, #"| x| + \| v\|"#),
    (#"\left( a \middle| b \right)"#, #"\left( a | b \right)"#),
    (#"\operatorname{sgn} x + \operatorname*{arg\,max}"#, #"\mathrm{sgn} x + \mathrm{arg\,max}"#),
    (#"\iint_D f + \iiint_V g"#, #"\int\!\!\int_D f + \int\!\!\int\!\!\int_V g"#),
    (#"a \equiv b \pmod{p}"#, #"a \equiv b \;(\mathrm{mod}\;p)"#),
    (#"a \bmod b"#, #"a \;\mathrm{mod}\; b"#),
    (#"a \not= b, x\not\in A, x\not\subset A"#, #"a \neq  b, x\notin A, x\not\subset A"#),
    (#"a\not=b"#, #"a\neq b"#),
    (#"p \implies q \impliedby r"#, #"p \Longrightarrow q \Longleftarrow r"#),
    (#"\boldsymbol{\alpha}+\mathscr{F}+\varnothing"#, #"\bm{\alpha}+\mathcal{F}+\emptyset"#),
    (#"x = 1 \tag{1}"#, #"x = 1 \qquad(1)"#),
    (#"x = 1 \tag*{(a)}"#, #"x = 1 \qquad (a)"#),
    (#"\frac{a}{b} + \sqrt{x}"#, #"\frac{a}{b} + \sqrt{x}"#),          // 认得的不动
    ("x + y", "x + y"),
]
for (input, want) in cases {
    let got = LatexCompat.rewrite(input)
    check("rewrite \(input)", got == want, "→ \(got)  期望 \(want)")
}

// ② 换之前渲染失败、换之后能渲染
let bridge = SwiftMathBridge()
let theme = MarkdownEditorTheme.default
let samples = [
    #"\displaystyle y''+2y'+5y = e^{-x}\big[(-3\cos 2x+4\sin 2x) - 2(\cos 2x+2\sin 2x) + 5\cos 2x\big]"#,
    #"\Bigl( a \Bigr)"#, #"\biggl[ a \biggr]"#, #"a \bigm| b"#,
    #"\dfrac{a}{b}"#, #"\tfrac{a}{b}"#, #"\cfrac{a}{b}"#, #"\dbinom{n}{k}"#,
    #"a\dots b"#, #"a\leqslant b"#, #"\lvert x\rvert"#, #"\left( a \middle| b \right)"#,
    #"\operatorname{sgn} x"#, #"\iint_D f"#, #"a \pmod{p}"#, #"a\bmod b"#,
    #"a\not= b"#, #"x\not\in A"#, #"a\implies b"#, #"\boldsymbol{\alpha}"#, #"\mathscr{F}"#,
    #"\varnothing"#, #"x \tag{1}"#,
]
for f in samples {
    let before = bridge.render(latex: f, fontSize: 18, theme: theme)
    let after = bridge.render(latex: LatexCompat.rewrite(f), fontSize: 18, theme: theme)
    check("renders after rewrite: \(f)", before == nil && after != nil,
          "before=\(before == nil ? "nil" : "ok") after=\(after == nil ? "nil" : "ok")")
}

print(failures == 0 ? "\n全部通过（\(cases.count + samples.count) 项）" : "\n❌ \(failures) 项失败")
exit(failures == 0 ? 0 : 1)
