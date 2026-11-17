// `LatexCheck`（Agent 写进来的公式能不能画出来，2026-11-17）的测试：① 从 Markdown 正文里认公式；② 试排判断与显示一致；
// ③ 给 Agent 的提示。运行（先按 AGENTS.md 编一次 Debug，要用它的产物）：
//   P=build/dev/Build/Products/Debug; D=/tmp/latex-check; mkdir -p $D && cp spike/latex-check-test.swift $D/main.swift \
//     && rm -rf $D/SwiftMath_SwiftMath.bundle && cp -R $P/SwiftMath_SwiftMath.bundle $D/ \
//     && swiftc -I $P $D/main.swift Sources/Markdown/LatexCheck.swift Sources/Markdown/LatexCompat.swift Sources/App/MarkdownLink.swift \
//        $P/MarkdownEngine.o $P/MarkdownEngineLatex.o $P/SwiftMath.o -o $D/run && $D/run
// App 里的 `NoteLatexRenderer` 依赖整套编辑器视图，这里用同样两步（`LatexCompat.rewrite` → `SwiftMathBridge`）的替身。
import AppKit
import MarkdownEngine
import MarkdownEngineLatex

final class NoteLatexRenderer {
    static let shared = NoteLatexRenderer()
    private let bridge = SwiftMathBridge()
    func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
        bridge.render(latex: LatexCompat.rewrite(latex), fontSize: fontSize, theme: theme)
    }
}

_ = NSApplication.shared
var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { print("✅ \(label)") } else { failures += 1; print("❌ \(label) \(detail())") }
}

MainActor.assumeIsolated {
    // ① 认公式
    let doc = """
    价格 $5 和 $10 不算。行内 $\\frac{a}{b}$，转义 \\$x\\$ 不算。
    $$
    [A \\mid E] \\xrightarrow{\\text{初等行变换}} [E \\mid A^{-1}]
    $$
    `$\\boxed{x}$` 在代码里不算
    ```
    $$\\overset{a}{b}$$
    ```
    """
    let fs = LatexCheck.formulas(in: doc)
    check("认出行内与块公式，价格 / 转义 / 代码里的不算", fs == [#"\frac{a}{b}"#, #"[A \mid E] \xrightarrow{\text{初等行变换}} [E \mid A^{-1}]"#], "\(fs)")

    // ② 能不能排
    let bad = LatexCheck.unrenderable(in: doc)
    check("用户报的那条判为排不出来", bad == [#"[A \mid E] \xrightarrow{\text{初等行变换}} [E \mid A^{-1}]"#], "\(bad)")
    check("改成建议写法就能排", LatexCheck.unrenderable(in: #"$[A \mid E] \longrightarrow [E \mid A^{-1}]$（初等行变换）"#).isEmpty)
    check("LatexCompat 能换的不报（\\dfrac、\\big、\\implies）", LatexCheck.unrenderable(in: #"$\dfrac{1}{2} \big[ x \big] \implies y$"#).isEmpty)
    check("中文 \\text 不报", LatexCheck.unrenderable(in: #"$x \text{且} y$"#).isEmpty)
    check("分段函数推荐写法不报", LatexCheck.unrenderable(in: #"$$f(x)=\left\{\begin{aligned} &0, && x<0 \\ &1, && x\ge 0 \end{aligned}\right.$$"#).isEmpty)
    check("\\boxed 报", LatexCheck.unrenderable(in: #"$\boxed{x}$"#).count == 1)
    check("括号不配对报", LatexCheck.unrenderable(in: #"$\frac{a}{b$"#).count == 1)

    // ③ 提示
    let n = LatexCheck.notice(for: [doc]) ?? ""
    check("提示里点名不支持的命令", n.contains(#"\xrightarrow"#) && n.contains("cannot be drawn"), n)
    check("都能排时没有提示", LatexCheck.notice(for: [#"$\frac{a}{b}$ 和 $x^2$"#]) == nil)
    check("\\limits 不误报成 \\lim", LatexCheck.knownUnsupported(in: #"\lim_{x\to0}"#).isEmpty)
}
print(failures == 0 ? "全部通过" : "\(failures) 项失败")
exit(failures == 0 ? 0 : 1)
