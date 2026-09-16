// 笔记公式的**样张**：某条 LaTeX 在笔记里能不能渲染、渲染出来什么样。运行（先按 AGENTS.md 编一次 Debug，要用它的产物）：
//   P=build/dev/Build/Products/Debug; mkdir -p /tmp/latex-look && cp spike/latex-look.swift /tmp/latex-look/main.swift \
//     && cp -R $P/SwiftMath_SwiftMath.bundle /tmp/latex-look/ \
//     && swiftc -I $P /tmp/latex-look/main.swift $P/MarkdownEngine.o $P/MarkdownEngineLatex.o $P/SwiftMath.o -o /tmp/latex-look/run \
//     && /tmp/latex-look/run ['\frac{a}{b}' …]
// 产物：/tmp/latex-look/f<N>.png —— 直接看，别猜。不带参数就出下面那组样例。
//
// 走的是 App 里同一条路（`SwiftMathBridge`），颜色取气泡正文色。注意 App 里 `$$…$$` 块会被 `NoteLatexRenderer` 在前面加上
// `\displaystyle`（按块排版），这里不加——想看块的样子就自己在参数前面写 `\displaystyle`。
// 打印 nil 的 = SwiftMath 不认，App 里会原样显示源码（2026-09-16 实测：`cases` 环境不认，`aligned` / `pmatrix` 认）。
// SwiftMath 的字体包按 `Bundle.module` 找，要和可执行文件放在同一目录——所以上面要把 bundle 复制过去。
import AppKit
import MarkdownEngine
import MarkdownEngineLatex

_ = NSApplication.shared   // bridge 要读 NSApp.keyWindow 判深浅色，NSApp 不能是 nil

let outDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let args = Array(CommandLine.arguments.dropFirst())
let formulas = args.isEmpty ? [
    #"dxyz = \frac{\partial xyz}{\partial x} dx + \frac{\partial xyz}{\partial y} dy + \frac{\partial xyz}{\partial z} dz"#,
    #"\displaystyle \sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}"#,
    #"\int_0^1 x^2\,dx = \frac{1}{3}"#,
    #"\lim_{x\to 0}\frac{\sin x}{x} = 1"#,
    #"\begin{aligned} a &= b \\ c &= d \end{aligned}"#,
    #"\begin{pmatrix} 1 & 0 \\ 0 & 1 \end{pmatrix}"#,
    #"\begin{cases} x+y=1 \\ x-y=0 \end{cases}"#,
] : args

let bridge = SwiftMathBridge()
var theme = MarkdownEditorTheme.default
theme.latexLightModeText = NSColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1)   // = MarkdownNoteEditor.readerTheme.bodyText
theme.latexDarkModeText = theme.latexLightModeText

for (i, f) in formulas.enumerated() {
    guard let r = bridge.render(latex: f, fontSize: 18, theme: theme),
          let tiff = r.image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("f\(i) nil（App 里显示源码）：\(f)")
        continue
    }
    let url = outDir.appendingPathComponent("f\(i).png")
    try png.write(to: url)
    print("f\(i) \(Int(r.size.width))×\(Int(r.size.height))pt → \(url.path)：\(f)")
}
